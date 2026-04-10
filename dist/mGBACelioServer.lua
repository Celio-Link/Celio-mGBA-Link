package.preload['base64'] = (function (...)

local base64 = {}

local function extract(v, from, width)
  return (v >> from) & ((1 << width) - 1)
end


function base64.makeencoder( s62, s63, spad )
	local encoder = {}
	for b64code, char in pairs{[0]='A','B','C','D','E','F','G','H','I','J',
		'K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y',
		'Z','a','b','c','d','e','f','g','h','i','j','k','l','m','n',
		'o','p','q','r','s','t','u','v','w','x','y','z','0','1','2',
		'3','4','5','6','7','8','9',s62 or '+',s63 or'/',spad or'='} do
		encoder[b64code] = char:byte()
	end
	return encoder
end

function base64.makedecoder( s62, s63, spad )
	local decoder = {}
	for b64code, charcode in pairs( base64.makeencoder( s62, s63, spad )) do
		decoder[charcode] = b64code
	end
	return decoder
end

local DEFAULT_ENCODER = base64.makeencoder()
local DEFAULT_DECODER = base64.makedecoder()

local char, concat = string.char, table.concat

function base64.encode( str, encoder, usecaching )
	encoder = encoder or DEFAULT_ENCODER
	local t, k, n = {}, 1, #str
	local lastn = n % 3
	local cache = {}
	for i = 1, n-lastn, 3 do
		local a, b, c = str:byte( i, i+2 )
		local v = a*0x10000 + b*0x100 + c
		local s
		if usecaching then
			s = cache[v]
			if not s then
				s = char(encoder[extract(v,18,6)], encoder[extract(v,12,6)], encoder[extract(v,6,6)], encoder[extract(v,0,6)])
				cache[v] = s
			end
		else
			s = char(encoder[extract(v,18,6)], encoder[extract(v,12,6)], encoder[extract(v,6,6)], encoder[extract(v,0,6)])
		end
		t[k] = s
		k = k + 1
	end
	if lastn == 2 then
		local a, b = str:byte( n-1, n )
		local v = a*0x10000 + b*0x100
		t[k] = char(encoder[extract(v,18,6)], encoder[extract(v,12,6)], encoder[extract(v,6,6)], encoder[64])
	elseif lastn == 1 then
		local v = str:byte( n )*0x10000
		t[k] = char(encoder[extract(v,18,6)], encoder[extract(v,12,6)], encoder[64], encoder[64])
	end
	return concat( t )
end

function base64.decode( b64, decoder, usecaching )
	decoder = decoder or DEFAULT_DECODER
	local pattern = '[^%w%+%/%=]'
	if decoder then
		local s62, s63
		for charcode, b64code in pairs( decoder ) do
			if b64code == 62 then s62 = charcode
			elseif b64code == 63 then s63 = charcode
			end
		end
		pattern = ('[^%%w%%%s%%%s%%=]'):format( char(s62), char(s63) )
	end
	b64 = b64:gsub( pattern, '' )
	local cache = usecaching and {}
	local t, k = {}, 1
	local n = #b64
	local padding = b64:sub(-2) == '==' and 2 or b64:sub(-1) == '=' and 1 or 0
	for i = 1, padding > 0 and n-4 or n, 4 do
		local a, b, c, d = b64:byte( i, i+3 )
		local s
		if usecaching then
			local v0 = a*0x1000000 + b*0x10000 + c*0x100 + d
			s = cache[v0]
			if not s then
				local v = decoder[a]*0x40000 + decoder[b]*0x1000 + decoder[c]*0x40 + decoder[d]
				s = char( extract(v,16,8), extract(v,8,8), extract(v,0,8))
				cache[v0] = s
			end
		else
			local v = decoder[a]*0x40000 + decoder[b]*0x1000 + decoder[c]*0x40 + decoder[d]
			s = char( extract(v,16,8), extract(v,8,8), extract(v,0,8))
		end
		t[k] = s
		k = k + 1
	end
	if padding == 1 then
		local a, b, c = b64:byte( n-3, n-1 )
		local v = decoder[a]*0x40000 + decoder[b]*0x1000 + decoder[c]*0x40
		t[k] = char( extract(v,16,8), extract(v,8,8))
	elseif padding == 2 then
		local a, b = b64:byte( n-3, n-2 )
		local v = decoder[a]*0x40000 + decoder[b]*0x1000
		t[k] = char( extract(v,16,8))
	end
	return concat( t )
end

return base64
 end)
