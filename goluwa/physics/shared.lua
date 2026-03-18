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
physics.PreviousCollisionPairs = physics.PreviousCollisionPairs or {}
physics.CurrentCollisionPairs = physics.CurrentCollisionPairs or {}
physics.PreviousWorldCollisionPairs = physics.PreviousWorldCollisionPairs or {}
physics.CurrentWorldCollisionPairs = physics.CurrentWorldCollisionPairs or {}
physics.WorldTraceSource = physics.WorldTraceSource or nil
physics.EPSILON = 0.000001

function physics.SetWorldTraceSource(source)
	physics.WorldTraceSource = source
	return source
end

function physics.GetWorldTraceSource()
	return physics.WorldTraceSource
end

function physics.GetInterpolationAlpha()
	return math.min(math.max(physics.InterpolationAlpha or 0, 0), 1)
end

function physics.IsActiveRigidBody(body)
	if body and body.GetBody then body = body:GetBody() end

	return body and
		body.Enabled and
		body.Owner and
		body.Owner.IsValid and
		body.Owner:IsValid() and
		body.Owner.transform
end

return physics