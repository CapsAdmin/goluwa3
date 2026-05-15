local ljsocket = import("goluwa/bindings/socket.lua")
local system = import("goluwa/system.lua")
local socket = {
	_VERSION = "LuaSocket 3.0.0-goluwa",
	_COPYRIGHT = "LuaSocket 3.0.0-goluwa",
	_DESCRIPTION = "LuaSocket compatibility layer for Goluwa",
}
local socket_meta = {}
socket_meta.__index = socket_meta

local function convert_timeout(seconds)
	if seconds == nil then return nil end

	if seconds < 0 then return 0 end

	return math.floor(seconds * 1000)
end

local function normalize_option_name(name)
	if name == "tcp-nodelay" then return "nodelay", "tcp" end

	if name == "keepalive" then return "keepalive", "socket" end

	if name == "reuseaddr" then return "reuseaddr", "socket" end

	return name, "socket"
end

local function wrap_socket(raw_socket)
	return setmetatable(
		{
			raw_socket = raw_socket,
			receive_buffer = "",
			received_bytes = 0,
			sent_bytes = 0,
			birth = system.GetTime(),
		},
		socket_meta
	)
end

local function read_chunk(self, size)
	local chunk, err, code = self.raw_socket:receive(size)

	if chunk then
		self.received_bytes = self.received_bytes + #chunk
		self.receive_buffer = self.receive_buffer .. chunk
		return true
	end

	if err == "closed" then return nil, err, code end

	return nil, err, code
end

function socket_meta:settimeout(value)
	local timeout = convert_timeout(value)

	if timeout ~= nil then
		local ok, err = self.raw_socket:set_option("rcvtimeo", timeout)

		if not ok then return nil, err end

		ok, err = self.raw_socket:set_option("sndtimeo", timeout)

		if not ok then return nil, err end
	end

	return 1
end

function socket_meta:setoption(name, value)
	local option_name, level = normalize_option_name(name)
	local ok, err = self.raw_socket:set_option(option_name, value, level == "tcp" and "tcp" or nil)

	if not ok then return nil, err end

	return 1
end

function socket_meta:getoption(name)
	local option_name, level = normalize_option_name(name)
	return self.raw_socket:get_option(option_name, level == "tcp" and "tcp" or nil)
end

function socket_meta:connect(host, service)
	local ok, err = self.raw_socket:connect(host, service)

	if not ok then return nil, err end

	return 1
end

function socket_meta:bind(host, service)
	local ok, err = self.raw_socket:bind(host, service)

	if not ok then return nil, err end

	return 1
end

function socket_meta:listen(backlog)
	local ok, err = self.raw_socket:listen(backlog)

	if not ok then return nil, err end

	return 1
end

function socket_meta:accept()
	local client, err = self.raw_socket:accept()

	if not client then return nil, err end

	return wrap_socket(client)
end

function socket_meta:send(data, start_index, end_index)
	start_index = start_index or 1
	end_index = end_index or #data
	local payload = data:sub(start_index, end_index)
	local sent, err, code = self.raw_socket:send(payload)

	if not sent then return nil, err, code end

	self.sent_bytes = self.sent_bytes + sent
	return start_index + sent - 1
end

