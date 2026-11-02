LinkStatus = require('celio_device').LinkStatus
CommandType = require('celio_device').CommandType

local Direction = {
  SERVER = "Server",
  CLIENT = "Client"
}

local create_celio_server = function (send)

  local celio_server = {
    _send = send,
    _server = LinkStatus.AwaitPlayerSettings,
    _client = LinkStatus.AwaitPlayerSettings,
  }

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_server:checkSendStartHandshake()
    if (celio_server._server == LinkStatus.HandshakeReceived and celio_server._client == LinkStatus.HandshakeReceived) then
      celio_server._send(Direction.CLIENT, "command", { commandType = CommandType.StartHandshake })
      celio_server._send(Direction.SERVER, "command", { CommandType.StartHandshake })
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  function celio_server:receive_status(source, status)
    console:log("Received raw status from " .. source .. ": " .. string.format("0x%x", status))

    -- local link is always two players, the emulated GBA is the master in seat 0
    if (status == LinkStatus.AwaitPlayerSettings) then
      console:log("Received status: AwaitPlayerSettings")
      if (source == Direction.CLIENT) then
        celio_server._send(Direction.CLIENT, "command", {
          commandType = CommandType.PlayerSettings,
          args = { playerCount = 2, playerIndex = 1 }
        })
      elseif (source == Direction.SERVER)  then
        celio_server._send(Direction.SERVER, "command", { CommandType.PlayerSettings, 2, 0 })
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
        celio_server._send(Direction.SERVER, "command", { CommandType.ConnectLink })
      elseif (source == Direction.SERVER)  then
        celio_server._server = LinkStatus.LinkConnected
        celio_server._send(Direction.CLIENT, "command", { commandType = CommandType.ConnectLink })
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

  -- data is a byte array of packets [seat, 8 little endian words]
  function celio_server:receive_data(source, data)
    if (source == Direction.SERVER) then
      celio_server._send(Direction.CLIENT, "data", data)
    elseif (source == Direction.CLIENT) then
      celio_server._send(Direction.SERVER, "data", data)
    end
  end

  return celio_server
end

return {
  create_celio_server = create_celio_server,
  Direction = Direction
}