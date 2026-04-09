local ffi = require("ffi")
local buffer = require("string.buffer")
local fs = import("goluwa/fs.lua")
local native_fs = import("goluwa/bindings/filesystem.lua")
local native_threads = import("goluwa/bindings/threads.lua")
local system = import("goluwa/system.lua")
local line = import("goluwa/love/line.lua")
local love = ... or _G.love
local ENV = love._line_env
love.thread = love.thread or {}
ENV.threads = ENV.threads or {}
ENV.threads_by_id = ENV.threads_by_id or {}
ENV.channels = ENV.channels or {}
ENV.channels_by_id = ENV.channels_by_id or {}
local Thread = line.TypeTemplate("Thread", love)
local Channel = line.TypeTemplate("Channel", love)
local CHANNEL_REF_KEY = "__love_thread_channel_ref"
local TRANSPORT_TYPE_KEY = "__love_thread_transport_type"
ENV.transport_deserializers = ENV.transport_deserializers or {}

local function make_byte_buffer(data)
	data = data or ""
	local len = #data
	local out = ffi.new("uint8_t[?]", math.max(len, 1))

	if len > 0 then ffi.copy(out, data, len) end

	return out, len
end

local function encode_transport_value(value, seen)
	local value_type = type(value)

	if value_type ~= "table" then return value end

	if value.type and type(value.Serialize) == "function" then
		return {
			[TRANSPORT_TYPE_KEY] = value:type(),
			payload = value:Serialize(),
		}
	end

	seen = seen or {}

	if seen[value] then
		error("love.thread values cannot contain recursive tables", 3)
	end

	seen[value] = true
	local out = {}

	for key, child in pairs(value) do
		out[encode_transport_value(key, seen)] = encode_transport_value(child, seen)
	end

	seen[value] = nil
	return out
end

local function decode_transport_value(value, current_love, seen)
	if type(value) ~= "table" then return value end

	local transport_type = rawget(value, TRANSPORT_TYPE_KEY)

	if transport_type then
		local deserialize = current_love._line_env.transport_deserializers and
			current_love._line_env.transport_deserializers[transport_type]

		if type(deserialize) == "function" then
			return deserialize(value.payload, current_love)
		end
	end

	seen = seen or {}

	if seen[value] then return seen[value] end

	local out = {}
	seen[value] = out

	for key, child in pairs(value) do
		out[decode_transport_value(key, current_love, seen)] = decode_transport_value(child, current_love, seen)
	end

	return out
end

local function encode_value(value)
	local buf = buffer.new()
	buf:encode(encode_transport_value(value))
	local ptr, len = buf:ref()
	return ffi.string(ptr, len)
end

local function decode_value(blob)
	local buf = buffer.new()
	buf:set(blob)
	return decode_transport_value(buf:decode(), love)
end

local function get_temp_directory()
	return os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
end

local function encode_path_component(value)
	return tostring(value):gsub("[^%w%-_]", function(chr)
		return string.format("_%02X", string.byte(chr))
	end)
end

local function ensure_directory(path)
	local ok, err = fs.create_directory_recursive(path)

	if not ok and not fs.is_directory(path) then
		error(err or ("failed to create directory: " .. path), 2)
	end

	return path
end

local function get_time_seconds()
	return tonumber(system.GetTime()) or 0
end

local function get_time_ns()
	local ok, value = pcall(system.GetTimeNS)

	if ok and value ~= nil then return tonumber(value) or 0 end

	return math.floor(get_time_seconds() * 1000000000)
end

local function generate_session_root()
	local root = string.format(
		"%s/goluwa-love-thread-%d-%08x",
		get_temp_directory(),
		get_time_ns(),
		math.random(0, 0x7fffffff)
	)
	ensure_directory(root)
	ensure_directory(root .. "/channels")
	return root
end

local function ensure_session_root()
	if not ENV.thread_session_root or ENV.thread_session_root == "" then
		ENV.thread_session_root = generate_session_root()
	else
		ensure_directory(ENV.thread_session_root)
		ensure_directory(ENV.thread_session_root .. "/channels")
	end

	return ENV.thread_session_root
end

local function register_thread(self)
	if self.name then ENV.threads[self.name] = self end

	ENV.threads_by_id[self.id] = self
	return self
end

