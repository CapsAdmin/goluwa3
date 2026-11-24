local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local exposure = import("goluwa/render3d/exposure.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/taa.lua",
	"goluwa/render3d/passes/blit.lua",
}

local function disc_light(texture)
	local scene = texture:Download()
	local cx, cy = math.floor(scene.width / 2), math.floor(scene.height / 2)
	local sum = 0

	for y = cy - 20, cy + 20 do
		for x = cx - 20, cx + 20 do
			local r, g, b = scene:GetPixelFloat(x, y)
			sum = sum + r * 0.2126 + g * 0.7152 + b * 0.0722
		end
	end

	return sum
end

local function spread(list)
	local mean, min, max = 0, math.huge, -math.huge

	for _, v in ipairs(list) do
		mean = mean + v / #list
		min = math.min(min, v)
		max = math.max(max, v)
	end

	return mean, (max - min) / mean
end

T.Test3D("Graphics render3d the sun disc's light does not change with the jitter, before or after taa", function(draw)
	local passes = {}

	for i, path in ipairs(PASSES) do
		local module = import(path)
		passes[i] = module.pass or module
	end

	render3d.Initialize{passes = passes}
	local ev_min, ev_max = exposure.Get("camera.ev_min"), exposure.Get("camera.ev_max")
	exposure.Set("camera.ev_min", 15)
	exposure.Set("camera.ev_max", 15)
	local elevation = 25
	test_scene.Reset{sun = {elevation = elevation, azimuth = 0}}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetPosition(Vec3(0, 3, 0))
	camera:SetAngles{x = math.rad(elevation), y = 0, z = 0}

	for _ = 1, 120 do
		draw()
	end

	local raw, resolved = {}, {}

	for i = 1, 16 do
		draw()
		raw[i] = disc_light(post_source.GetRawSceneSourceTexture())
		resolved[i] = disc_light(post_source.GetBloomSceneTexture())
	end

	test_scene.Reset()
	exposure.Set("camera.ev_min", ev_min)
	exposure.Set("camera.ev_max", ev_max)
	local raw_mean, raw_spread = spread(raw)
	local resolved_mean, resolved_spread = spread(resolved)
	T(raw_spread)["<"](0.04)
	T(resolved_spread)["<"](0.01)
	T(math.abs(resolved_mean / raw_mean - 1))["<"](0.03)
end)
