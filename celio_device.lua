
local LinkStatus = {

  AwaitMode = 0xFF02,
  HandshakeReceived = 0xFF03,
  HandshakeFinished = 0xFF04,

  LinkConnected = 0xFF05,
  LinkReconnecting = 0xFF06,
  LinkClosed = 0xFF07,

  DeviceReady = 0xFF08,
  EmuTradeSessionFinished = 0xFF09,

  StatusDebug = 0xFFFF
}

local CommandType = {
  SetMode = 0x00,
  Cancel = 0x01,
  SetModeMaster = 0x10,
  SetModeSlave = 0x11,
  StartHandshake = 0x12,
  ConnectLink = 0x13,

  EmuSessionStart = 0xFF0A
}

local Transive = {
  HANDSHAKE = 0,
  CRC = 1,
  COMMAND = 2
}

local HandshakeState = {
  WAITING = 0,
  LISTENING = 1,
  WAITING_TO_RESPOND = 2,
  RESPONDING = 3
}

local create_celio_device = function(send)

  local create_state = function()
    local state = {
      _handshakeState = HandshakeState.WAITING,
      _transive_state = Transive.HANDSHAKE,

      _emu_reconnect = false,
      _gba_reconnect = false,
      _keep_alive = true,
   
      _received_queue = {},
      _transmit_queue = {},
      _current_tx_command = {},
      _current_rx_command = {}
    }
    return state
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  local celio_device = {
    state = create_state(),
    send = send
  }

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:transive(rx_value)
    if (celio_device.state._transive_state == Transive.HANDSHAKE) then
      return celio_device:transive_handshake(rx_value)
    end
    if (celio_device.state._transive_state == Transive.CRC) then
      return celio_device:transive_crc(rx_value)
    end
    if (celio_device.state._transive_state == Transive.COMMAND) then
      return celio_device:transive_command(rx_value)
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:transive_handshake(rx_value)
    if (rx_value == 0xB9A0 and celio_device.state._handshakeState == HandshakeState.LISTENING) then
        celio_device.send(tostring(LinkStatus.HandshakeReceived), require'websocket'.TEXT)
        celio_device.state_handshakeState = HandshakeState.WAITING_TO_RESPOND
    end

    if (rx_value == 0x8FFF) then
      celio_device.send(tostring(LinkStatus.LinkConnected), require'websocket'.TEXT)
      celio_device.state._transive_state = Transive.CRC
    end

    if (celio_device.state._handshakeState == HandshakeState.RESPONDING) then
      return 0xB9A0
    end

    return  0xD15E
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  local flush_rx_queue = function ()
    console:log("Flusing rx queue")
    for i = #celio_device.state._transmit_queue, 32 do
      table.insert(celio_device.state._transmit_queue, 0x00)
    end
    local fmt = ">" .. string.rep("I2", #celio_device.state._transmit_queue)
    local data = string.pack(fmt, table.unpack(celio_device.state._transmit_queue))
    celio_device.state._transmit_queue = {}
    celio_device.send(data, require'websocket'.BINARY)
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:transive_crc(rx_value)

    if (celio_device.state._emu_reconnect and celio_device.state._gba_reconnect) then
      console:log("Reconnecting...")
      flush_rx_queue()
      celio_device.send(tostring(LinkStatus.LinkReconnecting), require'websocket'.TEXT)
      celio_device.state = create_state()
    else
      celio_device.state._transive_state = Transive.COMMAND
    end
    return rx_value
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  local print_command_db = function (prefix, command)
    local print_command = false
    for i = 1, #command do
      if command[i] ~= 0x00 then
        print_command = true
        break
      end
    end

    local command_string = ""
    if (print_command) then
      for i = 1, #command do
        command_string = command_string .. string.format("0x%x", tonumber(command[i])) .. " "
      end
      console:log(prefix .. command_string)
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  local load_tx_command = function ()
    if (#celio_device.state._received_queue == 0) then
      celio_device.state._current_tx_command = {0,0,0,0,0,0,0,0}
    else
      for i = 1, 8 do
        local dequeued_value = table.remove(celio_device.state._received_queue, 1)
        local swapped = ((dequeued_value >> 8) | (dequeued_value << 8)) & 0xFFFF
        table.insert(celio_device.state._current_tx_command, swapped)
      end
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  local save_rx_command = function ()

    -- queue_command if not all zero or if a command is already in queue to avoid stalling
    local queue_command = false
    for i = 1, #celio_device.state._current_rx_command do
      if celio_device.state._current_rx_command[i] ~= 0x00 then
        queue_command = true
        break
      end
    end

    if (#celio_device.state._transmit_queue > 0) then
      queue_command = true
    end

    if (queue_command) then
      for i = 1, 8 do
        local dequeued_value = table.remove(celio_device.state._current_rx_command, 1)
        table.insert(celio_device.state._transmit_queue, dequeued_value)
      end
    end

    celio_device.state._current_rx_command = {}
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:transive_command(rx_value)

    table.insert(celio_device.state._current_rx_command, rx_value)

    if (#celio_device.state._current_tx_command == 0) then
      load_tx_command()
      if (celio_device.state._current_tx_command[1] == 0x5fff) then
        console:log("Client ready for reconnect")
        celio_device.state._emu_reconnect = true
      end
      print_command_db("tx command ", celio_device.state._current_tx_command)
    end

    if (#celio_device.state._current_rx_command == 8) then
      print_command_db("rx command ", celio_device.state._current_rx_command)

      if (celio_device.state._current_rx_command[1] == 0x5fff) then
        console:log("Server ready for reconnect")
        celio_device.state._gba_reconnect = true
      end
      save_rx_command()

      celio_device.state._transive_state = Transive.CRC
    end

    if (#celio_device.state._transmit_queue >= 32) then
      flush_rx_queue()
    end

    return table.remove(celio_device.state._current_tx_command, 1)
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:receive_command(command)
    if (command == CommandType.EmuSessionStart) then
      console:log("Received Command: EmuSessionStart")
      celio_device.send(tostring(LinkStatus.AwaitMode), require'websocket'.TEXT)

    elseif (command == CommandType.SetModeSlave) then
      console:log("Received Command: SetModeSlave")
      celio_device.state._handshakeState = HandshakeState.LISTENING

    elseif (command == CommandType.SetModeMaster) then
      console:error("master mode is currently not supported")

    elseif (command == CommandType.StartHandshake) then
      console:log("Received Command: StartHandshake")
      celio_device.state._handshakeState = HandshakeState.RESPONDING
    else
      console:warn("Received unknown command " .. tostring(command))
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:receive_data(data)
    for i = 1, #data, 2 do
      local value = string.unpack(">I2", data, i)
      table.insert(celio_device.state._received_queue, value)
      end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  return celio_device
end

return {
  create_celio_device = create_celio_device
}
