local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local water = import("goluwa/render3d/water.lua")
local weather = import("goluwa/render3d/weather.lua")
local View = import("goluwa/render3d/view.lua")
local ShadowMap = import("goluwa/render3d/shadow_map.lua")
local commands = import("goluwa/cli/commands.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local LAND_HEIGHT = 3
local LAKE = {x = -70, z = 60, radius = 30, surface = 2.3, depth = 9}
local POND = {x = -15, z = 38, radius = 12, surface = 2.55, depth = 1.8}
local SWAMP = {x = 32, z = 72, radius = 24, surface = 2.4, depth = 1.1}
local RIVER = {z = 115, width = 9, surface = 2.1, depth = 1.6}
local POOL = {x = 60, z = 20, width = 20, length = 12, depth = 2.2}
local HEADER = noise.WORLD .. string.format(
		[=[
const float LAND_HEIGHT = %f;
const vec4 LAKE = vec4(%f, %f, %f, %f);
const vec4 POND = vec4(%f, %f, %f, %f);
const vec4 SWAMP = vec4(%f, %f, %f, %f);
const vec3 RIVER = vec3(%f, %f, %f);
const vec4 POOL = vec4(%f, %f, %f, %f);

// a bowl whose rim rises out of the water at radius r, depth deep below the surface
float basin(vec2 p, vec4 b, float depth) {
	float r = length(p - b.xy) / b.z;
	float bowl = 1.0 - clamp(r, 0.0, 1.0);
	return b.w - depth * pow(bowl, 0.7) * smoothstep(0.0, 0.25, bowl) + smoothstep(0.75, 1.0, r) * 1.2;
}

float smin(float a, float b, float k) {
	float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}
]=],
		LAND_HEIGHT,
		LAKE.x,
		LAKE.z,
		LAKE.radius,
		LAKE.surface,
		POND.x,
		POND.z,
		POND.radius,
		POND.surface,
		SWAMP.x,
		SWAMP.z,
		SWAMP.radius,
		SWAMP.surface,
		RIVER.z,
		RIVER.width,
		RIVER.surface,
		POOL.x,
		POOL.z,
		POOL.width,
		POOL.length
	)
local HEIGHT_GLSL = [=[
float terrain_height(vec2 p) {
	float step = terrain_bake_step();
	// the coast winds along x, the beach runs down into a sea floor that
	// keeps falling away
	float coast = -18.0 + pn_noise(vec2(p.x * 0.006, 1.3)) * 14.0;
	float d = p.y - coast;
	float land = LAND_HEIGHT + 1.0 + pn_fbm_lod(p * 0.012, 4, 83.0, step) * 0.9 + smoothstep(60.0, 260.0, p.y) * 28.0 * (0.6 + 0.4 * pn_noise(p * 0.004));
	float beach = mix(-1.5, LAND_HEIGHT, smoothstep(-25.0, 10.0, d));
	float h = mix(beach, land, smoothstep(0.0, 30.0, d));
	// past the shallows the shelf drops away
	h = max(h - max(-d - 15.0, 0.0) * 0.25, -40.0);
	// sandbars and ripples on the sea floor
	h += pn_fbm_lod(p * 0.05, 3, 20.0, step) * (d < 0.0 ? 0.6 : 0.25);

	h = smin(h, basin(p, LAKE, 9.0 + pn_noise(p * 0.05) * 2.0), 3.0);
	h = smin(h, basin(p, POND, 1.8), 1.5);
	// the swamp is shallow and lumpy, with islands of mud and reeds
	float swamp = basin(p, vec4(SWAMP.xy, SWAMP.z * (0.85 + 0.25 * pn_noise(p * 0.04)), SWAMP.w), 1.1);
	swamp += max(pn_fbm_lod(p * 0.09, 3, 11.0, step) - 0.15, 0.0) * 2.4;
	h = smin(h, swamp, 2.0);

	// the river meanders across, its bed deepest in the middle
	float center = RIVER.x + sin(p.x * 0.025) * 9.0 + pn_noise(vec2(p.x * 0.01, 7.0)) * 6.0;
	float across = abs(p.y - center) / RIVER.y;
	float bed = RIVER.z - 1.6 * (1.0 - smoothstep(0.0, 1.0, across)) + smoothstep(0.8, 1.6, across) * 1.4;
	h = smin(h, bed, 1.5);

	// a flat deck around the pool, the pool itself is built from boxes
	vec2 to_pool = abs(p - POOL.xy) - POOL.zw * 0.5;
	float pool_deck = max(to_pool.x, to_pool.y);
	h = mix(LAND_HEIGHT, h, smoothstep(8.0, 20.0, pool_deck));
	if (pool_deck < 0.3) h = LAND_HEIGHT - 3.0;
	return h;
}
]=]
local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 p, float h, vec3 n) {
	float slope = 1.0 - n.y;
	float breakup = pn_fbm(p * 0.05, 3);
	float coast = -18.0 + pn_noise(vec2(p.x * 0.006, 1.3)) * 14.0;
	float sand = 1.0 - smoothstep(4.0, 16.0, p.y - coast + breakup * 6.0);
	// banks that are under water or wet are mud
	float wet = 1.0 - smoothstep(2.3, 3.1, h + breakup * 0.4);
	float rock = smoothstep(0.25, 0.45, slope + breakup * 0.1);
	vec4 w;
	w.x = sand;
	w.w = rock * (1.0 - sand);
	w.z = wet * (1.0 - sand) * (1.0 - rock);
	w.y = max(1.0 - w.x - w.z - w.w, 0.0);
	return w / max(dot(w, vec4(1.0)), 0.0001);
}
]=]
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 p, float h, vec3 n) {
	float patches = pn_fbm(p * 0.01 + vec2(1.0, 7.0), 3);
	return clamp(mix(vec3(0.75, 1.0, 0.7), vec3(1.0, 0.95, 0.8), smoothstep(-0.2, 0.5, patches)) * (0.9 + pn_fbm(p * 0.004, 2) * 0.1), 0.0, 1.0);
}
]=]

