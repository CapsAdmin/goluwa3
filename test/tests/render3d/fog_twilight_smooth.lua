local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/volumetric_fog.lua",
	"goluwa/render3d/passes/blit.lua",
}
local NODE_ELEVATION = math.deg(math.asin(-0.2 + 3 * 1.2 / 31))
local STEP = 0.15

local function fog_luminance(draw, elevation)
	test_scene.Reset{sun = {elevation = elevation, azimuth = 0}, ground_fog_visibility = 1500}
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

T.Test3D("Graphics render3d fog brightness has no kink where the sun crosses a node of the scattering tables", function(draw)
	local passes = {}

	for i, path in ipairs(PASSES) do
		local module = import(path)
		passes[i] = module.pass or module
	end

	render3d.Initialize{passes = passes}
	local below = fog_luminance(draw, NODE_ELEVATION - STEP)
	local at = fog_luminance(draw, NODE_ELEVATION)
	local above = fog_luminance(draw, NODE_ELEVATION + STEP)
	local slope_ratio = (above - at) / (at - below)
	print("TWSMOOTH", below, at, above, slope_ratio)
	T(slope_ratio > 0.4 and slope_ratio < 2.5)["=="](true)
end)
