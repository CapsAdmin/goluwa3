local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
physics.FixedTimeStep = (1 / 60)
physics.RigidBodyIterations = 1
physics.RigidBodySubsteps = 1
physics.Gravity = Vec3(0, -28, 0)
physics.Up = Vec3(0, 1, 0)
physics.DefaultSkin = 0.02
physics.MaxFrameTime = 0.1
physics.FrameAccumulator = 0
physics.InterpolationAlpha = 0
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