local function layer(name, scale)
	local textures = terrain_textures[name]
	return {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale}
end

if _G.water_showcase then
	_G.water_showcase.terrain:Stop()

	for _, ent in ipairs(_G.water_showcase.entities) do
		if ent:IsValid() then ent:Remove() end
	end
end

local showcase = {entities = {}}
_G.water_showcase = showcase
showcase.terrain = Terrain.New{
	Name = "water_showcase_terrain",
	Source = ShaderSource.New{
		Header = HEADER,
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = -45,
		MaxHeight = 45,
		Layers = {
			layer("sand", 4),
			layer("grass", 3),
			layer("dirt", 3),
			layer("rock", 11),
		},
	},
	Levels = 7,
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ColorSize = 64,
	ShadowLevels = 5,
	BuildsPerUpdate = 4,
}:Start()

local function track(ent)
	list.insert(showcase.entities, ent)
	return ent
end

local function mat(color, roughness, metallic)
	return shapes.Material{Color = color, Roughness = roughness, Metallic = metallic or 0}
end

local function box(name, position, size, material, rotation)
	return track(
		shapes.Box{
			Name = name,
			Position = position,
			Rotation = rotation,
			Size = size,
			Material = material,
			Collision = false,
			RigidBody = false,
		}
	)
end

local function sphere(name, position, radius, material, scale)
	return track(
		shapes.Sphere{
			Name = name,
			Position = position,
			Radius = radius,
			Scale = scale,
			Material = material,
			Collision = false,
			RigidBody = false,
		}
	)
end

