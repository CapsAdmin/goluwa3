local event = import("goluwa/event.lua")
local physics = import("goluwa/physics/shared.lua")
import("goluwa/physics/trace.lua")
import("goluwa/physics/constraint.lua")
import("goluwa/physics/solver.lua")
import("goluwa/physics/rigid_body.lua")

local function get_fixed_step()
	return math.max(physics.FixedTimeStep or (1 / 120), 0.000001)
end

function physics.Step(dt)
	if not dt or dt <= 0 then return end

	physics.UpdateRigidBodies(dt)
end

function physics.Update(dt)
	if not dt or dt <= 0 then return 0 end

	physics.FrameAccumulator = 0
	physics.InterpolationAlpha = 0
	local fixed_dt = get_fixed_step()
	local steps = 0

	while dt >= fixed_dt do
		physics.Step(fixed_dt)
		dt = dt - fixed_dt
		steps = steps + 1
	end

	if dt > 0 then
		physics.Step(dt)
		steps = steps + 1
	end

	return steps
end

function physics.UpdateFixed(dt)
	if not dt or dt <= 0 then return 0 end

	local max_frame_time = math.max(physics.MaxFrameTime or 0.1, 0)

	if max_frame_time > 0 then dt = math.min(dt, max_frame_time) end

	local fixed_dt = get_fixed_step()
	local accumulator = (physics.FrameAccumulator or 0) + dt
	local max_steps = math.max(1, physics.MaxCatchUpSteps or 1)
	local steps = 0

	while accumulator >= fixed_dt and steps < max_steps do
		physics.Step(fixed_dt)
		accumulator = accumulator - fixed_dt
		steps = steps + 1
	end

	if accumulator >= fixed_dt then accumulator = accumulator % fixed_dt end

	physics.FrameAccumulator = accumulator
	physics.InterpolationAlpha = accumulator / fixed_dt
	return steps
end

physics.UpdateFrame = physics.UpdateFixed

if not physics.UpdateListenerRegistered then
	event.AddListener("Update", "physics", function(dt)
		physics.UpdateFixed(dt)
	end)

	physics.UpdateListenerRegistered = true
end

return physics