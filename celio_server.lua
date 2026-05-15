LinkStatus = require('celio_device').LinkStatus
CommandType = require('celio_device').CommandType

local Direction = {
  SERVER = "Server",
  CLIENT = "Client"
}

local create_celio_server = function (send)

  local celio_server = {
    _send = send,
    _server = LinkStatus.AwaitMode,
    _client = LinkStatus.AwaitMode,
  }

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_server:checkSendStartHandshake()
    if (celio_server._server == LinkStatus.HandshakeReceived and celio_server._client == LinkStatus.HandshakeReceived) then
      celio_server._send(Direction.CLIENT, tostring(CommandType.StartHandshake), require'websocket'.TEXT)
      celio_server._send(Direction.SERVER, tostring(CommandType.StartHandshake), require'websocket'.TEXT)
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_server:receive_status(source, status)
    if (status == LinkStatus.AwaitMode) then
      console:log("Received status: AwaitMode")
      if (source == Direction.CLIENT) then
        celio_server._send(Direction.CLIENT, tostring(CommandType.SetModeMaster), require'websocket'.TEXT)
      elseif (source == Direction.SERVER)  then
        celio_server._send(Direction.SERVER, tostring(CommandType.SetModeSlave), require'websocket'.TEXT)
      end

    elseif (status == LinkStatus.HandshakeReceived) then
      console:log("Received status: HandshakeReceived")
      if (source == Direction.CLIENT) then
        celio_server._client = LinkStatus.HandshakeReceived
      elseif (source == Direction.SERVER)  then
        celio_server._server = LinkStatus.HandshakeReceived
      end
      celio_server:checkSendStartHandshake()

    elseif (status == LinkStatus.LinkConnected) then
      console:log("Received status: LinkConnected")
      if (source == Direction.CLIENT) then
        celio_server._client = LinkStatus.LinkConnected
        celio_server._send(Direction.SERVER, tostring(CommandType.ConnectLink), require'websocket'.TEXT)
      elseif (source == Direction.SERVER)  then
        celio_server._server = LinkStatus.LinkConnected
        celio_server._send(Direction.CLIENT, tostring(CommandType.ConnectLink), require'websocket'.TEXT)
      end

    elseif (status == LinkStatus.LinkReconnecting) then
      console:log("Received status: LinkReconnecting")
      if (source == Direction.CLIENT) then
        celio_server._client = LinkStatus.LinkReconnecting
      elseif (source == Direction.SERVER)  then
        celio_server._server = LinkStatus.LinkReconnecting
      end

    elseif (status == LinkStatus.LinkClosed) then
      console:log("Received status: LinkClosed")
      if (source == Direction.CLIENT) then
        celio_server._client = LinkStatus.LinkClosed
      elseif (source == Direction.SERVER)  then
        celio_server._server = LinkStatus.LinkClosed
      end
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_server:receive_data(source, data)
    if (source == Direction.SERVER) then
      celio_server._send(Direction.CLIENT, data, require'websocket'.BINARY)
    elseif (source == Direction.CLIENT) then
      celio_server._send(Direction.SERVER, data, require'websocket'.BINARY)
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_server:receive(source, message, opcode)
    if (opcode == require'websocket'.TEXT) then
      if (source == Direction.SERVER) then
        console:log("Received raw status from emulated device: " .. string.format("0x%x", tonumber(message)))
      end
      if (source == Direction.CLIENT) then 
        console:log("Received raw status from connected device: " .. string.format("0x%x", tonumber(message)))
      end
      celio_server:receive_status(source, tonumber(message))
    elseif (opcode == require'websocket'.BINARY) then
      celio_server:receive_data(source, message)
    end
  end

  return celio_server
end

return {
  create_celio_server = create_celio_server,
  Direction = Direction
}