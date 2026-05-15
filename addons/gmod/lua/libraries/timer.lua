local host_timer = import("goluwa/timer.lua")
local timer = gine.env.timer

function timer.Create(id, delay, repetitions, func)
	return host_timer.Repeat("gine_" .. tostring(id), delay, repetitions, function()
		func()
	end)
end

function timer.Destroy(id)
	return host_timer.RemoveTimer("gine_" .. tostring(id))
end

timer.Remove = timer.Destroy

function timer.Stop(id)
	return host_timer.StopTimer("gine_" .. tostring(id))
end

function timer.Start(id)
	return host_timer.StartTimer("gine_" .. tostring(id))
end

function timer.Exists(id)
	return host_timer.IsTimer("gine_" .. tostring(id))
end

function timer.Simple(delay, func)
	return host_timer.Delay(delay, function()
		func()
	end)
end