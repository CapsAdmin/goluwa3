local Vec3 = import("goluwa/structs/vec3.lua")
local MeshBuilder = import("lua/foliage/mesh_builder.lua")
local foliage = import("lua/foliage/foliage.lua")
local trees = import("lua/foliage/trees.lua")
local grass = {}
local cos, sin, rad, sqrt, max, min = math.cos, math.sin, math.rad, math.sqrt, math.max, math.min
local UP = Vec3(0, 1, 0)
local NORMAL_UP = 0.55
grass.FLEX = 2

function grass.AddBlade(mesh, root, facing, height, width, lean, arch, twist, segments, u0, u1, phase)
	local stiffness
	local p1 = root + UP * (height * 0.65) + facing * (height * lean * 0.25)
	local p2 = root + UP * (height * (1 - arch)) + facing * (height * lean)
	local side0 = Vec3(-facing.z, 0, facing.x)
	local first = mesh:GetVertexCount()
	local flip = side0:GetCross((p1 - root):GetNormalized()):GetDot(facing) > 0

	for row = 0, segments do
		local t = row / segments
		local a = root + (p1 - root) * t
		local b = p1 + (p2 - p1) * t
		local center = a + (b - a) * t
		local tangent = ((p1 - root) * (1 - t) + (p2 - p1) * t):GetNormalized()
		local side = side0:GetRotated(tangent, twist * t)
		local normal = side:GetCross(tangent):GetNormalized()

		if flip then normal = normal * -1 end

		normal = (normal * (1 - NORMAL_UP) + UP * NORMAL_UP):GetNormalized()
		stiffness = trees.StiffnessAlong(1, center - root, grass.FLEX)
		mesh:SetColor(t * 0.6, phase, stiffness)

		if row == segments then
			mesh:Vertex(center.x, center.y, center.z, normal.x, normal.y, normal.z, (u0 + u1) * 0.5, 1)
		else
			local half = width * 0.5 * (1 - t ^ 1.5)
			local left = center - side * half
			local right = center + side * half
			mesh:Vertex(left.x, left.y, left.z, normal.x, normal.y, normal.z, u0, t)
			mesh:Vertex(right.x, right.y, right.z, normal.x, normal.y, normal.z, u1, t)
		end
	end

	for row = 0, segments - 2 do
		local a = first + row * 2

		if flip then
			mesh:Quad(a, a + 2, a + 3, a + 1)
		else
			mesh:Quad(a, a + 1, a + 3, a + 2)
		end
	end

	local a = first + (segments - 1) * 2

	if flip then
		mesh:Triangle(a, a + 2, a + 1)
	else
		mesh:Triangle(a, a + 1, a + 2)
	end

	return stiffness
end

function grass.AddCrossedCards(mesh, base, up, size, aspect, tile, atlas, phase, stiffness, rng)
	local top_stiffness = trees.StiffnessAlong(stiffness, up * size, grass.FLEX)
	local yaw = rng:Next() * math.pi
	local u0, u1 = tile / atlas, (tile + 1) / atlas

	for k = 0, 1 do
		local angle = yaw + k * math.pi * 0.5
		local side = Vec3(cos(angle), 0, sin(angle))
		side = (side - up * side:GetDot(up)):GetNormalized()
		local normal = side:GetCross(up):GetNormalized()
		local center = base + up * (size * 0.5)
		local r = side * (size * 0.5 * aspect)
		local u = up * (size * 0.5)
		local first = mesh:GetVertexCount()
		mesh:SetColor(0, phase, stiffness)
		mesh:Vertex(
			center.x - r.x - u.x,
			center.y - r.y - u.y,
			center.z - r.z - u.z,
			normal.x,
			normal.y,
			normal.z,
			u0,
			0
		)
		mesh:Vertex(
			center.x + r.x - u.x,
			center.y + r.y - u.y,
			center.z + r.z - u.z,
			normal.x,
			normal.y,
			normal.z,
			u1,
			0
		)
		mesh:SetColor(0.8, phase, top_stiffness)
		mesh:Vertex(
			center.x + r.x + u.x,
			center.y + r.y + u.y,
			center.z + r.z + u.z,
			normal.x,
			normal.y,
			normal.z,
			u1,
			1
		)
		mesh:Vertex(
			center.x - r.x + u.x,
			center.y - r.y + u.y,
			center.z - r.z + u.z,
			normal.x,
			normal.y,
			normal.z,
			u0,
			1
		)
		mesh:Quad(first, first + 1, first + 2, first + 3)
	end
