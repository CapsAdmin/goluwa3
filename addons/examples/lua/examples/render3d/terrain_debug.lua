-- a bare rolling terrain with nothing on it, colored to show how it is chunked: every lod level has its own hue, every
-- chunk has a white border, a checker of 8x8 cells and a slight brightness of its own, so a missing, doubled, late or
-- wrongly sized chunk is easy to see
-- luajit glw --3d lua "import('addons/examples/lua/examples/render3d/terrain_debug.lua')"
-- `terrain_debug_view N` goes to one of the views below (0 lists them), `terrain_tiles` prints the tile state
local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local commands = import("goluwa/cli/commands.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BASE_CHUNK_SIZE = 64
local debug_terrain = {}
local HEIGHT_GLSL = [=[
float terrain_height(vec2 p) {
	return 18.0 * sin(p.x / 310.0) * cos(p.y / 260.0) +
		7.0 * sin(p.x / 97.0 + p.y / 131.0) +
		55.0 * sin(p.x / 1700.0 + 1.0) * sin(p.y / 1400.0) +
		2.0 * sin(p.x / 23.0) * sin(p.y / 29.0);
}
]=]
local COLOR_GLSL = string.format(
	[=[
vec3 terrain_color(vec2 world, float h, vec3 n) {
	int level = terrain_bake.layer0;
	float size = %f * exp2(float(level));
	vec2 chunk = floor(world / size);
	vec2 local = world / size - chunk;
	vec3 hue = 0.5 + 0.5 * cos(6.2832 * (float(level) / 8.0 + vec3(0.0, 0.33, 0.67)));
	vec2 cell = floor(local * 8.0);
	float checker = mod(cell.x + cell.y, 2.0) * 0.18 + 0.82;
	float own = 0.85 + 0.15 * fract(sin(dot(chunk, vec2(12.9898, 78.233))) * 43758.5453);
	float edge = terrain_bake.step_x / size * 1.01;
	bool border = local.x < edge || local.y < edge || local.x > 1.0 - edge || local.y > 1.0 - edge;
	vec3 color = hue * checker * own;
	return border ? vec3(1.0) : color;
}
]=],
	BASE_CHUNK_SIZE
)

if _G.terrain_debug then _G.terrain_debug:Stop() end

_G.terrain_debug = Terrain.New{
	Name = "terrain_debug",
	Source = ShaderSource.New{
		HeightGLSL = HEIGHT_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = -120,
		MaxHeight = 120,
		SelectChunkLayers = function(request)
			return {}, {math.round(math.log(request.size / BASE_CHUNK_SIZE, 2))}
		end,
	},
	BVHLevels = _G.TERRAIN_BVH_LEVELS,
	BVHDelay = _G.TERRAIN_BVH_DELAY,
	BaseChunkSize = BASE_CHUNK_SIZE,
	Samples = 65,
	DetailSize = 256,
	ColorSize = 128,
	BuildsPerFrame = 4,
}:Start()
debug_terrain.views = {
	{name = "ground", position = Vec3(0, 40, 0), angles = QuatDeg3(-8, 0, 0), fov = 75},
	{name = "low horizon", position = Vec3(0, 12, 0), angles = QuatDeg3(0, 45, 0), fov = 90},
	{name = "high", position = Vec3(0, 350, 0), angles = QuatDeg3(-30, 20, 0), fov = 75},
}

function debug_terrain.GetView(index)
	local view = debug_terrain.views[index]

	return {Position = view.position, Rotation = view.angles, FOV = math.rad(view.fov)}
end

commands.Add("terrain_debug_view=number[0]", function(index)
	if debug_terrain.view then
		debug_terrain.view:Remove()
		debug_terrain.view = nil
	end

	if index == 0 then
		for i, view in ipairs(debug_terrain.views) do
			logn(i, ": ", view.name)
		end

		return
	end

	debug_terrain.view = View.New(table.merge({Priority = 100}, debug_terrain.GetView(index))):Activate()
end)

return debug_terrain
