-- the small things: flowers, ferns, mushrooms, fallen logs, stumps, leaf litter and fallen branches
local Vec3 = import("goluwa/structs/vec3.lua")
local MeshBuilder = import("lua/foliage/mesh_builder.lua")
local foliage = import("lua/foliage/foliage.lua")
local trees = import("lua/foliage/trees.lua")
local grass = import("lua/foliage/grass.lua")
local plants = {}
local cos, sin, rad, sqrt, max, min, pi = math.cos, math.sin, math.rad, math.sqrt, math.max, math.min, math.pi
local UP = Vec3(0, 1, 0)

local function add_generator(name, category, defaults, build)
	foliage.AddGenerator(name, {category = category, defaults = defaults, build = build})
end

-- a flower head from above as a shallow cup, the picture laid over it from the top so it reads from the side too. it
-- is held in the middle with the stiffness of its stem's top, its petals flutter
local function add_head(mesh, center, up, radius, cup, tile, atlas, phase, stiffness)
	local side = trees.perpendicular(up)
	local other = up:GetCross(side)
	local first = mesh:GetVertexCount()
	local u0 = tile / atlas
	local rings, segments = 2, 12
	mesh:SetColor(0, phase, stiffness)
	mesh:Vertex(center.x, center.y, center.z, up.x, up.y, up.z, u0 + 0.5 / atlas, 0.5)

	for ring = 1, rings do
		local r = ring / rings

		for segment = 0, segments - 1 do
			local angle = segment / segments * pi * 2
			local x, y = cos(angle) * r, sin(angle) * r
			local p = center + (side * x + other * y) * radius + up * (cup * r * r * radius)
			local normal = (up - (side * x + other * y) * (cup * 1.2)):GetNormalized()
			mesh:SetColor(r * 0.6, phase, trees.StiffnessAlong(stiffness, p - center, grass.FLEX))
			mesh:Vertex(p.x, p.y, p.z, normal.x, normal.y, normal.z, u0 + (x * 0.5 + 0.5) / atlas, y * 0.5 + 0.5)
		end
	end

	for segment = 0, segments - 1 do
		local next_segment = (segment + 1) % segments
		mesh:Triangle(first, first + 1 + segment, first + 1 + next_segment)

		for ring = 1, rings - 1 do
			local a = first + 1 + (ring - 1) * segments
			local b = a + segments
			mesh:Quad(a + segment, b + segment, b + next_segment, a + next_segment)
		end
	end
end