end

function grass.BuildPatch(config, rng)
	local blades = MeshBuilder.New()
	local heads = MeshBuilder.New()
	local blade_rng = rng:Fork("blades")
	local tufts = {}

	for i = 1, config.tufts do
		local angle = blade_rng:Next() * math.pi * 2
		local distance = i == 1 and 0 or sqrt(blade_rng:Next()) * config.radius * 0.7
		tufts[i] = Vec3(cos(angle) * distance, 0, sin(angle) * distance)
	end

	local tuft_radius = config.radius / sqrt(config.tufts)
	local tallest = 0

	for i = 1, config.blades do
		local tuft = tufts[(i - 1) % config.tufts + 1]
		local angle = blade_rng:Next() * math.pi * 2
		local distance = blade_rng:Next() ^ config.clump * tuft_radius
		local root = tuft + Vec3(cos(angle) * distance, -0.02, sin(angle) * distance)
		local out_angle = angle + (blade_rng:Next() - 0.5) * config.spread
		local facing = Vec3(cos(out_angle), 0, sin(out_angle))
		local centered = 1 - distance / tuft_radius
		local height = blade_rng:Pick(config.height) * (0.75 + 0.25 * centered)
		local lean = blade_rng:Pick(config.lean) * (1.2 - 0.4 * centered)
		local arch = blade_rng:Pick(config.arch)
		local tile = blade_rng:Int(0, config.atlas - 1)
		tallest = max(tallest, height)
		grass.AddBlade(
			blades,
			root,
			facing,
			height,
			blade_rng:Pick(config.width),
			lean,
			arch,
			(blade_rng:Next() - 0.5) * rad(config.twist),
			config.segments,
			tile / config.atlas,
			(tile + 1) / config.atlas,
			blade_rng:Next()
		)
	end

	if config.stems > 0 then
		local stem_rng = rng:Fork("stems")

		for _ = 1, config.stems do
			local angle = stem_rng:Next() * math.pi * 2
			local root = Vec3(cos(angle), 0, sin(angle)) * (sqrt(stem_rng:Next()) * config.radius * 0.6)
			local height = stem_rng:Pick(config.stem_height)
			local lean = rad(stem_rng:Range(0, 14))
			local yaw = stem_rng:Next() * math.pi * 2
			local dir = Vec3(sin(lean) * cos(yaw), cos(lean), sin(lean) * sin(yaw))
			local size = stem_rng:Pick(config.head_size)
			local stem_top = root + dir * (height - size * 0.6)
			local phase = stem_rng:Next()
			tallest = max(tallest, height)
			local held = grass.AddBlade(
				blades,
				root - UP * 0.02,
				Vec3(cos(yaw), 0, sin(yaw)),
				stem_top.y - root.y + 0.02,
				config.stem_width,
				sin(lean),
				0,
				0,
				3,
				0,
				1 / config.atlas,
				phase
			)
			grass.AddCrossedCards(heads, stem_top, dir, size, 0.5, stem_rng:Int(0, 1), 2, phase, held, stem_rng)
		end
	end

	local parts = {
		{
			mesh = blades:Build{bend_height = tallest, name = "foliage_grass"},
			material = foliage.GetMaterial(config.material),
		},
	}

	if not heads:IsEmpty() then
		parts[2] = {
			mesh = heads:Build{bend_height = tallest, name = "foliage_grass_heads"},
			material = foliage.GetMaterial(config.head_material),
		}
	end

	return parts
