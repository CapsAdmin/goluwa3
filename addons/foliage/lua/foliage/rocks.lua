local Vec3 = import("goluwa/structs/vec3.lua")
local noise = import("goluwa/math/noise.lua")
local lod = import("goluwa/render3d/lod.lua")
local MeshBuilder = import("lua/foliage/mesh_builder.lua")
local foliage = import("lua/foliage/foliage.lua")
local textures = import("lua/foliage/textures.lua")
local trees = import("lua/foliage/trees.lua")
local rocks = {}
local tan, pi, sqrt, max, min, abs = math.tan, math.pi, math.sqrt, math.max, math.min, math.abs
local PAD = textures.kinds.rock.defaults.pad
local FACES = {
	{Vec3(1, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0)},
	{Vec3(-1, 0, 0), Vec3(0, 0, 1), Vec3(0, 1, 0)},
	{Vec3(0, 1, 0), Vec3(1, 0, 0), Vec3(0, 0, -1)},
	{Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1)},
	{Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(0, 1, 0)},
	{Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, 1, 0)},
}

local function new_shape(config, rng)
	local offset = Vec3(rng:Range(-500, 500), rng:Range(-500, 500), rng:Range(-500, 500))
	local planes = {}

	for i = 1, config.facets do
		local yaw = rng:Next() * pi * 2
		local pitch = rng:Range(-0.3, 1.2)
		local normal = Vec3(math.cos(yaw) * math.cos(pitch), math.sin(pitch), math.sin(yaw) * math.cos(pitch))
		planes[i] = {normal = normal, distance = rng:Range(config.facet_depth[1], config.facet_depth[2])}
	end

	local frequency, amplitude, octaves, ridged = config.frequency, config.noise, config.octaves, config.ridged
	local flat = config.flatten

	return function(d)
		local sum, weight, scale, norm = 0, 1, frequency, 0

		for _ = 1, octaves do
			local n = noise.Simplex3D(d.x * scale + offset.x, d.y * scale + offset.y, d.z * scale + offset.z)
			n = n * (1 - ridged) + (1 - abs(n) * 2) * ridged
			sum = sum + n * weight
			norm = norm + weight
			weight = weight * 0.5
			scale = scale * 2.1
		end

		local r = 1 + amplitude * sum / norm

		for _, plane in ipairs(planes) do
			local along = d:GetDot(plane.normal)

			if along > 0.05 then
				local cut = plane.distance / along
				local k = 0.08
				local h = math.clamp(0.5 + 0.5 * (cut - r) / k, 0, 1)
				r = cut + (r - cut) * h - k * h * (1 - h)
			end
		end

		if d.y < 0 and -d.y * r > flat then r = flat / -d.y end

		return r
	end
end

local function add_stone(meshes, resolutions, shape, size, scale, center, phase)
	local function position(d)
		local r = shape(d) * size
		return Vec3(d.x * r * scale.x, d.y * r * scale.y, d.z * r * scale.z) + center
	end

	local e = 0.004

	for level, mesh in ipairs(meshes) do
		local resolution = resolutions[level]

		for face_index, face in ipairs(FACES) do
			local n, u, v = face[1], face[2], face[3]
			local tile_x, tile_y = (face_index - 1) % 3, math.floor((face_index - 1) / 3)
			local first = mesh:GetVertexCount()
			mesh:SetColor(0, phase, 1)

			for j = 0, resolution do
				for i = 0, resolution do
					local s, t = i / resolution * 2 - 1, j / resolution * 2 - 1
					local d = (n + u * tan(s * pi * 0.25) + v * tan(t * pi * 0.25)):GetNormalized()
					local p = position(d)
					local t1 = trees.perpendicular(d)
					local t2 = d:GetCross(t1)
					local normal = (position((d + t1 * e):GetNormalized()) - p):GetCross(position((d + t2 * e):GetNormalized()) - p)

					if normal:GetDot(d) < 0 then normal = normal * -1 end

					mesh:Vertex(
						p.x,
						p.y,
						p.z,
						normal.x,
						normal.y,
						normal.z,
						(tile_x + PAD + (s * 0.5 + 0.5) * (1 - 2 * PAD)) / 3,
						(tile_y + PAD + (t * 0.5 + 0.5) * (1 - 2 * PAD)) / 2
					)
				end
			end

			for j = 0, resolution - 1 do
				for i = 0, resolution - 1 do
					local a = first + j * (resolution + 1) + i
					local b = a + resolution + 1
					mesh:Quad(a, a + 1, b + 1, b)
				end
			end
		end
	end
