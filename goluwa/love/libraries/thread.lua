local line = import("goluwa/love/line.lua")
local tasks = import("goluwa/tasks.lua")
local timer = import("goluwa/timer.lua")
local love = ... or _G.love
local ENV = love._line_env
love.thread = love.thread or {}
ENV.threads = ENV.threads or {}
ENV.threads2 = ENV.threads2 or {}
local Thread = line.TypeTemplate("Thread", love)

local function make_thread_ffi_proxy()
	local ffi = require("ffi")
	local seen_cdefs = {}
	return setmetatable(
		{
			cdef = function(def)
				if seen_cdefs[def] then return end

				local ok, err = pcall(ffi.cdef, def)

				if not ok then
					if not tostring(err):find("attempt to redefine", 1, true) then
						error(err, 2)
					end
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

local function make_thread_env(base_env)
	local thread_ffi = make_thread_ffi_proxy()
	local thread_env = {}
	local loaded_modules = {}
	thread_env.require = function(name)
		if name == "ffi" then return thread_ffi end

		if name == "love" then return base_env.love end

		local love_library = name:match("^love%.(.+)$")

		if love_library and base_env.love[love_library] then
			return base_env.love[love_library]
		end

		if loaded_modules[name] ~= nil then return loaded_modules[name] end

		local base_path = name:gsub("%.", "/")

		for _, candidate in ipairs{base_path .. ".lua", base_path .. "/init.lua"} do
			if base_env.love.filesystem.getInfo(candidate, "file") then
				local func, err = base_env.love.filesystem.load(candidate)

				if not func then error(err, 2) end

				setfenv(func, thread_env)
				local result = func(name)

				if result == nil then result = true end

				loaded_modules[name] = result
				return result
			end
		end

		return base_env.require(name)
	end
	setfenv(thread_env.require, thread_env)
	setmetatable(thread_env, {
		__index = base_env,
	})
	thread_env._G = thread_env
	return thread_env
end

function Thread:start(...)
	self.args = {...}

	if self.thread.co then
		ENV.threads2[self.thread.co] = self
		self.thread:Start()
	else
		ENV.running = self

		timer.Delay(0, function()
			self.thread:Start()
			ENV.running = nil
		end)
	end
end

function Thread:wait() end

function Thread:set(key, val)
	self.vars[key] = val
end

function Thread:send() end

function Thread:receive() end

function Thread:peek() end

function Thread:kill() end

function Thread:getName()
	return self.name
end

function Thread:getKeys()
	return {}
end

function Thread:get()
	return
end

function Thread:demand(name)
	return self.vars[name]
end

function Thread:getError(name) end

function love.thread.newThread(name, script_path)
	local self = line.CreateObject("Thread", love)
	self.vars = {}
	local env = make_thread_env(getfenv(2))
	local func = love.filesystem.load(script_path or name)
	local thread = tasks.CreateTask()

	function thread.OnStart()
		setfenv(func, env)

		if thread.co then thread:Wait() end

		func(unpack(self.args))

		if thread.co then thread:Wait() end
	end

	function thread:OnFinish()
		llog("thread ", name, " finished")
	end

	self.thread = thread
	ENV.threads[name] = self
	self.name = name
	llog("creating thread ", name)
	return self
end

function love.thread.getThread(name)
	if not name then return ENV.threads2[coroutine.running()] or ENV.running end

	return ENV.threads[name]
end

function love.thread.getThreads()
	return ENV.threads
end

line.RegisterType(Thread, love)
ENV.channels = {}
local Channel = line.TypeTemplate("Channel", love)

function Channel:clear()
	list.clear(self.queue)
end

function Channel:demand()
	while #self.queue == 0 do
		tasks.Wait(0.001)
	end

	return self:pop()
end -- supposedly blocking
function Channel:getCount()
	return #self.queue
end

function Channel:peek()
	return self.queue[1]
end

function Channel:pop()
	return list.remove(self.queue, 1)
end

function Channel:push(value)
	return list.insert(self.queue, value)
end

function Channel:performAtomic(func, ...)
	assert(type(func) == "function", "Channel:performAtomic expects a function")
	return func(self, ...)
end

function Channel:supply(value)
	return self:push(value)
end -- supposedly blocking
function love.thread.newChannel()
	local self = line.CreateObject("Channel", love)
	self.queue = {}
	return self
end

function love.thread.getChannel(name)
	if not ENV.channels[name] then
		ENV.channels[name] = love.thread.newChannel()
	end

	return ENV.channels[name]
end

line.RegisterType(Channel, love)