local function lamp(name, position, color, lumen, range)
	local ent = track(Entity.New{Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	local light = ent:AddComponent("light_point")
	light:SetColor(color)
	light:SetLumen(lumen)
	light:SetRange(range)
	light:SetOcclusionMap(false)
	ShadowMap.New{
		mode = "point",
		light = ent,
		size = Vec2() + 512,
		near_plane = 0.05,
		far_plane = range,
	}
	return light
end

local function volume(name, position, config)
	return track(Entity.New{Name = name, transform = {Position = position}, water_volume = config})
end

local function preset(name, config)
	local out = table.shallow_copy(water.presets[name])
	out.Absorption = out.Absorption:Copy()
	out.ParticleScattering = out.ParticleScattering:Copy()

	for k, v in pairs(config) do
		out[k] = v
	end

	return out
end

local function tile_material(width, height, tile_size, color, grout)
	return shapes.Material{
		Albedo = string.format(
			[[
				vec2 cell = uv * vec2(%f, %f);
				vec2 f = abs(fract(cell) - 0.5);
				float line = smoothstep(0.44, 0.47, max(f.x, f.y));
				float shade = fract(sin(dot(floor(cell), vec2(12.9898, 78.233))) * 43758.5453) * 0.06;
				vec3 tile = vec3(%f, %f, %f) * (0.97 + shade);
				return vec4(mix(tile, vec3(%f, %f, %f), line), 1.0);
			]],
			width / tile_size,
			height / tile_size,
			color.r,
			color.g,
			color.b,
			grout.r,
			grout.g,
			grout.b
		),
		Roughness = 0.25,
		Metallic = 0,
	}
end

do
	weather.SetTimeScale(0)
	weather.SetSunDirection(Vec3(0.35, 0.42, -0.84):GetNormalized())
	render3d.SetOceanEnabled(true)
	render3d.SetOceanLevel(0)
	water.SetOcean{
		WindSpeed = 8,
		WindDirection = 70,
		SwellHeight = 0.6,
		SwellWavelength = 120,
		SwellDirection = 95,
	}
end

do
	local rock = mat(Color(0.33, 0.31, 0.29, 1), 0.85)
	local positions = {
		{-40, -0.5, -22, 2.2},
		{-34, -1.2, -30, 1.4},
		{15, 0.2, -14, 1.8},
		{22, -2, -34, 2.6},
		{70, -1, -26, 3.2},
		{-95, 0, -16, 2.8},
	}

	for i, p in ipairs(positions) do
		sphere("shore_rock" .. i, Vec3(p[1], p[2], p[3]), p[4], rock, Vec3(1.3, 0.7, 1))
	end
end

volume(
	"lake",
	Vec3(LAKE.x, LAKE.surface, LAKE.z),
	preset(
		"lake",
		{
			Size = Vec3(LAKE.radius * 2 + 10, LAKE.depth + 4, LAKE.radius * 2 + 10),
			WaveHeight = 0.06,
			WaveLength = 2.5,
			WindDirection = 70,
			Foam = 0.3,
		}
	)
)

do
	local wood = mat(Color(0.34, 0.24, 0.16, 1), 0.8)
	box(
		"jetty",
		Vec3(LAKE.x + 18, LAKE.surface + 0.6, LAKE.z - 8),
		Vec3(3, 0.2, 16),
		wood
	)

	for i = 0, 3 do
		for side = -1, 1, 2 do
			box(
				"jetty_post",
				Vec3(LAKE.x + 18 + side * 1.3, LAKE.surface - 2, LAKE.z - 15 + i * 4.5),
				Vec3(0.25, 5.2, 0.25),
				wood
			)
		end
	end

	local stone = mat(Color(0.4, 0.38, 0.35, 1), 0.7)
	sphere("lake_boulder_1", Vec3(LAKE.x - 6, LAKE.surface - 1.5, LAKE.z + 4), 2.5, stone)
	sphere("lake_boulder_2", Vec3(LAKE.x + 8, LAKE.surface - 3.5, LAKE.z + 10), 2, stone)
end

volume(
	"pond",
	Vec3(POND.x, POND.surface, POND.z),
	preset(
		"pond",
		{
			Size = Vec3(POND.radius * 2 + 4, POND.depth + 2, POND.radius * 2 + 4),
			WaveHeight = 0,
			Roughness = 0.03,
			Foam = 0.2,
		}
	)
)

do
	local leaf = mat(Color(0.12, 0.3, 0.07, 1), 0.5)

	for i = 1, 14 do
		local a = i * 2.4
		local r = 3 + (i * 37 % 7)
		sphere(
			"lily" .. i,
			Vec3(POND.x + math.cos(a) * r, POND.surface + 0.01, POND.z + math.sin(a) * r),
			0.5 + (i % 3) * 0.15,
			leaf,
			Vec3(1, 0.04, 1)
		)
	end
end

volume(
	"swamp",
	Vec3(SWAMP.x, SWAMP.surface, SWAMP.z),
	preset(
		"swamp",
		{
			Size = Vec3(SWAMP.radius * 2 + 16, SWAMP.depth + 3, SWAMP.radius * 2 + 16),
			WaveHeight = 0,
			Roughness = 0.05,
			Foam = 0.15,
			Caustics = 0.3,
		}
	)
)

do
	local bark = mat(Color(0.2, 0.15, 0.1, 1), 0.9)
	local logs = {
		{SWAMP.x - 6, SWAMP.z + 2, 0.4, 25},
		{SWAMP.x + 5, SWAMP.z - 6, 0.35, -40},
		{SWAMP.x + 10, SWAMP.z + 8, 0.5, 70},
	}

	for i, l in ipairs(logs) do
		box(
			"log" .. i,
			Vec3(l[1], SWAMP.surface - 0.1, l[2]),
			Vec3(l[3] * 2, l[3] * 2, 9),
			bark,
			QuatDeg3(0, l[4], 0)
		)
	end

	for i = 1, 5 do
		box(
			"stump" .. i,
			Vec3(SWAMP.x - 12 + i * 5, SWAMP.surface + 0.4, SWAMP.z - 10 + (i * 7 % 13)),
			Vec3(0.6, 3, 0.6),
			bark
		)
	end
end

volume(
	"river",
	Vec3(-20, RIVER.surface, RIVER.z),
	preset(
		"glacial",
		{
			Size = Vec3(200, RIVER.depth + 2, 50),
			WaveHeight = 0.05,
			WaveLength = 0.8,
			WindDirection = 0,
			Flow = Vec2(1.4, 0),
			Roughness = 0.03,
			Foam = 0.35,
		}
	)
)

do
	local stone = mat(Color(0.45, 0.43, 0.4, 1), 0.6)

	for i = 0, 5 do
		sphere(
			"stepping_stone" .. i,
			Vec3(-2 + (i % 2) * 0.8, RIVER.surface - 0.2, RIVER.z - 8 + i * 3.2),
			0.7,
			stone,
			Vec3(1, 0.6, 1)
		)
	end
end

do
	local w, l, depth = POOL.width, POOL.length, POOL.depth
	local rim = LAND_HEIGHT
	local floor_y = rim - depth - 0.2
	local tiles = Color(0.78, 0.9, 0.94, 1)
	local grout = Color(0.6, 0.66, 0.68, 1)
	local concrete = mat(Color(0.62, 0.6, 0.56, 1), 0.85)
	box(
		"pool_floor",
		Vec3(POOL.x, floor_y - 0.25, POOL.z),
		Vec3(w, 0.5, l),
		tile_material(w, l, 0.5, tiles, grout)
	)
	box(
		"pool_wall_n",
		Vec3(POOL.x, floor_y + depth / 2, POOL.z + l / 2 + 0.25),
		Vec3(w + 1, depth + 0.4, 0.5),
		tile_material(w + 1, depth + 0.4, 0.5, tiles, grout)
	)
	box(
		"pool_wall_s",
		Vec3(POOL.x, floor_y + depth / 2, POOL.z - l / 2 - 0.25),
		Vec3(w + 1, depth + 0.4, 0.5),
		tile_material(w + 1, depth + 0.4, 0.5, tiles, grout)
	)
	box(
		"pool_wall_e",
		Vec3(POOL.x + w / 2 + 0.25, floor_y + depth / 2, POOL.z),
		Vec3(0.5, depth + 0.4, l),
		tile_material(l, depth + 0.4, 0.5, tiles, grout)
	)
	box(
		"pool_wall_w",
		Vec3(POOL.x - w / 2 - 0.25, floor_y + depth / 2, POOL.z),
		Vec3(0.5, depth + 0.4, l),
		tile_material(l, depth + 0.4, 0.5, tiles, grout)
	)
	local lane = mat(Color(0.05, 0.12, 0.3, 1), 0.3)

	for i = -1, 1 do
		box(
			"pool_lane" .. i,
			Vec3(POOL.x, floor_y + 0.005, POOL.z + i * 3.5),
			Vec3(w - 3, 0.02, 0.3),
			lane
		)
	end

	box(
		"deck_n",
		Vec3(POOL.x, rim - 0.1, POOL.z + l / 2 + 4.5),
		Vec3(w + 18, 0.4, 8),
		concrete
	)
	box(
		"deck_s",
		Vec3(POOL.x, rim - 0.1, POOL.z - l / 2 - 4.5),
		Vec3(w + 18, 0.4, 8),
		concrete
	)
	box(
		"deck_e",
		Vec3(POOL.x + w / 2 + 4.5, rim - 0.1, POOL.z),
		Vec3(8, 0.4, l + 1),
		concrete
	)
	box(
		"deck_w",
		Vec3(POOL.x - w / 2 - 4.5, rim - 0.1, POOL.z),
		Vec3(8, 0.4, l + 1),
		concrete
	)
	local steel = mat(Color(0.85, 0.85, 0.85, 1), 0.2, 1)

	for side = -1, 1, 2 do
		box(
			"ladder_rail",
			Vec3(POOL.x - w / 2 + 3 + side * 0.3, rim - 0.4, POOL.z + l / 2 - 0.1),
			Vec3(0.06, 2.4, 0.06),
			steel
		)
	end

	for i = 0, 3 do
		box(
			"ladder_step",
			Vec3(POOL.x - w / 2 + 3, rim - 0.4 - i * 0.45, POOL.z + l / 2 - 0.12),
			Vec3(0.6, 0.05, 0.12),
			steel
		)
	end

	box(
		"diving_board",
		Vec3(POOL.x + w / 2 - 1, rim + 0.6, POOL.z),
		Vec3(4, 0.12, 0.8),
		mat(Color(0.9, 0.9, 0.88, 1), 0.4)
	)
	box(
		"diving_stand",
		Vec3(POOL.x + w / 2 + 0.8, rim + 0.3, POOL.z),
		Vec3(0.6, 0.6, 0.8),
		concrete
	)
	sphere(
		"beach_ball",
		Vec3(POOL.x - 3, rim - 0.25, POOL.z - 2),
		0.35,
		mat(Color(0.9, 0.2, 0.1, 1), 0.35)
	)
	volume(
		"pool",
		Vec3(POOL.x, rim - 0.2, POOL.z),
		preset(
			"pool",
			{
				Size = Vec3(w, depth + 0.1, l),
				WaveHeight = 0.03,
				WaveLength = 0.6,
				Roughness = 0.008,
				Foam = 0,
				Caustics = 1,
			}
		)
	)
end

do
	local x, z = POOL.x + 28, POOL.z
	local base_y = LAND_HEIGHT + 0.9
	local size = Vec3(6, 2.6, 2.4)
	local frame = mat(Color(0.08, 0.08, 0.09, 1), 0.4)
	box(
		"tank_stand",
		Vec3(x, LAND_HEIGHT + 0.45, z),
		Vec3(size.x + 0.3, 0.9, size.z + 0.3),
		mat(Color(0.25, 0.2, 0.16, 1), 0.7)
	)
	box(
		"tank_sand",
		Vec3(x, base_y + 0.15, z),
		Vec3(size.x, 0.3, size.z),
		mat(Color(0.8, 0.72, 0.55, 1), 0.9)
	)

	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			box(
				"tank_post",
				Vec3(x + sx * size.x / 2, base_y + size.y / 2, z + sz * size.z / 2),
				Vec3(0.08, size.y, 0.08),
				frame
			)
		end
	end

	box(
		"tank_lid",
		Vec3(x, base_y + size.y + 0.05, z),
		Vec3(size.x + 0.1, 0.1, size.z + 0.1),
		frame
	)
	local coral = {
		Color(0.9, 0.35, 0.3, 1),
		Color(0.95, 0.75, 0.2, 1),
		Color(0.6, 0.3, 0.8, 1),
		Color(0.2, 0.75, 0.6, 1),
	}

	for i = 1, 9 do
		sphere(
			"tank_coral" .. i,
			Vec3(x - 2.5 + i * 0.55, base_y + 0.35 + (i % 3) * 0.15, z - 0.6 + (i * 0.37 % 1.2)),
			0.2 + (i % 3) * 0.1,
			mat(coral[i % 4 + 1], 0.6),
			Vec3(1, 1.6, 1)
		)
	end

	for i = 1, 5 do
		sphere(
			"tank_fish" .. i,
			Vec3(x - 2 + i * 0.8, base_y + 1.1 + (i % 2) * 0.6, z + (i % 3 - 1) * 0.5),
			0.12,
			mat(coral[(i + 1) % 4 + 1], 0.3),
			Vec3(2.2, 1, 0.7)
		)
	end

	volume(
		"aquarium",
		Vec3(x, base_y + size.y, z),
		preset(
			"tropical",
			{
				Size = Vec3(size.x, size.y - 0.3, size.z),
				WaveHeight = 0.003,
				WaveLength = 0.3,
				Roughness = 0.01,
				Foam = 0,
			}
		)
	)
end

do
	local iron = mat(Color(0.08, 0.08, 0.09, 1), 0.5, 1)
	local lantern_pos = Vec3(LAKE.x + 18, LAKE.surface + 3.2, LAKE.z - 2)
	box(
		"lantern_post",
		Vec3(LAKE.x + 19.6, LAKE.surface + 1.8, LAKE.z - 2),
		Vec3(0.12, 3.6, 0.12),
		iron
	)
	box(
		"lantern_arm",
		Vec3(LAKE.x + 18.8, LAKE.surface + 3.6, LAKE.z - 2),
		Vec3(1.8, 0.08, 0.08),
		iron
	)
	lamp("lake_lantern", lantern_pos, Color(1, 0.72, 0.4, 1), 12000, 40)
	lamp(
		"lake_underwater",
		Vec3(LAKE.x - 6, LAKE.surface - 4.5, LAKE.z - 2),
		Color(0.3, 0.8, 1, 1),
		15000,
		30
	)
	box(
		"pond_post",
		Vec3(POND.x - 4, POND.surface + 1.5, POND.z),
		Vec3(0.12, 3, 0.12),
		iron
	)
	box(
		"pond_canopy",
		Vec3(POND.x - 1.5, POND.surface + 2.6, POND.z),
		Vec3(4.5, 0.12, 4.5),
		iron
	)
	lamp(
		"pond_lamp",
		Vec3(POND.x - 1.5, POND.surface + 2.3, POND.z),
		Color(1, 0.85, 0.55, 1),
		6000,
		30
	)
	lamp(
		"pool_light_1",
		Vec3(POOL.x - 9.6, LAND_HEIGHT - 1.4, POOL.z - 2.5),
		Color(0.6, 0.9, 1, 1),
		6000,
		25
	)
	lamp(
		"pool_light_2",
		Vec3(POOL.x + 9.6, LAND_HEIGHT - 1.4, POOL.z + 2.5),
		Color(1, 0.5, 0.9, 1),
		6000,
		25
	)
	lamp(
		"swamp_wisp",
		Vec3(SWAMP.x, SWAMP.surface + 0.6, SWAMP.z + 2),
		Color(0.5, 1, 0.4, 1),
		3000,
		20
	)
end

showcase.views = {
	{name = "beach", pos = Vec3(-45, 6, -28), target = Vec3(0, 0, -22)},
	{name = "ocean", pos = Vec3(40, 2.5, -45), target = Vec3(80, 0, -200)},
	{name = "underwater", pos = Vec3(10, -4, -75), target = Vec3(20, -2, -40)},
	{
		name = "lake",
		pos = Vec3(LAKE.x + 34, 7, LAKE.z - 28),
		target = Vec3(LAKE.x, LAKE.surface - 2, LAKE.z),
	},
	{
		name = "pond",
		pos = Vec3(POND.x + 14, 6, POND.z - 12),
		target = Vec3(POND.x, POND.surface - 1, POND.z),
	},
	{
		name = "swamp",
		pos = Vec3(SWAMP.x - 22, 5.5, SWAMP.z - 22),
		target = Vec3(SWAMP.x, SWAMP.surface, SWAMP.z),
	},
	{
		name = "river",
		pos = Vec3(-30, 6, RIVER.z - 18),
		target = Vec3(0, RIVER.surface, RIVER.z),
	},
	{
		name = "pool",
		pos = Vec3(POOL.x - 14, 7, POOL.z - 11),
		target = Vec3(POOL.x, POOL.depth, POOL.z),
	},
	{
		name = "in_lake",
		pos = Vec3(LAKE.x + 8, LAKE.surface - 2.5, LAKE.z - 12),
		target = Vec3(LAKE.x + 18, LAKE.surface - 1.5, LAKE.z - 4),
	},
	{
		name = "in_lake_lamp",
		pos = Vec3(LAKE.x - 18, LAKE.surface - 3.5, LAKE.z - 2),
		target = Vec3(LAKE.x - 6, LAKE.surface - 4.5, LAKE.z - 2),
	},
	{
		name = "in_pool",
		pos = Vec3(POOL.x - 8, LAND_HEIGHT - 1.5, POOL.z - 3),
		target = Vec3(POOL.x + 4, LAND_HEIGHT - 1.2, POOL.z + 2),
	},
	{
		name = "aquarium",
		pos = Vec3(POOL.x + 28, 5.8, POOL.z - 6),
		target = Vec3(POOL.x + 28, 5, POOL.z),
	},
}

function showcase.GetView(index)
	local view = showcase.views[index]
	local dir = (view.target - view.pos):GetNormalized()
	return {
		Position = view.pos,
		Rotation = QuatDeg3(math.deg(math.asin(dir.y)), math.deg(math.atan2(-dir.x, -dir.z)), 0),
		FOV = math.rad(65),
	}
end

commands.Add("water_night", function()
	weather.SetSunDirection(Vec3(0.35, -0.6, -0.84):GetNormalized())
end)

commands.Add("water_view=number[0]", function(index)
	if showcase.view then
		showcase.view:Remove()
		showcase.view = nil
	end

	if index == 0 then
		for i, view in ipairs(showcase.views) do
			logn(i, ": ", view.name)
		end

		return
	end

	showcase.view = View.New(table.merge({Priority = 100}, showcase.GetView(index))):Activate()
end)

return showcase
