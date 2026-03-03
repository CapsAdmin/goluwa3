local timer = require("timer")
local tasks = require("tasks")
local callback = library()

do
	local meta = {}
	meta.__index = meta

	--meta.Type = "callback"
	function meta:__tostring()
		return string.format("callback: %p", self)
	end

	function meta:Start()
		if not self.on_start then return end

		if self.start_on_callback then return end

		self:on_start()
		return self
	end

	function meta:Stop()
		if self.on_stop then self:on_stop() end
	end

	local function done(self)
		for _, cb in ipairs(self.funcs.done) do
			cb()
		end
	end

	function meta:Resolve(...)
		if self.is_resolved or self.is_rejected then
			--[[
			logn(
				self,
				"attempted to resolve " .. (
						self.is_resolved and
						"resolved" or
						"rejected"
					) .. " promise"
			)
			logn(self.debug_trace)
			]]
			return
		end

		if not self.funcs.resolved[1] and self.warn_unhandled then
			logn(self, " unhandled resolve: ", ...)
			logn(self.debug_trace)
		end

		self.resolved_values = list.pack(...)

		for _, cb in ipairs(self.funcs.resolved) do
			local ok, err, err2 = pcall(cb, ...)

			if not ok then
				self:Reject(err)
				return false, err
			end

			if ok and err == false and type(err2) == "string" then
				self:Reject(err2)
				return false, err2
			end
		end

		done(self)
		self.is_resolved = true
		return self
	end

	local handled = false

	function meta:Reject(msg, ...)
		if self.is_resolved then
			--logn(self, "attempted to resolve resolved promise")
			--logn(self.debug_trace)
			return
		end

		handled = false
		self.rejected_values = list.pack(msg, ...)

		if self.children then
			for _, cb in ipairs(self.children) do
				cb:Reject(msg, ...)
			end
		end

		for _, cb in ipairs(self.funcs.rejected) do
			cb(msg, ...)
			handled = true
		end

		if not handled and self.warn_unhandled then
			logn(self, " unhandled reject: ", ...)
			logn(debug.traceback("current trace:"))
			logn(self.debug_trace)
		end

		done(self)
		self.is_rejected = true
		return self
	end

	function meta:Then(func)
		local cb = callback.Create()
		cb:SetParent(self)
		cb.error_level = self.error_level
		cb.warn_unhandled = false

		local function resolve(...)
			local ret = list.pack(func(...))
			local returned_cb = ret[1]

			if getmetatable(returned_cb) == meta then
				returned_cb:Catch(function(...)
					return cb:Reject(...)
				end)

				return returned_cb:Then(function(...)
					return cb:Resolve(...)
				end),
				list.unpack(ret, 2)
			else
				cb:Resolve(...)
			end

			return list.unpack(ret)
		end

		if self.is_resolved then
			local result = list.pack(resolve(unpack(self.resolved_values)))
			return result[1]
		end

		list.insert(self.funcs.resolved, resolve)

		if self.start_on_callback then
			self.start_on_callback = nil
			self:Start()
		end

		return cb
	end

	function meta:Catch(func)
		list.insert(self.funcs.rejected, func)

		if self.is_rejected then func(unpack(self.rejected_values)) end

		return self
	end

	function meta:Done(callback)
		list.insert(self.funcs.done, callback)
		return self
	end

	function meta:ErrorLevel(level)
		self.error_level = level

		if self.children then
			for _, child in ipairs(self.children) do
				child:ErrorLevel(level)
			end
		end

		return self
	end

	function meta:Get()
		local res
		local err

		self:Then(function(...)
			res = {...}
		end)

		self:Catch(function(msg)
			err = msg
		end)

		while not res do
			if err then error(tostring(err), self.error_level or 3) end

			tasks.Wait()
		end

		return unpack(res)
	end

	function meta:Subscribe(what, callback)
		self.funcs[what] = self.funcs[what] or {}
		table.insert(self.funcs[what], callback)

		if self.values and self.values[what] then
			for _, args in ipairs(self.values[what]) do
				callback(table.unpack(args))
			end
		end

		if self.children then
			for _, child in ipairs(self.children) do
				child:Subscribe(what, callback)
			end
		end

		return self
	end

	function meta:Trigger(what, ...)
		self.values = self.values or {}
		self.values[what] = self.values[what] or {}
		table.insert(self.values[what], {...})

		if self.funcs[what] then
			for _, cb in ipairs(self.funcs[what]) do
				local ok, res, err = pcall(cb, ...)

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

		if self.children then
			for _, child in ipairs(self.children) do
				local ok, err = child:Trigger(what, ...)

				if ok == false then return false, err end
			end
		end

		return true
	end

	local function on_index(t, key)
		local self = t.self
		return function(...)
			if key == "resolve" then
				local ok, err = self:Resolve(...)

				if ok == false and type(err) == "string" then
					self.is_resolved = false
					self:Reject(err)
				end

				return
			elseif key == "reject" then
				return self:Reject(...)
			end

			print(self, key)
			self:Trigger(key, ...)
		end
	end

	function callback.Create(on_start)
		local self = setmetatable({}, meta)
		self.on_start = on_start
		self.funcs = {resolved = {}, rejected = {}, done = {}}
		self.callbacks = setmetatable({self = self}, {__index = on_index})
		self.debug_trace = debug.traceback("creation trace:")
		self.children = {}
		self.warn_unhandled = true
		return self
	end

	function meta:SetParent(parent)
		self.parent = parent
		list.insert(parent.children, self)
		return self
	end
end

function callback.WrapKeyedTask(create_callback, max, queue_callback, start_on_callback)
	local callbacks = {}
	local total = 0
	local queue = {}
	max = max or math.huge

	local function add(key, options, ...)
		local args = list.pack(...)

		if callbacks[key] and not (callbacks[key].is_resolved or callbacks[key].is_rejected) then
			return callbacks[key]
		end

		local last_cb = callbacks[key]
		callbacks[key] = callback.Create(function(self)
			create_callback(self, key, list.unpack(args))
		end)
		callbacks[key].warn_unhandled = false
		callbacks[key].start_on_callback = start_on_callback

		if type(options) == "table" then
			if options.error_level then
				callbacks[key]:ErrorLevel(options.error_level)
			end
		end

		if total >= max then
			list.insert(queue, callbacks[key])
			callbacks[key].key = key

			if queue_callback then
				queue_callback("push", callbacks[key], key, queue)
			end
		else
			callbacks[key]:Start()

			if max ~= math.huge then
				callbacks[key]:Done(function()
					total = total - 1

					if total < max then
						local cb = list.remove(queue)

						if cb then
							if queue_callback then
								queue_callback("pop", cb, cb.key, queue)
							end

							cb:Start()
						end
					end
				end)

				total = total + 1
			end
		end

		if tasks and tasks.IsEnabled() and tasks.GetActiveTask() then
			local active_task = tasks.GetActiveTask()

			-- Don't auto-wait for test tasks - they need to control async behavior
			if not active_task.is_test_task then return callbacks[key]:Get() end
		end

		return callbacks[key]
	end

	return add
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
	local function await(func)
		tasks.CreateTask(func)
	end

	local Delay = callback.WrapTask(function(self, delay)
		local resolve = self.callbacks.resolve
		local reject = self.callbacks.reject

		timer.Delay(delay, function()
			resolve("result!")
		end)
	end)

	await(function()
		print(1)
		local res = Delay(1):Get()
		print(2, res)
	end)
end

return callback