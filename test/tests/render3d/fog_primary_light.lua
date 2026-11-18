local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local weather = import("goluwa/render3d/weather.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/volumetric_fog.lua",
	"goluwa/render3d/passes/blit.lua",
}
local TWILIGHT_WITH_MOON_UP = 1787870293.495

local function set_primary_light(direction, lux)
	weather.syncing_light = true
	weather.light.transform:SetRotation(weather.GetSunRotationFromDirection(direction))
	weather.syncing_light = false
	weather.light.light_sun:SetLux(lux)
end

local function fog_luminance(draw, use_moon)
	test_scene.Reset{ground_fog_visibility = 1500}
	weather.SetLocation(-3.971713, 106.070245)
	weather.SetTime(TWILIGHT_WITH_MOON_UP)
	local moon_direction, _, moon_illuminance = weather.GetMoonAt(weather.time, weather.latitude, weather.longitude)

	if use_moon then
		set_primary_light(moon_direction, moon_illuminance)
	else
		set_primary_light(weather.GetSunDirection(), atmosphere.GetSunIlluminance())
	end

	test_scene.Ground{size = 400000, material = test_scene.Matte(0.2)}
	test_scene.Box{
		name = "hill",
		pos = Vec3(0, 400, -3000),
		size = Vec3(8000, 800, 400),
		material = test_scene.Matte(0.2),
	}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(70))
	camera:SetPosition(Vec3(0, 2, 0))
	camera:SetAngles{x = math.rad(3), y = 0, z = 0}

	for _ = 1, 60 do
		draw()
	end

	local scene = post_source.GetRawSceneSourceTexture():Download()
	local sum, count = 0, 0

	for y = 0.4, 0.52, 0.02 do
		for x = 0.25, 0.75, 0.05 do
			local r, g, b = scene:GetPixelFloat(math.floor(scene.width * x), math.floor(scene.height * y))
			sum = sum + r * 0.2126 + g * 0.7152 + b * 0.0722
			count = count + 1
		end
	end

	test_scene.Reset()
	return sum / count
end

T.Test3D("Graphics render3d fog and ambient do not depend on whether the sun or the moon is the primary light", function(draw)
	local passes = {}

	for i, path in ipairs(PASSES) do
		local module = import(path)
		passes[i] = module.pass or module
	end

	render3d.Initialize{passes = passes}
	weather.Initialize()
	local with_sun = fog_luminance(draw, false)
	local with_moon = fog_luminance(draw, true)
	weather.light:Remove()
	weather.shelter_caster:Remove()
	weather.light = nil
	print("PRIMARY", with_sun, with_moon)
	T(math.max(with_sun, with_moon) / math.min(with_sun, with_moon) < 1.5)["=="](true)
end)
