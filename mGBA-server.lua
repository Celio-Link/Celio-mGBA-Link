

console:log("Starting websocket server")

local Handshake = {
  WAITING = "handshakeWaiting",
  RECEIVED = "handshakeReceived",
  START = "startHandshake",
  CONNECT = "handshakeConnect"
}

local Transive = {
  HANDSHAKE = 0,
  CRC = 1,
  COMMAND = 2
}

local create_celio_client = function(ws)
  local celio_client = {
    _server = Handshake.WAITING,
    _client = Handshake.WAITING,
    _transive_state = Transive.HANDSHAKE,
    _received_queue = {},
    _transmit_queue = {},
    _current_tx_command = {},
    _current_rx_command = {},
    _ws = ws
  }

  local rx_value_current = 0x00
  local tx_value_current = 0x00

  emu:setWatchpoint(function ()
      rx_value_current = emu:read16(0x400012A)
      tx_value_current = celio_client:transive(rx_value_current)
      emu:write16(0x4000120, rx_value_current)
      emu:write16(0x4000122, rx_value_current)
      console:log(string.format("0x%x", rx_value_current))
      console:log(string.format("0x%x", tx_value_current))
      console:log("\n")
    end,
    0x4000120,
    C.WATCHPOINT_TYPE.READ
  )

  function celio_client:transive(rx_value)
    if (celio_client._transive_state == Transive.HANDSHAKE) then
      return celio_client:transive_handshake(rx_value)
    end
    if (celio_client._transive_state == Transive.CRC) then
      return celio_client:transive_crc(rx_value)
    end
    if (celio_client._transive_state == Transive.COMMAND) then
      return celio_client:transive_command(rx_value)
    end
  end

  function celio_client:transive_handshake(rx_value)
    console:log("Handshake")
    if (rx_value == 0xB9A0) then
      if (celio_client._server == Handshake.WAITING) then
        celio_client._server = Handshake.RECEIVED
        celio_client._ws:send(Handshake.RECEIVED)
      end

      if (celio_client._client == Handshake.RECEIVED and
          celio_client._server == Handshake.RECEIVED) then
        celio_client._ws:send(Handshake.START)
        celio_client._client = Handshake.START
        celio_client._server = Handshake.START
      end
    end

    if (rx_value == 0x8FFF) then
      celio_client._ws:send(Handshake.CONNECT)
      celio_client._client = Handshake.CONNECT
      celio_client._server = Handshake.CONNECT

      celio_client._transive_state = Transive.CRC
    end

    if (celio_client._server == Handshake.WAITING or celio_client._server == Handshake.RECEIVED) then
      return 0xD15E
    end
    if (celio_client._server == Handshake.START or celio_client._server == Handshake.CONNECT) then
      return 0xB9A0
    end
  end

  function celio_client:transive_crc(rx_value)
    console:log("CRC")
    celio_client._transive_state = Transive.COMMAND
    return rx_value
  end

  local load_tx_command = function ()
    if (#celio_client._received_queue == 0) then
      celio_client._current_tx_command = {0,0,0,0,0,0,0,0}
    else
      for i = 1, 8 do
        local dequeued_value = table.remove(celio_client._received_queue)
        table.insert(celio_client._current_tx_command, dequeued_value)
      end
    end
  end

  local save_rx_command = function ()
    local queue_command = false
    for i = 1, #celio_client._current_rx_command do
      if celio_client._current_rx_command[i] ~= 0x00 then
        queue_command = true
        break
      end
    end

    if (queue_command) then
      for i = 1, 8 do
        local dequeued_value = table.remove(celio_client._current_rx_command, 1)
        table.insert(celio_client._transmit_queue, dequeued_value)
      end
    end
    celio_client._current_rx_command = {}
  end

  local flush_rx_queue = function ()
    local fmt = ">" .. string.rep("I2", #celio_client._transmit_queue)
    local data = string.pack(fmt, table.unpack(celio_client._transmit_queue))
    celio_client._transmit_queue = {}
    celio_client._ws:send(data, require'websocket'.BINARY)
  end

  function celio_client:transive_command(rx_value)
    console:log("Command")
    if (#celio_client._current_tx_command == 0) then
      load_tx_command()
    end

    table.insert(celio_client._current_rx_command, rx_value)

    if (#celio_client._current_rx_command == 8) then
      save_rx_command()
      celio_client._transive_state = Transive.CRC
    end

    if (#celio_client._transmit_queue >= 32) then
      flush_rx_queue()
    end

    return table.remove(celio_client._current_tx_command)
  end

  function celio_client:receive_command(command)
    if (command == Handshake.RECEIVED) then
        celio_client._client = Handshake.RECEIVED
        if (celio_client._server == Handshake.RECEIVED) then
          celio_client._ws:send(Handshake.START)
          celio_client._client = Handshake.START
          celio_client._server = Handshake.START
        end
      end
  end

  function celio_client:receive_data(data)
    if #data % 16 ~= 0 then
      console:error("Data is not a multiply of 16, data size: " .. #data)
      return
    end

    for i = 1, #data, 2 do
      local value = string.unpack(">I2", data, i)
      table.insert(celio_client._received_queue, value)
      end
  end

  return celio_client
end

local server = require'websocket'.server.listen
{
  port = 8080,
  protocols = {
    celio = function(ws)

      local celio_client = create_celio_client(ws)

      ws:send(Handshake.WAITING)

      ws:set_on_message(function(ws, message, opcode)
        if (opcode == require'websocket'.TEXT) then
          celio_client:receive_command(message)
        elseif (opcode == require'websocket'.BINARY) then
          celio_client:receive_data(message)
        end
      end)
    end
  }
}
