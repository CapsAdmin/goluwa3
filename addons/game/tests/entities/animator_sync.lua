local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")

local function create_animator(duration, time)
	local animator = Entity.New{animator = {}}.animator
	animator.clip = {Duration = duration}
	animator.clip_dirty = false
	animator.time = time
	return animator
end

T.Test("an animator snaps to a far cycle and follows a near one smoothly", function()
	local animator = create_animator(2, 0.2)
	animator:SyncCycle(0.5, 1 / 60)
	T(animator.time)["~"](1, 1e-9)
	animator.time = 1
	animator:SyncCycle(0.6, 1 / 60)
	T(animator.time > 1 and animator.time < 1.2)["=="](true)

	for _ = 1, 120 do
		animator:SyncCycle(0.6, 1 / 60)
	end

	T(animator.time)["~"](1.2, 0.001)
	animator.Owner:Remove()
end)

T.Test("an animator follows a cycle across the loop point the short way round", function()
	local animator = create_animator(2, 1.9)

	for _ = 1, 120 do
		animator:SyncCycle(0.05, 1 / 60)
	end

	T(animator.time)["~"](0.1, 0.001)
	animator.Owner:Remove()
end)

T.Test("two animators on different frame histories end on the same cycle of a shared clock", function()
	local duration, rate = 1.3, 1.07
	local first = create_animator(duration, 0.1)
	local second = create_animator(duration, 0.9)
	local clock = 100

	for step = 1, 600 do
		local dt_first = 1 / 60
		local dt_second = step % 3 == 0 and 1 / 30 or 1 / 90
		clock = clock + 1 / 60
		first.time = (first.time + dt_first * rate) % duration
		second.time = (second.time + dt_second * rate * 0.5) % duration
		local target = clock * rate / duration % 1
		first:SyncCycle(target, dt_first)
		second:SyncCycle(target, dt_second)
	end

	local difference = math.abs(first.time - second.time) / duration
	T(math.min(difference, 1 - difference))["<"](0.05)
	first.Owner:Remove()
	second.Owner:Remove()
end)
