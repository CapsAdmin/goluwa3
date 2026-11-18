local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/blit.lua",
}

local function luminance(texture, x, y)
	local r, g, b = texture:GetPixelFloat(x, y)
	return r * 0.2126 + g * 0.7152 + b * 0.0722
end

local function disc_stats(draw, pitch)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(20))
	camera:SetPosition(Vec3(0, 3, 0))
	camera:SetAngles{x = math.rad(pitch), y = 0, z = 0}

	for _ = 1, 12 do
		draw()
	end

	local scene = post_source.GetRawSceneSourceTexture():Download()
	local cx, cy = math.floor(scene.width / 2), math.floor(scene.height / 2)
	local peak = 0

	for y = cy - 30, cy + 30 do
		for x = cx - 30, cx + 30 do
			peak = math.max(peak, luminance(scene, x, y))
		end
	end

	local area = 0

	for y = cy - 30, cy + 30 do
		for x = cx - 30, cx + 30 do
			if luminance(scene, x, y) > peak * 0.5 then area = area + 1 end
		end
	end

	return peak, area
end

T.Test3D("Graphics render3d a perfect mirror reflects the sun disc at full strength and its size", function(draw)
	local passes = {}

	for i, path in ipairs(PASSES) do
		local module = import(path)
		passes[i] = module.pass or module
	end

	render3d.Initialize{passes = passes}
	local elevation = 25
	test_scene.Reset{sun = {elevation = elevation, azimuth = 0}}
	local mirror = shapes.Polygon{
		Name = "mirror",
		Position = Vec3(0, 0, 0),
		Polygon = function(poly)
			shapes.BuildPlane(poly, Vec3(0, 0, 0), Vec3(0, 1, 0), 4000, 4000)
		end,
		Material = {
			Color = Color(1, 1, 1, 1),
			MetallicMultiplier = 1,
			RoughnessMultiplier = 0,
			DoubleSided = true,
		},
		Collision = false,
		RigidBody = false,
	}
	test_scene.GetRoot():AddChild(mirror)
	local sky_peak, sky_area = disc_stats(draw, elevation)
	local mirror_peak, mirror_area = disc_stats(draw, -elevation)
	test_scene.Reset()
	T(mirror_peak > sky_peak * 0.1)["=="](true)
	T(mirror_area < sky_area * 3)["=="](true)
end)
