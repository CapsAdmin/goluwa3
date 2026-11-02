local blade = import("lua/weapons/blade.lua")
local melee = import("lua/weapons/melee.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local model_replacements = import("lua/model_replacements.lua")
local SCALE = 1.25
local LENGTH = 1.55
local POMMEL = 0.12
model_replacements.Register(
	"shovel",
	{
		Game = "gmod",
		Path = "models/props_junk/shovel01a.mdl",
		Position = FORWARD * (LENGTH / 2 - POMMEL),
		Rotation = Quat():SetAngles(Vec3(math.pi / 2, 0, 0)),
		Scale = Vec3(SCALE, SCALE, SCALE),
	}
)
return {
	Values = {
		WorldSize = Vec3(0.25, 0.08, LENGTH),
		WorldCenter = FORWARD * (LENGTH / 2 - POMMEL),
		WorldMass = 6,
		Slot = 4.9,
		DisplayName = "Gravedigger",
		Category = "melee",
		Stance = "melee",
		TwoHanded = true,
		SupportGrip = Vec3(0, -0.15, 0.07),
		HoldOffset = Vec3(0.05, -0.1, 0),
		FireRate = 0.05,
		Replacement = "shovel",
		Rollable = true,
		Sheath = "back",
		SheathOffset = Vec3(0.12, 0.3, 0.2),
		SheathRotation = blade.SheathRotation(Vec3(-0.5, -1, 0.1)),
	},
	Nodes = blade.Nodes{
		Radius = 0.025,
		Length = LENGTH,
		Pommel = POMMEL,
		Grip = -0.05,
		Base = 1.05,
		Tip = 1.4,
		Material = {Color = Color(0.42, 0.3, 0.2, 1), Roughness = 0.8, Metallic = 0},
	},
	Source = melee.Source,
	ScriptValues = {
		Moveset = "shovel",
		Damage = 26,
		Range = 2.2,
		SwingPitch = 0.75,
		TrailColor = Color(0.95, 0.8, 0.55, 1),
		Guard = 0.6,
		Parry = 0.15,
	},
}
