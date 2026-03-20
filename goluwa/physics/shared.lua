local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
physics.DefaultRigidBodyIterations = physics.DefaultRigidBodyIterations or 1
physics.DefaultRigidBodySubsteps = physics.DefaultRigidBodySubsteps or 2
physics.DefaultFixedTimeStep = physics.DefaultFixedTimeStep or (1 / 30)
physics.RigidBodyIterations = physics.RigidBodyIterations or physics.DefaultRigidBodyIterations
physics.RigidBodySubsteps = physics.RigidBodySubsteps or physics.DefaultRigidBodySubsteps
physics.Gravity = physics.Gravity or Vec3(0, -28, 0)
physics.Up = physics.Up or Vec3(0, 1, 0)
physics.DefaultSkin = physics.DefaultSkin or 0.02
physics.FixedTimeStep = physics.FixedTimeStep or physics.DefaultFixedTimeStep
physics.MaxFrameTime = physics.MaxFrameTime or 0.1
physics.MaxCatchUpSteps = physics.MaxCatchUpSteps or 8
physics.BusyMaxFrameTime = physics.BusyMaxFrameTime or (1 / 30)
physics.BusyMaxCatchUpSteps = physics.BusyMaxCatchUpSteps or 1
physics.DropBusyFrameDebt = physics.DropBusyFrameDebt ~= false
physics.FrameAccumulator = physics.FrameAccumulator or 0
physics.InterpolationAlpha = physics.InterpolationAlpha or 0
physics.EPSILON = 0.000001

function physics.GetInterpolationAlpha()
	return math.min(math.max(physics.InterpolationAlpha or 0, 0), 1)
end

function physics.IsActiveRigidBody(body)
	if not body then return nil end
	if body.GetBody then body = body:GetBody() end
	if not (body and body.Enabled) then return nil end

	local owner = body.Owner

	if not (owner and owner.transform and owner.IsValid) then return nil end

	return owner:IsValid() and owner.transform or nil
end

return physics