function socket_meta:receive(pattern, prefix)
	pattern = pattern or "*l"
	prefix = prefix or ""

	if prefix ~= "" then self.receive_buffer = prefix .. self.receive_buffer end

	if type(pattern) == "number" then
		while #self.receive_buffer < pattern do
			local ok, err = read_chunk(self, pattern - #self.receive_buffer)

			if not ok then
				local partial = self.receive_buffer
				self.receive_buffer = ""
				return nil, err, partial ~= "" and partial or nil
			end
		end

		local out = self.receive_buffer:sub(1, pattern)
		self.receive_buffer = self.receive_buffer:sub(pattern + 1)
		return out
	end

	if pattern == "*a" then
		while true do
			local ok, err = read_chunk(self, 2048)

			if not ok then
				if err == "closed" then
					local out = self.receive_buffer
					self.receive_buffer = ""
					return out
				end

				local partial = self.receive_buffer
				self.receive_buffer = ""
				return nil, err, partial ~= "" and partial or nil
			end
		end
	end

	if pattern ~= "*l" then
		return nil, "unsupported receive pattern: " .. tostring(pattern)
	end

	while true do
		local newline_start, newline_end = self.receive_buffer:find("\n", 1, true)

		if newline_start then
			local line = self.receive_buffer:sub(1, newline_start - 1)
			self.receive_buffer = self.receive_buffer:sub(newline_end + 1)

			if line:sub(-1) == "\r" then line = line:sub(1, -2) end

			return line
		end

		local ok, err = read_chunk(self, 2048)

		if not ok then
			local partial = self.receive_buffer
			self.receive_buffer = ""

			if partial ~= "" then return nil, err, partial end

			return nil, err
		end
	end
end

function socket_meta:close()
	local ok, err = self.raw_socket:close()

	if not ok then return nil, err end

	return 1
end

function socket_meta:getfd()
	return self.raw_socket.fd
end

function socket_meta:dirty()
	return self.receive_buffer ~= ""
end

function socket_meta:getstats()
	return self.received_bytes, self.sent_bytes, system.GetTime() - self.birth
end

function socket_meta:setstats(received, sent)
	self.received_bytes = received or self.received_bytes
	self.sent_bytes = sent or self.sent_bytes
	return 1
end

function socket_meta:getsockname()
	return self.raw_socket:get_name()
end

function socket_meta:getpeername()
	return self.raw_socket:get_peer_name()
end

function socket_meta:shutdown(how)
	how = how or "both"
	local lookup = {receive = 0, send = 1, both = 2}
	local ok, err = ljsocket.socket.shutdown(self.raw_socket.fd, lookup[how] or 2)

	if not ok then return nil, err end

	return 1
end

function socket.skip(count, ...)
	return select(count + 1, ...)
end

function socket.newtry(finalizer)
	return function(ok, ...)
		if ok then return ok, ... end

		if finalizer then pcall(finalizer) end

		error((...), 0)
	end
end

function socket.try(ok, ...)
	return socket.newtry()(ok, ...)
end

function socket.protect(func)
	return function(...)
		local ok, result, extra1, extra2 = xpcall(func, debug.traceback, ...)

		if ok then return result, extra1, extra2 end

		return nil, result
	end
end

function socket.tcp4()
	return wrap_socket(assert(ljsocket.create("inet", "stream", "tcp")))
end

function socket.tcp6()
	return wrap_socket(assert(ljsocket.create("inet6", "stream", "tcp")))
end

function socket.tcp()
	return socket.tcp4()
end

function socket.connect(address, port, laddress, lport, family)
	local client = assert((family == "inet6" and socket.tcp6 or socket.tcp4)())

	if laddress or lport then
		local ok, err = client:bind(laddress or "*", lport or 0)

		if not ok then
			client:close()
			return nil, err
		end
	end

	local ok, err = client:connect(address, port)

	if not ok then
		client:close()
		return nil, err
	end

	return client
end

function socket.bind(host, port, backlog)
	local server = assert(socket.tcp())
	local ok, err = server:setoption("reuseaddr", true)

	if not ok then
		server:close()
		return nil, err
	end

	ok, err = server:bind(host or "*", port)

	if not ok then
		server:close()
		return nil, err
	end

	ok, err = server:listen(backlog)

	if not ok then
		server:close()
		return nil, err
	end

	return server
end

function socket.select(read_list, write_list, timeout)
	local entries = {}
	local keyed = {}

	local function add(sock, flags)
		local key = tostring(sock:getfd())
		local entry = keyed[key]

		if not entry then
			entry = {sock = sock, flags = {}}
			keyed[key] = entry
			entries[#entries + 1] = entry
		end

		for _, flag in ipairs(flags) do
			entry.flags[#entry.flags + 1] = flag
		end
	end

	for _, sock in ipairs(read_list or {}) do
		add(sock, {"in", "err", "hup", "nval"})
	end

	for _, sock in ipairs(write_list or {}) do
		add(sock, {"out", "err", "hup", "nval"})
	end

	local results, err = ljsocket.poll(entries, convert_timeout(timeout) or 0)

	if not results then return nil, nil, err end

	local readable = {}
	local writable = {}

	for _, result in ipairs(results) do
		local events = result.events
		local sock = result.entry.sock

		if events["in"] or events.err or events.hup or events.nval then
			readable[#readable + 1] = sock
		end

		if events.out or events.err or events.hup or events.nval then
			writable[#writable + 1] = sock
		end
	end

	return readable, writable
end

socket.dns = {}

function socket.dns.getaddrinfo(host)
	local infos, err = ljsocket.find_address_info(host, nil, nil, nil, nil, nil)

	if not infos then return nil, err end

	local out = {}

	for _, info in ipairs(infos) do
		out[#out + 1] = {
			family = info.family,
			addr = info:get_ip(),
			canonname = info.canonical_name,
		}
	end

	return out
end

function socket.gettime()
	return system.GetTime()
end

function socket.sleep(seconds)
	system.Sleep(seconds or 0)
	return 1
end

return socket
