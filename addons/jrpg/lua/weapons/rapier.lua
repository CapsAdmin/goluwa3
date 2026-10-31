local blade = import("lua/weapons/blade.lua")
local melee = import("lua/weapons/melee.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local model_replacements = import("lua/model_replacements.lua")
local SCALE = 0.55
model_replacements.Register(
	"rapier",
	{
		Game = "gmod",
		Path = "models/props_junk/harpoon002a.mdl",
		Position = FORWARD * (0.85 * SCALE),
		Rotation = Quat(0, 0, 0, 1),
		Scale = Vec3(SCALE, SCALE, SCALE),
	}
)
return {
	Values = {
		WorldSize = Vec3(0.06, 0.06, 1.15),
		WorldCenter = FORWARD * 0.45,
		WorldMass = 1.5,
		Slot = 4.7,
		DisplayName = "Rapier",
		Category = "melee",
		Stance = "melee",
		HoldOffset = Vec3(0.12, -0.03, 0),
		FireRate = 0.05,
		Replacement = "rapier",
		Rollable = true,
		Sheath = "back",
		SheathOffset = Vec3(0.12, 0.25, 0.16),
		SheathRotation = blade.SheathRotation(Vec3(-0.5, -1, 0.1)),
	},
	Nodes = blade.Nodes{
		Radius = 0.012,
		Length = 1.13,
		Pommel = 0.1,
		Grip = -0.06,
		Base = 0.1,
		Tip = 1.02,
		Material = {Color = Color(0.85, 0.86, 0.9, 1), Roughness = 0.15, Metallic = 1},
	},
	Source = melee.Source,
	ScriptValues = {
		Moveset = "rapier",
		Damage = 12,
		Range = 1.9,
		SwingPitch = 1.35,
		Guard = 0.4,
		Parry = 0.25,
	},
}
