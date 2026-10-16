-- a landscape grown over with all of the procedural foliage (addons/foliage): a meadow valley, forest on the hills to
-- the east, a rocky ridge to the west, and a lake to the north with a beach of palms on its east shore and reeds and
-- willows on its west one. in the middle stands a mesa with every preset on it in rows (lua/foliage/gallery.lua),
-- labelled with its path when you are near, cliffs on three sides and a long slope down the south one. you spawn on it
-- luajit glw --3d lua "import('addons/examples/lua/examples/render3d/foliage_world.lua')"
-- `foliage_world_view N` goes to a view (0 lists them and gives the camera back), `foliage_world_labels` toggles the labels
local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local noise = import("goluwa/terrain/noise.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local commands = import("goluwa/cli/commands.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local sets = import("lua/foliage/scatter_sets.lua")
local gallery = import("lua/foliage/gallery.lua")
local world = {}
-- the layout, in meters. the same numbers are in the glsl below
local MESA = Vec3(0, 62, 0)
local MESA_HALF_X, MESA_HALF_Z = 70, 38
local LAKE_X, LAKE_Z, LAKE_RADIUS = 0, -330, 150
local FOREST_X, FOREST_Z = 330, -80
local RIDGE_X, RIDGE_Z = -340, -60
-- nothing is scattered above this, so the mesa's top is bare for the gallery
local SCATTER_CEILING = 54
local HEIGHT_GLSL = ([=[
const vec2 MESA = vec2(%f, %f);
const vec2 MESA_HALF = vec2(%f, %f);
const float MESA_TOP = %f;
const vec2 LAKE = vec2(%f, %f);
const float LAKE_RADIUS = %f;
const vec2 FOREST = vec2(%f, %f);
const vec2 RIDGE = vec2(%f, %f);

// how much of the ridge is here, a crest along z
float ridge_amount(vec2 p) {
	vec2 r = (p - RIDGE) / vec2(55.0, 260.0);
	return exp(-dot(r, r));
}

// rolling ground, the forest's hills, the ridge and the lake's basin
float world_base(vec2 p) {
	float h = 13.0 + 5.0 * sin(p.x * 0.011) * cos(p.y * 0.013) + 3.0 * sin(p.x * 0.023 + p.y * 0.017 + 1.3);
	vec2 f = (p - FOREST) / 230.0;
	h += 24.0 * exp(-dot(f, f));
	h += 34.0 * ridge_amount(p) * (0.75 + 0.25 * sin(p.y * 0.021));
	return mix(h, -7.0, smoothstep(1.35, 0.55, length(p - LAKE) / LAKE_RADIUS));
}

// how much of the mesa's height a point has: 1 on its flat top, ragged cliffs on three sides and a long slope down the
// south one. the cliffs' noise is what world.GetHeight in lua leaves out
float mesa_amount(vec2 p, float bake_step) {
	vec2 q = abs(p - MESA) - MESA_HALF;
	float outside = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
	float south = smoothstep(MESA.y + MESA_HALF.y - 10.0, MESA.y + MESA_HALF.y + 10.0, p.y);
	float ragged = pn_fbm_lod(p / 30.0, 3, 30.0, bake_step) * 7.0 + pn_fbm_lod(p / 90.0 + 4.0, 2, 90.0, bake_step) * 12.0;
	return 1.0 - smoothstep(0.0, mix(22.0, 200.0, south), outside + ragged * (1.0 - south));
}

float terrain_height(vec2 world) {
	float bake_step = terrain_bake_step();
	float mesa = mesa_amount(world, bake_step);
	float detail = pn_fbm_lod(world / 40.0, 3, 40.0, bake_step);
	return mix(world_base(world), MESA_TOP, mesa) + detail * 0.8 * (1.0 - mesa);
}
]=]):format(MESA.x, MESA.z, MESA_HALF_X, MESA_HALF_Z, MESA.y, LAKE_X, LAKE_Z, LAKE_RADIUS, FOREST_X, FOREST_Z, RIDGE_X, RIDGE_Z)
-- the four layers are the four biomes: x the meadow (grass), y the forest floor (dirt), z rock, w the beach (sand)
local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 world, float h, vec3 n) {
	vec2 p = world;
	float slope = 1.0 - n.y;
	float fine = pn_fbm(p * 0.03 + vec2(9.0, -4.0), 3) * 0.5;
	float breakup = pn_fbm(p * 0.006 + vec2(3.0, 5.0), 3) * 0.5;
	float rock = smoothstep(0.22, 0.4, slope + fine * 0.1);
	float ridge = pow(ridge_amount(p), 0.4);
	rock = max(rock, smoothstep(20.0, 28.0, h + breakup * 10.0) * ridge);
	float lake = length(p - LAKE) / LAKE_RADIUS;
	// the beach is on the east shore, the west one is grass for the reeds
	float sand = (1.0 - smoothstep(2.0, 4.5, h + fine * 2.0)) * step(lake, 1.7) * smoothstep(-0.25, 0.25, (p.x - LAKE.x) / LAKE_RADIUS + breakup);
	float forest = smoothstep(1.05, 0.8, length((p - FOREST) / 270.0) + breakup * 0.6);
	// and a few groves out in the meadow, not on the ridge
	forest = max(forest, smoothstep(0.62, 0.7, pn_fbm(p * 0.005 + vec2(11.0, 2.0), 3) * 0.5 + 0.5 + fine * 0.1) * (1.0 - ridge));
	vec4 w;
	w.w = sand * (1.0 - rock);
	w.z = rock;
	w.y = forest * (1.0 - rock) * (1.0 - w.w);
	w.x = max(1.0 - w.w - w.z - w.y, 0.0);
	return w / max(dot(w, vec4(1.0)), 0.0001);
}
]=]
-- the forest floor is the dirt layer darkened, the same mask as in the splat
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 world, float h, vec3 n) {
	float patches = pn_fbm(world * 0.008 + vec2(1.0, 7.0), 3);
	float shade = 0.92 + pn_fbm(world * 0.003 + vec2(8.0, 3.0), 2) * 0.1;
	vec3 tint = mix(vec3(1.0), vec3(1.0, 0.92, 0.7), smoothstep(0.05, 0.45, patches) * 0.35);
	float breakup = pn_fbm(world * 0.006 + vec2(3.0, 5.0), 3) * 0.5;
	float forest = smoothstep(1.05, 0.8, length((world - FOREST) / 270.0) + breakup * 0.6);
	tint *= mix(vec3(1.0), vec3(0.55, 0.5, 0.42), forest);
	float wet = 1.0 - smoothstep(0.0, 1.5, h);
	return clamp(tint * shade * (1.0 - wet * 0.35), 0.0, 1.0);
}
]=]

