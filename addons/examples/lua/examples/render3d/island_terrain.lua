local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local presets = import("lua/autorun/render_3d/scatter_presets.lua")
local commands = import("goluwa/cli/commands.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local event = import("goluwa/event.lua")
local trace = import("goluwa/physics/trace.lua")
local SEED = 77
local island = {}
local scatter_set = presets[_G.SCATTER_SET or "crysis_jungle"] or ScatterSet.GetGrass()
scatter_set:SetDensityMultiplier(_G.SCATTER_DENSITY or 2)
scatter_set:SetDistanceMultiplier(_G.SCATTER_DISTANCE or 10)
local HEIGHT_GLSL = [=[
const vec2 MOUNTAIN_PEAK = vec2(-180.0, 140.0);

float island_shore_profile(float s) {
	float sea = -34.0 * (1.0 - exp(min(s, 0.0) / 420.0));
	float beach = 5.0 * (1.0 - exp(-max(s, 0.0) / 62.0));
	return sea + beach;
}

vec2 island_warp(vec2 p, float scale, float amount, float bake_step) {
	vec2 q = p / scale + SEED_OFFSET;
	return vec2(pn_fbm_lod(q + vec2(2.0, 5.0), 4, scale, bake_step), pn_fbm_lod(q + vec2(-7.0, 1.0), 4, scale, bake_step)) * amount;
}

float island_main_shore(vec2 p, float bake_step) {
	vec2 q = p + island_warp(p, 900.0, 520.0, bake_step) + island_warp(p + 40.0, 260.0, 90.0, bake_step);
	float radius = 1900.0 + 300.0 * pn_fbm_lod(p / 2500.0 + SEED_OFFSET + vec2(4.0, 4.0), 2, 2500.0, bake_step);
	return radius - length(q * vec2(0.85, 1.0));
}

vec2 island_satellite(vec2 p, float bake_step) {
	const float CELL = 650.0;
	vec2 cell = floor(p / CELL);
	vec2 best = vec2(-1e5, 0.0);

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 c = cell + vec2(float(x), float(y));
			vec2 h1 = pn_hash(c + 17.3);
			vec2 h2 = pn_hash(c + 91.7);
			vec2 center = (c + 0.5 + h1 * 0.28) * CELL;
			float present = step(-0.1, h2.x) * step(2700.0, length(center));
			float radius = 70.0 + 150.0 * pow(h2.y * 0.5 + 0.5, 2.0);
			vec2 q = p + island_warp(p + c * 13.0, 150.0, radius * 0.4, bake_step);
			float s = (radius - length(q - center)) * present - (1.0 - present) * 1e5;

			if (s > best.x) best = vec2(s, 10.0 + 40.0 * (h1.y * 0.5 + 0.5));
		}
	}

	return best;
}

float terrain_height(vec2 world) {
	float bake_step = terrain_bake_step();
	vec2 p = world;
	float s = island_main_shore(p, bake_step);
	float land = smoothstep(0.0, 40.0, s);
	float inland = smoothstep(40.0, 500.0, s);
	float hills = pn_fbm_lod(p / 700.0 + SEED_OFFSET + vec2(5.0, 1.5), 5, 700.0, bake_step);
	float detail = pn_fbm_lod(p / 45.0 + SEED_OFFSET, 3, 45.0, bake_step);
	float h = island_shore_profile(s) + inland * (20.0 + 22.0 * hills) + land * detail * 1.6;
	vec2 mq = p - MOUNTAIN_PEAK + island_warp(p, 500.0, 160.0, bake_step);
	float cone = pow(1.0 - smoothstep(0.0, 1300.0, length(mq)), 1.5);
	float ridges = pn_ridged_lod(p / 420.0 + SEED_OFFSET + vec2(8.0, 3.0), 6, 1.0, 2.0, 420.0, bake_step);
	h += cone * (230.0 + 560.0 * ridges) * inland;
	vec2 sat = island_satellite(p, bake_step);
	float bump = pn_fbm_lod(p / 90.0 + SEED_OFFSET + vec2(1.0, 7.0), 3, 90.0, bake_step);
	float h_sat = island_shore_profile(sat.x) + sat.y * smoothstep(20.0, 110.0, sat.x) * (0.75 + 0.5 * bump);
	float sea_floor = pn_fbm_lod(p / 300.0 + SEED_OFFSET, 3, 300.0, bake_step) * 3.0;
	return max(h + sea_floor * (1.0 - land), h_sat);
}
]=]
local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 world, float h, vec3 n) {
	vec2 p = world + SEED_OFFSET;
	float slope = 1.0 - n.y;
	float breakup = pn_fbm(p * 0.004 + vec2(3.0, 5.0), 3) * 0.5;
	float fine = pn_fbm(p * 0.03 + vec2(9.0, -4.0), 3) * 0.5;
	float sand = 1.0 - smoothstep(3.0, 7.5, h + breakup * 4.0 + fine * 0.8);
	float rock = max(smoothstep(0.16, 0.34, slope + fine * 0.14), smoothstep(330.0, 480.0, h + breakup * 60.0) * 0.85);
	float trail = smoothstep(0.3, 0.55, pn_fbm(p * 0.01 + vec2(6.0, 2.0), 3) * 0.5) * 0.35;
	float dirt = clamp(smoothstep(0.06, 0.2, slope + fine * 0.1) + smoothstep(220.0, 330.0, h + breakup * 50.0) * 0.5 + trail, 0.0, 1.0);
	vec4 w;
	w.w = sand * (1.0 - rock);
	w.z = rock;
	w.y = dirt * (1.0 - rock) * (1.0 - w.w);
	w.x = max(1.0 - w.w - w.z - w.y, 0.0);
	return w / max(dot(w, vec4(1.0)), 0.0001);
}
]=]
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 world, float h, vec3 n) {
	vec2 p = world + SEED_OFFSET;
	float patches = pn_fbm(p * 0.008 + vec2(1.0, 7.0), 3);
	float dry = smoothstep(0.05, 0.45, patches);
	float shade = 0.9 + pn_fbm(p * 0.003 + vec2(8.0, 3.0), 2) * 0.12;
	vec3 tint = mix(vec3(1.0), vec3(1.0, 0.9, 0.64), dry * 0.4);
	float wet = 1.0 - smoothstep(0.0, 1.6, h);
	return clamp(tint * shade * (1.0 - wet * 0.35), 0.0, 1.0);
}
]=]

