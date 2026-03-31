local timer = import("goluwa/timer.lua")
local callstack = import("goluwa/helpers/callstack.lua")
local tasks = import("goluwa/tasks.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local callback = library()

local function pump_blocking_get()
	local dt = 0.001
	system.SetElapsedTime(system.GetElapsedTime() + dt)
	event.Call("Update", dt)
	system.Sleep(dt)
end

do
	local meta = {}
	meta.__index = meta

	function meta:__tostring()
		return string.format("callback: %p", self)
	end

	function meta:Start()
		if not self.on_start or self.start_on_callback then return end

		self:on_start()
		return self
	end

	function meta:Stop()
		if self.on_stop then self:on_stop() end
	end

	function meta:Resolve(...)
		if self.is_resolved or self.is_rejected then return end

		if not self.funcs.resolved[1] and self.warn_unhandled then
			logn(self, " unhandled resolve: ", ...)
			logn(self.debug_trace)
		end

		self.resolved_values = list.pack(...)

		for _, handler in ipairs(self.funcs.resolved) do
			local ok, a, b = pcall(handler, ...)

			if not ok then
				self:Reject(a)
				return false, a
			end

			if a == false and type(b) == "string" then
				self:Reject(b)
				return false, b
			end
		end

		for _, fn in ipairs(self.funcs.done) do
			fn()
		end

		self.is_resolved = true
		return self
	end

	function meta:Reject(msg, ...)
		if self.is_resolved then return end

		self.rejected_values = list.pack(msg, ...)

		for _, child in ipairs(self.children) do
			child:Reject(msg, ...)
		end

		local handled = false

		for _, handler in ipairs(self.funcs.rejected) do
			handler(msg, ...)
			handled = true
		end

		if not handled and self.warn_unhandled then
			logn(self, " unhandled reject: ", ...)
			logn(debug.traceback("current trace:"))
			logn(self.debug_trace)
		end

		for _, fn in ipairs(self.funcs.done) do
			fn()
		end

		self.is_rejected = true
		return self
	end

	function meta:Then(func)
		local child = callback.Create()
		child:SetParent(self)
		child.error_level = self.error_level
		child.warn_unhandled = false

		local function on_resolve(...)
			local ret = list.pack(func(...))

			if getmetatable(ret[1]) == meta then
				ret[1]:Catch(function(...)
					return child:Reject(...)
				end)

				return ret[1]:Then(function(...)
					return child:Resolve(...)
				end),
				list.unpack(ret, 2)
			end

			child:Resolve(...)
			return list.unpack(ret)
		end

		if self.is_resolved then
			return list.pack(on_resolve(unpack(self.resolved_values)))[1]
		end

		list.insert(self.funcs.resolved, on_resolve)

		if self.start_on_callback then
			self.start_on_callback = nil
			self:Start()
		end

		return child
	end

	function meta:Catch(func)
		list.insert(self.funcs.rejected, func)

		if self.is_rejected then func(unpack(self.rejected_values)) end

		return self
	end

	function meta:Done(func)
		list.insert(self.funcs.done, func)
		return self
	end

	function meta:ErrorLevel(level)
		self.error_level = level

		for _, child in ipairs(self.children) do
			child:ErrorLevel(level)
		end

		return self
	end

	function meta:Get()
		if self.start_on_callback then
			self.start_on_callback = nil
			self:Start()
		end

		while not self.is_resolved do
			if self.is_rejected then
				local msg = self.rejected_values and self.rejected_values[1]
				local level = self.error_level or 3
				error(callstack.get_line(level) .. ": " .. tostring(msg), level)
			end

			if tasks.GetActiveTask() then
				tasks.Wait()
			else
				pump_blocking_get()
			end
		end

		return unpack(self.resolved_values or {})
	end

	function meta:TryGet()
		return pcall(function()
			return self:Get()
		end)
	end

	function meta:Subscribe(what, func)
		self.funcs[what] = self.funcs[what] or {}
		table.insert(self.funcs[what], func)

		if self.values and self.values[what] then
			for _, args in ipairs(self.values[what]) do
				func(table.unpack(args))
			end
		end

		for _, child in ipairs(self.children) do
			child:Subscribe(what, func)
		end

		return self
	end

	function meta:Trigger(what, ...)
		self.values = self.values or {}
		self.values[what] = self.values[what] or {}
		table.insert(self.values[what], {...})

		if self.funcs[what] then
			for _, handler in ipairs(self.funcs[what]) do
				local ok, res, err = pcall(handler, ...)

				if not ok then
					self:Reject(res)
					return false, res
				end

				if res == false and type(err) == "string" then
					self:Reject(err)
					return false, err
				end
			end
		end

		for _, child in ipairs(self.children) do
			local ok, err = child:Trigger(what, ...)

			if ok == false then return false, err end
		end

		return true
	end

	function meta:SetParent(parent)
		self.parent = parent
		list.insert(parent.children, self)
		return self
	end

	function callback.Create(on_start)
		local self = setmetatable(
			{
				on_start = on_start,
				funcs = {resolved = {}, rejected = {}, done = {}},
				children = {},
				warn_unhandled = true,
				debug_trace = debug.traceback("creation trace:"),
			},
			meta
		)
		self.callbacks = setmetatable(
			{self = self},
			{
				__index = function(t, key)
					local s = t.self
					return function(...)
						if key == "resolve" then
							local ok, err = s:Resolve(...)

							if ok == false and type(err) == "string" then
								s.is_resolved = false
								s:Reject(err)
							end
						elseif key == "reject" then
							s:Reject(...)
						else
							s:Trigger(key, ...)
						end
					end
				end,
			}
		)
		return self
	end

	function callback.All(...)
		local input = {...}

		if #input == 1 and type(input[1]) == "table" and getmetatable(input[1]) ~= meta then
			input = input[1]
		end

		local all = callback.Create()
		local remaining = #input
		local results = {}
		local done = false

		if remaining == 0 then
			all:Resolve(results)
			return all
		end

		local function finish_one()
			remaining = remaining - 1

			if remaining <= 0 and not done then
				done = true
				all:Resolve(results)
			end
		end

		for i, cb in ipairs(input) do
			if getmetatable(cb) == meta then
				cb:Then(function(...)
					results[i] = list.pack(...)
					finish_one()
				end)

				cb:Catch(function(...)
					if done then return end

					done = true
					all:Reject(...)
				end)
			else
				results[i] = list.pack(cb)
				finish_one()
			end
		end

		return all
	end
end

function callback.WrapKeyedTask(create_callback, max, queue_callback, start_on_callback)
	local callbacks = {}
	local active = 0
	local queue = {}
	max = max or math.huge
	return function(key, ...)
		local args = list.pack(...)
		local cache_key = key

		if
			callbacks[cache_key] and
			not (
				callbacks[cache_key].is_resolved or
				callbacks[cache_key].is_rejected
			)
		then
			return callbacks[cache_key]
		end

		local cb = callback.Create(function(self)
			create_callback(self, key, list.unpack(args))
		end)
		cb.warn_unhandled = false
		cb.start_on_callback = start_on_callback
		callbacks[cache_key] = cb

		if active >= max then
			list.insert(queue, cb)
			cb.key = key

			if queue_callback then queue_callback("push", cb, key, queue) end
		else
			cb:Start()

			if max ~= math.huge then
				cb:Done(function()
					active = active - 1

					if active < max then
						local next_cb = list.remove(queue)

						if next_cb then
							if queue_callback then
								queue_callback("pop", next_cb, next_cb.key, queue)
							end

							next_cb:Start()
						end
					end
				end)

				active = active + 1
			end
		end

		--if tasks and tasks.IsEnabled() and tasks.GetActiveTask() then
		--if not tasks.GetActiveTask().is_test_task then return cb:Get() end
		--end
		return cb
	end
end

function callback.WrapTask(create_callback)
	return function(...)
		local args = list.pack(...)
		local cb = callback.Create(function(self)
			create_callback(self, list.unpack(args))
		end)
		cb:Start()
		return cb
	end
end

function callback.ResolveImmediate(...)
	local cb = callback.Create()
	cb:Resolve(...)
	return cb
end

function callback.Resolve(...)
	local cb = callback.Create()
	local args = {...}
	local count = select("#", ...)

	timer.Delay(0, function()
		cb:Resolve(unpack(args, 1, count))
	end)

	return cb
end

if HOTRELOAD then
	local Delay = callback.WrapTask(function(self, delay)
		local resolve = self.callbacks.resolve
		local reject = self.callbacks.reject

		timer.Delay(delay, function()
			resolve("result!")
		end)
	end)

	tasks.CreateTask(function()
		print(1)
		local res = Delay(1):Get()
		print(2, res)
	end)
end

return callback
