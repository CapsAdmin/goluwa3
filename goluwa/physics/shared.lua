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

return physics