function plants.BuildFlowers(config, rng)
	local stems = MeshBuilder.New()
	local heads = MeshBuilder.New()
	local leaves = MeshBuilder.New()
	local flower_rng = rng:Fork("flowers")
	local count = flower_rng:Int(config.count[1], config.count[2])
	local tallest = 0

	for _ = 1, count do
		local angle = flower_rng:Next() * pi * 2
		local root = Vec3(cos(angle), 0, sin(angle)) * (sqrt(flower_rng:Next()) * config.radius) - UP * 0.02
		local height = flower_rng:Pick(config.height)
		local lean = rad(flower_rng:Range(0, config.lean))
		local yaw = flower_rng:Next() * pi * 2
		local dir = Vec3(sin(lean) * cos(yaw), cos(lean), sin(lean) * sin(yaw))
		local phase = flower_rng:Next()
		tallest = max(tallest, height)
		local points = trees.Grow(flower_rng, root, dir, height, config.stem_radius, {taper = 0.3, curve = 0, noise = 6}, 5)

		-- held at the root like a blade of grass
		trees.AddTube(
			stems,
			points,
			4,
			0.3,
			phase,
			function(point)
				return trees.Stiffness(point.reach, grass.FLEX)
			end,
			false
		)
		local top = points[#points]
		local held = trees.Stiffness(top.reach, grass.FLEX)
		local tile = flower_rng:Int(0, config.atlas - 1)

		if config.spike then
			grass.AddCrossedCards(heads, top.pos - top.dir * (config.head_size[2] * 0.3), top.dir, flower_rng:Pick(config.head_size), 0.5, tile, config.atlas, phase, held, flower_rng)
		else
			local tilt = rad(flower_rng:Range(0, config.head_tilt))
			local head_up = top.dir:GetRotated(trees.perpendicular(top.dir), tilt)
			add_head(heads, top.pos, head_up, flower_rng:Pick(config.head_size), config.cup, tile, config.atlas, phase, held)
		end
	end

	-- the leaves at the foot of the clump
	local leaf_rng = rng:Fork("leaves")

	for _ = 1, config.leaves do
		local angle = leaf_rng:Next() * pi * 2
		local root = Vec3(cos(angle), 0, sin(angle)) * (leaf_rng:Next() * config.radius * 0.8) - UP * 0.01
		local facing = Vec3(cos(angle + (leaf_rng:Next() - 0.5)), 0, sin(angle + (leaf_rng:Next() - 0.5)))
		grass.AddBlade(leaves, root, facing, leaf_rng:Pick(config.leaf_length), leaf_rng:Pick(config.leaf_width), 0.9, 0.5, 0.3, 4, 0, 0.25, leaf_rng:Next())
	end

	local parts = {
		{mesh = stems:Build{bend_height = tallest, name = "foliage_flower_stems"}, material = foliage.GetMaterial("plant_stem")},
		{mesh = heads:Build{bend_height = tallest, name = "foliage_flower_heads"}, material = foliage.GetMaterial(config.material)},
	}

	if not leaves:IsEmpty() then
		parts[3] = {mesh = leaves:Build{bend_height = tallest, name = "foliage_flower_leaves"}, material = foliage.GetMaterial("plant_stem")}
	end

	return parts
end

local FLOWER_DEFAULTS = {
	count = {4, 7},
	radius = 0.15,
	height = {0.25, 0.45},
	lean = 15,
	stem_radius = 0.003,
	head_size = {0.032, 0.045},
	head_tilt = 30,
	cup = 0.35,
	spike = false,
	atlas = 2,
	leaves = 8,
	leaf_length = {0.08, 0.16},
	leaf_width = {0.012, 0.02},
	material = "flower_daisy",
}

local function flower(name, overrides)
	local defaults = {}

	for key, value in pairs(FLOWER_DEFAULTS) do
		defaults[key] = value
	end

	for key, value in pairs(overrides) do
		defaults[key] = value
	end

	add_generator(name, "plants", defaults, plants.BuildFlowers)
end

flower("daisies", {material = "flower_daisy"})
flower("poppies", {count = {3, 5}, height = {0.35, 0.6}, head_size = {0.04, 0.055}, cup = 0.6, material = "flower_poppy", leaves = 6, leaf_width = {0.015, 0.025}})
flower("cornflowers", {count = {4, 8}, height = {0.35, 0.6}, head_size = {0.03, 0.04}, cup = 0.2, material = "flower_cornflower", leaves = 5, leaf_width = {0.006, 0.01}, leaf_length = {0.12, 0.22}})
flower("buttercups", {count = {5, 9}, height = {0.2, 0.4}, head_size = {0.02, 0.028}, cup = 0.9, stem_radius = 0.002, material = "flower_buttercup", leaves = 10, leaf_length = {0.06, 0.1}, leaf_width = {0.015, 0.025}})
flower("lupines", {count = {3, 6}, height = {0.35, 0.55}, head_size = {0.3, 0.42}, stem_radius = 0.005, spike = true, material = "flower_lupine", leaves = 12, leaf_length = {0.15, 0.25}, leaf_width = {0.015, 0.025}, radius = 0.2})

-- a fern: fronds out of the ground from upright to lying, drooping at their tips
function plants.BuildFern(config, rng)
	local mesh = MeshBuilder.New()
	local frond_rng = rng:Fork("fronds")
	local count = frond_rng:Int(config.fronds[1], config.fronds[2])
	local spin = frond_rng:Next() * pi * 2
	local tallest = 0

	for i = 1, count do
		local k = (i - 1) / max(count - 1, 1)
		local pitch = rad(config.pitch[1] + (config.pitch[2] - config.pitch[1]) * k + (frond_rng:Next() - 0.5) * 10)
		local yaw = spin + i * rad(137.5)
		local out = Vec3(cos(yaw), 0, sin(yaw))
		local length = frond_rng:Pick(config.length)
		local points = trees.AddFrond(mesh, frond_rng, out * 0.03 - UP * 0.02, (UP * cos(pitch) + out * sin(pitch)):GetNormalized(), length, config.width, config.fold, config.droop, -15, 10, frond_rng:Next(), config.flex, Vec3(0, 0, 0), config.bend)

		for _, point in ipairs(points) do
			tallest = max(tallest, point.pos.y)
		end
	end

	return {{mesh = mesh:Build{bend_height = max(tallest, 0.1), name = "foliage_fern"}, material = foliage.GetMaterial(config.material)}}
end

add_generator(
	"fern",
	"plants",
	{
		fronds = {9, 14},
		pitch = {20, 70},
		length = {0.7, 1.1},
		width = 0.4,
		fold = 12,
		droop = 0.9,
		-- how much less stiff a meter of a frond's reach
		flex = 0.6,
		-- how far the normals lean away from the root
		bend = 0.3,
		material = "fern_frond",
	},
	plants.BuildFern
)

-- mushrooms: a cap (a dome turned on a lathe, its texture around it and out from the middle), the gills under it and a
-- stem, in a little group
function plants.BuildMushrooms(config, rng)
	local caps = MeshBuilder.New()
	local under = MeshBuilder.New()
	local mushroom_rng = rng:Fork("mushrooms")
	local count = mushroom_rng:Int(config.count[1], config.count[2])
	local sides = 14

	for i = 1, count do
		local angle = mushroom_rng:Next() * pi * 2
		local root = i == 1 and Vec3(0, -0.01, 0) or Vec3(cos(angle), -0.01, sin(angle)) * (sqrt(mushroom_rng:Next()) * config.spread)
		local scale = i == 1 and 1 or mushroom_rng:Range(0.45, 0.9)
		local radius = mushroom_rng:Pick(config.cap_radius) * scale
		local height = mushroom_rng:Pick(config.height) * scale
		local lean = rad(mushroom_rng:Range(0, 12))
		local yaw = mushroom_rng:Next() * pi * 2
		local up = Vec3(sin(lean) * cos(yaw), cos(lean), sin(lean) * sin(yaw))
		local stem_radius = radius * config.stem
		local top = root + up * height
		local stem = {}

		for k = 0, 3 do
			local t = k / 3
			-- a little thicker at the foot
			stem[k + 1] = {pos = root + up * (height * t), dir = up, radius = stem_radius * (1.25 - 0.25 * t), t = t}
		end

		trees.AddTube(
			under,
			stem,
			8,
			0.1,
			0,
			function()
				return 1
			end,
			false
		)
		local side = trees.perpendicular(up)
		local other = up:GetCross(side)
		-- the cap's profile from its top (0) to its rim (1): how far out and how high
		local rings = 6
		local first = caps:GetVertexCount()
		local under_first = under:GetVertexCount()

		for ring = 0, rings do
			local t = ring / rings
			local out = sin(t * pi * 0.5) * radius
			local rise = cos(t * pi * 0.5) * radius * config.dome - radius * 0.1 * t * t

			for s = 0, sides do
				local a = s / sides * pi * 2
				local dir = side * cos(a) + other * sin(a)
				local p = top + dir * out + up * rise
				local normal = (dir * sin(t * pi * 0.5) / max(config.dome, 0.2) + up * cos(t * pi * 0.5)):GetNormalized()
				caps:SetColor(0, 0, 1)
				caps:Vertex(p.x, p.y, p.z, normal.x, normal.y, normal.z, s / sides, t)
			end
		end

		for ring = 0, rings - 1 do
			for s = 0, sides - 1 do
				local a = first + ring * (sides + 1) + s
				local b = a + sides + 1
				caps:Quad(a, b, b + 1, a + 1)
			end
		end

		-- the gills, from the stem out to the rim, facing down
		for k = 0, 1 do
			for s = 0, sides do
				local a = s / sides * pi * 2
				local dir = side * cos(a) + other * sin(a)
				local out = k == 0 and stem_radius or radius
				local p = top + dir * out - up * (k == 0 and 0 or radius * 0.1)
				under:SetColor(0, 0, 1)
				under:Vertex(p.x, p.y, p.z, -up.x, -up.y, -up.z, s / sides, k)
			end
		end

		for s = 0, sides - 1 do
			local a = under_first + s
			local b = a + sides + 1
			under:Quad(a, a + 1, b + 1, b)
		end
	end

	return {
		{mesh = caps:Build{name = "foliage_mushroom_caps"}, material = foliage.GetMaterial(config.material)},
		{mesh = under:Build{name = "foliage_mushroom_stems"}, material = foliage.GetMaterial("mushroom_stem")},
	}
end

add_generator(
	"mushrooms",
	"plants",
	{
		count = {1, 3},
		spread = 0.15,
		cap_radius = {0.05, 0.08},
		height = {0.08, 0.13},
		dome = 0.7,
		-- the stem's radius, of the cap's
		stem = 0.22,
		material = "mushroom_amanita",
	},
	plants.BuildMushrooms
)

-- a disc of end grain capping a tube, facing along normal
local function add_end(mesh, center, normal, radius, sides)
	local side = trees.perpendicular(normal)
	local other = normal:GetCross(side)
	local first = mesh:GetVertexCount()
	mesh:SetColor(0, 0, 1)
	mesh:Vertex(center.x, center.y, center.z, normal.x, normal.y, normal.z, 0.5, 0.5)

	for s = 0, sides - 1 do
		local a = s / sides * pi * 2
		local p = center + (side * cos(a) + other * sin(a)) * radius
		mesh:Vertex(p.x, p.y, p.z, normal.x, normal.y, normal.z, 0.5 + cos(a) * 0.5, 0.5 + sin(a) * 0.5)
	end

	for s = 0, sides - 1 do
		mesh:Triangle(first, first + 1 + s, first + 1 + (s + 1) % sides)
	end
end

-- a fallen log, lying along x with a few broken branches
function plants.BuildLog(config, rng)
	local wood = MeshBuilder.New()
	local ends = MeshBuilder.New()
	local log_rng = rng:Fork("log")
	local length = log_rng:Pick(config.length)
	local radius = log_rng:Pick(config.radius)
	local yaw = log_rng:Next() * pi
	local dir = Vec3(cos(yaw), log_rng:Range(-0.03, 0.03), sin(yaw))
	local start = dir * (-length * 0.5) + Vec3(0, radius * (1 - config.sink), 0)
	local points = trees.Grow(log_rng, start, dir, length, radius, {taper = 0.25, curve = 0, noise = 3}, 10)
	local function stiff()
		return 1
	end

	trees.AddTube(wood, points, 12, config.bark_tile, 0, stiff, false)
	local first, last = points[1], points[#points]
	-- the ends are cut, a little in from the bark
	add_end(ends, first.pos, first.dir * -1, first.radius * 0.98, 12)
	add_end(ends, last.pos, last.dir, last.radius * 0.98, 12)

	for _ = 1, log_rng:Int(config.stubs[1], config.stubs[2]) do
		local pos, branch_dir, branch_radius = trees.Sample(points, log_rng:Range(0.15, 0.85))
		local out = trees.perpendicular(branch_dir):GetRotated(branch_dir, log_rng:Next() * pi * 2)

		if out.y < -0.2 then out = out * -1 end

		local stub = trees.Grow(log_rng, pos, (out + branch_dir * 0.4):GetNormalized(), log_rng:Range(0.3, 0.8), branch_radius * 0.3, {taper = 0.6, noise = 10}, 3)
		trees.AddTube(wood, stub, 6, config.bark_tile, 0, stiff, true)
	end

	return {
		{mesh = wood:Build{name = "foliage_log"}, material = foliage.GetMaterial(config.bark)},
		{mesh = ends:Build{name = "foliage_log_ends"}, material = foliage.GetMaterial("end_grain")},
	}
end

add_generator(
	"log",
	"plants",
	{
		length = {3, 5},
		radius = {0.18, 0.3},
		sink = 0.2,
		stubs = {2, 4},
		bark = "oak_bark",
		bark_tile = 0.7,
	},
	plants.BuildLog
)

-- a stump: a short trunk with roots running out into the ground, cut on top
function plants.BuildStump(config, rng)
	local wood = MeshBuilder.New()
	local ends = MeshBuilder.New()
	local stump_rng = rng:Fork("stump")
	local radius = stump_rng:Pick(config.radius)
	local height = stump_rng:Pick(config.height)
	local points = trees.Grow(stump_rng, Vec3(0, -0.2, 0), UP, height + 0.2, radius, {taper = 0.1, noise = 2}, 5)

	for _, point in ipairs(points) do
		point.radius = point.radius * (1 + 0.5 * math.exp(-(point.pos.y + 0.2) / 0.25))
	end

	local function stiff()
		return 1
	end

	trees.AddTube(wood, points, 14, config.bark_tile, 0, stiff, false)
	local top = points[#points]
	add_end(ends, top.pos, top.dir, top.radius * 0.97, 14)
	local roots = stump_rng:Int(config.roots[1], config.roots[2])

	for i = 1, roots do
		local angle = (i - 1) / roots * pi * 2 + stump_rng:Range(-0.3, 0.3)
		local out = Vec3(cos(angle), -0.12, sin(angle)):GetNormalized()
		-- from inside the stump out and down into the ground
		local root = trees.Grow(stump_rng, Vec3(cos(angle) * radius * 0.4, 0.12, sin(angle) * radius * 0.4), out, stump_rng:Range(0.7, 1.2), radius * 0.38, {taper = 0.8, noise = 8, gravity = 0.35}, 7)
		trees.AddTube(wood, root, 7, config.bark_tile, 0, stiff, true)
	end

	return {
		{mesh = wood:Build{name = "foliage_stump"}, material = foliage.GetMaterial(config.bark)},
		{mesh = ends:Build{name = "foliage_stump_top"}, material = foliage.GetMaterial("end_grain")},
	}
end

add_generator(
	"stump",
	"plants",
	{
		radius = {0.25, 0.4},
		height = {0.3, 0.6},
		roots = {4, 6},
		bark = "oak_bark",
		bark_tile = 0.7,
	},
	plants.BuildStump
)

-- fallen leaves lying about, cards nearly flat on the ground, the later ones on top
function plants.BuildLitter(config, rng)
	local mesh = MeshBuilder.New()
	local leaf_rng = rng:Fork("leaves")

	for i = 1, config.leaves do
		local angle = leaf_rng:Next() * pi * 2
		local center = Vec3(cos(angle), 0, sin(angle)) * (sqrt(leaf_rng:Next()) * config.radius)
		center.y = 0.004 + i * 0.0004 + leaf_rng:Next() * 0.01
		local size = leaf_rng:Pick(config.size)
		local yaw = leaf_rng:Next() * pi * 2
		local tilt = rad(leaf_rng:Range(0, config.tilt))
		local forward = Vec3(cos(yaw), sin(tilt), sin(yaw)):GetNormalized()
		local normal = UP:GetRotated(trees.perpendicular(forward), leaf_rng:Range(-tilt, tilt))
		-- right by up is the card's normal
		local side = forward:GetCross(normal):GetNormalized()
		normal = side:GetCross(forward)
		local tile = leaf_rng:Int(0, config.atlas - 1)
		mesh:SetColor(0, 0, 1)
		local r, u = side * (size * 0.5), forward * (size * 0.5)
		mesh:Card(center.x, center.y, center.z, r.x, r.y, r.z, u.x, u.y, u.z, normal.x, normal.y, normal.z, {tile / config.atlas, 0, (tile + 1) / config.atlas, 1})
	end

	return {{mesh = mesh:Build{name = "foliage_litter"}, material = foliage.GetMaterial(config.material)}}
end

add_generator(
	"leaf_litter",
	"plants",
	{
		leaves = 45,
		radius = 0.5,
		size = {0.07, 0.12},
		tilt = 20,
		atlas = 4,
		material = "litter_leaves",
	},
	plants.BuildLitter
)

-- fallen branches lying on the ground, a few forks each
function plants.BuildBranches(config, rng)
	local wood = MeshBuilder.New()
	local branch_rng = rng:Fork("branches")

	local function stiff()
		return 1
	end

	local function grow(start, dir, length, radius, depth)
		local points = trees.Grow(branch_rng, start, dir, length, radius, {taper = 0.7, noise = 12, curve = 0}, 5)
		trees.AddTube(wood, points, depth == 0 and 5 or 3, config.bark_tile, 0, stiff, true)

		if depth < 2 then
			for _ = 1, branch_rng:Int(1, 3) do
				local t = branch_rng:Range(0.3, 0.8)
				local pos, branch_dir, branch_radius = trees.Sample(points, t)
				local angle = branch_rng:Range(25, 50) * branch_rng:Sign()
				local child = branch_dir:GetRotated(UP, rad(angle))
				child = (child + Vec3(0, branch_rng:Range(-0.05, 0.2), 0)):GetNormalized()
				grow(pos, child, length * branch_rng:Range(0.3, 0.55), branch_radius * 0.6, depth + 1)
			end
		end
	end

	for _ = 1, branch_rng:Int(config.count[1], config.count[2]) do
		local angle = branch_rng:Next() * pi * 2
		local start = Vec3(cos(angle), 0, sin(angle)) * (branch_rng:Next() * config.radius)
		local yaw = branch_rng:Next() * pi * 2
		local radius = branch_rng:Pick(config.thickness)
		start.y = radius * 0.6
		grow(start, Vec3(cos(yaw), 0, sin(yaw)), branch_rng:Pick(config.length), radius, 0)
	end

	return {{mesh = wood:Build{name = "foliage_branches"}, material = foliage.GetMaterial(config.bark)}}
end

add_generator(
	"branches",
	"plants",
	{
		count = {2, 3},
		radius = 0.4,
		length = {0.8, 1.5},
		thickness = {0.015, 0.03},
		bark = "dead_bark",
		bark_tile = 0.4,
	},
	plants.BuildBranches
)

for _, name in ipairs{"daisies", "poppies", "cornflowers", "buttercups", "lupines", "fern", "log", "stump", "leaf_litter", "branches"} do
	foliage.AddPreset("plants", name .. "_a", name, {seed = 1})
	foliage.AddPreset("plants", name .. "_b", name, {seed = 2})
end

foliage.AddPreset("plants", "fly_agaric_a", "mushrooms", {seed = 1})
foliage.AddPreset("plants", "fly_agaric_b", "mushrooms", {seed = 2, count = {2, 4}})
foliage.AddPreset("plants", "boletes_a", "mushrooms", {seed = 3, material = "mushroom_bolete", dome = 0.55, stem = 0.35, cap_radius = {0.06, 0.09}, height = {0.07, 0.1}})
foliage.AddPreset("plants", "boletes_b", "mushrooms", {seed = 4, material = "mushroom_bolete", dome = 0.55, stem = 0.35, count = {3, 5}, cap_radius = {0.04, 0.07}, height = {0.05, 0.08}})
foliage.AddPreset("plants", "birch_log_a", "log", {seed = 3, bark = "birch_bark", bark_tile = 0.5, radius = {0.12, 0.18}})
foliage.AddPreset("plants", "pine_log_a", "log", {seed = 4, bark = "pine_bark", length = {5, 7}})
return plants
