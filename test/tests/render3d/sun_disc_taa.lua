local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/taa.lua",
	"goluwa/render3d/passes/blit.lua",
}

local function luminance(texture, x, y)
	local r, g, b = texture:GetPixelFloat(x, y)
	return r * 0.2126 + g * 0.7152 + b * 0.0722
end

T.Test3D("Graphics render3d taa keeps the sun disc filled and its surroundings free of dark and hot pixels", function(draw)
	local passes = {}

	for i, path in ipairs(PASSES) do
		local module = import(path)
		passes[i] = module.pass or module
	end

	render3d.Initialize{passes = passes}
	local elevation = 25
	test_scene.Reset{sun = {elevation = elevation, azimuth = 0}}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(20))
	camera:SetPosition(Vec3(0, 3, 0))
	camera:SetAngles{x = math.rad(elevation), y = 0, z = 0}

	for _ = 1, 40 do
		draw()
	end

	local scene = post_source.GetAntiAliasedSceneTexture():Download()
	local cx, cy = math.floor(scene.width / 2), math.floor(scene.height / 2)
	local sky = luminance(scene, cx + 200, cy + 200)
	local disc_max = 0
	local dark, hot = 0, 0

	for y = cy - 30, cy + 30 do
		for x = cx - 30, cx + 30 do
			local v = luminance(scene, x, y)
			disc_max = math.max(disc_max, v)
			local distance = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2)

			if v < sky * 0.5 then dark = dark + 1 end

			if distance > 14 and v > sky * 20 then hot = hot + 1 end
		end
	end

	test_scene.Reset()
	T(disc_max > sky * 20)["=="](true)
	T(dark)["=="](0)
	T(hot)["=="](0)
end)
