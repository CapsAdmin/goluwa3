local blade = import("lua/weapons/blade.lua")
local melee = import("lua/weapons/melee.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local model_replacements = import("lua/model_replacements.lua")
local SCALE = 0.45
model_replacements.Register(
	"greatsword",
	{
		Game = "gmod",
		Path = "models/props_c17/gravestone_cross001a.mdl",
		Position = FORWARD * (1.38 * SCALE),
		Rotation = Quat():SetAngles(Vec3(math.pi / 2, 0, 0)),
		Scale = Vec3(SCALE, SCALE, SCALE),
	}
)
return {
	Values = {
		WorldSize = Vec3(0.45, 0.35, 1.4),
		WorldCenter = FORWARD * 0.65,
		WorldMass = 25,
		Slot = 4.6,
		DisplayName = "Greatsword",
		Category = "melee",
		Stance = "melee",
		TwoHanded = true,
		SupportGrip = Vec3(0, -0.15, 0.07),
		HoldOffset = Vec3(0.05, -0.1, 0),
		FireRate = 0.05,
		Replacement = "greatsword",
		Rollable = true,
		Sheath = "back",
		SheathOffset = Vec3(0.12, 0.32, 0.22),
		SheathRotation = blade.SheathRotation(Vec3(-0.5, -1, 0.1)),
	},
	Nodes = blade.Nodes{
		Radius = 0.05,
		Length = 1.37,
		Pommel = 0.06,
		Grip = -0.05,
		Base = 0.15,
		Tip = 1.3,
		Material = {Color = Color(0.5, 0.5, 0.48, 1), Roughness = 0.8, Metallic = 0},
	},
	Source = melee.Source,
	ScriptValues = {
		Moveset = "greatsword",
		Damage = 38,
		Range = 2.4,
		SwingPitch = 0.65,
		Guard = 0.75,
		Parry = 0.12,
	},
}
