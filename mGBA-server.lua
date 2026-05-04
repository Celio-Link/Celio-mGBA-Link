

console:log("Starting websocket server")

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

local Source = {
  SERVER = 0,
  CLIENT = 1
}

local create_celio_server = function (ws)

  local celio_server = {
    _ws = ws,
    _celio_device = nil,
    _server = LinkStatus.AwaitMode,
    _client = LinkStatus.AwaitMode,
  }

  function celio_server:set_celio_device(device)
    celio_server._celio_device = device
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_server:checkSendStartHandshake()
    if (celio_server._server == LinkStatus.HandshakeReceived and celio_server._server == LinkStatus.HandshakeReceived) then
      celio_server._ws:send(tostring(CommandType.StartHandshake))
      celio_server._celio_device:receive_command(CommandType.StartHandshake)
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_server:receive_status(source, status)
    if (status == LinkStatus.AwaitMode) then
      console:log("Received status: AwaitMode")
      if (source == Source.CLIENT) then
        celio_server._ws:send(tostring(CommandType.SetModeMaster))
      elseif (source == Source.SERVER)  then
         celio_server._celio_device:receive_command(CommandType.SetModeSlave)
      end

    elseif (status == LinkStatus.HandshakeReceived) then
      console:log("Received status: HandshakeReceived")
      if (source == Source.CLIENT) then
        celio_server._client = LinkStatus.HandshakeReceived
      elseif (source == Source.SERVER)  then
        celio_server._server = LinkStatus.HandshakeReceived
      end
      celio_server:checkSendStartHandshake()

    elseif (status == LinkStatus.LinkConnected) then
      console:log("Received status: LinkConnected")
      if (source == Source.CLIENT) then
        celio_server._client = LinkStatus.LinkConnected
        celio_server._celio_device:receive_command(CommandType.ConnectLink)
      elseif (source == Source.SERVER)  then
        celio_server._server = LinkStatus.LinkConnected
        celio_server._ws:send(tostring(CommandType.ConnectLink))
      end
      
      elseif (status == LinkStatus.LinkReconnecting) then
        console:log("Received status: LinkReconnecting")
        if (source == Source.CLIENT) then
          celio_server._client = LinkStatus.LinkReconnecting
        elseif (source == Source.SERVER)  then
          celio_server._server = LinkStatus.LinkReconnecting
        end

    elseif (status == LinkStatus.LinkClosed) then
      console:log("Received status: LinkClosed")
      celio_server.state._client = LinkStatus.LinkClosed
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_server:receive_data(source, data)
    if (source == Source.SERVER) then
      celio_server._ws:send(data, require'websocket'.BINARY)
    elseif (source == Source.CLIENT) then
      celio_server._celio_device:receive_data(data)
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  return celio_server
end

local celio_device = nil
local celio_device_factory = require'celio_device'

local watchpointId = emu:setWatchpoint(function ()
    local rx_value_current = emu:read16(0x400012A)
    if (celio_device == nil) then return end
    local tx_value_current = celio_device:transive(rx_value_current)
    emu:write16(0x4000120, rx_value_current)
    emu:write16(0x4000122, tx_value_current)
    emu:write16(0x4000124, 0xFFFF)
    emu:write16(0x4000126, 0xFFFF)
  end,
  0x4000120,
  C.WATCHPOINT_TYPE.READ
)

local server = require'websocket'.server.listen
{
  port = 51784,
  protocols = {
    celio_local = function(ws)

      local celio_server = create_celio_server(ws)

      celio_device = celio_device_factory.create_celio_device(function(message, opcode)
        if (opcode == require'websocket'.TEXT) then
          console:log("Received raw status from emulated device: " .. string.format("0x%x", tonumber(message)))
          celio_server:receive_status(Source.SERVER, tonumber(message))
        elseif (opcode == require'websocket'.BINARY) then
          celio_server:receive_data(Source.SERVER, message)
        end
      end)

      celio_server:set_celio_device(celio_device)
      celio_device:receive_command(CommandType.EmuSessionStart)

      ws:set_on_message(function(ws, message, opcode)
        if (opcode == require'websocket'.TEXT) then
          console:log("Received raw status from socket: " .. string.format("0x%x", tonumber(message)))
          celio_server:receive_status(Source.CLIENT, tonumber(message))
        elseif (opcode == require'websocket'.BINARY) then
          celio_server:receive_data(Source.CLIENT, message)
        end
      end)

    end,

    celio_online = function(ws)

      celio_device = require'celio_device'.create_celio_device(function(message, opcode)
        ws:send(message, opcode)
      end)

      ws:set_on_message(function(ws, message, opcode)
        if (opcode == require'websocket'.TEXT) then
          console:log("Received raw status: " .. string.format("0x%x", tonumber(message)))
          celio_device:receive_command(tonumber(message))
        elseif (opcode == require'websocket'.BINARY) then
          celio_device:receive_data(message)
        end
      end)
    end,
  }
}