-- the height without the small noise of the glsl (at most 0.8 m off), and exactly the mesa's on its top
function world.GetHeight(x, z)
	local h = 13 + 5 * math.sin(x * 0.011) * math.cos(z * 0.013) + 3 * math.sin(x * 0.023 + z * 0.017 + 1.3)
	local fx, fz = (x - FOREST_X) / 230, (z - FOREST_Z) / 230
	h = h + 24 * math.exp(-(fx * fx + fz * fz))
	local rx, rz = (x - RIDGE_X) / 55, (z - RIDGE_Z) / 260
	h = h + 34 * math.exp(-(rx * rx + rz * rz)) * (0.75 + 0.25 * math.sin(z * 0.021))
	local lake = math.sqrt((x - LAKE_X) ^ 2 + (z - LAKE_Z) ^ 2) / LAKE_RADIUS
	h = math.lerp(math.smoothstep(1.35, 0.55, lake), h, -7)
	local qx, qz = math.abs(x - MESA.x) - MESA_HALF_X, math.abs(z - MESA.z) - MESA_HALF_Z
	local outside = math.sqrt(math.max(qx, 0) ^ 2 + math.max(qz, 0) ^ 2) + math.min(math.max(qx, qz), 0)
	local south = math.smoothstep(MESA.z + MESA_HALF_Z - 10, MESA.z + MESA_HALF_Z + 10, z)

	-- the ragged cliffs are not in here, only the slope
	if south < 1 and outside > 0 then return h end

	return math.lerp(1 - math.smoothstep(0, math.lerp(south, 22, 200), outside), h, MESA.y)
end

