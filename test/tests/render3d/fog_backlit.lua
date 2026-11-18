local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FOG_PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/volumetric_fog.lua",
	"goluwa/render3d/passes/blit.lua",
}
local SKY_PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/blit.lua",
}

local function luminance(texture, x, y)
	local r, g, b = texture:GetPixelFloat(x, y)
	return r * 0.2126 + g * 0.7152 + b * 0.0722
end

local function render(draw, paths, sun_azimuth, box_x, box_width)
	local passes = {}

	for i, path in ipairs(paths) do
		local module = import(path)
		passes[i] = module.pass or module
	end

	render3d.Initialize{passes = passes}
	test_scene.Reset{sun = {elevation = 3, azimuth = sun_azimuth}}
	test_scene.Ground{size = 400000}
	test_scene.Box{
		name = "mountain",
		pos = Vec3(box_x, 3000, -40000),
		size = Vec3(box_width, 6000, 8000),
		material = test_scene.Matte(0.3),
	}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(40))
	camera:SetPosition(Vec3(0, 2, 0))
	camera:SetAngles{x = math.rad(6), y = 0, z = 0}

	for _ = 1, 60 do
		draw()
	end

	local scene = post_source.GetRawSceneSourceTexture():Download()
	local row = math.floor(scene.height * 0.6)
	local values = {}

	for _, x in ipairs{0.29, 0.86} do
		values[x] = luminance(scene, math.floor(scene.width * x), row)
	end

	test_scene.Reset()
	return values
end

local function glow_ratio(draw, sun_azimuth, box_x, box_width)
	local lit = render(draw, FOG_PASSES, sun_azimuth, box_x, box_width)
	local bare = render(draw, SKY_PASSES, sun_azimuth, box_x, box_width)
	local ratio = (lit[0.29] - bare[0.29]) / lit[0.86]
	return ratio
end

T.Test3D("Graphics render3d fog does not glow in front of a mountain with the sun behind it, sun on screen", function(draw)
	T(glow_ratio(draw, 15, -40000 * math.tan(math.rad(15)), 20000) < 0.3)["=="](true)
end)
