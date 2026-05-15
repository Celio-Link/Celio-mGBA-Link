local celio_device_factory = require'celio_device'
local celio_server_factory = require'celio_server'
Direction = require('celio_server').Direction

local celio_device = nil
local server = nil
local watchpointId = nil

console:log("Celio-mGBA-Link Version 0.1")
console:log("Wating for emulation to start")

local function start()

  console:log("Registering SIO watchpoint")

  watchpointId = emu:setWatchpoint(function ()
      local rx_value_current = emu.memory.io:read16(0x12A)
      if (celio_device == nil) then return end
      local tx_value_current = celio_device:transive(rx_value_current)
      emu.memory.io:write16(0x120, rx_value_current)
      emu.memory.io:write16(0x122, tx_value_current)
      emu.memory.io:write16(0x124, 0xFFFF)
      emu.memory.io:write16(0x126, 0xFFFF)
      console:log("" .. rx_value_current)
    end,
    0x4000120,
    C.WATCHPOINT_TYPE.READ
  )

  console:log("Starting websocket server \n")

  server = require'websocket'.server.listen
  {
    port = 51784,
    protocols = {
      celio_local = function(ws)

        local celio_server = celio_server_factory.create_celio_server(function(dest, message, opcode)
          if (dest == Direction.SERVER and celio_device ~= nil) then
            celio_device:receive(message, opcode)
          elseif (dest == Direction.CLIENT) then
            ws:send(message, opcode)
          end
        end)

        celio_device = celio_device_factory.create_celio_device(
          function(message) celio_server:receive(Direction.SERVER, tostring(message), require'websocket'.TEXT) end,
          function(message) celio_server:receive(Direction.SERVER, message, require'websocket'.BINARY) end
        )

        celio_device:receive_command(CommandType.EmuSessionStart)

        ws:set_on_message(function(ws, message, opcode)
          celio_server:receive(Direction.CLIENT, message, opcode)
        end)

      end,

      celio_online = function(ws)

        celio_device = require'celio_device'.create_celio_device(
          function(message) ws:send(tostring(message), require'websocket'.TEXT) end,
          function(message) ws:send(message, require'websocket'.BINARY) end
        )

        ws:set_on_message(function(ws, message, opcode)
          celio_device:receive(message, opcode)
        end)
      end,
    }
  }
end

local function stop()
    console:log("Stopping script")
    if (server ~= nil) then server.close(false) end
    if (watchpointId ~= nil and emu ~= nil) then emu:clearBreakpoint(watchpointId) end
end

if (emu ~= nil) then
  start()
else
  callbacks:add("start", start)
end

callbacks:add("stop", stop)