-- one set of all five foliage sets, each growing on its own layer, the wetland's near the water
local function build_scatter_set()
	local prototypes = {}

	local function add(set, layers, altitude)
		for _, definition in ipairs(set.Prototypes) do
			local copy = {}

			for key, value in pairs(definition) do
				copy[key] = value
			end

			copy.layers = layers
			copy.altitude = altitude(definition)
			prototypes[#prototypes + 1] = copy
		end
	end

	local function below_ceiling()
		return {-1e9, SCATTER_CEILING, 4}
	end

	add(sets.foliage_meadow, {1, 0, 0, 0}, below_ceiling)
	add(sets.foliage_forest, {0, 1, 0, 0}, below_ceiling)
	add(sets.foliage_rocky, {0, 0.2, 1, 0}, below_ceiling)
	add(sets.foliage_tropical, {0, 0, 0, 1}, function()
		return {0.4, SCATTER_CEILING, 0.5}
	end)
	-- reeds stand in the shallows, the rest of the wetland just above the water
	add(sets.foliage_wetland, {1, 0.3, 0, 0.3}, function(definition)
		if definition.model:find("reeds") then return {-0.6, 2, 0.6} end

		return {0, 4.5, 1}
	end)
	return ScatterSet.New{Name = "foliage_world", Prototypes = prototypes, DistanceMultiplier = 2.5}
end

local function layer(name, scale)
	local textures = terrain_textures[name]
	return {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale, scatter = 1}
end

if _G.foliage_world then _G.foliage_world.Remove() end

world.scatter_set = build_scatter_set()
world.terrain = Terrain.New{
	Name = "foliage_world",
	ScatterSet = world.scatter_set,
	Source = ShaderSource.New{
		Header = noise.WORLD,
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = -20,
		MaxHeight = 90,
		Layers = {layer("grass", 3), layer("dirt", 3), layer("rock", 11), layer("sand", 4)},
	},
	Levels = 6,
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ColorSize = 64,
	BuildsPerFrame = 2,
	Physics = {
		chunk_size = 64,
		samples = 65,
		radius = 2,
	},
}:Start()
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(0)
world.root = Entity.New{Name = "foliage_world", Parent = Entity.World}
world.root:AddComponent("transform")
local _, placements = gallery.Spawn(world.root, Vec3(MESA.x, MESA.y, MESA.z + 20))
world.placements = placements
local spawn = Entity.New{Name = "foliage_world_spawn", Parent = world.root}
spawn:AddComponent("transform"):SetPosition(Vec3(MESA.x, MESA.y, MESA.z + 30))
spawn:AddComponent("spawn_point", {Group = "start"})

-- a rotation looking from one point at another
local function look(from, to)
	local dir = (to - from):GetNormalized()
	local rotation = Quat()
	rotation:Identity()
	rotation:RotateYaw(math.atan2(-dir.x, -dir.z))
	rotation:RotatePitch(math.asin(dir.y))
	return rotation
end

local function on_ground(x, z, above)
	return Vec3(x, world.GetHeight(x, z) + above, z)
end

world.views = {
	{name = "the gallery on the mesa", from = Vec3(MESA.x, MESA.y + 5, MESA.z + 30), to = Vec3(MESA.x, MESA.y, MESA.z - 2)},
	{name = "the trees of the gallery", from = Vec3(MESA.x - 30, MESA.y + 7, MESA.z + 12), to = Vec3(MESA.x - 10, MESA.y + 4, MESA.z - 15)},
	{name = "over the land", from = Vec3(-60, 170, 330), to = Vec3(0, 20, -150), fov = 75},
	{name = "in the meadow", from = on_ground(-200, 250, 1.7), to = on_ground(-100, 150, 3)},
	{name = "up the slope of the mesa", from = on_ground(0, 230, 1.7), to = on_ground(0, 60, 1.7)},
	{name = "in the forest", from = on_ground(300, -40, 1.7), to = on_ground(360, -120, 3)},
	{name = "on the ridge", from = on_ground(-290, 110, 2), to = on_ground(-340, -60, 8)},
	{name = "on the beach", from = on_ground(LAKE_X + 165, LAKE_Z + 40, 1.7), to = Vec3(LAKE_X, 1, LAKE_Z)},
	{name = "by the reeds", from = on_ground(LAKE_X - 160, LAKE_Z + 30, 1.7), to = Vec3(LAKE_X, 1, LAKE_Z)},
	{name = "from the lake", from = Vec3(LAKE_X, 6, LAKE_Z + 40), to = on_ground(MESA.x, MESA.z, -20)},
}

function world.SetView(index)
	if world.view then
		world.view:Remove()
		world.view = nil
	end

	local view = world.views[index]

	if not view then return end

	world.view = View.New{
		Priority = 100,
		Position = view.from,
		Rotation = look(view.from, view.to),
		FOV = math.rad(view.fov or 70),
	}:Activate()
end

commands.Add("foliage_world_view=number[0]", function(index)
	if index == 0 then
		for i, view in ipairs(world.views) do
			logn(i, ": ", view.name)
		end
	end

	world.SetView(index)
end)

-- the path of each preset over it when the camera is near
world.labels = true
local LABEL_DISTANCE = 10

event.AddListener("Update", "foliage_world_labels", function()
	if not world.labels then return end

	local camera = render3d.GetCamera():GetPosition()

	for i, placement in ipairs(world.placements) do
		if (placement.position - camera):GetLength() < LABEL_DISTANCE then
			debug_draw.DrawText{
				id = "foliage_world_label_" .. i,
				position = placement.position + Vec3(0, 1.2, 0),
				text = placement.path:match("models/foliage/(.+)%.lua$"),
				time = 0.1,
				background_alpha = 0.45,
			}
		end
	end
end)

commands.Add("foliage_world_labels", function()
	world.labels = not world.labels
end)

function world.Remove()
	event.RemoveListener("Update", "foliage_world_labels")
	world.SetView(nil)
	world.root:Remove()
	world.terrain:Stop()
	world.scatter_set:Remove()
	render3d.SetOceanEnabled(false)
	_G.foliage_world = nil
end

_G.foliage_world = world
return world
