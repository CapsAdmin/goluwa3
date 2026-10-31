local blade = import("lua/weapons/blade.lua")
local melee = import("lua/weapons/melee.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local model_replacements = import("lua/model_replacements.lua")
local SCALE = 1.6
model_replacements.Register(
	"reaper",
	{
		Game = "gmod",
		Path = "models/props_junk/meathook001a.mdl",
		Position = FORWARD * (0.3 * SCALE),
		Rotation = Quat():SetAngles(Vec3(math.pi / 2, 0, 0)),
		Scale = Vec3(SCALE, SCALE, SCALE),
	}
)
return {
	Values = {
		WorldSize = Vec3(0.45, 0.06, 1.3),
		WorldCenter = FORWARD * 0.5,
		WorldMass = 4,
		Slot = 4.8,
		DisplayName = "Reaper",
		Category = "melee",
		Stance = "melee",
		HoldOffset = Vec3(0.1, -0.05, 0),
		FireRate = 0.05,
		Replacement = "reaper",
		Rollable = true,
		Sheath = "back",
		SheathOffset = Vec3(0.12, 0.25, 0.18),
		SheathRotation = blade.SheathRotation(Vec3(-0.5, -1, 0.1)),
	},
	Nodes = blade.Nodes{
		Radius = 0.03,
		Length = 1.32,
		Pommel = 0.18,
		Grip = -0.06,
		Base = 0.3,
		Tip = 1.1,
		Material = {Color = Color(0.35, 0.3, 0.28, 1), Roughness = 0.6, Metallic = 1},
	},
	Source = melee.Source,
	ScriptValues = {
		Moveset = "reaper",
		Damage = 18,
		Range = 1.9,
		SwingPitch = 0.85,
		TrailColor = Color(0.45, 1, 0.65, 1),
		Guard = 0.5,
		Parry = 0.15,
	},
}
