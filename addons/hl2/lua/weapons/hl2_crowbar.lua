local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model("hl2_crowbar", "models/weapons/w_crowbar.mdl", Vec3(0, 0, -0.25), hl2.FORWARD_Z)
return {
	Values = {
		WorldSize = Vec3(0.1, 0.12, 0.65),
		WorldCenter = Vec3(0, 0, -0.25),
		Stance = "melee",
		Slot = 1,
		Category = "hl2",
		DisplayName = "Crowbar",
		FireRate = 0.4,
		Automatic = true,
		HoldOffset = Vec3(0.1, -0.05, 0),
		Replacement = "hl2_crowbar",
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.03, 0.06, 0.65),
			Vec3(0, 0, -0.25),
			{Color = Color(0.55, 0.12, 0.08, 1), Roughness = 0.45, Metallic = 0.8}
		),
		nodes.Marker("muzzle", Vec3(0, 0, -0.55)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local hl2_gun = import("lua/hl2_gun.lua")
local META = hl2_gun.Melee(
	objects.CreateTemplate("weapon_hl2_crowbar"),
	{
		Damage = 25,
		Range = 1.5,
		MissDelay = 0.4,
		HitDelay = 0.5,
		SwingSounds = {"weapons/iceaxe/iceaxe_swing1.wav"},
		HitSounds = {"weapons/crowbar/crowbar_impact1.wav", "weapons/crowbar/crowbar_impact2.wav"},
		FleshSounds = {
			"physics/flesh/flesh_impact_bullet1.wav",
			"physics/flesh/flesh_impact_bullet2.wav",
			"physics/flesh/flesh_impact_bullet3.wav",
			"physics/flesh/flesh_impact_bullet4.wav",
			"physics/flesh/flesh_impact_bullet5.wav",
		},
	}
)
return META:Register()
]=====],
}
