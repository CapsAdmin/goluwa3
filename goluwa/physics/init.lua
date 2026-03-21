local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
import("goluwa/physics/shared.lua")
local Broadphase = import("goluwa/physics/broadphase.lua")
local CollisionPairs = import("goluwa/physics/collision_pairs.lua")
import("goluwa/physics/convex_hull.lua")
import("goluwa/physics/sweep.lua")
import("goluwa/physics/trace.lua")
import("goluwa/physics/constraint.lua")
local Solver = import("goluwa/physics/solver.lua")
local mesh_contact_pipeline = import("goluwa/physics/mesh_contact_pipeline.lua")
physics.collision_pairs = physics.collision_pairs or CollisionPairs.New({physics = physics})
physics.broadphase = physics.broadphase or Broadphase.New({physics = physics})
physics.solver = Solver.New({physics = physics})
import("goluwa/physics/pair_solvers/polyhedron.lua")
import("goluwa/physics/pair_solvers/sphere.lua")
import("goluwa/physics/pair_solvers/capsule.lua")
import("goluwa/physics/pair_solvers/box.lua")
mesh_contact_pipeline.RegisterPairHandlers(physics.solver)
import("goluwa/physics/rigid_body.lua")

function physics.ResetState()
	local collision_pairs = physics.collision_pairs or CollisionPairs.New({physics = physics})
	local broadphase = physics.broadphase or Broadphase.New({physics = physics})
	local solver = physics.solver or Solver.New({physics = physics})
	local constraints = physics.GetConstraints and physics.GetConstraints() or nil
	physics.collision_pairs = collision_pairs
	physics.broadphase = broadphase
	physics.solver = solver
	collision_pairs:ResetState()
	broadphase:ResetState()
	solver:ResetState()

	if constraints then
		for i = #constraints, 1, -1 do
			local constraint = constraints[i]

			if not (constraint and constraint.IsValid and constraint:IsValid()) then
				table.remove(constraints, i)
			end
		end
	end

end

local function get_fixed_step()
	return math.max(physics.FixedTimeStep, 0.000001)
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
	local steps = 0

	while accumulator >= fixed_dt do
		physics.Step(fixed_dt)
		accumulator = accumulator - fixed_dt
		steps = steps + 1
	end

	if accumulator >= fixed_dt then accumulator = accumulator % fixed_dt end

	physics.FrameAccumulator = accumulator
	physics.InterpolationAlpha = accumulator / fixed_dt
	return steps
end

if not physics.UpdateListenerRegistered then
	event.AddListener("Update", "physics", function(dt)
		physics.UpdateFixed(dt)
	end)

	physics.UpdateListenerRegistered = true
end

return physics
