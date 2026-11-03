local T = import("test/environment.lua")

T.Test3D("a weapon hit with a force bursts the force emitter at the hit strength", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Entity = import("goluwa/entities/entity.lua")
	local vfx = import("goluwa/render3d/vfx.lua")
	local clips = import("goluwa/render3d/clips.lua")
	local weapon_effects = import("lua/weapon_effects.lua")
	weapon_effects.Init()
	clips.Play(
		"weapon_hit",
		{
			position = Vec3(0, 1, 0),
			normal = Vec3(0, 1, 0),
			force_direction = Vec3(1, 0, 0),
			speed = 2.5,
		}
	)
	T(vfx.HasBurst("hit_force:Strength=2.5"))["=="](true)

	for _, child in ipairs(Entity.World:GetChildrenList()) do
		child:Remove()
	end
end)
