local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local weather = import("goluwa/render3d/weather.lua")
local Texture = import("goluwa/render/texture.lua")
local scene = {}
scene.sun = Vec3(0.7, 0.72, 0):GetNormalized()
scene.height = 2.5
scene.floor = shapes.Material{Roughness = 0.9, Metallic = 0, ColorMultiplier = Color(0.8, 0.8, 0.8, 1)}
local Material = import("goluwa/render3d/material.lua")
scene.toggles = {}

local function mat(config)
	config.MetallicMultiplier = 0
	config.RoughnessMultiplier = config.RoughnessMultiplier or 0.8
	config.ColorMultiplier = config.ColorMultiplier or Color(1, 1, 1, 1)

	if os.getenv("TOGGLE") then
		local material = Material.New{
			MetallicMultiplier = 0,
			RoughnessMultiplier = 0.8,
			ColorMultiplier = Color(0.8, 0.8, 0.8, 1),
		}
		scene.toggles[#scene.toggles + 1] = {material = material, props = config}
		return material
	end

	return Material.New(config)
end

function scene.Toggle()
	for _, t in ipairs(scene.toggles) do
		for k, v in pairs(t.props) do
			t.material["Set" .. k](t.material, v)
		end
	end
end

local grey = Color(0.8, 0.8, 0.8, 1)
scene.panels = {
	{name = "opaque", expect = 0, material = mat{ColorMultiplier = grey}},
	{
		name = "blend a=0.75",
		expect = 0.25,
		material = mat{Translucent = true, ColorMultiplier = Color(0.8, 0.8, 0.8, 0.75)},
	},
	{
		name = "blend a=0.5",
		expect = 0.5,
		material = mat{Translucent = true, ColorMultiplier = Color(0.8, 0.8, 0.8, 0.5)},
	},
	{
		name = "blend a=0.25",
		expect = 0.75,
		material = mat{Translucent = true, ColorMultiplier = Color(0.8, 0.8, 0.8, 0.25)},
	},
	{
		name = "blend a=0.9",
		expect = 0.1,
		material = mat{Translucent = true, ColorMultiplier = Color(0.8, 0.8, 0.8, 0.9)},
	},
	{
		name = "blend red a=0.5",
		expect = 0.5,
		material = mat{Translucent = true, ColorMultiplier = Color(0.9, 0.1, 0.1, 0.5)},
	},
	{
		name = "cutoff a=0.3",
		expect = 1,
		material = mat{AlphaTest = true, ColorMultiplier = Color(0.8, 0.8, 0.8, 0.3)},
	},
	{
		name = "cutoff a=0.8",
		expect = 0,
		material = mat{AlphaTest = true, ColorMultiplier = Color(0.8, 0.8, 0.8, 0.8)},
	},
	{
		name = "additive",
		expect = 1,
		material = mat{Additive = true, Translucent = true, ColorMultiplier = Color(0.6, 0.6, 0.6, 1)},
	},
	{
		name = "refract clear",
		expect = 0.9,
		material = mat{Refraction = 1, RoughnessMultiplier = 0.02},
	},
	{
		name = "refract tinted",
		expect = 0.59,
		material = mat{
			Refraction = 1,
			RoughnessMultiplier = 0.02,
			ColorMultiplier = Color(0.4, 0.7, 1, 1),
		},
	},
	{
		name = "refract 0.5",
		expect = 0.45,
		material = mat{Refraction = 0.5, RoughnessMultiplier = 0.02},
	},
}

local function shaded(glsl)
	local texture = Texture.New{width = 64, height = 64, format = "r8g8b8a8_unorm"}
	texture:Shade(glsl)
	return texture
end

if os.getenv("TEX") then
	local stripes = shaded("return vec4(1.0, 1.0, 1.0, step(0.5, fract(uv.x * 8.0)));")
	local gradient = shaded("return vec4(1.0, 1.0, 1.0, uv.x);")

	local function textured(config, texture)
		config.AlbedoTexture = texture
		return config
	end

	table.insert(
		scene.panels,
		{
			name = "tex cutoff stripes",
			expect = 0.5,
			material = mat(textured({AlphaTest = true}, stripes)),
		}
	)
	table.insert(
		scene.panels,
		{
			name = "tex blend gradient",
			expect = 0.5,
			material = mat(textured({Translucent = true}, gradient)),
		}
	)
	table.insert(
		scene.panels,
		{
			name = "tex blend gradient .5",
			expect = 0.75,
			material = mat(textured({Translucent = true, ColorMultiplier = Color(1, 1, 1, 0.5)}, gradient)),
		}
	)
	table.insert(
		scene.panels,
		{
			name = "tex refract gradient",
			expect = 0.95,
			material = mat(textured({Refraction = 1}, gradient)),
		}
	)
end

scene.spacing = 3
scene.per_row = 8
shapes.Box{
	Position = Vec3(0, -0.5, 0),
	Size = Vec3(tonumber(os.getenv("FLOOR") or "200"), 1, tonumber(os.getenv("FLOOR") or "200")),
	Material = scene.floor,
	Collision = false,
	RigidBody = false,
}

for i, panel in ipairs(scene.panels) do
	local col = (i - 1) % scene.per_row
	local row = math.floor((i - 1) / scene.per_row)
	panel.z = (col - (scene.per_row - 1) / 2) * scene.spacing
	panel.x = row * 6
	panel.entity = shapes.Box{
		Position = Vec3(panel.x, scene.height, panel.z),
		Size = Vec3(2, 0.1, 2),
		Material = panel.material,
		Collision = false,
		RigidBody = false,
	}
end

if os.getenv("BIG") then
	shapes.Box{
		Position = Vec3(0, 3, 14),
		Size = Vec3(4, 6, 4),
		Material = scene.panels[1].material,
		Collision = false,
		RigidBody = false,
	}
end

if not os.getenv("NOSUN") then weather.SetSunDirection(scene.sun) end

return scene
