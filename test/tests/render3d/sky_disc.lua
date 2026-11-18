local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/blit.lua",
}

T.Test3D("Graphics render3d the sun disk is a filled disk far from the world origin", function(draw)
	local passes = {}

	for i, path in ipairs(PASSES) do
		local module = import(path)
		passes[i] = module.pass or module
	end

	render3d.Initialize{passes = passes}
	local elevation = 30
	test_scene.Reset{sun = {elevation = elevation, azimuth = 0}}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(20))
	camera:SetPosition(Vec3(-40000, 2, -40000))
	camera:SetAngles{x = math.rad(elevation), y = 0, z = 0}

	for _ = 1, 8 do
		draw()
	end

	local scene = post_source.GetRawSceneSourceTexture():Download()
	local cx, cy = math.floor(scene.width / 2), math.floor(scene.height / 2)
	local _, g_corner = scene:GetPixelFloat(4, 4)
	local dark = 0

	for dy = -6, 6 do
		for dx = -6, 6 do
			if dx * dx + dy * dy <= 36 then
				local _, g = scene:GetPixelFloat(cx + dx, cy + dy)

				if g < g_corner * 100 then dark = dark + 1 end
			end
		end
	end

	test_scene.Reset()
	T(dark)["=="](0)
end)
