local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
hl2.Model(
	"hl2_bugbait",
	"models/weapons/w_bugbait.mdl",
	Vec3(0, 0.0, -0.05),
	Quat(0, 0, 0, 1)
)
return {
	Values = {
		WorldSize = Vec3(0.14, 0.15, 0.14),
		WorldCenter = Vec3(0, 0, -0.05),
		Slot = 6,
		Category = "hl2",
		DisplayName = "Bugbait",
		Stance = "grenade",
		FireRate = 1,
		Replacement = "hl2_bugbait",
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.14, 0.15, 0.14),
			Vec3(0, 0, -0.05),
			{Color = Color(0.6, 0.35, 0.3, 1), Roughness = 0.6, Metallic = 0}
		),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local hl2 = import("lua/hl2.lua")
local META = objects.CreateTemplate("weapon_hl2_bugbait")
META:GetSet("ThrowSpeed", 14)
local SQUEEZE = {
	"weapons/bugbait/bugbait_squeeze1.wav",
	"weapons/bugbait/bugbait_squeeze2.wav",
	"weapons/bugbait/bugbait_squeeze3.wav",
}

function META:OnWeaponPrimary(cmd)
	local caster = self.Owner:GetParent()
	local velocity = cmd.aim:GetForward() * self.ThrowSpeed + Vec3(0, 2, 0)

	if caster.rigid_body then velocity = velocity + caster.rigid_body:GetVelocity() end

	caster.character_pose:PlayAction("cast_r", 0.35)
	hl2.Sound(self.Owner, "weapons/slam/throw.wav", 70, 1.2)
	hl2.Launch(caster, self.Owner, hl2.GetLaunchOrigin(caster, cmd.aim, 0.5), velocity, {Kind = "bugbait", Life = 6})
end

function META:OnWeaponSecondary()
	hl2.RandomSound(self.Owner, SQUEEZE, 75)
	return 0.6
end

return META:Register()
]=====],
}