local function create_thread_object(name, script_path, id)
	local self = line.CreateObject("Thread", love)
	self.vars = {}
	self.name = name
	self.script_path = script_path
	self.id = id or string.format("thread-%d-%08x", get_time_ns(), math.random(0, 0x7fffffff))
	return register_thread(self)
end

local function create_channel(name, id)
	if id and ENV.channels_by_id[id] then return ENV.channels_by_id[id] end

	if name and ENV.channels[name] then return ENV.channels[name] end

	ensure_session_root()
	id = id or string.format("channel-%d-%08x", get_time_ns(), math.random(0, 0x7fffffff))
	local base_path = ensure_directory(ENV.thread_session_root .. "/channels/" .. encode_path_component(id))
	local messages_path = ensure_directory(base_path .. "/messages")
	local self = line.CreateObject("Channel", love)
	self.name = name
	self.id = id
	self.base_path = base_path
	self.messages_path = messages_path
	self.lock_path = base_path .. "/lock"
	ENV.channels_by_id[id] = self

	if name then ENV.channels[name] = self end

	return self
end

local function list_message_files(channel)
	local files = native_fs.get_files(channel.messages_path) or {}
	local out = {}

	for _, name in ipairs(files) do
		if name:sub(-4) == ".msg" then out[#out + 1] = name end
	end

	table.sort(out)
	return out
end

local function with_channel_lock(channel, callback, ...)
	if channel._lock_depth and channel._lock_depth > 0 then
		channel._lock_depth = channel._lock_depth + 1
		local results = {pcall(callback, ...)}
		channel._lock_depth = channel._lock_depth - 1

		if not results[1] then error(results[2], 0) end

		return select(2, unpack(results))
	end

	local deadline = get_time_seconds() + 10

	while true do
		local ok = native_fs.create_directory(channel.lock_path)

		if ok then break end

		if get_time_seconds() >= deadline then
			error("timed out acquiring love.thread channel lock", 2)
		end

		native_threads.sleep(1)
	end

	channel._lock_depth = 1
	local results = {pcall(callback, ...)}
	channel._lock_depth = 0
	native_fs.remove_directory(channel.lock_path)

	if not results[1] then error(results[2], 0) end

	return select(2, unpack(results))
end

local encode_thread_value = encode_transport_value

function love.thread._getChannelById(id, name)
	return create_channel(name, assert(id, "channel id is required"))
end

function Channel:Serialize()
	return {
		[CHANNEL_REF_KEY] = true,
		id = self.id,
		name = self.name,
	}
end

function Channel.Deserialize(payload, current_love)
	if rawget(payload, CHANNEL_REF_KEY) then
		return current_love.thread._getChannelById(payload.id, payload.name)
	end

	error("invalid Channel transport payload", 2)
end

ENV.transport_deserializers.Channel = Channel.Deserialize

function love.thread._registerCurrentThread(name, id, script_path)
	local current = create_thread_object(name, script_path, id)
	current.current_thread = true
	current.started = true
	ENV.current_thread = current
	return current
end

local function get_native_status(native_thread)
	if not native_thread or not native_thread.input_data then return nil end

	return native_threads.get_status(native_thread)
end

local function decode_native_error(native_thread)
	if not native_thread or not native_thread.input_data then return nil end

	local data = native_thread.input_data

	if native_threads.get_status(native_thread) ~= native_threads.STATUS_ERROR then return nil end

	local result = native_threads.pointer_decode(data.output_buffer, data.output_buffer_len)
	return result and result[2] or nil
end

local thread_worker_source = [[
		local payload = ...
		local function make_thread_ffi_proxy()
			local ffi = require("ffi")
			local seen_cdefs = {}
			return setmetatable(
				{
					cdef = function(def)
						if seen_cdefs[def] then return end

						local ok, err = pcall(ffi.cdef, def)

						if not ok and not tostring(err):find("attempt to redefine", 1, true) then
							error(err, 2)
						end

						seen_cdefs[def] = true
					end,
				},
				{
					__index = ffi,
					__newindex = ffi,
				}
			)
		end

		local function make_byte_buffer(data)
			data = data or ""
			local len = #data
			local out = ffi.new("uint8_t[?]", math.max(len, 1))

			if len > 0 then ffi.copy(out, data, len) end

			return out, len
		end

		local function revive_thread_value(value, seen, love)
			if type(value) ~= "table" then return value end

			local transport_type = rawget(value, "__love_thread_transport_type")

			if transport_type then
				local deserialize = love._line_env.transport_deserializers and
					love._line_env.transport_deserializers[transport_type]

				if type(deserialize) == "function" then return deserialize(value.payload, love) end
			end

			seen = seen or {}

			if seen[value] then return seen[value] end

			local out = {}
			seen[value] = out

			for key, child in pairs(value) do
				out[revive_thread_value(key, seen, love)] = revive_thread_value(child, seen, love)
			end

			return out
		end

		require("goluwa.global_environment")
		local line = import("goluwa/love/line.lua")
		local function create_thread_love_env(version)
			local love = {
				_line_env = {},
				_modules = {},
				package_loaders = {},
			}
			version = tostring(version or "0.10.1")
			local major, minor, revision = version:match("^(%d+)%.(%d+)%.?(%d*)$")

			if not major then major, minor, revision = "0", "10", "1" end

			revision = revision ~= "" and revision or "0"
			love._version_major = tonumber(major) or 0
			love._version_minor = tonumber(minor) or 0
			love._version_revision = tonumber(revision) or 0
			love._version = string.format(
				"%d.%d.%d",
				love._version_major,
				love._version_minor,
				love._version_revision
			)

			local function load_library(path, key)
				line.LoadLoveLibrary(love, path)

				if key then love._modules[key] = true end
			end

			load_library("goluwa/love/libraries/arg.lua", "arg")
			load_library("goluwa/love/libraries/event.lua", "event")
			load_library("goluwa/love/libraries/love.lua")
			load_library("goluwa/love/libraries/system.lua", "system")
			load_library("goluwa/love/libraries/timer.lua", "timer")
			load_library("goluwa/love/libraries/filesystem.lua", "filesystem")
			load_library("goluwa/love/libraries/data.lua", "data")
			load_library("goluwa/love/libraries/image_data.lua", "image")
			load_library("goluwa/love/libraries/audio.lua", "audio")
			load_library("goluwa/love/libraries/math.lua", "math")
			load_library("goluwa/love/libraries/particles.lua", "particles")
			load_library("goluwa/love/libraries/sound.lua", "sound")
			load_library("goluwa/love/libraries/thread.lua", "thread")
			return love
		end

		local love = create_thread_love_env(payload.version)
		local ENV = love._line_env
		ENV.filesystem_source = payload.filesystem_source or ""
		love.filesystem.setIdentity(payload.filesystem_identity or "none")

		if ENV.filesystem_source ~= "" then
			love.filesystem.mount(ENV.filesystem_source, "")
		end

		ENV.thread_session_root = payload.thread_session_root
		local current_thread = love.thread._registerCurrentThread(payload.name, payload.id, payload.script_path)
		local thread_ffi = make_thread_ffi_proxy()
		local loaded_modules = {}
		local thread_env = {}

		thread_env.require = function(name)
			if name == "ffi" then return thread_ffi end
			if name == "love" then return love end

			local love_library = name:match("^love%.(.+)$")

			if love_library and love[love_library] then return love[love_library] end
			if loaded_modules[name] ~= nil then return loaded_modules[name] end

			local base_path = name:gsub("%.", "/")

			for _, candidate in ipairs({base_path .. ".lua", base_path .. "/init.lua"}) do
				if love.filesystem.getInfo(candidate, "file") then
					local func, err = love.filesystem.load(candidate)

					if not func then error(err, 2) end

					setfenv(func, thread_env)
					local result = func(name)

					if result == nil then result = true end

					loaded_modules[name] = result
					return result
				end
			end

			return require(name)
		end

		setfenv(thread_env.require, thread_env)
		setmetatable(thread_env, {__index = getfenv(1)})
		thread_env._G = thread_env
		thread_env.love = love
		thread_env.thread = current_thread

		local func, err = love.filesystem.load(payload.script_path)

		if not func then error(err, 2) end

		setfenv(func, thread_env)
		local args = revive_thread_value(payload.args or {}, nil, love)
		return func(unpack(args))
]]

function Thread:_sync_state()
	if not self.native_thread or self.finished then return end

	local status = get_native_status(self.native_thread)

	if status == native_threads.STATUS_ERROR and not self.error_message then
		self.error_message = decode_native_error(self.native_thread)
	elseif status == native_threads.STATUS_COMPLETED then
		self.completed = true
	end
end

function Thread:start(...)
	if self:isRunning() then error("thread is already running", 2) end

	ensure_session_root()
	self.error_message = nil
	self.completed = false
	self.finished = false
	self.started = true
	self.args = {...}
	self.native_thread = native_threads.new(thread_worker_source)
	self.thread = self.native_thread
	self.native_thread:run{
		args = encode_thread_value({...}),
		filesystem_identity = ENV.filesystem_identity,
		filesystem_source = ENV.filesystem_source or
			(
				love.filesystem and
				love.filesystem.getSource and
				love.filesystem.getSource()
			)
			or
			"",
		id = self.id,
		name = self.name,
		script_path = self.script_path,
		thread_session_root = ENV.thread_session_root,
		version = love._version,
	}
end

function Thread:isRunning()
	self:_sync_state()
	local status = get_native_status(self.native_thread)
	return self.started == true and
		self.finished ~= true and
		status == native_threads.STATUS_UNDEFINED
end

function Thread:wait()
	if not self.native_thread or self.finished then return end

	local native_thread = self.native_thread
	local _, err = native_thread:join()
	self.finished = true
	self.completed = err == nil

	if err then self.error_message = err end

	native_thread.lua_state = nil
	native_thread.func_ptr = nil
	native_thread.id = nil
	self.native_thread = nil
	self.thread = nil
end

function Thread:set(key, value)
	self.vars[key] = value
	return value
end

function Thread:send() end

function Thread:receive() end

function Thread:peek() end

function Thread:kill() end

function Thread:getName()
	return self.name
end

function Thread:getKeys()
	local out = {}

	for key in pairs(self.vars) do
		out[#out + 1] = key
	end

	table.sort(out)
	return out
end

function Thread:get(name)
	return self.vars[name]
end

function Thread:demand(name)
	return self.vars[name]
end

function Thread:getError()
	self:_sync_state()
	return self.error_message
end

function love.thread.newThread(name, script_path)
	local resolved_script_path = script_path or name
	local resolved_name = script_path and name or resolved_script_path
	return create_thread_object(resolved_name, resolved_script_path)
end

function love.thread.getThread(name)
	if not name then return ENV.current_thread end

	return ENV.threads[name] or ENV.threads_by_id[name]
end

function love.thread.getThreads()
	return ENV.threads
end

line.RegisterType(Thread, love)

function Channel:clear()
	with_channel_lock(self, function()
		for _, name in ipairs(list_message_files(self)) do
			native_fs.remove_file(self.messages_path .. "/" .. name)
		end
	end)
end

function Channel:demand(timeout)
	timeout = tonumber(timeout)
	local deadline = timeout and timeout >= 0 and (get_time_seconds() + timeout) or nil

	while true do
		local value = self:pop()

		if value ~= nil then return value end

		if deadline and get_time_seconds() >= deadline then return nil end

		native_threads.sleep(1)
	end
end

function Channel:getCount()
	return with_channel_lock(self, function()
		return #list_message_files(self)
	end)
end

function Channel:peek()
	return with_channel_lock(self, function()
		local name = list_message_files(self)[1]

		if not name then return nil end

		local blob = assert(fs.read_file(self.messages_path .. "/" .. name))
		return decode_value(blob)
	end)
end

function Channel:pop()
	return with_channel_lock(self, function()
		local name = list_message_files(self)[1]

		if not name then return nil end

		local path = self.messages_path .. "/" .. name
		local blob = assert(fs.read_file(path))
		native_fs.remove_file(path)
		return decode_value(blob)
	end)
end

function Channel:push(value)
	assert(value ~= nil, "Channel:push does not support nil values")
	return with_channel_lock(self, function()
		self._message_counter = (self._message_counter or 0) + 1
		local name = string.format("%020d_%08d.msg", get_time_ns(), self._message_counter)
		local path = self.messages_path .. "/" .. name
		assert(fs.write_file(path, encode_value(value)))
		return true
	end)
end

function Channel:performAtomic(func, ...)
	assert(type(func) == "function", "Channel:performAtomic expects a function")
	return with_channel_lock(self, func, self, ...)
end

function Channel:supply(value)
	return self:push(value)
end

function love.thread.newChannel()
	return create_channel(nil)
end

function love.thread.getChannel(name)
	return create_channel(assert(name, "channel name is required"), tostring(name))
end

line.RegisterType(Channel, love)
