local celio_device_factory = require'celio_device'
local celio_server_factory = require'celio_server'
Direction = require('celio_server').Direction
Mode = require('celio_device').Mode

local celio_device = nil
local server = nil
local watchpointId = nil

console:log("Celio-mGBA-Link Version 0.2")
console:log("Waiting for emulation to start")

local function start()

  if (system.commit ~= "3da13060a586f2da8eb4ecbb167f642e2e4889c2") then
    console:error("This script is not comatible with the version of mGBA that it was loaded with.")
    console:log("Please visit https://github.com/Exormeter/mGBA_celio_edition/releases to obtain a compatible release and script")
    return
  end
  console:log("Registering SIO watchpoint")

  watchpointId = emu:setWatchpoint(
    function ()
      local rx_value_current = emu.memory.io:read16(0x12A)
      if (celio_device == nil) then return end
      local tx_value_current = celio_device:transive(rx_value_current)
      if (celio_device.mode == Mode.MASTER) then
        emu.memory.io:write16(0x120, tx_value_current)
        emu.memory.io:write16(0x122, rx_value_current)
        emu.memory.io:write16(0x124, 0xFFFF)
        emu.memory.io:write16(0x126, 0xFFFF)
      else
        emu.memory.io:write16(0x120, rx_value_current)
        emu.memory.io:write16(0x122, tx_value_current)
        emu.memory.io:write16(0x124, 0xFFFF)
        emu.memory.io:write16(0x126, 0xFFFF)
      end
      
    end,
    0x4000122,
    C.WATCHPOINT_TYPE.READ
  )

  console:log("Registering vblanck IRQ callback")

  callbacks:add("vblankIRQ",
    function ()
      if (celio_device == nil) then return end
      celio_device:sync_timer()
    end
  )

  console:log("Registering timer3 IRQ callback")

  callbacks:add("timer3IRQ",
    function ()
      if (celio_device == nil) then return end
      celio_device:transmission_timer()
    end
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
          if (opcode == require'websocket'.TEXT and message == "getVersion") then
            console:log("Sending version info")
            ws:send("0.2", require'websocket'.TEXT)
            return
          end
          celio_server:receive(Direction.CLIENT, message, opcode)
        end)

      end,

      celio_online = function(ws)

        celio_device = require'celio_device'.create_celio_device(
          function(message) ws:send(tostring(message), require'websocket'.TEXT) end,
          function(message) ws:send(message, require'websocket'.BINARY) end
        )

        ws:set_on_message(function(ws, message, opcode)
          if (opcode == require'websocket'.TEXT and message == "getVersion") then
            console:log("Sending version info")
            ws:send("0.2", require'websocket'.TEXT)
            return
          end
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