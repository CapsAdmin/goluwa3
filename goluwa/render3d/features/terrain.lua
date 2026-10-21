local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local ray = "InvalidateRayMaterial"
local params = {}

local function add(param)
	table.insert(params, param)
end

local function texture(name, requires, callback)
	add{
		name = name,
		kind = "texture",
		type = "render_texture",
		callback = callback,
		requires = requires,
	}
end

local function layer_values(suffix, requires)
	local function values(name, default, callback)
		add{
			name = "TerrainLayer" .. name .. suffix,
			kind = "vec4",
			default = default,
			callback = callback,
			requires = requires,
		}
	end

	values("Scales", Color(1.0, 1.0, 1.0, 1.0))

	if suffix == "" then params[#params].category = "Terrain Shading" end

	values("HeightScales", Color(0.0, 0.0, 0.0, 0.0))

	if suffix == "" then
		add{
			name = "TerrainLayerHeightDistance",
			default = 128,
			requires = requires,
		}
		add{
			name = "TerrainTriplanarSharpness",
			default = 4,
			requires = requires,
		}
	end

	values("Roughness", Color(1.0, 1.0, 1.0, 1.0))
	values("AmbientOcclusion", Color(1.0, 1.0, 1.0, 1.0))
	values("DetailStrength", Color(0.0, 0.0, 0.0, 0.0), ray)
	values("AdditiveDetail", Color(0.0, 0.0, 0.0, 0.0), ray)
	values("Specular", Color(1.0, 1.0, 1.0, 1.0))
	values("SlopeMin", Color(-1.0, -1.0, -1.0, -1.0))
	values("SlopeMax", Color(2.0, 2.0, 2.0, 2.0))
	values("SlopeBlend", Color(0.01, 0.01, 0.01, 0.01))
	values("HeightBlend", Color(0.0, 0.0, 0.0, 0.0))
	values("FarScales", Color(0.0, 0.0, 0.0, 0.0))
	values("FarDistances", Color(0.0, 0.0, 0.0, 0.0))
	values("FarScaleB", Color(0.0, 0.0, 0.0, 0.0))
	values("FarDistanceB", Color(0.0, 0.0, 0.0, 0.0))
	values("FadeDistance", Color(0.0, 0.0, 0.0, 0.0))
	values("AntiTiling", Color(0.0, 0.0, 0.0, 0.0))
	values("CoverSlope", Color(0.0, 0.0, 0.0, 0.0))
	values("CoverStart", Color(0.0, 0.0, 0.0, 0.0))
	values("CoverRange", Color(1000.0, 1000.0, 1000.0, 1000.0))
	values("CoverPower", Color(1.0, 1.0, 1.0, 1.0))
	values("CoverBlend", Color(0.05, 0.05, 0.05, 0.05))
end

texture("TerrainMaterialTexture", nil, ray)
params[1].category = "Terrain Layers"
add{
	name = "TerrainBounds",
	kind = "vec3",
	default = Vec3(0, 0, 0),
	callback = ray,
	requires = "TerrainMaterialTexture",
	block = false,
}

for layer = 1, 4 do
	texture("TerrainLayer" .. layer .. "Texture", "TerrainMaterialTexture", ray)
end

for layer = 1, 4 do
	texture("TerrainLayer" .. layer .. "NormalTexture", "TerrainMaterialTexture")
end

for layer = 1, 4 do
	texture("TerrainLayer" .. layer .. "HeightTexture", "TerrainMaterialTexture")
end

texture("TerrainMaterial2Texture", "TerrainMaterialTexture", ray)

for layer = 5, 8 do
	texture("TerrainLayer" .. layer .. "Texture", "TerrainMaterial2Texture", ray)
	texture("TerrainLayer" .. layer .. "NormalTexture", "TerrainMaterial2Texture")
	texture("TerrainLayer" .. layer .. "HeightTexture", "TerrainMaterial2Texture")
end

layer_values("", "TerrainMaterialTexture")
add{
	name = "TerrainLayerScatter",
	kind = "vec4",
	default = Color(1.0, 1.0, 1.0, 1.0),
	requires = {"ScatterSet", "TerrainMaterialTexture"},
	block = false,
}
layer_values("2", "TerrainMaterial2Texture")
return {
	name = "terrain",
	category = "Terrain Layers",
	block = "own",
	active = function(material)
		return material:GetTerrainMaterialTexture() ~= nil
	end,
	params = params,
}