package.preload['frame'] = (function (...)
-- Following Websocket RFC: http://tools.ietf.org/html/rfc6455

local ssub = string.sub
local sbyte = string.byte
local schar = string.char
local tinsert = table.insert
local tconcat = table.concat
local mmin = math.min
local mfloor = math.floor
local mrandom = math.random
local unpack = table.unpack
local tools = require'websocket.tools'
local write_int8 = tools.write_int8
local write_int16 = tools.write_int16
local write_int32 = tools.write_int32
local read_int8 = tools.read_int8
local read_int16 = tools.read_int16
local read_int32 = tools.read_int32

local bits = function(...)
  local n = 0
  for _,bitn in pairs{...} do
    n = n + 2^bitn
  end
  return n
end

local bit_7 = bits(7)
local bit_0_3 = bits(0,1,2,3)
local bit_0_6 = bits(0,1,2,3,4,5,6)

-- TODO: improve performance
local xor_mask = function(encoded,mask,payload)
  local transformed,transformed_arr = {},{}
  -- xor chunk-wise to prevent stack overflow.
  -- sbyte and schar multiple in/out values
  -- which require stack
  for p=1,payload,2000 do
    local last = mmin(p+1999,payload)
    local original = {sbyte(encoded,p,last)}
    for i=1,#original do
      local j = (i-1) % 4 + 1
      transformed[i] = original[i] ~ mask[j]
    end
    local xored = schar(unpack(transformed,1,#original))
    tinsert(transformed_arr,xored)
  end
  return tconcat(transformed_arr)
end

local encode_header_small = function(header, payload)
  return schar(header, payload)
end

local encode_header_medium = function(header, payload, len)
  return schar(header, payload, ((len >> 8) & 0xFF), (len & 0xFF))
end

local encode_header_big = function(header, payload, high, low)
  return schar(header, payload)..write_int32(high)..write_int32(low)
end

local encode = function(data, opcode, masked, fin)
  local header = opcode or 1-- TEXT is default opcode
  if fin == nil or fin == true then
    header = (header | bit_7)
  end
  local payload = 0
  if masked then
    payload = (payload | bit_7)
  end
  local len = #data
  local chunks = {}
  if len < 126 then
    payload = (payload | len)
    tinsert(chunks,encode_header_small(header,payload))
  elseif len <= 0xffff then
    payload = (payload | 126)
    tinsert(chunks,encode_header_medium(header,payload,len))
  elseif len < 2^53 then
    local high = mfloor(len/2^32)
    local low = len - high*2^32
    payload = (payload | 127)
    tinsert(chunks,encode_header_big(header,payload,high,low))
  end
  if not masked then
    tinsert(chunks,data)
  else
    local m1 = mrandom(0,0xff)
    local m2 = mrandom(0,0xff)
    local m3 = mrandom(0,0xff)
    local m4 = mrandom(0,0xff)
    local mask = {m1,m2,m3,m4}
    tinsert(chunks,write_int8(m1,m2,m3,m4))
    tinsert(chunks,xor_mask(data,mask,#data))
  end
  return tconcat(chunks)
end

local decode = function(encoded)
  local encoded_bak = encoded
  if #encoded < 2 then
    return nil,2-#encoded
  end
  local pos,header,payload
  pos,header = read_int8(encoded,1)
  pos,payload = read_int8(encoded,pos)
  local high,low
  encoded = ssub(encoded,pos)
  local bytes = 2
  local fin = (header & bit_7) > 0
  local opcode = (header & bit_0_3)
  local mask = (payload & bit_7) > 0
  payload = (payload & bit_0_6)
  if payload > 125 then
    if payload == 126 then
      if #encoded < 2 then
        return nil,2-#encoded
      end
      pos,payload = read_int16(encoded,1)
    elseif payload == 127 then
      if #encoded < 8 then
        return nil,8-#encoded
      end
      pos,high = read_int32(encoded,1)
      pos,low = read_int32(encoded,pos)
      payload = high*2^32 + low
      if payload < 0xffff or payload > 2^53 then
        assert(false,'INVALID PAYLOAD '..payload)
      end
    else
      assert(false,'INVALID PAYLOAD '..payload)
    end
    encoded = ssub(encoded,pos)
    bytes = bytes + pos - 1
  end
  local decoded
  if mask then
    local bytes_short = payload + 4 - #encoded
    if bytes_short > 0 then
      return nil,bytes_short
    end
    local m1,m2,m3,m4
    pos,m1 = read_int8(encoded,1)
    pos,m2 = read_int8(encoded,pos)
    pos,m3 = read_int8(encoded,pos)
    pos,m4 = read_int8(encoded,pos)
    encoded = ssub(encoded,pos)
    local mask = {
      m1,m2,m3,m4
    }
    decoded = xor_mask(encoded,mask,payload)
    bytes = bytes + 4 + payload
  else
    local bytes_short = payload - #encoded
    if bytes_short > 0 then
      return nil,bytes_short
    end
    if #encoded > payload then
      decoded = ssub(encoded,1,payload)
    else
      decoded = encoded
    end
    bytes = bytes + payload
  end
  return decoded,fin,opcode,encoded_bak:sub(bytes+1),mask
end

local encode_close = function(code,reason)
  if code then
    local data = write_int16(code)
    if reason then
      data = data..tostring(reason)
    end
    return data
  end
  return ''
end

local decode_close = function(data)
  local _,code,reason
  if data then
    if #data > 1 then
      _,code = read_int16(data,1)
    end
    if #data > 2 then
      reason = data:sub(3)
    end
  end
  return code,reason
end

return {
  encode = encode,
  decode = decode,
  encode_close = encode_close,
  decode_close = decode_close,
  encode_header_small = encode_header_small,
  encode_header_medium = encode_header_medium,
  encode_header_big = encode_header_big,
  CONTINUATION = 0,
  TEXT = 1,
  BINARY = 2,
  CLOSE = 8,
  PING = 9,
  PONG = 10
}
 end)
package.preload['handshake'] = (function (...)
local sha1 = require'websocket.tools'.sha1
local base64 = require'websocket.tools'.base64
local tinsert = table.insert

local guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local sec_websocket_accept = function(sec_websocket_key)
  local a = sec_websocket_key..guid
  local sha1 = sha1(a)
  assert((#sha1 % 2) == 0)
  return base64.encode(sha1)
end

local http_headers = function(request)
  local headers = {}
  if not request:match('.*HTTP/1%.1') then
    return headers
  end
  request = request:match('[^\r\n]+\r\n(.*)')
  local empty_line
  for line in request:gmatch('[^\r\n]*\r\n') do
    local name,val = line:match('([^%s]+)%s*:%s*([^\r\n]+)')
    if name and val then
      name = name:lower()
      if not name:match('sec%-websocket') then
        val = val:lower()
      end
      if not headers[name] then
        headers[name] = val
      else
        headers[name] = headers[name]..','..val
      end
    elseif line == '\r\n' then
      empty_line = true
    else
      assert(false,line..'('..#line..')')
    end
  end
  return headers,request:match('\r\n\r\n(.*)')
end

local upgrade_request = function(req)
  local format = string.format
  local lines = {
    format('GET %s HTTP/1.1',req.uri or ''),
    format('Host: %s',req.host),
    'Upgrade: websocket',
    'Connection: Upgrade',
    format('Sec-WebSocket-Key: %s',req.key),
    format('Sec-WebSocket-Protocol: %s',table.concat(req.protocols,', ')),
    'Sec-WebSocket-Version: 13',
  }
  if req.origin then
    tinsert(lines,string.format('Origin: %s',req.origin))
  end
  if req.port and req.port ~= 80 then
    lines[2] = format('Host: %s:%d',req.host,req.port)
  end
  tinsert(lines,'\r\n')
  return table.concat(lines,'\r\n')
end

local accept_upgrade = function(request, protocols)
  local headers = http_headers(request)

  if headers['upgrade'] ~= 'websocket' or
  not headers['connection'] or
  not headers['connection']:match('upgrade') or
  headers['sec-websocket-key'] == nil or
  headers['sec-websocket-version'] ~= '13' then
    return nil,'HTTP/1.1 400 Bad Request\r\n\r\n'
  end

  local prot = nil
  if headers['sec-websocket-protocol'] then
    for protocol in headers['sec-websocket-protocol']:gmatch('([^,%s]+)%s?,?') do
      if protocols[protocol] ~= nil then
        prot = protocol
      end
      if prot then
        break
      end
    end
  end

  local lines = {
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    string.format('Sec-WebSocket-Accept: %s',sec_websocket_accept(headers['sec-websocket-key'])),
  }

  if prot then  
    tinsert(lines,string.format('Sec-WebSocket-Protocol: %s',prot))
  end

  tinsert(lines,'\r\n')
  return table.concat(lines,'\r\n'),prot
end

return {
  sec_websocket_accept = sec_websocket_accept,
  http_headers = http_headers,
  accept_upgrade = accept_upgrade,
  upgrade_request = upgrade_request,
}
 end)
package.preload['server_client'] = (function (...)
local frame = require'websocket.frame'
local handshake = require'websocket.handshake'
local concat = table.concat
local insert = table.insert

--TODO absorb into client
local message_io = function(sock, on_message, on_error)
  local frames = {}
  local first_opcode

  local self = {}

  self.receive = function()

    local encoded, err = sock:receive(100000)

    if err then
      console:error('WS: Error on receive of package occured ' .. err)
      on_error(err)
      return
    end

    repeat
      local decoded, fin, opcode, rest = frame.decode(encoded)
      if decoded then
        if not first_opcode then
            first_opcode = opcode
        end
        insert(frames,decoded)
        encoded = rest
        if fin == true then
            on_message(concat(frames), first_opcode)
            frames = {}
            first_opcode = nil
        end
      end
    until not decoded

  end

  return self

end

local create_client = function(sock, opts)
  local handler = {
    _sock = sock,
    _receive_state = 'handshake',
    _state = 'OPEN',
    _message_io = nil,
    _callback_received_id = nil,
    _callback_error_id = nil,
    _user_on_close = nil,
    _user_on_error = nil,
    _user_on_message = nil,
    _opts = opts
  }

  handler._callback_received_id = handler._sock:add("received", function()
    if handler._state == 'CLOSED' then return end

    if handler._receive_state == 'handshake' then
      handler:exchange_handshake()
      handler._receive_state = 'frame'
    elseif handler._receive_state == 'frame' then
      handler._message_io:receive()
    end
  end)

  handler._callback_id = handler._sock:add("error", function()
    console:error("WS: An unknown error occured on the client socket")
    handler:handle_sock_err('unknown error')
  end)

  function handler:set_on_close(on_close_arg)
    self._user_on_close = on_close_arg
  end

  function handler:set_on_error(on_error_arg)
    self._user_on_error = on_error_arg
  end

  function handler:set_on_message(on_message_arg)
    self._user_on_message = on_message_arg
  end

  local function on_close(was_clean, code, reason)

    -- set everything to nil for good measure, we are done here
    handler._state = 'CLOSED'
    handler._sock:remove(handler._callback_received_id)
    handler._sock:remove(handler._callback_error_id)
    handler._sock:close()
    handler._sock = nil
    handler._message_io = nil
    handler._user_on_close = nil
    handler._user_on_error = nil
    handler._user_on_message = nil
    handler._opts = nil

    if handler._user_on_close then
      handler._user_on_close(handler, was_clean, code, reason or '')
    end

    console:log("WS: Socket closed, client disconnected")
  end

  local function handle_sock_err(err)
    if err == 'closed' and handler._state ~= 'CLOSED' then
        handler:close()
    else
      on_close(false, 1000, '')
    end
    if handler._user_on_close then
      handler._user_on_error(handler, err)
    end
  end

  function handler:send(message, opcode)
    local encoded = frame.encode(message, opcode or frame.TEXT)
    return sock:send(encoded)
  end

  --FIXME
  function handler:broadcast(...)
  end

  function handler:close(code, reason)
    code = code or 1000
    reason = reason or ''

    if self._state == 'OPEN' then
      self._state = 'CLOSING'
      local encoded = frame.encode_close(code, reason)
      encoded = frame.encode(encoded, frame.CLOSE)
      sock:send(encoded)
    end

    on_close(true, code, reason)
  end

  function handler:on_message(message, opcode)
    if opcode == frame.TEXT or opcode == frame.BINARY then
      self._user_on_message(self, message, opcode)
    elseif opcode == frame.CLOSE then
      if self._state ~= 'CLOSING' then
        self._state = 'CLOSING'
        local code, reason = frame.decode_close(message)
        local encoded = frame.encode_close(code)
        encoded = frame.encode(encoded,frame.CLOSE)
        sock:send(encoded)
        on_close(true, code or 1006, reason)
      else
        on_close(true, 1006, '')
      end
    end
  end

  function handler:exchange_handshake()
    console:log("WS: Handshake received \n")
    local request = {}

    local buffer = self._sock:receive(1024)

    repeat
      local line_end = buffer:find("\r\n", 1, true)
      local line = buffer:sub(1, line_end - 1)
      buffer = buffer:sub(line_end + 2)
      request[#request+1] = line
      console:log(line)
    until line == ''

    local upgrade_request = concat(request,'\r\n')
    local response, protocol = handshake.accept_upgrade(upgrade_request, self._opts.protocols)

    console:log(response)

    if not response then
      console:error('WS: Handshake failed, Request:')
      console:log(upgrade_request)
      self.close(nil, nil)
      return
    end

    local sent, err = self._sock:send(response)

    if err then
      console:log('WS: Websocket client closed while handshake ' .. err)
      self.close(nil, nil)
      return
    end

    self:accept_client(protocol)
  end

  function handler:accept_client(protocol)

    local protocol_handler

    if protocol and opts.protocols[protocol] then
      console:log("WS: Using " .. protocol .. " protocol")
      protocol_handler = opts.protocols[protocol]
    elseif opts.default then
      console:log("WS: Using default protocol")
      protocol_handler = opts.default
    else
      console:error('WS: No Protocol is matching and no default one has been assinged. Closing.')
      handler:close(1006, 'Wrong Protocol')
      return
    end

    protocol_handler(handler)
  end

  handler._message_io = message_io(
    sock,
    function(...)
      console:log("WS: Received frame")
      handler:on_message(...)
    end,
    handle_sock_err
  )

  return handler
end

return {
  create_client = create_client
} end)
package.preload['server'] = (function (...)
local insert = table.insert
local remove = table.remove

local clientFactory = require'websocket.server_client'

local listener = {}
local clients = {}

--////////////////////////////////////////////////////////////////////////////////////////////////////////--

local listen = function(opts)
  local self = {}

  assert(opts and (opts.protocols or opts.default))

  console:log("WS: Start listening on port " .. opts.port)
  listener = socket.bind(nil , opts.port)

  if not listener then
    console:error("WS: Listening filed with error. Port already in use?")
    return
  else
    console:log("WS: Listening...")
  end

  listener:add("received", function() self.socket_accept() end)
  listener:listen()

  self.sock = function()
    return listener
  end

  self.close = function(keep_clients)
    listener:close()
    listener = nil
    if not keep_clients then
      for client in clients do
        client:close()
      end
    end
  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  self.socket_accept = function()
    local client_sock = listener:accept()

    if not client_sock then
      console:error("WS: Error when accepting connection")
      return
    end

    local client = clientFactory.create_client(client_sock, opts)

    client:set_on_close(
      function(handler, was_clean, code, reason)
        for index, tempClient in ipairs(clients) do
          if (tempClient == handler) then
            remove(clients, index)
          end
        end
      end
    )

    insert(clients, client)

  end

  --////////////////////////////////////////////////////////////////////////////////////////////////////////--

  return self
end

--////////////////////////////////////////////////////////////////////////////////////////////////////////--

return {
  listen = listen
}

--////////////////////////////////////////////////////////////////////////////////////////////////////////--
 end)
package.preload['sha1'] = (function (...)

local function ZERO()
   return {
      false, false, false, false,     false, false, false, false, 
      false, false, false, false,     false, false, false, false, 
      false, false, false, false,     false, false, false, false, 
      false, false, false, false,     false, false, false, false, 
   }
end

local hex_to_bits = {
   ["0"] = { false, false, false, false },
   ["1"] = { false, false, false, true  },
   ["2"] = { false, false, true,  false },
   ["3"] = { false, false, true,  true  },

   ["4"] = { false, true,  false, false },
   ["5"] = { false, true,  false, true  },
   ["6"] = { false, true,  true,  false },
   ["7"] = { false, true,  true,  true  },

   ["8"] = { true,  false, false, false },
   ["9"] = { true,  false, false, true  },
   ["A"] = { true,  false, true,  false },
   ["B"] = { true,  false, true,  true  },

   ["C"] = { true,  true,  false, false },
   ["D"] = { true,  true,  false, true  },
   ["E"] = { true,  true,  true,  false },
   ["F"] = { true,  true,  true,  true  },

   ["a"] = { true,  false, true,  false },
   ["b"] = { true,  false, true,  true  },
   ["c"] = { true,  true,  false, false },
   ["d"] = { true,  true,  false, true  },
   ["e"] = { true,  true,  true,  false },
   ["f"] = { true,  true,  true,  true  },
}

--
-- Given a string of 8 hex digits, return a W32 object representing that number
--
local function from_hex(hex)

   assert(type(hex) == 'string')
   assert(hex:match('^[0123456789abcdefABCDEF]+$'))
   assert(#hex == 8)

   local W32 = { }

   for letter in hex:gmatch('.') do
      local b = hex_to_bits[letter]
      assert(b)
      table.insert(W32, 1, b[1])
      table.insert(W32, 1, b[2])
      table.insert(W32, 1, b[3])
      table.insert(W32, 1, b[4])
   end

   return W32
end

local function COPY(old)
   local W32 = { }
   for k,v in pairs(old) do
      W32[k] = v
   end

   return W32
end

local function ADD(first, ...)

   local a = COPY(first)

   local C, b, sum

   for v = 1, select('#', ...) do
      b = select(v, ...)
      C = 0

      for i = 1, #a do
         sum = (a[i] and 1 or 0)
             + (b[i] and 1 or 0)
             + C

         if sum == 0 then
            a[i] = false
            C    = 0
         elseif sum == 1 then
            a[i] = true
            C    = 0
         elseif sum == 2 then
            a[i] = false
            C    = 1
         else
            a[i] = true
            C    = 1
         end
      end
      -- we drop any ending carry

   end

   return a
end

local function XOR(first, ...)

   local a = COPY(first)
   local b
   for v = 1, select('#', ...) do
      b = select(v, ...)
      for i = 1, #a do
         a[i] = a[i] ~= b[i]
      end
   end

   return a

end

local function AND(a, b)

   local c = ZERO()

   for i = 1, #a do
      -- only need to set true bits; other bits remain false
      if  a[i] and b[i] then
         c[i] = true
      end
   end

   return c
end

local function OR(a, b)

   local c = ZERO()

   for i = 1, #a do
      -- only need to set true bits; other bits remain false
      if  a[i] or b[i] then
         c[i] = true
      end
   end

   return c
end

local function OR3(a, b, c)

   local d = ZERO()

   for i = 1, #a do
      -- only need to set true bits; other bits remain false
      if a[i] or b[i] or c[i] then
         d[i] = true
      end
   end

   return d
end

local function NOT(a)

   local b = ZERO()

   for i = 1, #a do
      -- only need to set true bits; other bits remain false
      if not a[i] then
         b[i] = true
      end
   end

   return b
end

local function ROTATE(bits, a)

   local b = COPY(a)

   while bits > 0 do
      bits = bits - 1
      table.insert(b, 1, table.remove(b))
   end

   return b

end


local binary_to_hex = {
   ["0000"] = "0",
   ["0001"] = "1",
   ["0010"] = "2",
   ["0011"] = "3",
   ["0100"] = "4",
   ["0101"] = "5",
   ["0110"] = "6",
   ["0111"] = "7",
   ["1000"] = "8",
   ["1001"] = "9",
   ["1010"] = "a",
   ["1011"] = "b",
   ["1100"] = "c",
   ["1101"] = "d",
   ["1110"] = "e",
   ["1111"] = "f",
}

function asHEX(a)

   local hex = ""
   local i = 1
   while i < #a do
      local binary = (a[i + 3] and '1' or '0')
                     ..
                     (a[i + 2] and '1' or '0')
                     ..
                     (a[i + 1] and '1' or '0')
                     ..
                     (a[i + 0] and '1' or '0')

      hex = binary_to_hex[binary] .. hex

      i = i + 4
   end

   return hex

end

local x67452301 = from_hex("67452301")
local xEFCDAB89 = from_hex("EFCDAB89")
local x98BADCFE = from_hex("98BADCFE")
local x10325476 = from_hex("10325476")
local xC3D2E1F0 = from_hex("C3D2E1F0")

local x5A827999 = from_hex("5A827999")
local x6ED9EBA1 = from_hex("6ED9EBA1")
local x8F1BBCDC = from_hex("8F1BBCDC")
local xCA62C1D6 = from_hex("CA62C1D6")


function sha1(msg)

   assert(type(msg) == 'string')
   assert(#msg < 0x7FFFFFFF) -- have no idea what would happen if it were large

   local H0 = x67452301
   local H1 = xEFCDAB89
   local H2 = x98BADCFE
   local H3 = x10325476
   local H4 = xC3D2E1F0

   local msg_len_in_bits = #msg * 8

   local first_append = string.char(0x80) -- append a '1' bit plus seven '0' bits

   local non_zero_message_bytes = #msg +1 +8 -- the +1 is the appended bit 1, the +8 are for the final appended length
   local current_mod = non_zero_message_bytes % 64
   local second_append = ""
   if current_mod ~= 0 then
      second_append = string.rep(string.char(0), 64 - current_mod)
   end

   -- now to append the length as a 64-bit number.
   local B1, R1 = math.modf(msg_len_in_bits  / 0x01000000)
   local B2, R2 = math.modf( 0x01000000 * R1 / 0x00010000)
   local B3, R3 = math.modf( 0x00010000 * R2 / 0x00000100)
   local B4     =            0x00000100 * R3

   local L64 = string.char( 0) .. string.char( 0) .. string.char( 0) .. string.char( 0) -- high 32 bits
            .. string.char(B1) .. string.char(B2) .. string.char(B3) .. string.char(B4) --  low 32 bits



   msg = msg .. first_append .. second_append .. L64         

   assert(#msg % 64 == 0)

   --local fd = io.open("/tmp/msg", "wb")
   --fd:write(msg)
   --fd:close()

   local chunks = #msg / 64

   local W = { }
   local start, A, B, C, D, E, f, K, TEMP
   local chunk = 0

   while chunk < chunks do
      --
      -- break chunk up into W[0] through W[15]
      --
      start = chunk * 64 + 1
      chunk = chunk + 1

      for t = 0, 15 do
         W[t] = from_hex(string.format("%02x%02x%02x%02x", msg:byte(start, start + 3)))
         start = start + 4
      end

      --
      -- build W[16] through W[79]
      --
      for t = 16, 79 do
         -- For t = 16 to 79 let Wt = S1(Wt-3 XOR Wt-8 XOR Wt-14 XOR Wt-16). 
         W[t] = ROTATE(1, XOR(W[t-3], W[t-8], W[t-14], W[t-16]))
      end

      A = H0
      B = H1
      C = H2
      D = H3
      E = H4

      for t = 0, 79 do
         if t <= 19 then
            -- (B AND C) OR ((NOT B) AND D)
            f = OR(AND(B, C), AND(NOT(B), D))
            K = x5A827999
         elseif t <= 39 then
            -- B XOR C XOR D
            f = XOR(B, C, D)
            K = x6ED9EBA1
         elseif t <= 59 then
            -- (B AND C) OR (B AND D) OR (C AND D
            f = OR3(AND(B, C), AND(B, D), AND(C, D))
            K = x8F1BBCDC
         else
            -- B XOR C XOR D
            f = XOR(B, C, D)
            K = xCA62C1D6
         end

         -- TEMP = S5(A) + ft(B,C,D) + E + Wt + Kt; 
         TEMP = ADD(ROTATE(5, A), f, E, W[t], K)

         --E = D; 　　D = C; 　　　C = S30(B);　　 B = A; 　　A = TEMP;
         E = D
         D = C
         C = ROTATE(30, B)
         B = A
         A = TEMP

         --printf("t = %2d: %s  %s  %s  %s  %s", t, A:HEX(), B:HEX(), C:HEX(), D:HEX(), E:HEX())
      end

      -- Let H0 = H0 + A, H1 = H1 + B, H2 = H2 + C, H3 = H3 + D, H4 = H4 + E. 
      H0 = ADD(H0, A)
      H1 = ADD(H1, B)
      H2 = ADD(H2, C)
      H3 = ADD(H3, D)
      H4 = ADD(H4, E)
   end

   return asHEX(H0) .. asHEX(H1) .. asHEX(H2) .. asHEX(H3) .. asHEX(H4)
end

local function hex_to_binary(hex)
   return hex:gsub('..', function(hexval)
                            return string.char(tonumber(hexval, 16))
                         end)
end

function sha1_binary(msg)
   return hex_to_binary(sha1(msg))
end

local xor_with_0x5c = {
   [string.char(  0)] = string.char( 92),   [string.char(  1)] = string.char( 93),
   [string.char(  2)] = string.char( 94),   [string.char(  3)] = string.char( 95),
   [string.char(  4)] = string.char( 88),   [string.char(  5)] = string.char( 89),
   [string.char(  6)] = string.char( 90),   [string.char(  7)] = string.char( 91),
   [string.char(  8)] = string.char( 84),   [string.char(  9)] = string.char( 85),
   [string.char( 10)] = string.char( 86),   [string.char( 11)] = string.char( 87),
   [string.char( 12)] = string.char( 80),   [string.char( 13)] = string.char( 81),
   [string.char( 14)] = string.char( 82),   [string.char( 15)] = string.char( 83),
   [string.char( 16)] = string.char( 76),   [string.char( 17)] = string.char( 77),
   [string.char( 18)] = string.char( 78),   [string.char( 19)] = string.char( 79),
   [string.char( 20)] = string.char( 72),   [string.char( 21)] = string.char( 73),
   [string.char( 22)] = string.char( 74),   [string.char( 23)] = string.char( 75),
   [string.char( 24)] = string.char( 68),   [string.char( 25)] = string.char( 69),
   [string.char( 26)] = string.char( 70),   [string.char( 27)] = string.char( 71),
   [string.char( 28)] = string.char( 64),   [string.char( 29)] = string.char( 65),
   [string.char( 30)] = string.char( 66),   [string.char( 31)] = string.char( 67),
   [string.char( 32)] = string.char(124),   [string.char( 33)] = string.char(125),
   [string.char( 34)] = string.char(126),   [string.char( 35)] = string.char(127),
   [string.char( 36)] = string.char(120),   [string.char( 37)] = string.char(121),
   [string.char( 38)] = string.char(122),   [string.char( 39)] = string.char(123),
   [string.char( 40)] = string.char(116),   [string.char( 41)] = string.char(117),
   [string.char( 42)] = string.char(118),   [string.char( 43)] = string.char(119),
   [string.char( 44)] = string.char(112),   [string.char( 45)] = string.char(113),
   [string.char( 46)] = string.char(114),   [string.char( 47)] = string.char(115),
   [string.char( 48)] = string.char(108),   [string.char( 49)] = string.char(109),
   [string.char( 50)] = string.char(110),   [string.char( 51)] = string.char(111),
   [string.char( 52)] = string.char(104),   [string.char( 53)] = string.char(105),
   [string.char( 54)] = string.char(106),   [string.char( 55)] = string.char(107),
   [string.char( 56)] = string.char(100),   [string.char( 57)] = string.char(101),
   [string.char( 58)] = string.char(102),   [string.char( 59)] = string.char(103),
   [string.char( 60)] = string.char( 96),   [string.char( 61)] = string.char( 97),
   [string.char( 62)] = string.char( 98),   [string.char( 63)] = string.char( 99),
   [string.char( 64)] = string.char( 28),   [string.char( 65)] = string.char( 29),
   [string.char( 66)] = string.char( 30),   [string.char( 67)] = string.char( 31),
   [string.char( 68)] = string.char( 24),   [string.char( 69)] = string.char( 25),
   [string.char( 70)] = string.char( 26),   [string.char( 71)] = string.char( 27),
   [string.char( 72)] = string.char( 20),   [string.char( 73)] = string.char( 21),
   [string.char( 74)] = string.char( 22),   [string.char( 75)] = string.char( 23),
   [string.char( 76)] = string.char( 16),   [string.char( 77)] = string.char( 17),
   [string.char( 78)] = string.char( 18),   [string.char( 79)] = string.char( 19),
   [string.char( 80)] = string.char( 12),   [string.char( 81)] = string.char( 13),
   [string.char( 82)] = string.char( 14),   [string.char( 83)] = string.char( 15),
   [string.char( 84)] = string.char(  8),   [string.char( 85)] = string.char(  9),
   [string.char( 86)] = string.char( 10),   [string.char( 87)] = string.char( 11),
   [string.char( 88)] = string.char(  4),   [string.char( 89)] = string.char(  5),
   [string.char( 90)] = string.char(  6),   [string.char( 91)] = string.char(  7),
   [string.char( 92)] = string.char(  0),   [string.char( 93)] = string.char(  1),
   [string.char( 94)] = string.char(  2),   [string.char( 95)] = string.char(  3),
   [string.char( 96)] = string.char( 60),   [string.char( 97)] = string.char( 61),
   [string.char( 98)] = string.char( 62),   [string.char( 99)] = string.char( 63),
   [string.char(100)] = string.char( 56),   [string.char(101)] = string.char( 57),
   [string.char(102)] = string.char( 58),   [string.char(103)] = string.char( 59),
   [string.char(104)] = string.char( 52),   [string.char(105)] = string.char( 53),
   [string.char(106)] = string.char( 54),   [string.char(107)] = string.char( 55),
   [string.char(108)] = string.char( 48),   [string.char(109)] = string.char( 49),
   [string.char(110)] = string.char( 50),   [string.char(111)] = string.char( 51),
   [string.char(112)] = string.char( 44),   [string.char(113)] = string.char( 45),
   [string.char(114)] = string.char( 46),   [string.char(115)] = string.char( 47),
   [string.char(116)] = string.char( 40),   [string.char(117)] = string.char( 41),
   [string.char(118)] = string.char( 42),   [string.char(119)] = string.char( 43),
   [string.char(120)] = string.char( 36),   [string.char(121)] = string.char( 37),
   [string.char(122)] = string.char( 38),   [string.char(123)] = string.char( 39),
   [string.char(124)] = string.char( 32),   [string.char(125)] = string.char( 33),
   [string.char(126)] = string.char( 34),   [string.char(127)] = string.char( 35),
   [string.char(128)] = string.char(220),   [string.char(129)] = string.char(221),
   [string.char(130)] = string.char(222),   [string.char(131)] = string.char(223),
   [string.char(132)] = string.char(216),   [string.char(133)] = string.char(217),
   [string.char(134)] = string.char(218),   [string.char(135)] = string.char(219),
   [string.char(136)] = string.char(212),   [string.char(137)] = string.char(213),
   [string.char(138)] = string.char(214),   [string.char(139)] = string.char(215),
   [string.char(140)] = string.char(208),   [string.char(141)] = string.char(209),
   [string.char(142)] = string.char(210),   [string.char(143)] = string.char(211),
   [string.char(144)] = string.char(204),   [string.char(145)] = string.char(205),
   [string.char(146)] = string.char(206),   [string.char(147)] = string.char(207),
   [string.char(148)] = string.char(200),   [string.char(149)] = string.char(201),
   [string.char(150)] = string.char(202),   [string.char(151)] = string.char(203),
   [string.char(152)] = string.char(196),   [string.char(153)] = string.char(197),
   [string.char(154)] = string.char(198),   [string.char(155)] = string.char(199),
   [string.char(156)] = string.char(192),   [string.char(157)] = string.char(193),
   [string.char(158)] = string.char(194),   [string.char(159)] = string.char(195),
   [string.char(160)] = string.char(252),   [string.char(161)] = string.char(253),
   [string.char(162)] = string.char(254),   [string.char(163)] = string.char(255),
   [string.char(164)] = string.char(248),   [string.char(165)] = string.char(249),
   [string.char(166)] = string.char(250),   [string.char(167)] = string.char(251),
   [string.char(168)] = string.char(244),   [string.char(169)] = string.char(245),
   [string.char(170)] = string.char(246),   [string.char(171)] = string.char(247),
   [string.char(172)] = string.char(240),   [string.char(173)] = string.char(241),
   [string.char(174)] = string.char(242),   [string.char(175)] = string.char(243),
   [string.char(176)] = string.char(236),   [string.char(177)] = string.char(237),
   [string.char(178)] = string.char(238),   [string.char(179)] = string.char(239),
   [string.char(180)] = string.char(232),   [string.char(181)] = string.char(233),
   [string.char(182)] = string.char(234),   [string.char(183)] = string.char(235),
   [string.char(184)] = string.char(228),   [string.char(185)] = string.char(229),
   [string.char(186)] = string.char(230),   [string.char(187)] = string.char(231),
   [string.char(188)] = string.char(224),   [string.char(189)] = string.char(225),
   [string.char(190)] = string.char(226),   [string.char(191)] = string.char(227),
   [string.char(192)] = string.char(156),   [string.char(193)] = string.char(157),
   [string.char(194)] = string.char(158),   [string.char(195)] = string.char(159),
   [string.char(196)] = string.char(152),   [string.char(197)] = string.char(153),
   [string.char(198)] = string.char(154),   [string.char(199)] = string.char(155),
   [string.char(200)] = string.char(148),   [string.char(201)] = string.char(149),
   [string.char(202)] = string.char(150),   [string.char(203)] = string.char(151),
   [string.char(204)] = string.char(144),   [string.char(205)] = string.char(145),
   [string.char(206)] = string.char(146),   [string.char(207)] = string.char(147),
   [string.char(208)] = string.char(140),   [string.char(209)] = string.char(141),
   [string.char(210)] = string.char(142),   [string.char(211)] = string.char(143),
   [string.char(212)] = string.char(136),   [string.char(213)] = string.char(137),
   [string.char(214)] = string.char(138),   [string.char(215)] = string.char(139),
   [string.char(216)] = string.char(132),   [string.char(217)] = string.char(133),
   [string.char(218)] = string.char(134),   [string.char(219)] = string.char(135),
   [string.char(220)] = string.char(128),   [string.char(221)] = string.char(129),
   [string.char(222)] = string.char(130),   [string.char(223)] = string.char(131),
   [string.char(224)] = string.char(188),   [string.char(225)] = string.char(189),
   [string.char(226)] = string.char(190),   [string.char(227)] = string.char(191),
   [string.char(228)] = string.char(184),   [string.char(229)] = string.char(185),
   [string.char(230)] = string.char(186),   [string.char(231)] = string.char(187),
   [string.char(232)] = string.char(180),   [string.char(233)] = string.char(181),
   [string.char(234)] = string.char(182),   [string.char(235)] = string.char(183),
   [string.char(236)] = string.char(176),   [string.char(237)] = string.char(177),
   [string.char(238)] = string.char(178),   [string.char(239)] = string.char(179),
   [string.char(240)] = string.char(172),   [string.char(241)] = string.char(173),
   [string.char(242)] = string.char(174),   [string.char(243)] = string.char(175),
   [string.char(244)] = string.char(168),   [string.char(245)] = string.char(169),
   [string.char(246)] = string.char(170),   [string.char(247)] = string.char(171),
   [string.char(248)] = string.char(164),   [string.char(249)] = string.char(165),
   [string.char(250)] = string.char(166),   [string.char(251)] = string.char(167),
   [string.char(252)] = string.char(160),   [string.char(253)] = string.char(161),
   [string.char(254)] = string.char(162),   [string.char(255)] = string.char(163),
}

local xor_with_0x36 = {
   [string.char(  0)] = string.char( 54),   [string.char(  1)] = string.char( 55),
   [string.char(  2)] = string.char( 52),   [string.char(  3)] = string.char( 53),
   [string.char(  4)] = string.char( 50),   [string.char(  5)] = string.char( 51),
   [string.char(  6)] = string.char( 48),   [string.char(  7)] = string.char( 49),
   [string.char(  8)] = string.char( 62),   [string.char(  9)] = string.char( 63),
   [string.char( 10)] = string.char( 60),   [string.char( 11)] = string.char( 61),
   [string.char( 12)] = string.char( 58),   [string.char( 13)] = string.char( 59),
   [string.char( 14)] = string.char( 56),   [string.char( 15)] = string.char( 57),
   [string.char( 16)] = string.char( 38),   [string.char( 17)] = string.char( 39),
   [string.char( 18)] = string.char( 36),   [string.char( 19)] = string.char( 37),
   [string.char( 20)] = string.char( 34),   [string.char( 21)] = string.char( 35),
   [string.char( 22)] = string.char( 32),   [string.char( 23)] = string.char( 33),
   [string.char( 24)] = string.char( 46),   [string.char( 25)] = string.char( 47),
   [string.char( 26)] = string.char( 44),   [string.char( 27)] = string.char( 45),
   [string.char( 28)] = string.char( 42),   [string.char( 29)] = string.char( 43),
   [string.char( 30)] = string.char( 40),   [string.char( 31)] = string.char( 41),
   [string.char( 32)] = string.char( 22),   [string.char( 33)] = string.char( 23),
   [string.char( 34)] = string.char( 20),   [string.char( 35)] = string.char( 21),
   [string.char( 36)] = string.char( 18),   [string.char( 37)] = string.char( 19),
   [string.char( 38)] = string.char( 16),   [string.char( 39)] = string.char( 17),
   [string.char( 40)] = string.char( 30),   [string.char( 41)] = string.char( 31),
   [string.char( 42)] = string.char( 28),   [string.char( 43)] = string.char( 29),
   [string.char( 44)] = string.char( 26),   [string.char( 45)] = string.char( 27),
   [string.char( 46)] = string.char( 24),   [string.char( 47)] = string.char( 25),
   [string.char( 48)] = string.char(  6),   [string.char( 49)] = string.char(  7),
   [string.char( 50)] = string.char(  4),   [string.char( 51)] = string.char(  5),
   [string.char( 52)] = string.char(  2),   [string.char( 53)] = string.char(  3),
   [string.char( 54)] = string.char(  0),   [string.char( 55)] = string.char(  1),
   [string.char( 56)] = string.char( 14),   [string.char( 57)] = string.char( 15),
   [string.char( 58)] = string.char( 12),   [string.char( 59)] = string.char( 13),
   [string.char( 60)] = string.char( 10),   [string.char( 61)] = string.char( 11),
   [string.char( 62)] = string.char(  8),   [string.char( 63)] = string.char(  9),
   [string.char( 64)] = string.char(118),   [string.char( 65)] = string.char(119),
   [string.char( 66)] = string.char(116),   [string.char( 67)] = string.char(117),
   [string.char( 68)] = string.char(114),   [string.char( 69)] = string.char(115),
   [string.char( 70)] = string.char(112),   [string.char( 71)] = string.char(113),
   [string.char( 72)] = string.char(126),   [string.char( 73)] = string.char(127),
   [string.char( 74)] = string.char(124),   [string.char( 75)] = string.char(125),
   [string.char( 76)] = string.char(122),   [string.char( 77)] = string.char(123),
   [string.char( 78)] = string.char(120),   [string.char( 79)] = string.char(121),
   [string.char( 80)] = string.char(102),   [string.char( 81)] = string.char(103),
   [string.char( 82)] = string.char(100),   [string.char( 83)] = string.char(101),
   [string.char( 84)] = string.char( 98),   [string.char( 85)] = string.char( 99),
   [string.char( 86)] = string.char( 96),   [string.char( 87)] = string.char( 97),
   [string.char( 88)] = string.char(110),   [string.char( 89)] = string.char(111),
   [string.char( 90)] = string.char(108),   [string.char( 91)] = string.char(109),
   [string.char( 92)] = string.char(106),   [string.char( 93)] = string.char(107),
   [string.char( 94)] = string.char(104),   [string.char( 95)] = string.char(105),
   [string.char( 96)] = string.char( 86),   [string.char( 97)] = string.char( 87),
   [string.char( 98)] = string.char( 84),   [string.char( 99)] = string.char( 85),
   [string.char(100)] = string.char( 82),   [string.char(101)] = string.char( 83),
   [string.char(102)] = string.char( 80),   [string.char(103)] = string.char( 81),
   [string.char(104)] = string.char( 94),   [string.char(105)] = string.char( 95),
   [string.char(106)] = string.char( 92),   [string.char(107)] = string.char( 93),
   [string.char(108)] = string.char( 90),   [string.char(109)] = string.char( 91),
   [string.char(110)] = string.char( 88),   [string.char(111)] = string.char( 89),
   [string.char(112)] = string.char( 70),   [string.char(113)] = string.char( 71),
   [string.char(114)] = string.char( 68),   [string.char(115)] = string.char( 69),
   [string.char(116)] = string.char( 66),   [string.char(117)] = string.char( 67),
   [string.char(118)] = string.char( 64),   [string.char(119)] = string.char( 65),
   [string.char(120)] = string.char( 78),   [string.char(121)] = string.char( 79),
   [string.char(122)] = string.char( 76),   [string.char(123)] = string.char( 77),
   [string.char(124)] = string.char( 74),   [string.char(125)] = string.char( 75),
   [string.char(126)] = string.char( 72),   [string.char(127)] = string.char( 73),
   [string.char(128)] = string.char(182),   [string.char(129)] = string.char(183),
   [string.char(130)] = string.char(180),   [string.char(131)] = string.char(181),
   [string.char(132)] = string.char(178),   [string.char(133)] = string.char(179),
   [string.char(134)] = string.char(176),   [string.char(135)] = string.char(177),
   [string.char(136)] = string.char(190),   [string.char(137)] = string.char(191),
   [string.char(138)] = string.char(188),   [string.char(139)] = string.char(189),
   [string.char(140)] = string.char(186),   [string.char(141)] = string.char(187),
   [string.char(142)] = string.char(184),   [string.char(143)] = string.char(185),
   [string.char(144)] = string.char(166),   [string.char(145)] = string.char(167),
   [string.char(146)] = string.char(164),   [string.char(147)] = string.char(165),
   [string.char(148)] = string.char(162),   [string.char(149)] = string.char(163),
   [string.char(150)] = string.char(160),   [string.char(151)] = string.char(161),
   [string.char(152)] = string.char(174),   [string.char(153)] = string.char(175),
   [string.char(154)] = string.char(172),   [string.char(155)] = string.char(173),
   [string.char(156)] = string.char(170),   [string.char(157)] = string.char(171),
   [string.char(158)] = string.char(168),   [string.char(159)] = string.char(169),
   [string.char(160)] = string.char(150),   [string.char(161)] = string.char(151),
   [string.char(162)] = string.char(148),   [string.char(163)] = string.char(149),
   [string.char(164)] = string.char(146),   [string.char(165)] = string.char(147),
   [string.char(166)] = string.char(144),   [string.char(167)] = string.char(145),
   [string.char(168)] = string.char(158),   [string.char(169)] = string.char(159),
   [string.char(170)] = string.char(156),   [string.char(171)] = string.char(157),
   [string.char(172)] = string.char(154),   [string.char(173)] = string.char(155),
   [string.char(174)] = string.char(152),   [string.char(175)] = string.char(153),
   [string.char(176)] = string.char(134),   [string.char(177)] = string.char(135),
   [string.char(178)] = string.char(132),   [string.char(179)] = string.char(133),
   [string.char(180)] = string.char(130),   [string.char(181)] = string.char(131),
   [string.char(182)] = string.char(128),   [string.char(183)] = string.char(129),
   [string.char(184)] = string.char(142),   [string.char(185)] = string.char(143),
   [string.char(186)] = string.char(140),   [string.char(187)] = string.char(141),
   [string.char(188)] = string.char(138),   [string.char(189)] = string.char(139),
   [string.char(190)] = string.char(136),   [string.char(191)] = string.char(137),
   [string.char(192)] = string.char(246),   [string.char(193)] = string.char(247),
   [string.char(194)] = string.char(244),   [string.char(195)] = string.char(245),
   [string.char(196)] = string.char(242),   [string.char(197)] = string.char(243),
   [string.char(198)] = string.char(240),   [string.char(199)] = string.char(241),
   [string.char(200)] = string.char(254),   [string.char(201)] = string.char(255),
   [string.char(202)] = string.char(252),   [string.char(203)] = string.char(253),
   [string.char(204)] = string.char(250),   [string.char(205)] = string.char(251),
   [string.char(206)] = string.char(248),   [string.char(207)] = string.char(249),
   [string.char(208)] = string.char(230),   [string.char(209)] = string.char(231),
   [string.char(210)] = string.char(228),   [string.char(211)] = string.char(229),
   [string.char(212)] = string.char(226),   [string.char(213)] = string.char(227),
   [string.char(214)] = string.char(224),   [string.char(215)] = string.char(225),
   [string.char(216)] = string.char(238),   [string.char(217)] = string.char(239),
   [string.char(218)] = string.char(236),   [string.char(219)] = string.char(237),
   [string.char(220)] = string.char(234),   [string.char(221)] = string.char(235),
   [string.char(222)] = string.char(232),   [string.char(223)] = string.char(233),
   [string.char(224)] = string.char(214),   [string.char(225)] = string.char(215),
   [string.char(226)] = string.char(212),   [string.char(227)] = string.char(213),
   [string.char(228)] = string.char(210),   [string.char(229)] = string.char(211),
   [string.char(230)] = string.char(208),   [string.char(231)] = string.char(209),
   [string.char(232)] = string.char(222),   [string.char(233)] = string.char(223),
   [string.char(234)] = string.char(220),   [string.char(235)] = string.char(221),
   [string.char(236)] = string.char(218),   [string.char(237)] = string.char(219),
   [string.char(238)] = string.char(216),   [string.char(239)] = string.char(217),
   [string.char(240)] = string.char(198),   [string.char(241)] = string.char(199),
   [string.char(242)] = string.char(196),   [string.char(243)] = string.char(197),
   [string.char(244)] = string.char(194),   [string.char(245)] = string.char(195),
   [string.char(246)] = string.char(192),   [string.char(247)] = string.char(193),
   [string.char(248)] = string.char(206),   [string.char(249)] = string.char(207),
   [string.char(250)] = string.char(204),   [string.char(251)] = string.char(205),
   [string.char(252)] = string.char(202),   [string.char(253)] = string.char(203),
   [string.char(254)] = string.char(200),   [string.char(255)] = string.char(201),
}


local blocksize = 64 -- 512 bits

function hmac_sha1(key, text)
   assert(type(key)  == 'string', "key passed to hmac_sha1 should be a string")
   assert(type(text) == 'string', "text passed to hmac_sha1 should be a string")

   if #key > blocksize then
      key = sha1_binary(key)
   end

   local key_xord_with_0x36 = key:gsub('.', xor_with_0x36) .. string.rep(string.char(0x36), blocksize - #key)
   local key_xord_with_0x5c = key:gsub('.', xor_with_0x5c) .. string.rep(string.char(0x5c), blocksize - #key)

   return sha1(key_xord_with_0x5c .. sha1_binary(key_xord_with_0x36 .. text))
end

function hmac_sha1_binary(key, text)
   return hex_to_binary(hmac_sha1(key, text))
end

return {
   sha1 = sha1,
   sha1_binary = sha1_binary,
   hmac_sha1 = hmac_sha1,
   hmac_sha1_binary = hmac_sha1_binary,
} end)
package.preload['tools'] = (function (...)
local base64 = require'websocket.base64'
local sha1 = require'websocket.sha1'

local mrandom = math.random

local read_n_bytes = function(str, pos, n)
  pos = pos or 1
  return pos+n, string.byte(str, pos, pos + n - 1)
end

local read_int8 = function(str, pos)
  return read_n_bytes(str, pos, 1)
end

local read_int16 = function(str, pos)
  local new_pos,a,b = read_n_bytes(str, pos, 2)
  return new_pos, (a << 8) + b
end

local read_int32 = function(str, pos)
  local new_pos,a,b,c,d = read_n_bytes(str, pos, 4)
  return new_pos,
  (a << 24) +
  (b << 16) +
  (c << 8 ) +
  d
end

local pack_bytes = string.char

local write_int8 = pack_bytes

local write_int16 = function(v)
  return pack_bytes((v >> 8), (v & 0xFF))
end

local write_int32 = function(v)
  return pack_bytes(
    ((v >> 24) & 0xFF),
    ((v >> 16) & 0xFF),
    ((v >>  8) & 0xFF),
    (v & 0xFF)
  )
end

-- used for generate key random ops
math.randomseed(os.time())

local sha1_crypto = function(msg)
  return sha1.sha1_binary(msg)
end


local base64_encode = function(data)
  return (base64.encode(data))
end

local DEFAULT_PORTS = {ws = 80, wss = 443}

local parse_url = function(url)
  local protocol, address, uri = url:match('^(%w+)://([^/]+)(.*)$')
  if not protocol then error('Invalid URL:'..url) end
  protocol = protocol:lower()
  local host, port = address:match("^(.+):(%d+)$")
  if not host then
    host = address
    port = DEFAULT_PORTS[protocol]
  end
  if not uri or uri == '' then uri = '/' end
  return protocol, host, tonumber(port), uri
end

local generate_key = function()
  local r1 = mrandom(0,0xfffffff)
  local r2 = mrandom(0,0xfffffff)
  local r3 = mrandom(0,0xfffffff)
  local r4 = mrandom(0,0xfffffff)
  local key = write_int32(r1)..write_int32(r2)..write_int32(r3)..write_int32(r4)
  assert(#key==16,#key)
  return base64_encode(key)
end

return {
  sha1 = sha1_crypto,
  base64 = {
    encode = base64_encode
  },
  parse_url = parse_url,
  generate_key = generate_key,
  read_int8 = read_int8,
  read_int16 = read_int16,
  read_int32 = read_int32,
  write_int8 = write_int8,
  write_int16 = write_int16,
  write_int32 = write_int32,
}

 end)
package.preload['websocket'] = (function (...)
local frame = require'websocket.frame'

return {
  server = require'websocket.server',
  CONTINUATION = frame.CONTINUATION,
  TEXT = frame.TEXT,
  BINARY = frame.BINARY,
  CLOSE = frame.CLOSE,
  PING = frame.PING,
  PONG = frame.PONG
}
 end)


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
  StartHandshake= 0x12,
  ConnectLink = 0x13
}

local Transive = {
  HANDSHAKE = 0,
  CRC = 1,
  COMMAND = 2
}

local create_celio_client = function(ws)
  local celio_client = {
    _server = LinkStatus.AwaitMode,
    _client = LinkStatus.AwaitMode,
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

  function celio_client:checkSendStartHandshake()
    if (celio_client._server == LinkStatus.HandshakeReceived and celio_client._server == LinkStatus.HandshakeReceived) then
      celio_client._ws:send(CommandType.StartHandshake)
    end
  end

  function celio_client:transive_handshake(rx_value)
    console:log("Handshake")
    if (rx_value == 0xB9A0) then
      if (celio_client._server == LinkStatus.AwaitMode) then
        celio_client._server = LinkStatus.HandshakeReceived
        celio_client:checkSendStartHandshake()
      end
    end

    if (rx_value == 0x8FFF) then
      celio_client._ws:send(CommandType.ConnectLink)
      celio_client._transive_state = Transive.CRC
      celio_client._server = LinkStatus.LinkConnected
    end

    if (celio_client._server == LinkStatus.HandshakeReceived and celio_client._client == LinkStatus.HandshakeReceived) then
      return 0xB9A0
    end

    return  0xD15E
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
    if (command == LinkStatus.AwaitMode) then
      celio_client._ws:send(CommandType.SetModeMaster)

    elseif (command == LinkStatus.HandshakeReceived) then
      celio_client._client = LinkStatus.HandshakeReceived
      celio_client:checkSendStartHandshake()

    elseif (command == LinkStatus.LinkConnected) then
      celio_client._client = LinkStatus.LinkConnected
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
          celio_client:receive_data(tonumber(message))
        end
      end)
    end
  }
}
