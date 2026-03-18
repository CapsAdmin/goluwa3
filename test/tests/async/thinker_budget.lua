local T = import("test/environment.lua")
local timer = import("goluwa/timer.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")

T.Test("fps-limited thinkers still make progress during a slow frame", function()
	local id = "test_slow_frame_thinker_progress"
	local old_frame_time = system.GetFrameTime()
	local count = 0

	timer.Thinker(
		function()
			count = count + 1

			if count >= 5 then return true end
		end,
		true,
		30,
		true,
		id
	)

	system.SetFrameTime(0.25)
	system.SetElapsedTime(system.GetElapsedTime() + 0.016)
	event.Call("Update", 0.016)
	local observed = count
	system.SetFrameTime(old_frame_time)

	T.WaitUntil(function()
		return not (timer.IsTimer(id) or false)
	end, 1)

	-- Tasks use fps-limited thinkers for `EnsureFPS`, so a slow frame should not
	-- force cheap callbacks to advance only once per update.
	T(observed)[">="](5)
	T(timer.IsTimer(id) or false)["=="](false)
end)
