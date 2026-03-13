local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import.loaded["goluwa/physics/shared.lua"] or
	import.loaded["goluwa/physics/init.lua"] or
	import.loaded["goluwa/physics.lua"]

if not physics then physics = library() end

import.loaded["goluwa/physics/shared.lua"] = physics
import.loaded["goluwa/physics/init.lua"] = physics
import.loaded["goluwa/physics.lua"] = physics
physics.Gravity = physics.Gravity or Vec3(0, -28, 0)
physics.Up = physics.Up or Vec3(0, 1, 0)
physics.DefaultSkin = physics.DefaultSkin or 0.02
physics.RigidBodySubsteps = physics.RigidBodySubsteps or 6
physics.RigidBodyIterations = physics.RigidBodyIterations or 2
physics.DistanceConstraints = physics.DistanceConstraints or {}

function physics.GetRigidBodyMeta()
	return import("goluwa/ecs/components/3d/rigid_body.lua")
end

function physics.IsActiveRigidBody(body)
	return body and
		body.Enabled and
		body.Owner and
		body.Owner.IsValid and
		body.Owner:IsValid() and
		body.Owner.transform
end

return physics