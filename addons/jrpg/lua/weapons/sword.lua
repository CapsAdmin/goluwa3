local blade = import("lua/weapons/blade.lua")
local melee = import("lua/weapons/melee.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local model_replacements = import("lua/model_replacements.lua")
model_replacements.Register(
	"sword",
	{
		Game = "gmod",
		Path = "models/weapons/w_crowbar.mdl",
		Position = FORWARD * 0.383,
		Rotation = Quat():SetAngles(Vec3(0, math.pi, 0)),
		Scale = Vec3(1.66, 1.66, 1.66),
	}
)
return {
	Values = {
		WorldSize = Vec3(0.2, 0.05, 1.1),
		WorldCenter = FORWARD * 0.4,
		Slot = 4.5,
		DisplayName = "Sword",
		Category = "melee",
		Stance = "melee",
		HoldOffset = Vec3(0.1, -0.05, 0),
		FireRate = 0.05,
		Replacement = "sword",
		Rollable = true,
		Sheath = "back",
		SheathOffset = Vec3(0.12, 0.25, 0.18),
		SheathRotation = blade.SheathRotation(Vec3(-0.5, -1, 0.1)),
	},
	Nodes = blade.Nodes{
		Radius = 0.025,
		Length = 1.08,
		Pommel = 0.11,
		Grip = -0.08,
		Base = 0.14,
		Tip = 0.97,
		Material = {Color = Color(0.78, 0.8, 0.84, 1), Roughness = 0.22, Metallic = 1},
	},
	Source = melee.Source,
	ScriptValues = {Moveset = "sword", Damage = 22, Range = 1.7},
}
