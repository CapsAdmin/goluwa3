local T = import("test/environment.lua")

T.Test3D("weapon events burst their emitters: the hit, the force, the muzzle flash and the tool hit", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Entity = import("goluwa/entities/entity.lua")
	local vfx = import("goluwa/render3d/vfx.lua")
	local sounds = import("lua/sounds.lua")
	local weapon_effects = import("lua/weapon_effects.lua")
	local saved_play = sounds.Play
	sounds.Play = function() end
	local muzzle = {transform = {GetWorldPosition = ||->Vec3(0, 1, 0)}}
	local weapon = {weapon = {GetMuzzle = ||->muzzle}}
	weapon_effects.MuzzleFlash(weapon, Vec3(0, 0, 1))
	T(vfx.HasBurst("muzzle_flash"))["=="](true)
	weapon_effects.Hit(weapon, Vec3(0, 1, 2), Vec3(0, 0, -1), Vec3(0, 0, 0))
	T(vfx.HasBurst("hit_position"))["=="](true)
	T(vfx.HasBurst("hit_normal"))["=="](true)
	weapon_effects.Hit(weapon, Vec3(0, 1, 2), Vec3(0, 0, -1), Vec3(0, 0, 10))
	T(vfx.HasBurst("hit_force:Strength=3"))["=="](true)
	weapon_effects.ToolTrace(weapon, Vec3(0, 1, 3), Vec3(0, 0, -1))
	T(vfx.HasBurst("tool_hit"))["=="](true)
	sounds.Play = saved_play

	for _, child in ipairs(Entity.World:GetChildrenList()) do
		child:Remove()
	end
end)
