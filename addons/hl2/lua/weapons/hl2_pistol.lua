local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model("hl2_pistol", "models/weapons/w_pistol.mdl", Vec3(0, 0.07, -0.06), hl2.BACKWARD_X)
return {
	Values = {
		WorldSize = Vec3(0.04, 0.13, 0.2),
		WorldCenter = Vec3(0, 0.0, -0.07),
		Stance = "pistol",
		Slot = 2,
		Category = "hl2",
		DisplayName = "9mm Pistol",
		FireRate = 0.12,
		HoldOffset = Vec3(0.16, 0, 0),
		Holster = true,
		AimSlack = true,
		Replacement = "hl2_pistol",
		AmmoType = "pistol",
		ClipSize = 18,
		DefaultAmmo = 150,
		ReloadTime = 1.4,
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.035, 0.13, 0.2),
			Vec3(0, 0.03, -0.07),
			{Color = Color(0.2, 0.2, 0.22, 1), Roughness = 0.35, Metallic = 0.8}
		),
		nodes.Marker("muzzle", Vec3(0, 0.075, -0.17)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local hl2_gun = import("lua/hl2_gun.lua")
local META = hl2_gun.Gun(
	objects.CreateTemplate("weapon_hl2_pistol"),
	{
		Damage = 8,
		Spread = 0.012,
		Muzzle = "hl2_pistol",
		ReloadSound = "weapons/pistol/pistol_reload1.wav",
		EmptySound = "weapons/pistol/pistol_empty.wav",
	}
)
return META:Register()
]=====],
}