end

function rocks.BuildRock(config, rng)
	local meshes = {MeshBuilder.New(), MeshBuilder.New()}
	local resolutions = {config.resolution, max(2, math.floor(config.resolution / 2))}
	local stone_rng = rng:Fork("stones")
	local top = 0

	for i = 1, config.count do
		local size = stone_rng:Pick(config.size)
		local scale = Vec3(stone_rng:Pick(config.stretch[1]), stone_rng:Pick(config.stretch[2]), stone_rng:Pick(config.stretch[3]))
		local center = Vec3(0, 0, 0)

		if i > 1 then
			local angle = stone_rng:Next() * pi * 2
			local distance = sqrt(stone_rng:Next()) * config.spread
			center = Vec3(math.cos(angle) * distance, 0, math.sin(angle) * distance)
			size = size * stone_rng:Range(0.5, 1)
		end

		center.y = size * scale.y * (config.flatten - config.sink * (1 + config.flatten))
		top = max(top, center.y + size * scale.y * (1 + config.noise))
		add_stone(meshes, resolutions, new_shape(config, stone_rng:Fork(i)), size, scale, center, stone_rng:Next())
	end

	local material = foliage.GetMaterial(config.material)
	return {
		{mesh = meshes[1]:Build{name = "foliage_rock"}, material = material},
		{mesh = meshes[2]:Build{name = "foliage_rock_lod1", lod_level = 1, lod_distance = lod.CRY_RADII_PER_LEVEL}, material = material},
	}
end

local DEFAULTS = {
	size = {0.6, 0.9},
	stretch = {{0.9, 1.1}, {0.65, 0.8}, {0.8, 1}},
	resolution = 14,
	noise = 0.22,
	frequency = 1.3,
	octaves = 4,
	ridged = 0,
	facets = 0,
	facet_depth = {0.6, 0.85},
	flatten = 0.45,
	sink = 0.12,
	count = 1,
	spread = 0,
	material = "rock_granite",
}

local function rock(name, overrides)
	local defaults = {}

	for key, value in pairs(DEFAULTS) do
		defaults[key] = value
	end

	for key, value in pairs(overrides) do
		defaults[key] = value
	end

	foliage.AddGenerator(name, {category = "rocks", defaults = defaults, build = rocks.BuildRock})
end

rock("boulder", {})
rock("slab", {size = {0.9, 1.3}, stretch = {{1.1, 1.4}, {0.3, 0.4}, {0.9, 1.1}}, noise = 0.12, frequency = 1.8, facets = 4, facet_depth = {0.75, 0.9}, flatten = 0.6, material = "rock_sandstone"})
rock("crag", {size = {0.9, 1.3}, stretch = {{0.6, 0.8}, {1.2, 1.6}, {0.6, 0.8}}, noise = 0.08, frequency = 2.2, ridged = 0.4, facets = 9, facet_depth = {0.45, 0.75}, flatten = 0.7, sink = 0.08, resolution = 16, material = "rock_basalt"})
rock("mossy_boulder", {size = {0.7, 1}, stretch = {{0.95, 1.1}, {0.7, 0.85}, {0.9, 1.05}}, noise = 0.15, frequency = 1.1, material = "rock_mossy"})
rock("pebbles", {size = {0.07, 0.13}, stretch = {{0.9, 1.2}, {0.45, 0.6}, {0.7, 0.9}}, noise = 0.06, frequency = 1, octaves = 2, flatten = 0.4, sink = 0.2, count = 9, spread = 0.35, resolution = 5, material = "rock_river"})
rock("scree", {size = {0.25, 0.4}, stretch = {{0.8, 1.2}, {0.6, 0.9}, {0.8, 1.2}}, noise = 0.1, frequency = 2, ridged = 0.3, facets = 6, facet_depth = {0.55, 0.8}, count = 5, spread = 0.7, resolution = 8, material = "rock_granite"})

for _, name in ipairs{"boulder", "slab", "crag", "mossy_boulder", "pebbles", "scree"} do
	foliage.AddPreset("rocks", name .. "_a", name, {seed = 1})
	foliage.AddPreset("rocks", name .. "_b", name, {seed = 2})
end

return rocks