local function build_header()
	return noise.WORLD .. string.format(
			"const vec2 SEED_OFFSET = vec2(%f, %f);\n",
			math.sin(SEED * 12.9898) * 16384.0,
			math.cos(SEED * 78.2330) * 16384.0
		)
end

local function layer(name, scale, extra)
	local textures = terrain_textures[name]
	local out = {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale}

	for k, v in pairs(extra or {}) do
		out[k] = v
	end

	return out
end

if _G.island_terrain then _G.island_terrain:Stop() end

_G.island_terrain = Terrain.New{
	Name = "island_terrain",
	ScatterSet = scatter_set,
	Source = ShaderSource.New{
		Header = build_header(),
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = -120,
		MaxHeight = 900,
		Layers = {
			layer("grass", 3, {scatter = 1}),
			layer("dirt", 3, {scatter = 1}),
			layer("rock", 11, {scatter = 1}),
			layer("sand", 4, {scatter = 1}),
		},
	},
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ColorSize = 64,
	ShadowLevels = 6,
	ShadowExtent = 12288,
	BuildsPerFrame = 2,
	Physics = {
		chunk_size = 64,
		samples = 65,
		radius = 2,
	},
}:Start()
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(0)
island.views = {
	{
		name = "map",
		position = Vec3(0, 3200, 0),
		angles = QuatDeg3(-90, 0, 0),
		fov = 60,
	},
	{
		name = "from the sea",
		position = Vec3(-5200, 90, -1500),
		angles = QuatDeg3(-4, -75, 0),
		fov = 65,
	},
	{
		name = "from a small island",
		position = Vec3(3000, 25, 700),
		angles = QuatDeg3(-2, 100, 0),
		fov = 70,
	},
	{
		name = "above the coast",
		position = Vec3(2300, 220, 0),
		angles = QuatDeg3(-9, 95, 0),
		fov = 70,
	},
	{
		name = "over the jungle",
		position = Vec3(1500, 120, -200),
		angles = QuatDeg3(-6, 100, 0),
		fov = 75,
	},
	{
		name = "in the jungle",
		position = Vec3(1200, 0, 0),
		ground = 1.7,
		angles = QuatDeg3(-2, 90, 0),
		fov = 75,
	},
	{
		name = "on the beach",
		position = Vec3(2050, 0, 0),
		ground = 1.7,
		angles = QuatDeg3(-1, 90, 0),
		fov = 75,
	},
}

function island.GetView(index)
	local view = island.views[index]
	return {
		Position = view.position,
		Rotation = view.angles,
		FOV = math.rad(view.fov),
		Ground = view.ground,
	}
end

commands.Add("island_view=number[0]", function(index)
	if island.view then
		island.view:Remove()
		island.view = nil
	end

	if index == 0 then
		for i, view in ipairs(island.views) do
			logn(i, ": ", view.name)
		end

		return
	end

	island.view = View.New(table.merge({Priority = 100}, island.GetView(index))):Activate()
end)

do
	local PEAK = Vec3(-180, 0, 140)
	local LOOKAHEAD = 1.2
	local DOWN = Vec3(0, -1, 0)
	local origin = Vec3()
	local fly = {}

	local function update(dt)
		local angle = fly.angle + fly.speed / fly.radius * dt
		fly.angle = angle
		local ahead = angle + fly.speed / fly.radius * LOOKAHEAD
		origin.x = PEAK.x + math.cos(ahead) * fly.radius
		origin.y = 1500
		origin.z = PEAK.z + math.sin(ahead) * fly.radius
		local hit = trace.RayCast(origin, DOWN, 2000)

		if hit then fly.ground = math.max(hit.position.y, 0) end

		fly.y = math.lerp(1 - 0.5 ^ (dt * 2), fly.y, fly.ground + fly.height)
		fly.view:SetPosition(
			Vec3(
				PEAK.x + math.cos(angle) * fly.radius,
				fly.y,
				PEAK.z + math.sin(angle) * fly.radius
			)
		)
		fly.view:SetRotation(QuatDeg3(-8, -math.deg(angle) - 25, 0))
	end

	function island.StopFly()
		if not fly.view then return end

		event.RemoveListener("Update", "island_fly")
		fly.view:Remove()
		fly.view = nil
	end

	function island.Fly(kmh, radius, height)
		island.StopFly()

		if kmh == 0 then return end

		fly.speed = kmh / 3.6
		fly.radius = radius
		fly.height = height
		fly.angle = 0
		fly.ground = 60
		fly.y = fly.ground + height
		fly.view = View.New{
			Priority = 100,
			Position = Vec3(PEAK.x + radius, fly.y, PEAK.z),
			Rotation = QuatDeg3(-8, 0, 0),
			FOV = math.rad(75),
		}:Activate()
		event.AddListener("Update", "island_fly", update)
	end

	commands.Add("island_fly=number[300],number|nil,number|nil", function(kmh, radius, height)
		island.Fly(kmh, radius or 1100, height or 60)
	end)
end

return island
