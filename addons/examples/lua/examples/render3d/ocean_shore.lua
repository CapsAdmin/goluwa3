local Terrain = import("goluwa/terrain/terrain.lua")
local ShaderSource = import("goluwa/terrain/shader_source.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local water = import("goluwa/render3d/water.lua")
local weather = import("goluwa/render3d/weather.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local terrain_textures = import("lua/autorun/render_3d/terrain_textures.lua")
local SHORE_X = 140
local WIND_STEP = 1
local MAX_WIND = 30
local HEIGHT_GLSL = [=[
float terrain_height(vec2 p) {
	float s = p.x - ]=] .. SHORE_X .. [=[.0 + 18.0 * sin(p.y / 83.0) + 7.0 * sin(p.y / 29.0 + 1.0);
	float sea = -40.0 * (1.0 - exp(min(s, 0.0) / 240.0));
	float beach = 7.0 * (1.0 - exp(-max(s, 0.0) / 45.0));
	float dunes = smoothstep(20.0, 80.0, s) * (1.2 * sin(p.x / 21.0 + p.y / 37.0) + 0.8 * sin(p.y / 13.0));
	return sea + beach + dunes;
}
]=]
local SPLAT_GLSL = [=[
vec4 terrain_splat(vec2 p, float h, vec3 n) {
	float inland = smoothstep(4.0, 6.5, h);
	return vec4(1.0 - inland, inland, 0.0, 0.0);
}
]=]
local COLOR_GLSL = [=[
vec3 terrain_color(vec2 p, float h, vec3 n) {
	return vec3(0.5, 0.45, 0.37);
}
]=]

local function layer(name, scale)
	local textures = terrain_textures[name]
	return {name = name, albedo = textures.albedo, normal = textures.normal, scale = scale}
end

if _G.ocean_shore then _G.ocean_shore.terrain:Stop() end

local shore = {}
_G.ocean_shore = shore
shore.terrain = Terrain.New{
	Name = "ocean_shore_terrain",
	Source = ShaderSource.New{
		HeightGLSL = HEIGHT_GLSL,
		SplatGLSL = SPLAT_GLSL,
		ColorGLSL = COLOR_GLSL,
		MinHeight = -45,
		MaxHeight = 20,
		Layers = {layer("sand", 4), layer("grass", 3), layer("dirt", 3), layer("rock", 11)},
	},
	Levels = 7,
	BaseChunkSize = 64,
	Samples = 65,
	DetailSize = 256,
	SplatSize = 128,
	ColorSize = 64,
	ShadowLevels = 5,
	BuildsPerFrame = 3,
}:Start()
weather.SetTimeScale(0)
weather.SetSunDirection(Vec3(-0.5, 0.55, 0.35):GetNormalized())
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(0)
water.SetOcean{WindSpeed = 12, WindDirection = 0, SwellHeight = 0.3, SwellWavelength = 100, SwellDirection = 0}

function shore.SetWind(speed)
	speed = math.clamp(speed, 0, MAX_WIND)
	water.SetOcean{WindSpeed = speed}
	logn("wind speed ", speed, " m/s")
end

event.AddListener("KeyInput", "ocean_shore", function(key, press)
	if not press then return end

	if key == "pageup" then
		shore.SetWind(water.GetOcean().WindSpeed + WIND_STEP)
	elseif key == "pagedown" then
		shore.SetWind(water.GetOcean().WindSpeed - WIND_STEP)
	end
end)

commands.Add("ocean_wind=number", shore.SetWind)
shore.views = {
	{name = "from the sea", pos = Vec3(-30, 6, 0), target = Vec3(SHORE_X, 0, 0)},
	{name = "low", pos = Vec3(-15, 2.5, 15), target = Vec3(SHORE_X, 0, 0)},
	{name = "along the beach", pos = Vec3(40, 6, -150), target = Vec3(60, 0, 100)},
	{name = "high", pos = Vec3(-120, 45, 0), target = Vec3(SHORE_X, 0, 0)},
	{name = "above", pos = Vec3(-60, 90, 0), target = Vec3(SHORE_X, 0, 0)},
}

function shore.GetView(index)
	local view = shore.views[index]
	local dir = (view.target - view.pos):GetNormalized()

	return {
		Position = view.pos,
		Rotation = QuatDeg3(math.deg(math.asin(dir.y)), math.deg(math.atan2(-dir.x, -dir.z)), 0),
		FOV = math.rad(70),
	}
end

commands.Add("ocean_shore_view=number[0]", function(index)
	if shore.view then
		shore.view:Remove()
		shore.view = nil
	end

	if index == 0 then
		for i, view in ipairs(shore.views) do
			logn(i, ": ", view.name)
		end

		return
	end

	shore.view = View.New(table.merge({Priority = 100}, shore.GetView(index))):Activate()
end)

return shore
