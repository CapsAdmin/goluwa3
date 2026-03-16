local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local traceback = import("goluwa/helpers/traceback.lua")
local timer = library()
timer.timers = timer.timers or {}
timer.MaxThinkerIterations = timer.MaxThinkerIterations or 128

local function get_precise_time_seconds()
	if system.GetTimeNS then return system.GetTimeNS() / 1000000000 end

	return system.GetTime()
end

function timer.Thinker(callback, run_now, frequency, iterations, id)
	if run_now and callback() == true then return end

	local info = {
		key = id or callback,
		type = "thinker",
		realtime = 0,
		callback = callback,
	}

	if iterations == true then
		info.fps = frequency or 120
		info.fps = 1 / info.fps
	else
		info.frequency = frequency or 0
		info.iterations = iterations or 1
	end

	list.insert(timer.timers, info)
end

function timer.Delay(time, callback, id, obj, ...)
	if not callback then
		callback = time
		time = 0
	end

	time = time or 0

	if id then
		for _, v in ipairs(timer.timers) do
			if v.key == id then
				v.realtime = system.GetElapsedTime() + time
				return
			end
		end
	end

	if obj and has_index(obj) and obj.IsValid then
		local old = callback
		callback = function(...)
			if obj:IsValid() then return old(...) end
		end
	end

	list.insert(
		timer.timers,
		{
			key = id or callback,
			type = "delay",
			callback = callback,
			realtime = system.GetElapsedTime() + time,
			args = {...},
		}
	)
end

function timer.Repeat(id, time, repeats, callback, run_now, error_callback)
	if not callback then
		callback = repeats
		repeats = 0
	end

	id = tostring(id)
	time = math.abs(time)
	repeats = math.max(repeats, 0)
	local data

	for _, v in ipairs(timer.timers) do
		if v.key == id then
			data = v

			break
		end
	end

	local is_new = data == nil
	data = data or {}
	data.key = id
	data.type = "timer"
	data.realtime = 0
	data.id = id
	data.time = time
	data.repeats = repeats
	data.callback = callback
	data.times_ran = 1
	data.paused = false
	data.error_callback = error_callback or function(id, msg)
		logn(id, msg)
	end

	if is_new then list.insert(timer.timers, data) end

	if run_now then
		callback(repeats - 1)
		data.repeats = data.repeats - 1
	end
end

function timer.RemoveTimer(id)
	for k, v in ipairs(timer.timers) do
		if v.key == id then
			list.remove(timer.timers, k)
			--profiler.RemoveSection(v.id)
			return true
		end
	end
end

function timer.StopTimer(id)
	for k, v in ipairs(timer.timers) do
		if v.key == id then
			v.realtime = 0
			v.times_ran = 1
			v.paused = true
			return true
		end
	end
end

function timer.StartTimer(id)
	for k, v in ipairs(timer.timers) do
		if v.key == id then
			v.paused = false
			return true
		end
	end
end

function timer.IsTimer(id)
	for k, v in ipairs(timer.timers) do
		if v.key == id then return true end
	end
end

local remove_these = {}
local updating = 0

function timer.UpdateTimers(a_, b_, c_, d_, e_)
	updating = updating + 1
	local cur = system.GetElapsedTime()
	local snapshot = {}

	for i, data in ipairs(timer.timers) do
		snapshot[i] = data
	end

	for _, data in ipairs(snapshot) do
		if remove_these[data] then goto continue end

		if data.type == "thinker" then
			if data.fps then
				local spent_time = 0
				local max_iterations = math.max(1, data.max_iterations or timer.MaxThinkerIterations or 128)
				local iterations = 0

				repeat
					iterations = iterations + 1
					local callback_start = get_precise_time_seconds()
					local res = data.callback()
					local callback_time = tonumber(get_precise_time_seconds() - callback_start) or 0

					if callback_time > 0 then spent_time = spent_time + callback_time end

					if res == true then
						remove_these[data] = true

						break
					elseif res == false then
						break
					end				
				until iterations >= max_iterations or spent_time >= data.fps
			else
				if data.realtime < cur then
					local fps = ((cur + data.frequency) - data.realtime)
					local extra_iterations = math.ceil(fps / data.frequency) - 2

					if extra_iterations == math.huge then extra_iterations = 1 end

					local done = false

					for _ = 1, data.iterations + extra_iterations do
						local res = data.callback()

						if res == true then
							done = true

							break
						elseif res == false then
							break
						end
					end

					if done then remove_these[data] = true end

					data.realtime = cur + data.frequency
				end
			end
		elseif data.type == "delay" then
			if data.realtime < cur then
				if not data.args then
					data.callback()
				else
					data.callback(unpack(data.args))
				end

				remove_these[data] = true
			end
		elseif data.type == "timer" then
			if not data.paused and data.realtime < cur then
				local msg = data.callback(data.times_ran - 1, a_, b_, c_, d_, e_)

				if msg == "stop" then remove_these[data] = true end

				if msg == "restart" then data.times_ran = 1 end

				if type(msg) == "number" then data.realtime = cur + msg end

				if data.times_ran == data.repeats then
					remove_these[data] = true
				--profiler.RemoveSection(data.id)
				else
					data.times_ran = data.times_ran + 1
					data.realtime = cur + data.time
				end
			end
		end

		::continue::
	end

	updating = updating - 1

	if updating == 0 and next(remove_these) then
		local write = 1

		for read = 1, #timer.timers do
			local data = timer.timers[read]

			if data and not remove_these[data] then
				timer.timers[write] = data
				write = write + 1
			end
		end

		for i = write, #timer.timers do
			timer.timers[i] = nil
		end

		remove_these = {}
	end
end

event.AddListener("Update", "timers", timer.UpdateTimers, {on_error = traceback.OnError})
return timer