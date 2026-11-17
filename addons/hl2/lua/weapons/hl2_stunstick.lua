local nodes = import("lua/weapon_nodes.lua")
local hl2 = import("lua/hl2.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
hl2.Model(
	"hl2_stunstick",
	"models/weapons/w_stunbaton.mdl",
	Vec3(0, 0, -0.05),
	hl2.BACKWARD_X
)
return {
	Values = {
		WorldSize = Vec3(0.06, 0.06, 0.43),
		WorldCenter = Vec3(0, 0, -0.08),
		Stance = "melee",
		Slot = 1.2,
		Category = "hl2",
		DisplayName = "Stunstick",
		FireRate = 0.8,
		Automatic = true,
		HoldOffset = Vec3(0.1, -0.05, 0),
		Replacement = "hl2_stunstick",
	},
	Nodes = {
		nodes.Replacement(
			Vec3(0.05, 0.05, 0.43),
			Vec3(0, 0, -0.08),
			{Color = Color(0.12, 0.12, 0.13, 1), Roughness = 0.4, Metallic = 0.6}
		),
		nodes.Marker("muzzle", Vec3(0, 0, -0.27)),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local hl2_gun = import("lua/hl2_gun.lua")
local META = hl2_gun.Melee(
	objects.CreateTemplate("weapon_hl2_stunstick"),
	{
		Damage = 40,
		Range = 1.4,
		Impulse = 6,
		DamageType = "lightning",
		MissDelay = 0.8,
		HitDelay = 0.8,
		SwingSounds = {"weapons/stunstick/stunstick_swing1.wav", "weapons/stunstick/stunstick_swing2.wav"},
		HitSounds = {"weapons/stunstick/stunstick_impact1.wav", "weapons/stunstick/stunstick_impact2.wav"},
		FleshSounds = {"weapons/stunstick/stunstick_fleshhit1.wav", "weapons/stunstick/stunstick_fleshhit2.wav"},
	}
)
return META:Register()
]=====],
}
