local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local stats  = require "stats"

package.path = package.path .. ";interface/?.lua;interface/?/init.lua"
local crawl = require "configcrawl"

-- luacheck: globals configure master loadSlave

function configure(parser)
	parser:description("Configuration based interface for MoonGen.")
	parser:option("-c --config", "Config file directory."):default("flows")
	parser:argument("txDev", "Device to transmit from."):convert(tonumber)
	parser:argument("rxDev", "Device to receive from."):convert(tonumber)
	parser:argument("flows", "List of flow names."):args "+"
end

function master(args)
	-- TODO figure out queue count
	local txDev = device.config{port = args.txDev, rxQueues = 1, txQueues = 1}
	local rxDev = device.config{port = args.rxDev, rxQueues = 1, txQueues = 1}
	device.waitForLinks()

	-- TODO rate limits

	local flowcfg = crawl()
	for _,fname in ipairs(args.flows) do
			local f = flowcfg[fname]

			if not f then
				print("Flow " .. fname .. " not found.")
			else
				mg.startTask("loadSlave", txDev:getTxQueue(0), rxDev, fname)
			end
		end

	mg.waitForTasks()
end

function loadSlave(txQueue, rxDev, fname)
	local flow = crawl()[fname] -- TODO improve
	-- TODO arp ?
	local mempool = memory.createMemPool(function(buf)
		buf["get" .. flow.packet.proto .. "Packet"](buf):fill(flow.packet.fillTbl)
	end)

	local bufs = mempool:bufArray()
	local txCtr = stats:newDevTxCounter(txQueue, "plain")
	local rxCtr = stats:newDevRxCounter(rxDev, "plain")

	-- start at 0 to leave first packet unchanged
	-- would skip first values of ranges otherwise
	local dynvarIndex, dynvarSize = 0, #flow.packet.dynvars

	while mg.running() do
		bufs:alloc(flow.packet.fillTbl.pktLength)

		for _, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			local dv = flow.packet.dynvars[dynvarIndex]

			dynvarIndex = dynvarIndex + 1
			if dynvarIndex > dynvarSize then
				dynvarIndex = 1
			end

			if dv then
				local var = pkt[dv.pkt][dv.var]
				if type(var) == "cdata" then
					var:set(dv.func())
				else
					pkt[dv.pkt][dv.var] = dv.func()
				end
			end
		end

		bufs:offloadUdpChecksums()
		txQueue:send(bufs)
		txCtr:update()
		rxCtr:update()
	end

	txCtr:finalize()
	rxCtr:finalize()
end