end

local DEFAULTS = {
	radius = 0.45,
	tufts = 3,
	blades = 50,
	clump = 0.7,
	spread = 1.5,
	height = {0.25, 0.45},
	width = {0.008, 0.014},
	lean = {0.15, 0.5},
	arch = {0, 0.15},
	twist = 60,
	segments = 4,
	material = "grass_meadow",
	atlas = 4,
	stems = 0,
	stem_height = {0.6, 0.9},
	stem_width = 0.004,
	head_size = {0.16, 0.22},
	head_material = "seed_oat",
}

local function patch(name, overrides)
	local defaults = {}

	for key, value in pairs(DEFAULTS) do
		defaults[key] = value
	end

	for key, value in pairs(overrides) do
		defaults[key] = value
	end

	foliage.AddGenerator(name, {category = "grass", defaults = defaults, build = grass.BuildPatch})
end

patch(
	"grass_lawn",
	{
		radius = 0.3,
		tufts = 4,
		blades = 140,
		clump = 0.5,
		height = {0.07, 0.15},
		width = {0.006, 0.01},
		lean = {0.05, 0.3},
		material = "grass_lawn",
	}
)
patch(
	"grass_meadow",
	{
		radius = 0.45,
		tufts = 3,
		blades = 90,
		height = {0.25, 0.5},
		width = {0.009, 0.015},
		lean = {0.2, 0.6},
		arch = {0, 0.2},
		material = "grass_meadow",
	}
)
patch(
	"grass_wild",
	{
		radius = 0.5,
		tufts = 2,
		blades = 60,
		height = {0.4, 0.75},
		width = {0.008, 0.013},
		lean = {0.25, 0.8},
		arch = {0.05, 0.3},
		material = "grass_wild",
		stems = 9,
		stem_height = {0.75, 1.05},
		head_size = {0.24, 0.32},
		head_material = "seed_oat",
	}
)
patch(
	"grass_dry",
	{
		radius = 0.45,
		tufts = 3,
		blades = 70,
		height = {0.25, 0.55},
		width = {0.007, 0.011},
		lean = {0.4, 1.0},
		arch = {0.1, 0.5},
		twist = 120,
		material = "grass_dry",
		stems = 5,
		stem_height = {0.5, 0.8},
		head_size = {0.18, 0.24},
		head_material = "seed_timothy",
	}
)
patch(
	"grass_tussock",
	{
		radius = 0.18,
		tufts = 1,
		blades = 110,
		clump = 1.5,
		spread = 0.6,
		height = {0.45, 0.8},
		width = {0.007, 0.012},
		lean = {0.5, 1.1},
		arch = {0.3, 0.75},
		twist = 40,
		segments = 6,
		material = "grass_sedge",
	}
)
patch(
	"reeds",
	{
		radius = 0.35,
		tufts = 2,
		blades = 36,
		clump = 1,
		spread = 0.8,
		height = {1.2, 1.8},
		width = {0.014, 0.022},
		lean = {0.05, 0.3},
		arch = {0, 0.1},
		twist = 30,
		segments = 5,
		material = "grass_reed",
		stems = 6,
		stem_height = {1.6, 2.1},
		stem_width = 0.006,
		head_size = {0.4, 0.5},
		head_material = "seed_plume",
	}
)

for _, name in ipairs{"grass_lawn", "grass_meadow", "grass_wild", "grass_dry", "grass_tussock"} do
	foliage.AddPreset("grass", name:gsub("^grass_", "") .. "_a", name, {seed = 1})
	foliage.AddPreset("grass", name:gsub("^grass_", "") .. "_b", name, {seed = 2})
end

foliage.AddPreset("plants", "reeds_a", "reeds", {seed = 1})
foliage.AddPreset("plants", "reeds_b", "reeds", {seed = 2})
return grass
