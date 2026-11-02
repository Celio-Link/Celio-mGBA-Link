
local LinkStatus = {
  AwaitModeEmulator = 0xFF01,
  AwaitPlayerSettings = 0xFF02,
  HandshakeReceived = 0xFF03,
  HandshakeFinished = 0xFF04,
  LinkConnected = 0xFF05,
  LinkReconnecting = 0xFF06,
  LinkClosed = 0xFF07,

  DeviceReady = 0xFF08,
  EmuTradeSessionFinished = 0xFF09,
  EmuSessionStarted = 0xFF0A,

  StatusDebug = 0xFFFF
}

local CommandType = {
  SetMode = 0x00,
  Cancel = 0x01,
  PlayerSettings = 0x10,
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

local Mode = {
  MASTER = 0,
  SLAVE = 1
}

local IE_REG = 0x200
local IF_REG = 0x202

local TM3CNT_L = 0x10C
local TM3CNT_H = 0x10E

local SIO_IRQ_IE_MASK = 0x80
local SIO_IRQ_IF_MASK = 0x80

local PACKET_SIZE = 17 -- seat byte + 8 little endian words
local MAX_BUFFERED_PACKETS = 3

local create_celio_device = function(emit_status_callback, emit_data_callback)

  local create_state = function(init)
    local state = {
      _handshakeState = HandshakeState.WAITING,
      _transive_state = Transive.HANDSHAKE,

      _emu_reconnect = false,
      _gba_reconnect = false,
      _keep_alive = true,
      _start_response = false,
      _start_connect = false, --this field is only relevent in master mode

      _received_queues = {}, -- received words, keyed by seat of the partner
      _transmit_queue = {}, -- rx commands of the GBA waiting to be flushed
      _current_tx_commands = {}, -- one command per partner, in ascending seat order
      _current_rx_command = {},
      _partner_reconnect = {},
      _empty_direction_streak = 0,

      _checksum = 0,

      _masterState = {
        timer_count = 0,
      }
    }
    if (not init) then state._handshakeState = HandshakeState.LISTENING end
    return state
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  local celio_device = {
    state = create_state(true),
    emit_status = emit_status_callback,
    emit_data = emit_data_callback,
    mode = Mode.SLAVE,
    timer_enabled = false,
    player_count = 2,
    seat = 0 -- seat of the emulated GBA, seat 0 is the master
  }

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  -- Seats of all other players in ascending order, which is the order their values are transmitted in
  function celio_device:partner_seats()
    local seats = {}
    for seat = 0, celio_device.player_count - 1 do
      if (seat ~= celio_device.seat) then table.insert(seats, seat) end
    end
    return seats
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  local for_each_partner = function (value)
    local values = {}
    for i = 1, celio_device.player_count - 1 do
      values[i] = value
    end
    return values
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:transive(rx_value)
    if (celio_device.state._transive_state == Transive.HANDSHAKE) then
      local tx_values = celio_device:transive_handshake(rx_value)
      -- console:log("Handshake - RX: " .. string.format("0x%x", rx_value) .. " TX: " .. string.format("0x%x", tx_value))
      --console:log("HandshakeState " .. tonumber(celio_device.state._handshakeState))
      return tx_values
    end
    if (celio_device.state._transive_state == Transive.CRC) then
      local tx_values = celio_device:transive_crc(rx_value)
      --console:log("CRC - RX: " .. string.format("0x%x", rx_value) .. " TX: " .. string.format("0x%x", tx_value))
      return tx_values
    end
    if (celio_device.state._transive_state == Transive.COMMAND) then
      local tx_values = celio_device:transive_command(rx_value)
      --console:log("Command - RX: " .. string.format("0x%x", rx_value) .. " TX: " .. string.format("0x%x", tx_value))
      return tx_values
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:enable_timer3()
    if (celio_device.state._masterState.timer_enabled) then
      return
    end
    celio_device.state._masterState.timer_enabled = true
    emu.memory.io:write16(0x10C, 0xFED0); -- Tim3 Reload Counter | OV at 197 ticks
    emu.memory.io:write16(TM3CNT_H, 0x00C1); -- Tim3 Enable | Request IRQ | 64 Prescaler
  end

    --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:disable_timer3()
    celio_device.state._masterState.timer_enabled = false
    celio_device.state._masterState.timer_count = 0
    emu.memory.io:write16(TM3CNT_H, 0x0000);
    emu.memory.io:write16(TM3CNT_L, 0x0000);
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:sync_timer()
    local ie_reg_value = emu.memory.io:read16(IE_REG)
    if (celio_device.mode == Mode.SLAVE or (ie_reg_value & SIO_IRQ_IE_MASK) == 0) then
      if (celio_device.state._masterState.timer_enabled) then
        celio_device:disable_timer3()
      end
      return
    end

    local if_reg_value = emu.memory.io:read16(IF_REG)
    if_reg_value = if_reg_value | SIO_IRQ_IF_MASK
    emu.memory.io:write16(IF_REG, if_reg_value)
    if (celio_device.state._transive_state == Transive.CRC) then
      celio_device:enable_timer3()
    end
    return true
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:transmission_timer()
    local ie_reg_value = emu.memory.io:read16(IE_REG)
    if (celio_device.mode == Mode.SLAVE or (ie_reg_value & SIO_IRQ_IE_MASK) == 0) then
      return
    end

    local if_reg_value = emu.memory.io:read16(IF_REG)
    if_reg_value = if_reg_value & 0xFFBF --Reset Tim3 irq IF
    if_reg_value = if_reg_value | SIO_IRQ_IF_MASK
    emu.memory.io:write16(IF_REG, if_reg_value)
    if (celio_device.state._masterState.timer_count == 7) then
      celio_device:disable_timer3()
      celio_device.state._masterState.timer_count = 0
    else
       celio_device.state._masterState.timer_count = celio_device.state._masterState.timer_count + 1
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  
  function celio_device:transive_handshake(rx_value)

    if (rx_value == 0xB9A0 and celio_device.state._handshakeState == HandshakeState.LISTENING) then
      celio_device.emit_status(LinkStatus.HandshakeReceived)
      celio_device.state._handshakeState = HandshakeState.WAITING_TO_RESPOND
    end

    -- the master (seat 0) is always the first partner, it sends the master handshake while the others keep responding
    if (celio_device.state._start_connect) then
      celio_device.emit_status(LinkStatus.LinkConnected)
      celio_device.state._transive_state = Transive.CRC
      local tx_values = for_each_partner(0xB9A0)
      tx_values[1] = 0x8FFF
      return tx_values
    end

    if (rx_value == 0x8FFF) then
      celio_device.emit_status(LinkStatus.LinkConnected)
      celio_device.state._transive_state = Transive.CRC
    end

    if (celio_device.state._handshakeState == HandshakeState.RESPONDING) then
      return for_each_partner(0xB9A0)
    end

    -- Fixes a race condition between setting RESPONDING and WAIT_TO_RESPONSE, to lazy to do it in a sane way
    if (celio_device.state._start_response) then celio_device.state._handshakeState = HandshakeState.RESPONDING end

    return for_each_partner(0xD15E)
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  -- Sends the queued commands as packets of [seat, 8 little endian words], same format as received
  local flush_rx_queue = function ()
    if (#celio_device.state._transmit_queue == 0) then return end
    console:log("Flusing rx queue")

    -- always send MAX_BUFFERED_PACKETS like the device does, padded with empty commands from the own seat
    while (#celio_device.state._transmit_queue < MAX_BUFFERED_PACKETS) do
      table.insert(celio_device.state._transmit_queue, {0,0,0,0,0,0,0,0})
    end

    local bytes = {}
    for _, command in ipairs(celio_device.state._transmit_queue) do
      table.insert(bytes, celio_device.seat)
      for _, word in ipairs(command) do
        table.insert(bytes, word & 0xFF)
        table.insert(bytes, (word >> 8) & 0xFF)
      end
    end
    celio_device.state._transmit_queue = {}
    celio_device.emit_data(string.char(table.unpack(bytes)))
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:transive_crc(rx_value)

    if (celio_device.state._emu_reconnect and celio_device.state._gba_reconnect) then
      flush_rx_queue()
      if (celio_device.state._keep_alive) then
        console:log("Emulated Device: Reconnecting...")
        celio_device.emit_status(LinkStatus.LinkReconnecting)
        celio_device.state = create_state(false)
      else
        console:log("Emulated Device: Link closed")
        celio_device.emit_status(LinkStatus.LinkClosed)
      end
      celio_device:disable_timer3()
    else
      celio_device.state._transive_state = Transive.COMMAND
    end

    local checksum = celio_device.state._checksum
    celio_device.state._checksum = 0
    return for_each_partner(checksum)
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

  local load_tx_commands = function ()
    celio_device.state._current_tx_commands = {}
    for i, seat in ipairs(celio_device:partner_seats()) do
      local queue = celio_device.state._received_queues[seat] or {}
      local command = {0,0,0,0,0,0,0,0}
      if (#queue > 0) then
        command = {}
        for j = 1, 8 do
          table.insert(command, table.remove(queue, 1))
        end
      end
      celio_device.state._current_tx_commands[i] = command
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  local save_rx_command = function ()

    -- "Packet inspect" and filter unneeded "direction none" commands so only one is transmitted per streak
    if (celio_device.state._current_rx_command[1] == 0xcafe and celio_device.state._current_rx_command[2] == 0x0011) then
      celio_device.state._empty_direction_streak = celio_device.state._empty_direction_streak + 1
      if (celio_device.state._empty_direction_streak > 1) then
        celio_device.state._current_rx_command[1] = 0x00
        celio_device.state._current_rx_command[2] = 0x00
      end
    else
      celio_device.state._empty_direction_streak = 0
    end

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
      print_command_db("rx command ", celio_device.state._current_rx_command)
      table.insert(celio_device.state._transmit_queue, celio_device.state._current_rx_command)
    end

    celio_device.state._current_rx_command = {}
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:transive_command(rx_value)

    table.insert(celio_device.state._current_rx_command, rx_value)

    if (#celio_device.state._current_tx_commands == 0 or #celio_device.state._current_tx_commands[1] == 0) then
      load_tx_commands()
      local all_partners_reconnect = true
      for i, command in ipairs(celio_device.state._current_tx_commands) do
        if (command[1] == 0xcafe and command[2] == 0x0017) then
          celio_device.state._keep_alive = false
        end
        if (command[1] == 0x5fff and not celio_device.state._partner_reconnect[i]) then
          console:log("Emulated Device: Partner " .. tostring(i) .. " ready for reconnect")
          celio_device.state._partner_reconnect[i] = true
        end
        all_partners_reconnect = all_partners_reconnect and celio_device.state._partner_reconnect[i] == true
        print_command_db("tx command " .. tostring(i) .. " ", command)
      end
      celio_device.state._emu_reconnect = all_partners_reconnect
    end

    if (#celio_device.state._current_rx_command == 8) then
      if (celio_device.state._current_rx_command[1] == 0x5fff) then
        console:log("Emulated Device: Ready for reconnect")
        celio_device.state._gba_reconnect = true
      end
      save_rx_command()

      celio_device.state._transive_state = Transive.CRC
    end

    if (#celio_device.state._transmit_queue >= MAX_BUFFERED_PACKETS) then
      flush_rx_queue()
    end

    local tx_values = {}
    for i, command in ipairs(celio_device.state._current_tx_commands) do
      tx_values[i] = table.remove(command, 1)
      celio_device.state._checksum = (celio_device.state._checksum + tx_values[i]) & 0xFFFF
    end
    celio_device.state._checksum = (celio_device.state._checksum + rx_value) & 0xFFFF

    return tx_values
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_device:receive_command(command)
    local commandType = command[1]

    if (commandType == CommandType.SetMode) then
      console:log("Emulated Device - Received Command: SetMode")
      celio_device.emit_status(LinkStatus.DeviceReady)
      celio_device.emit_status(LinkStatus.AwaitPlayerSettings)

    elseif (commandType == CommandType.EmuSessionStart) then
      console:log("Emulated Device - Received Command: EmuSessionStart")
      celio_device.emit_status(LinkStatus.AwaitPlayerSettings)

    elseif (commandType == CommandType.PlayerSettings) then
      celio_device.player_count = command[2]
      celio_device.seat = command[3]
      console:log("Emulated Device - Received Command: PlayerSettings, player count "
        .. tostring(celio_device.player_count) .. ", seat " .. tostring(celio_device.seat))
      celio_device.state._handshakeState = HandshakeState.LISTENING
      -- the emulated GBA in seat 0 is the master, so the device has to act as slave and vice versa
      if (celio_device.seat == 0) then
        celio_device.mode = Mode.SLAVE
        emu:setSioMaster()
      else
        celio_device.mode = Mode.MASTER
        emu:setSioSlave()
      end

    elseif (commandType == CommandType.StartHandshake) then
      console:log("Emulated Device - Received Command: StartHandshake")
      -- celio_device.state._handshakeState = HandshakeState.RESPONDING
      celio_device.state._start_response = true

    elseif (commandType == CommandType.ConnectLink) then
      console:log("Emulated Device - Received Command: ConnectLink")
      -- as seat 0 the emulated GBA sends the master handshake itself
      if (celio_device.seat ~= 0) then celio_device.state._start_connect = true end
      

    else
      console:warn("Received unknown command " .. tostring(command))
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  -- data is a list of packets [seat, 8 little endian words], each word is queued for the seat it came from
  function celio_device:receive_data(data)
    for offset = 1, #data - PACKET_SIZE + 1, PACKET_SIZE do
      local seat = data[offset]
      if (seat ~= celio_device.seat and seat < celio_device.player_count) then
        local queue = celio_device.state._received_queues[seat] or {}
        celio_device.state._received_queues[seat] = queue
        for i = offset + 1, offset + PACKET_SIZE - 1, 2 do
          table.insert(queue, data[i] | (data[i + 1] << 8))
        end
      end
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  return celio_device
end

return {
  LinkStatus = LinkStatus,
  CommandType = CommandType,
  Mode = Mode,
  create_celio_device = create_celio_device
}
