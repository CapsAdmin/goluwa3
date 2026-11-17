local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local model_replacements = import("lua/model_replacements.lua")
local PLACEHOLDER = {Color = Color(0.16, 0.17, 0.2, 1), Roughness = 0.3, Metallic = 0.9}
model_replacements.Register(
	"pistol",
	{
		Game = 546560,
		Path = "models/weapons/vr_pistol/vr_pistol.vmdl_c",
		Position = Vec3(0, 0.02, 0.03),
		Rotation = Quat(0, 0, 0, 1),
		Scale = Vec3(1.15, 1.15, 1.15),
	}
)
return {
	Values = {
		WorldSize = Vec3(0.05, 0.18, 0.32),
		WorldCenter = Vec3(0, 0.03, -0.14),
		Stance = "pistol",
		Slot = 2,
		DisplayName = "Pistol",
		FireRate = 0.25,
		HoldOffset = Vec3(0.16, 0, 0),
		Holster = true,
		AimSlack = true,
		Rollable = true,
		Replacement = "pistol",
	},
	Nodes = {
		nodes.Replacement(Vec3(0.03, 0.14, 0.2), Vec3(0, 0.02, -0.07), PLACEHOLDER),
		nodes.Marker("muzzle", Vec3(0, 0.07, -0.2)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local bullets = import("lua/bullets.lua")
local META = objects.CreateTemplate("weapon_pistol")
META:GetSet("Range", 50)
META:GetSet("Damage", 20)
META:GetSet("Impulse", 6)
META:GetSet("LimpSpread", 0.3)

function META:Shoot(cmd)
	local player = self.Owner:GetParent()
	local ragdoll = player.ragdoll
	local limp = ragdoll and math.max(ragdoll:GetPartLimp("upperarm_r"), ragdoll:GetPartLimp("forearm_r")) or 0
	bullets.Fire{
		Weapon = self.Owner,
		Attacker = player,
		Origin = bullets.GetEye(player),
		Direction = cmd.aim:GetForward(),
		Spread = self.LimpSpread * limp,
		Range = self.Range,
		Damage = self.Damage,
		Impulse = self.Impulse,
		Muzzle = "pistol",
	}
end

function META:OnWeaponPredictPrimary(cmd)
	self:Shoot(cmd)
end

function META:OnWeaponPrimary(cmd)
	self:Shoot(cmd)
end

return META:Register()
]=====],
}
