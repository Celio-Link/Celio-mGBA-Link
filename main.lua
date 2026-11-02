local celio_device_factory = require'celio_device'
local celio_server_factory = require'celio_server'
Direction = require('celio_server').Direction
Mode = require('celio_device').Mode

local celio_device = nil
local server = nil
local watchpointId = nil

console:log("Celio-mGBA-Link Version 0.3")
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
      local tx_values_current = celio_device:transive(rx_value_current)

      -- SIOMULTI0-3 hold the value of each seat, the partners values are in ascending seat order, unused seats are 0xFFFF
      local tx_index = 1
      for seat = 0, 3 do
        local value = 0xFFFF
        if (seat == celio_device.seat) then
          value = rx_value_current
        elseif (seat < celio_device.player_count) then
          value = tx_values_current[tx_index]
          tx_index = tx_index + 1
        end
        emu.memory.io:write16(0x120 + seat * 2, value)
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

        -- only messages to the client are json encoded, the emulated device is called directly
        local celio_server = celio_server_factory.create_celio_server(function(dest, msg_type, body)
          if (dest == Direction.SERVER and celio_device ~= nil) then
            if (msg_type == "command") then
              celio_device:receive_command(body)
            elseif (msg_type == "data") then
              celio_device:receive_data(body)
            end
          elseif (dest == Direction.CLIENT) then
            ws:send(require'json'.encode({ type = msg_type, body = body }), require'websocket'.TEXT)
          end
        end)

        celio_device = celio_device_factory.create_celio_device(
          function(status) celio_server:receive_status(Direction.SERVER, status) end,
          function(data) celio_server:receive_data(Direction.SERVER, { string.byte(data, 1, -1) }) end
        )

        celio_device:receive_command({ CommandType.EmuSessionStart })

        ws:set_on_message(function(ws, message, opcode)
          -- legacy version check of clients that predate the json protocol
          if (message == "getVersion") then
            console:log("Sending version info")
            ws:send("0.3", require'websocket'.TEXT)
            return
          end

          local msg = require'json'.decode(message)

          if (msg.type == "versionRequest") then
            console:log("Sending version info")
            ws:send(require'json'.encode({ type = "version", body = "0.3" }), require'websocket'.TEXT)

          elseif (msg.type == "status") then
            celio_server:receive_status(Direction.CLIENT, msg.body)

          elseif (msg.type == "data") then
            celio_server:receive_data(Direction.CLIENT, msg.body)
            
          else
            console:warn("Ignoring message type: " .. tostring(msg.type))
          end
        end)

      end,

      celio_online = function(ws)

        celio_device = require'celio_device'.create_celio_device(
          function(status)
            ws:send(require'json'.encode({ type = "status", body = status }), require'websocket'.TEXT)
          end,
          function(data)
            local body = { string.byte(data, 1, -1) }
            ws:send(require'json'.encode({ type = "data", body = body }), require'websocket'.TEXT)
          end
        )

        ws:set_on_message(function(ws, message, opcode)
          if (opcode ~= require'websocket'.TEXT) then
            console:warn("Ignoring non-text message")
            return
          end

          -- legacy version check of clients that predate the json protocol
          if (message == "getVersion") then
            console:log("Sending version info")
            ws:send("0.3", require'websocket'.TEXT)
            return
          end

          local ok, msg = pcall(require'json'.decode, message)
          if (not ok or type(msg) ~= "table") then
            console:warn("Ignoring invalid json: " .. tostring(message))
            return
          end

          if (type(msg.type) ~= "string") then
            console:warn("Ignoring message without type: " .. message)
            return
          end

          local msg_type = msg.type

          if (msg_type == "versionRequest") then
            console:log("Sending version info")
            ws:send(require'json'.encode({ type = "version", body = "0.3" }), require'websocket'.TEXT)
            return
          end

          local body = {}
          if (msg.body ~= nil) then
            if (type(msg.body) ~= "table") then
              console:warn("Ignoring message with invalid body: " .. message)
              return
            end
            for i = 1, #msg.body do
              local value = math.tointeger(msg.body[i])
              if (value == nil or value < 0 or value > 0xFF) then
                console:warn("Ignoring message with non uint8 body value: " .. message)
                return
              end
              body[i] = value
            end
          end

          if (msg_type == "command") then
            celio_device:receive_command(body)
            return
          end

          if (msg_type == "data") then
            celio_device:receive_data(body)
            return
          end

          console:warn("Ignoring message type: " .. msg_type)

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