local prefab = import("goluwa/entities/prefab.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local weapon_models = {}
local METAL = {Color = Color(0.25, 0.27, 0.3, 1), Roughness = 0.35, Metallic = 0.8}
local GLOW = {
	Color = Color(1, 0.55, 0.15, 1),
	Roughness = 0.6,
	Metallic = 0,
	AlbedoAlphaIsEmissive = true,
	EmissiveMultiplier = Color(1, 1, 1, 4),
}
local DARK_METAL = {Color = Color(0.12, 0.12, 0.14, 1), Roughness = 0.3, Metallic = 0.9}
local GRIP = {Color = Color(0.3, 0.2, 0.12, 1), Roughness = 0.8, Metallic = 0}
local CAMERA_BODY = {Color = Color(0.1, 0.1, 0.11, 1), Roughness = 0.5, Metallic = 0.3}
local GLASS = {Color = Color(0.1, 0.25, 0.4, 1), Roughness = 0.05, Metallic = 0.9}
local ACCENT = {Color = Color(0.7, 0.7, 0.72, 1), Roughness = 0.4, Metallic = 0.8}

local function box(name, size, position, material)
	return {
		guid = name,
		parent = "root",
		properties = {Name = name},
		components = {
			transform = {Position = position},
			model = {
				ModelPath = "models/box.lua",
				ModelOptions = {size = size},
				MaterialConfig = material,
			},
		},
	}
end

local function muzzle(distance)
	return {
		guid = "muzzle",
		parent = "root",
		properties = {Name = "muzzle"},
		components = {transform = {Position = FORWARD * distance}},
	}
end

function weapon_models.Register(name, nodes)
	local entities = {{guid = "root", components = {}}}

	for _, node in ipairs(nodes) do
		entities[#entities + 1] = node
	end

	prefab.Register(name, {inputs = {}, entities = entities}).builtin = true
end

weapon_models.Register(
	"weapon_camera_model",
	{
		box("body", Vec3(0.16, 0.1, 0.12), FORWARD * 0.22, CAMERA_BODY),
		box("lens", Vec3(0.075, 0.075, 0.09), FORWARD * 0.33, GLASS),
		box("ring", Vec3(0.09, 0.09, 0.03), FORWARD * 0.385, ACCENT),
		box("button", Vec3(0.05, 0.03, 0.05), FORWARD * 0.2 + Vec3(0, 0.065, 0), ACCENT),
		muzzle(0.4),
	}
)
weapon_models.Register(
	"weapon_physgun_model",
	{
		box("body", Vec3(0.1, 0.1, 0.36), FORWARD * 0.32, METAL),
		box("coil", Vec3(0.12, 0.05, 0.2), FORWARD * 0.28 + Vec3(0, 0.07, 0), GLOW),
		box("tip", Vec3(0.06, 0.06, 0.1), FORWARD * 0.59, GLOW),
		box("grip", Vec3(0.06, 0.13, 0.08), FORWARD * 0.16 - Vec3(0, 0.09, 0), METAL),
		muzzle(0.64),
	}
)
weapon_models.Register(
	"weapon_pistol_model",
	{
		box("barrel", Vec3(0.055, 0.07, 0.34), FORWARD * 0.29 + Vec3(0, 0.03, 0), DARK_METAL),
		box(
			"muzzle_block",
			Vec3(0.04, 0.04, 0.12),
			FORWARD * 0.4 - Vec3(0, 0.01, 0),
			DARK_METAL
		),
		box("grip", Vec3(0.05, 0.14, 0.07), FORWARD * 0.16 - Vec3(0, 0.08, 0), GRIP),
		muzzle(0.46),
	}
)
return weapon_models
