-- trees and bushes: a trunk (or a few stems), levels of branches grown off it and cards of leaves on the outer
-- branches, in the way of weber and penn's "creation and rendering of realistic trees". a branch is a curve of
-- points grown in steps that curve, wander, droop and reach up, the children of a level are spread along their
-- parent by a golden angle or in whorls, and the crown shape says how long the branches off the trunk are at each height
--
-- the wind: everything sways around the root by its height (the polygon's BendHeight and the material's Bending), and
-- the detail bending of model_pipeline.lua moves a vertex up and down by 1 - its stiffness (the vertex color's blue).
-- a part moving up and down by the same amount everywhere moves rigidly, one whose stiffness falls along it turns
-- about where it is stiff. so the trunk is rigid (it only sways), a branch is as stiff where it leaves the trunk and
-- loses `flex` a meter of horizontal reach out from there: a branch going out turns about where it is attached, one
-- going up or hanging down moves with its attachment and is not stretched along itself. each big limb has its own
-- phase, which its branches and leaves share so they move together. leaves turn about their twig and flutter at their
-- far edge
local Vec3 = import("goluwa/structs/vec3.lua")
local MeshBuilder = import("lua/foliage/mesh_builder.lua")
local foliage = import("lua/foliage/foliage.lua")
local trees = {}
local cos, sin, rad, sqrt, abs, max, min, floor = math.cos, math.sin, math.rad, math.sqrt, math.abs, math.max, math.min, math.floor
local UP = Vec3(0, 1, 0)

local function perpendicular(v)
	local other = abs(v.y) < 0.95 and UP or Vec3(1, 0, 0)
	return v:GetCross(other):GetNormalized()
end

trees.perpendicular = perpendicular

-- how long the branches off the trunk are at a height in the crown (0 its bottom, 1 its top)
local CROWN_SHAPES = {
	conical = function(r)
		return 0.15 + 0.85 * (1 - r)
	end,
	spherical = function(r)
		return 0.25 + 0.75 * sin(math.pi * r)
	end,
	dome = function(r)
		return 0.35 + 0.65 * sin(math.pi * 0.5 * (1 - r * r) + 0.0001)
	end,
	cylindrical = function()
		return 1
	end,
	tapered = function(r)
		return 0.5 + 0.5 * (1 - r)
	end,
	flame = function(r)
		return r < 0.7 and 0.3 + 0.7 * r / 0.7 or 0.3 + 0.7 * (1 - r) / 0.3
	end,
	umbrella = function(r)
		return 0.3 + 0.7 * r ^ 0.7
	end,
}
trees.CROWN_SHAPES = CROWN_SHAPES

-- the points of a branch from start along dir: {pos, dir, radius, t, reach}, reach the horizontal distance along it
-- from the start. spec: curve (degrees over the length, up is positive), noise (degrees of wander a step), gravity and
-- up (a pull a meter), taper (how much thinner the tip is)
function trees.Grow(rng, start, dir, length, radius, spec, segments, floor_height)
	local points = {}
	local pos = start
	local step = length / segments
	local tip_radius = radius * (1 - spec.taper)
	local curve = rad(spec.curve or 0) / segments
	local noise = rad(spec.noise or 0)
	local gravity = (spec.gravity or 0) * step
	local up = (spec.up or 0) * step
	local reach = 0

	for i = 0, segments do
		local t = i / segments
		points[i + 1] = {pos = pos, dir = dir, radius = radius + (tip_radius - radius) * t, t = t, reach = reach}

		if i < segments then
			reach = reach + sqrt(dir.x * dir.x + dir.z * dir.z) * step
			pos = pos + dir * step
			local across = dir:GetCross(UP)

			if across:GetLength() < 0.01 then across = perpendicular(dir) end

			dir = dir:GetRotated(across:GetNormalized(), curve)

			if noise > 0 then
				dir = dir:GetRotated(perpendicular(dir):GetRotated(dir, rng:Next() * math.pi * 2), rng:Gaussian() * noise)
			end

			dir = (dir + Vec3(0, up - gravity, 0)):GetNormalized()

			-- nothing grows into the ground
			if floor_height and pos.y < floor_height and dir.y < 0.2 then
				dir = (dir + Vec3(0, 0.4, 0)):GetNormalized()
			end
		end
	end

	return points
end

-- the point at t along a branch (0 to 1), interpolated: position, direction, radius and reach
function trees.Sample(points, t)
	local f = t * (#points - 1)
	local i = min(floor(f), #points - 2)
	local a, b = points[i + 1], points[i + 2]
	local k = f - i
	return a.pos + (b.pos - a.pos) * k,
	(a.dir + (b.dir - a.dir) * k):GetNormalized(),
	a.radius + (b.radius - a.radius) * k,
	a.reach + (b.reach - a.reach) * k
end

-- the stiffness of what is reach meters of horizontal distance out from where it is held
function trees.Stiffness(reach, flex)
	return max(1 - reach * flex, 0)
end

-- the stiffness at the top of something that goes up from a point of stiffness `stiffness` along a vector, its
-- horizontal part bends it
function trees.StiffnessAlong(stiffness, vector, flex)
	return max(stiffness - sqrt(vector.x * vector.x + vector.z * vector.z) * flex, 0)
end

-- the points as a tube in wood, the bark repeats every tile meters. stiffness(t) and phase are the bending colors
function trees.AddTube(wood, points, sides, tile, phase, stiffness, cap, v_offset)
	local ring = {}
	local circumference = math.pi * 2 * points[1].radius
	local u_repeat = circumference / tile

	-- a whole number of repeats where it can be, so there is no seam
	if u_repeat >= 1 then u_repeat = floor(u_repeat + 0.5) end

	for i, point in ipairs(points) do
		ring[i] = {point.pos.x, point.pos.y, point.pos.z, point.radius, 0, phase, stiffness(point)}
	end

	return wood:Tube(ring, {sides = sides, u_repeat = u_repeat, v_length = tile, v_offset = v_offset, cap = cap})
end

-- leaf cards of a tree, collected first so their normals can lean out from the middle of the crown. a card is its
-- bottom middle, its up and its preferred facing
function trees.NewCards()
	return {}
end

-- stiffness is at the bottom of the card, where the twig is held, the top loses flex over the card's horizontal extent
function trees.AddCard(cards, rng, base, up, facing, size, roll, phase, stiffness, flex, atlas, aspect)
	up = up:GetNormalized()
	local side = up:GetCross(facing)

	if side:GetLength() < 0.001 then side = perpendicular(up) end

	side = side:GetNormalized():GetRotated(up, (rng:Next() * 2 - 1) * rad(roll))
	local normal = side:GetCross(up)
	local tile = rng:Int(0, atlas - 1)
	cards[#cards + 1] = {
		center = base + up * (size * 0.5),
		side = side * (size * 0.5 * (aspect or 1)),
		up = up * (size * 0.5),
		normal = normal,
		uv = {tile / atlas, 0, (tile + 1) / atlas, 1},
		phase = phase,
		stiffness = stiffness,
		top_stiffness = trees.StiffnessAlong(stiffness, up * size, flex),
	}
end

-- the cards into a mesh. their normals lean away from the trunk by bend (0 to 1): towards the direction from the
-- nearest point of the trunk's center line (and the limbs it splits into, or a bush's stems), so a crown is lit like
-- the shape of its tree around its trunk, a cone for a pine, rather than each card by its own facing
do
	-- the nearest point to p on the segments of the lines
	local function nearest_on(lines, p)
		local best, nearest = math.huge, nil

		for _, line in ipairs(lines) do
			for i = 1, #line - 1 do
				local a, b = line[i].pos, line[i + 1].pos
				local ab = b - a
				local t = math.clamp((p - a):GetDot(ab) / max(ab:GetDot(ab), 1e-8), 0, 1)
				local q = a + ab * t
				local d = (p - q):GetLength()

				if d < best then best, nearest = d, q end
			end
		end

		return nearest
	end

	function trees.BuildCards(cards, bend, trunk)
		local mesh = MeshBuilder.New()

		for _, card in ipairs(cards) do
			local first = mesh:GetVertexCount()
			local c, r, u, n = card.center, card.side, card.up, card.normal
			local uv = card.uv
			local out = c - nearest_on(trunk, c)

			-- the front faces out of the crown, the back is only seen from inside it, where a mirrored bend is wrong
			if n:GetDot(out) < 0 then
				r, n = -r, -n
			end

			for k = 0, 3 do
				local sx = (k == 1 or k == 2) and 1 or -1
				local sy = k >= 2 and 1 or -1
				local p = c + r * sx + u * sy
				local out = p - nearest_on(trunk, p)
				out = out:GetLength() > 0.001 and out:GetNormalized() or n
				local normal = n * (1 - bend) + out * bend
				-- the bottom edge is held by the twig, the top flutters
				mesh:SetColor(sy > 0 and 1 or 0, card.phase, sy > 0 and card.top_stiffness or card.stiffness)
				mesh:Vertex(p.x, p.y, p.z, normal.x, normal.y, normal.z, sx > 0 and uv[3] or uv[1], sy > 0 and uv[4] or uv[2])
			end

			mesh:Quad(first, first + 1, first + 2, first + 3)
		end

		return mesh
	end
end

local function shape_ratio(state, y)
	local crown_bottom = state.height * state.config.crown_start
	local r = (y - crown_bottom) / max(state.height - crown_bottom, 0.01)

	if r < 0 or r > 1.05 then return 0 end

	return state.crown_shape(min(r, 1))
end

local add_branch

-- the children of a branch, the next level's spec says how many, where and how
local function add_children(state, level, points, length, phase, reach)
	local spec = state.config.levels[level + 1]

	if not spec then return end

	local rng = state.rng
	local reference = state.reference[level]
	local count = spec.count * (level == 0 and 1 or min(length / reference, 1.5))
	count = floor(count + rng:Next())

	if count <= 0 then return end

	local azimuth = rng:Next() * math.pi * 2
	local whorl = spec.whorl
	local positions = whorl and math.ceil(count / whorl) or count

	for i = 0, count - 1 do
		local slot = whorl and floor(i / whorl) or i
		local t = spec.start + (spec.stop - spec.start) * (slot + 0.5 + (rng:Next() - 0.5) * (spec.jitter or 0.6)) / positions
		local pos, dir, radius, along = trees.Sample(points, t)
		local child_length

		if level == 0 then
			child_length = state.height * rng:Pick(spec.length) * shape_ratio(state, pos.y)
		else
			child_length = length * rng:Pick(spec.length) * (1 - (spec.shorten or 0.5) * t)
		end

		if child_length > (spec.min_length or 0.05) then
			if whorl then
				azimuth = (i % whorl) / whorl * math.pi * 2 + slot * rad(spec.rotate) + (rng:Next() - 0.5) * 0.4
			else
				azimuth = azimuth + rad(spec.rotate) + (rng:Next() - 0.5) * rad(spec.rotate_variation or 20)
			end

			local around = perpendicular(dir)
			local out = around:GetRotated(dir, azimuth)
			local angle = rad(rng:Pick(spec.angle))

			-- the lower branches of a whorled tree hang more
			if spec.angle_by_height then
				angle = angle + rad(spec.angle_by_height) * (1 - min(pos.y / state.height, 1))
			end

			local child_dir = (dir * cos(angle) + out * sin(angle)):GetNormalized()
			local child_phase = level == 0 and rng:Next() or phase
			-- the trunk is rigid, what grows off it is held stiff where it leaves it
			add_branch(state, level + 1, pos, child_dir, child_length, radius * spec.radius, child_phase, level == 0 and 0 or reach + along)
		end
	end
end

-- reach is how far out horizontally from where its limb leaves the trunk the branch starts
function add_branch(state, level, start, dir, length, radius, phase, reach, root)
	local config = state.config
	local spec = level == 0 and config.trunk or config.levels[level]
	local segments = max(2, floor(spec.segments * min(length / max(state.reference[level], 0.01), 1) + 0.5))
	local points = trees.Grow(state.rng, start, dir, length, radius, spec, segments, level > 0 and min(0.4, state.height * 0.15) or nil)
	-- the trunk (and its limbs) only sway
	local flex = level == 0 and 0 or config.flex

	local function stiffness(point)
		return trees.Stiffness(reach + point.reach, flex)
	end

	-- the trunk flares at its root
	if root and config.flare > 0 then
		for _, point in ipairs(points) do
			local y = point.pos.y - start.y
			point.radius = point.radius * (1 + config.flare * math.exp(-y / (config.flare_height * state.height)))
		end
	end

	-- what the normals of the leaves lean away from
	if level == 0 then state.trunk[#state.trunk + 1] = points end

	if radius >= config.min_radius then
		trees.AddTube(state.wood, points, spec.sides, config.bark_tile, phase, stiffness, true)
	end

	local leaves = config.leaves

	if leaves and level >= leaves.level then
		local rng = state.rng
		local count = floor(length * leaves.density + rng:Next())

		for _ = 1, count do
			local t = leaves.start + (1 - leaves.start) * rng:Next()
			local pos, branch_dir, _, along = trees.Sample(points, t)
			local outward = Vec3(pos.x - state.center.x, 0, pos.z - state.center.z)
			outward = outward:GetLength() > 0.01 and outward:GetNormalized() or perpendicular(branch_dir)
			local up, facing

			if leaves.orientation == "hang" then
				up = (branch_dir + Vec3(0, -leaves.droop, 0)):GetNormalized()
				facing = outward
			elseif leaves.orientation == "flat" then
				up = (branch_dir + outward * 0.3):GetNormalized()
				facing = UP
			else
				up = (branch_dir * 0.6 + outward * 0.5 + UP * leaves.lift + perpendicular(branch_dir):GetRotated(branch_dir, rng:Next() * 6.28) * 0.5):GetNormalized()
				facing = (outward + UP * 0.6):GetNormalized()
			end

			local size = rng:Pick(leaves.size)
			-- the twig on the card starts a little inside the branch
			local base = pos - up * (size * 0.05)
			local held = trees.Stiffness(reach + along, flex)
			trees.AddCard(state.cards, rng, base, up, facing, size, leaves.roll, phase, held, config.flex, leaves.atlas, leaves.aspect)

			-- and a second one across it, for sprays that are seen from every side
			if leaves.cross then
				trees.AddCard(state.cards, rng, base, up, facing:GetRotated(up, math.pi * 0.5), size, leaves.roll, phase, held, config.flex, leaves.atlas, leaves.aspect)
			end
		end
	end

	if level == 0 and state.split and not state.split_done then
		state.split_done = true
		local split = state.split
		local tip = points[#points]
		local count = split.count
		local offset = state.rng:Next() * math.pi * 2

		for i = 1, count do
			local azimuth = offset + (i - 1) / count * math.pi * 2 + (state.rng:Next() - 0.5) * 0.5
			local out = perpendicular(tip.dir):GetRotated(tip.dir, azimuth)
			local angle = rad(state.rng:Pick(split.angle))
			local limb_dir = (tip.dir * cos(angle) + out * sin(angle)):GetNormalized()
			local limb_length = state.height * state.rng:Pick(split.length)
			add_branch(state, 0, tip.pos - tip.dir * (tip.radius * 0.5), limb_dir, limb_length, tip.radius * split.radius, state.rng:Next(), 0)
		end
	end

	add_children(state, level, points, length, phase, reach)
end

-- the reference length of each level, what a branch of it is at full length, the counts of the children are
-- scaled by how long their parent is against it
local function build_references(config, height)
	local reference = {[0] = height}

	for i, level in ipairs(config.levels) do
		local longest = type(level.length) == "table" and level.length[2] or level.length
		reference[i] = (i == 1 and height or reference[i - 1]) * longest
	end

	return reference
end

function trees.BuildTree(config, rng)
	local height = rng:Pick(config.height)
	local state = {
		config = config,
		rng = rng:Fork("branches"),
		height = height,
		wood = MeshBuilder.New(),
		cards = trees.NewCards(),
		crown_shape = assert(CROWN_SHAPES[config.crown_shape], "unknown crown shape " .. tostring(config.crown_shape)),
		reference = build_references(config, height),
		center = Vec3(0, 0, 0),
		-- the center lines of the trunk, its limbs or a bush's stems
		trunk = {},
	}
	local trunk_rng = rng:Fork("trunk")
	local stems = config.stems

	if config.split then
		state.split = config.split
	end

	for i = 1, stems do
		local azimuth = (i - 1) / stems * math.pi * 2 + trunk_rng:Next()
		local lean = rad(trunk_rng:Pick(config.lean))
		local dir = Vec3(sin(lean) * cos(azimuth), cos(lean), sin(lean) * sin(azimuth))
		local length = config.split and height * config.split.height or height
		local offset = stems > 1 and Vec3(cos(azimuth), 0, sin(azimuth)) * config.stem_spread or Vec3(0, 0, 0)
		state.split_done = false
		add_branch(state, 0, offset + Vec3(0, -config.sink, 0), dir, length * trunk_rng:Range(0.9, 1.1), height * config.trunk_radius, trunk_rng:Next(), 0, true)
	end

	local parts = {}
	local top = height

	if not state.wood:IsEmpty() then
		parts[#parts + 1] = {
			mesh = state.wood:Build{bend_height = top, name = "foliage_wood"},
			material = foliage.GetMaterial(config.bark),
		}
	end

	if state.cards[1] then
		parts[#parts + 1] = {
			mesh = trees.BuildCards(state.cards, config.leaves.bend, state.trunk):Build{bend_height = top, name = "foliage_leaves"},
			material = foliage.GetMaterial(config.leaves.material),
		}
	end

	return parts
end

-- the keys every tree has, a species gives the ones that differ
local function species(overrides)
	local out = {
		height = {10, 13},
		-- of the height, at the root above the flare
		trunk_radius = 0.025,
		flare = 0.5,
		-- of the height
		flare_height = 0.03,
		lean = {0, 4},
		sink = 0.3,
		stems = 1,
		stem_spread = 0,
		-- the trunk splits into limbs: {height = share of the height, count, angle, length = share of the height, radius}
		split = false,
		crown_start = 0.3,
		crown_shape = "spherical",
		trunk = {segments = 14, sides = 12, taper = 0.7, curve = 0, noise = 3, gravity = 0, up = 0},
		levels = {},
		-- how much less stiff a meter away from the trunk is
		flex = 0.1,
		min_radius = 0.004,
		bark = "oak_bark",
		bark_tile = 0.8,
		leaves = false,
	}

	for key, value in pairs(overrides) do
		out[key] = value
	end

	return out
end

local function level(overrides)
	local out = {
		count = 10,
		start = 0.2,
		stop = 0.95,
		length = {0.4, 0.6},
		shorten = 0.5,
		angle = {40, 60},
		rotate = 137.5,
		rotate_variation = 20,
		curve = 0,
		noise = 8,
		gravity = 0,
		up = 0,
		radius = 0.6,
		taper = 0.8,
		segments = 6,
		sides = 6,
		min_length = 0.05,
	}

	for key, value in pairs(overrides) do
		out[key] = value
	end

	return out
end

local function leaves(overrides)
	local out = {
		material = "oak_leaves",
		-- the lowest level that has leaves
		level = 3,
		-- cards a meter of branch
		density = 3,
		start = 0.2,
		size = {0.6, 0.8},
		orientation = "out",
		lift = 0.3,
		droop = 0,
		roll = 35,
		-- a second card across each one
		cross = false,
		atlas = 4,
		aspect = 1,
		-- how far the normals lean away from the trunk, 0 to 1
		bend = 0.55,
	}

	for key, value in pairs(overrides) do
		out[key] = value
	end

	return out
end

trees.species = species
trees.level = level
trees.leaves = leaves

local function add_species(name, category, defaults)
	foliage.AddGenerator(
		name,
		{
			category = category,
			defaults = defaults,
			build = trees.BuildTree,
		}
	)
end

trees.AddSpecies = add_species
-- broad and spreading, a short thick trunk that splits into crooked limbs
add_species(
	"oak",
	"trees",
	species{
		height = {9, 12},
		trunk_radius = 0.04,
		flare = 0.6,
		split = {height = 0.38, count = 3, angle = {28, 45}, length = {0.5, 0.62}, radius = 0.72},
		crown_start = 0.3,
		crown_shape = "dome",
		trunk = {segments = 10, sides = 14, taper = 0.35, curve = 0, noise = 6, gravity = 0, up = 0.02},
		levels = {
			level{count = 9, start = 0.2, length = {0.3, 0.42}, angle = {50, 75}, curve = -10, noise = 14, up = 0.05, radius = 0.5, segments = 8, sides = 8},
			level{count = 8, start = 0.15, length = {0.45, 0.6}, angle = {35, 60}, noise = 18, up = 0.08, radius = 0.55, segments = 6, sides = 5},
			level{count = 6, start = 0.25, length = {0.4, 0.55}, angle = {35, 55}, noise = 15, up = 0.1, radius = 0.6, segments = 3, sides = 3},
		},
		bark = "oak_bark",
		leaves = leaves{material = "oak_leaves", level = 2, density = 2.2, start = 0.45, size = {0.6, 0.85}},
	}
)
-- tall and narrow, a straight trunk with whorls of branches that hang lower down, the needles in flat sprays
add_species(
	"pine",
	"trees",
	species{
		height = {14, 19},
		trunk_radius = 0.016,
		flare = 0.4,
		lean = {0, 2},
		crown_start = 0.22,
		crown_shape = "conical",
		trunk = {segments = 18, sides = 10, taper = 0.95, curve = 0, noise = 1.5, gravity = 0, up = 0},
		levels = {
			level{count = 60, whorl = 5, start = 0.22, stop = 0.98, length = {0.24, 0.3}, angle = {75, 95}, angle_by_height = 20, rotate = 30, curve = 18, noise = 6, gravity = 0.03, radius = 0.45, segments = 7, sides = 5, jitter = 0.2},
			level{count = 14, start = 0.1, length = {0.35, 0.5}, angle = {50, 70}, rotate = 180, rotate_variation = 30, noise = 10, gravity = 0.1, radius = 0.5, segments = 3, sides = 3},
		},
		flex = 0.15,
		bark = "pine_bark",
		bark_tile = 0.7,
		leaves = leaves{material = "pine_needles", level = 1, density = 3.5, start = 0.1, size = {0.8, 1.1}, orientation = "flat", roll = 30, cross = true, atlas = 2, bend = 0.4},
	}
)
-- slender, white, with arching branches and hanging twigs of small leaves
add_species(
	"birch",
	"trees",
	species{
		height = {11, 15},
		trunk_radius = 0.013,
		flare = 0.3,
		lean = {1, 6},
		crown_start = 0.3,
		crown_shape = "flame",
		trunk = {segments = 16, sides = 10, taper = 0.9, curve = 0, noise = 4, gravity = 0, up = 0.01},
		levels = {
			level{count = 26, start = 0.3, length = {0.25, 0.35}, angle = {30, 45}, curve = -30, noise = 10, gravity = 0.02, radius = 0.5, segments = 8, sides = 5},
			level{count = 10, start = 0.2, length = {0.45, 0.6}, angle = {40, 60}, noise = 12, gravity = 0.25, radius = 0.5, segments = 5, sides = 3},
			level{count = 5, start = 0.3, length = {0.4, 0.55}, angle = {30, 45}, noise = 10, gravity = 0.5, radius = 0.6, segments = 3, sides = 3},
		},
		flex = 0.14,
		bark = "birch_bark",
		bark_tile = 0.5,
		leaves = leaves{material = "birch_leaves", level = 2, density = 3, start = 0.3, size = {0.45, 0.6}, orientation = "hang", droop = 0.6, bend = 0.5},
	}
)
-- a short thick trunk splitting into limbs that arch out, and curtains of long thin hanging strands
add_species(
	"willow",
	"trees",
	species{
		height = {8, 11},
		trunk_radius = 0.045,
		flare = 0.5,
		lean = {0, 5},
		split = {height = 0.3, count = 4, angle = {30, 50}, length = {0.45, 0.55}, radius = 0.68},
		crown_start = 0.3,
		crown_shape = "dome",
		trunk = {segments = 8, sides = 14, taper = 0.4, curve = 0, noise = 8, gravity = 0, up = 0.03},
		levels = {
			level{count = 8, start = 0.3, length = {0.28, 0.38}, angle = {40, 65}, curve = -25, noise = 10, up = 0.04, radius = 0.5, segments = 8, sides = 6},
			level{count = 10, start = 0.25, stop = 1, length = {1.2, 1.7}, shorten = 0.2, angle = {20, 40}, noise = 4, gravity = 0.9, radius = 0.35, taper = 0.6, segments = 10, sides = 3, min_length = 0.5},
		},
		flex = 0.12,
		bark = "willow_bark",
		bark_tile = 0.7,
		leaves = leaves{material = "willow_leaves", level = 2, density = 2.8, start = 0.15, size = {0.5, 0.7}, orientation = "hang", droop = 2, bend = 0.4, roll = 60},
	}
)
-- bare and grey, crooked and broken
add_species(
	"dead_tree",
	"trees",
	species{
		height = {7, 10},
		trunk_radius = 0.03,
		flare = 0.5,
		lean = {0, 8},
		crown_start = 0.35,
		crown_shape = "tapered",
		trunk = {segments = 12, sides = 10, taper = 0.85, curve = 0, noise = 7, gravity = 0, up = 0},
		levels = {
			level{count = 16, start = 0.25, length = {0.2, 0.42}, angle = {40, 75}, noise = 22, up = 0.02, radius = 0.5, segments = 6, sides = 6},
			level{count = 7, start = 0.15, length = {0.3, 0.55}, angle = {30, 60}, noise = 25, radius = 0.5, segments = 4, sides = 4},
			level{count = 4, start = 0.3, length = {0.3, 0.5}, angle = {30, 60}, noise = 25, radius = 0.55, segments = 2, sides = 3},
		},
		bark = "dead_bark",
	}
)
-- bushes: many stems from the ground and leaves all over
add_species(
	"bush",
	"plants",
	species{
		height = {1.2, 1.8},
		trunk_radius = 0.012,
		flare = 0,
		lean = {15, 35},
		sink = 0.05,
		stems = 6,
		stem_spread = 0.12,
		crown_start = 0.05,
		crown_shape = "spherical",
		trunk = {segments = 6, sides = 5, taper = 0.8, curve = -15, noise = 10, gravity = 0, up = 0},
		levels = {
			level{count = 7, start = 0.15, length = {0.4, 0.6}, angle = {35, 60}, noise = 18, up = 0.2, radius = 0.6, segments = 4, sides = 3},
			level{count = 4, start = 0.2, length = {0.4, 0.6}, angle = {30, 50}, noise = 15, up = 0.1, radius = 0.6, segments = 2, sides = 3},
		},
		flex = 0.4,
		min_radius = 0.003,
		bark = "twig_bark",
		bark_tile = 0.3,
		leaves = leaves{material = "bush_leaves", level = 1, density = 7, start = 0.15, size = {0.3, 0.42}, bend = 0.6, lift = 0.4},
	}
)
add_species(
	"berry_bush",
	"plants",
	species{
		height = {0.9, 1.3},
		trunk_radius = 0.012,
		flare = 0,
		lean = {20, 45},
		sink = 0.05,
		stems = 5,
		stem_spread = 0.1,
		crown_start = 0.05,
		crown_shape = "dome",
		trunk = {segments = 6, sides = 5, taper = 0.8, curve = -25, noise = 10, gravity = 0, up = 0},
		levels = {
			level{count = 6, start = 0.2, length = {0.4, 0.6}, angle = {35, 60}, noise = 18, up = 0.15, radius = 0.6, segments = 4, sides = 3},
			level{count = 3, start = 0.3, length = {0.4, 0.6}, angle = {30, 50}, noise = 15, radius = 0.6, segments = 2, sides = 3},
		},
		flex = 0.4,
		min_radius = 0.003,
		bark = "twig_bark",
		bark_tile = 0.3,
		leaves = leaves{material = "berry_leaves", level = 1, density = 8, start = 0.15, size = {0.28, 0.38}, bend = 0.6, lift = 0.4},
	}
)
add_species(
	"juniper",
	"plants",
	species{
		height = {1.4, 2.2},
		trunk_radius = 0.015,
		flare = 0,
		lean = {0, 10},
		sink = 0.05,
		stems = 1,
		crown_start = 0.05,
		crown_shape = "flame",
		trunk = {segments = 8, sides = 6, taper = 0.9, curve = 0, noise = 6, gravity = 0, up = 0},
		levels = {
			level{count = 40, start = 0.05, length = {0.3, 0.45}, angle = {35, 55}, curve = 10, noise = 10, up = 0.1, radius = 0.5, segments = 4, sides = 3},
		},
		flex = 0.3,
		bark = "pine_bark",
		bark_tile = 0.4,
		leaves = leaves{material = "pine_needles", level = 1, density = 9, start = 0.1, size = {0.3, 0.4}, roll = 70, atlas = 2, bend = 0.6, lift = 0.6},
	}
)

-- a frond: a strip along a drooping rachis, folded up along it in a v, with the frond texture across it (u 0 to 1,
-- the rachis in the middle) and along it (v from the base). width is of the length, fold in degrees. it is held at
-- its base and loses flex of its stiffness a meter of horizontal reach. its normals lean away from center (where the
-- plant's fronds grow from, the top of a palm's trunk) by bend, like the leaves of a tree from its trunk
function trees.AddFrond(mesh, rng, base, dir, length, width, fold, gravity, curve, segments, phase, flex, center, bend)
	local points = trees.Grow(rng, base, dir, length, 0, {taper = 0, curve = curve, noise = 3, gravity = gravity}, segments, nil)
	local half = length * width * 0.5
	local fold_angle = rad(fold)
	local first = mesh:GetVertexCount()

	for i, point in ipairs(points) do
		local t = point.t
		local side = point.dir:GetCross(UP)

		if side:GetLength() < 0.01 then side = perpendicular(point.dir) end

		side = side:GetNormalized()
		local up = side:GetCross(point.dir):GetNormalized()

		if up.y < 0 then
			up = up * -1
			side = side * -1
		end

		-- the leaflets lift towards the edges, the v of the fold
		local left = point.pos - side * (half * cos(fold_angle)) + up * (half * sin(fold_angle))
		local right = point.pos + side * (half * cos(fold_angle)) + up * (half * sin(fold_angle))
		local normal_left = (up * cos(fold_angle) + side * sin(fold_angle) + UP * 0.3):GetNormalized()
		local normal_right = (up * cos(fold_angle) - side * sin(fold_angle) + UP * 0.3):GetNormalized()
		local away_left, away_right, away = (left - center):GetNormalized(), (right - center):GetNormalized(), point.pos - center
		away = away:GetLength() > 0.001 and away:GetNormalized() or up
		normal_left = normal_left * (1 - bend) + away_left * bend
		normal_right = normal_right * (1 - bend) + away_right * bend
		local normal = up * (1 - bend) + away * bend
		local stiffness = trees.Stiffness(point.reach, flex)
		mesh:SetColor(t, phase, stiffness)
		mesh:Vertex(left.x, left.y, left.z, normal_left.x, normal_left.y, normal_left.z, 0, t)
		mesh:SetColor(t * 0.3, phase, stiffness)
		mesh:Vertex(point.pos.x, point.pos.y, point.pos.z, normal.x, normal.y, normal.z, 0.5, t)
		mesh:SetColor(t, phase, stiffness)
		mesh:Vertex(right.x, right.y, right.z, normal_right.x, normal_right.y, normal_right.z, 1, t)
	end

	for i = 0, #points - 2 do
		local a = first + i * 3
		local b = a + 3
		-- facing up, u grows to the right of the rachis
		mesh:Quad(a, a + 1, b + 1, b)
		mesh:Quad(a + 1, a + 2, b + 2, b + 1)
	end

	return points
end

-- a low poly ball, for fruit
function trees.AddBall(mesh, center, radius, rings, sides, phase, stiffness)
	local first = mesh:GetVertexCount()
	mesh:SetColor(0, phase, stiffness)

	for ring = 0, rings do
		local theta = ring / rings * math.pi

		for side = 0, sides do
			local phi = side / sides * math.pi * 2
			local nx, ny, nz = sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi)
			mesh:Vertex(center.x + nx * radius, center.y + ny * radius * 1.1, center.z + nz * radius, nx, ny, nz, side / sides, ring / rings)
		end
	end

	for ring = 0, rings - 1 do
		for side = 0, sides - 1 do
			local a = first + ring * (sides + 1) + side
			local b = a + sides + 1
			mesh:Quad(a, b, b + 1, a + 1)
		end
	end
end

-- a palm: a ringed trunk that leans and curves back up, a crown of fronds from upright to drooping, a few dead ones
-- hanging under it and coconuts
function trees.BuildPalm(config, rng)
	local height = rng:Pick(config.height)
	local trunk_rng = rng:Fork("trunk")
	local wood = MeshBuilder.New()
	local fronds = MeshBuilder.New()
	local dry = MeshBuilder.New()
	local fruit = MeshBuilder.New()
	local azimuth = trunk_rng:Next() * math.pi * 2
	local lean = rad(trunk_rng:Pick(config.lean))
	local dir = Vec3(sin(lean) * cos(azimuth), cos(lean), sin(lean) * sin(azimuth))
	local radius = height * config.trunk_radius
	-- curving back up against the lean
	local points = trees.Grow(trunk_rng, Vec3(0, -0.3, 0), dir, height, radius, {taper = config.taper, curve = trunk_rng:Pick(config.curve), noise = 2}, 16)

	for _, point in ipairs(points) do
		point.radius = point.radius * (1 + config.flare * math.exp(-(point.pos.y + 0.3) / 0.6))
	end

	-- the trunk only sways
	trees.AddTube(
		wood,
		points,
		10,
		config.bark_tile,
		0,
		function()
			return 1
		end,
		true
	)
	local top = points[#points]
	local frond_rng = rng:Fork("fronds")
	local count = frond_rng:Int(config.fronds[1], config.fronds[2])
	local golden = rad(137.5)
	local spin = frond_rng:Next() * math.pi * 2

	for i = 1, count do
		local k = (i - 1) / max(count - 1, 1)
		local pitch = rad(config.pitch[1] + (config.pitch[2] - config.pitch[1]) * k + (frond_rng:Next() - 0.5) * 12)
		local yaw = spin + i * golden
		local out = Vec3(cos(yaw), 0, sin(yaw))
		local frond_dir = (UP * cos(pitch) + out * sin(pitch)):GetNormalized()
		local length = frond_rng:Pick(config.frond_length) * (0.75 + 0.25 * k)
		trees.AddFrond(fronds, frond_rng, top.pos + out * (top.radius * 0.5), frond_dir, length, config.frond_width, config.fold, config.droop * (0.5 + k), -10, 12, frond_rng:Next(), config.frond_flex, top.pos, config.frond_bend)
	end

	for _ = 1, frond_rng:Int(config.dead_fronds[1], config.dead_fronds[2]) do
		local yaw = frond_rng:Next() * math.pi * 2
		local out = Vec3(cos(yaw), 0, sin(yaw))
		local frond_dir = (UP * -0.9 + out * 0.35):GetNormalized()
		trees.AddFrond(dry, frond_rng, top.pos - UP * 0.1 + out * top.radius, frond_dir, frond_rng:Pick(config.frond_length) * 0.6, config.frond_width * 0.6, 10, 0.05, 0, 6, frond_rng:Next(), config.frond_flex, top.pos, config.frond_bend)
	end

	local fruit_rng = rng:Fork("fruit")

	for _ = 1, fruit_rng:Int(config.fruit[1], config.fruit[2]) do
		local yaw = fruit_rng:Next() * math.pi * 2
		local offset = Vec3(cos(yaw), 0, sin(yaw)) * (top.radius + 0.08) - UP * fruit_rng:Range(0.1, 0.35)
		trees.AddBall(fruit, top.pos + offset, fruit_rng:Range(0.09, 0.12), 6, 8, 0, 1)
	end

	local parts = {
		{mesh = wood:Build{bend_height = height, name = "foliage_palm_trunk"}, material = foliage.GetMaterial(config.bark)},
		{mesh = fronds:Build{bend_height = height, name = "foliage_palm_fronds"}, material = foliage.GetMaterial(config.frond_material)},
	}

	if not dry:IsEmpty() then
		parts[#parts + 1] = {mesh = dry:Build{bend_height = height, name = "foliage_palm_dry"}, material = foliage.GetMaterial(config.dry_material)}
	end

	if not fruit:IsEmpty() then
		parts[#parts + 1] = {mesh = fruit:Build{bend_height = height, name = "foliage_palm_fruit"}, material = foliage.GetMaterial("coconut")}
	end

	return parts
end

foliage.AddGenerator(
	"palm",
	{
		category = "trees",
		defaults = {
			height = {7, 11},
			trunk_radius = 0.02,
			taper = 0.35,
			flare = 0.6,
			lean = {5, 18},
			-- degrees over the trunk, against the lean
			curve = {6, 18},
			bark = "palm_bark",
			bark_tile = 0.9,
			fronds = {14, 18},
			-- degrees from upright, the first frond to the last
			pitch = {15, 105},
			frond_length = {3.2, 4.2},
			frond_width = 0.5,
			fold = 22,
			droop = 0.28,
			-- how much less stiff a meter of a frond's reach out of the crown is
			frond_flex = 0.2,
			-- how far the normals of the fronds lean away from the top of the trunk
			frond_bend = 0.35,
			frond_material = "palm_frond",
			dead_fronds = {2, 4},
			dry_material = "palm_frond_dry",
			fruit = {3, 7},
		},
		build = trees.BuildPalm,
	}
)

foliage.AddPreset("trees", "oak_a", "oak", {seed = 1})
foliage.AddPreset("trees", "oak_b", "oak", {seed = 2})
foliage.AddPreset("trees", "oak_c", "oak", {seed = 3})
foliage.AddPreset("trees", "pine_a", "pine", {seed = 1})
foliage.AddPreset("trees", "pine_b", "pine", {seed = 2})
foliage.AddPreset("trees", "pine_c", "pine", {seed = 3})
foliage.AddPreset("trees", "birch_a", "birch", {seed = 1})
foliage.AddPreset("trees", "birch_b", "birch", {seed = 2})
foliage.AddPreset("trees", "birch_c", "birch", {seed = 3})
foliage.AddPreset("trees", "willow_a", "willow", {seed = 1})
foliage.AddPreset("trees", "willow_b", "willow", {seed = 2})
foliage.AddPreset("trees", "palm_a", "palm", {seed = 1})
foliage.AddPreset("trees", "palm_b", "palm", {seed = 2})
foliage.AddPreset("trees", "palm_c", "palm", {seed = 3, fruit = {0, 0}})
foliage.AddPreset("trees", "dead_tree_a", "dead_tree", {seed = 1})
foliage.AddPreset("trees", "dead_tree_b", "dead_tree", {seed = 2})
foliage.AddPreset("plants", "bush_a", "bush", {seed = 1})
foliage.AddPreset("plants", "bush_b", "bush", {seed = 2})
foliage.AddPreset("plants", "berry_bush_a", "berry_bush", {seed = 1})
foliage.AddPreset("plants", "berry_bush_b", "berry_bush", {seed = 2})
foliage.AddPreset("plants", "juniper_a", "juniper", {seed = 1})
return trees
