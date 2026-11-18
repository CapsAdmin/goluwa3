local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local test_scene = import("goluwa/render3d/test_scene.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD_PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/blit.lua",
}
local RADIANCE_PASSES = {
	"goluwa/render3d/light_grid.lua",
	"goluwa/render3d/passes/gbuffer.lua",
	"goluwa/render3d/passes/radiance_cache.lua",
	"goluwa/render3d/passes/radiance.lua",
	"goluwa/render3d/passes/lighting.lua",
	"goluwa/render3d/passes/blit.lua",
}

local function luminance(texture, x, y)
	local r, g, b = texture:GetPixelFloat(x, y)
	return r * 0.2126 + g * 0.7152 + b * 0.0722
end

local function disc_stats(draw, pitch, frames)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(20))
	camera:SetPosition(Vec3(0, 3, 0))
	camera:SetAngles{x = math.rad(pitch), y = 0, z = 0}

	for _ = 1, frames do
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

local function check_mirror(draw, pass_paths, frames)
	local passes = {}

	for i, path in ipairs(pass_paths) do
		local module = import(path)
		passes[i] = module.pass or module
	end

	render3d.Initialize{passes = passes}
	local elevation = 25
	test_scene.Reset{sun = {elevation = elevation, azimuth = 0}}
	test_scene.Box{
		name = "mirror",
		pos = Vec3(0, -0.1, 0),
		size = Vec3(4000, 0.2, 4000),
		material = shapes.Material{Color = Color(1, 1, 1, 1), Roughness = 0, Metallic = 1},
	}
	local sky_peak, sky_area = disc_stats(draw, elevation, frames)
	local mirror_peak, mirror_area = disc_stats(draw, -elevation, frames)
	test_scene.Reset()
	T(mirror_peak > sky_peak * 0.1)["=="](true)
	T(mirror_area < sky_area * 3)["=="](true)
end

T.Test3D("Graphics render3d a perfect mirror reflects the sun disc at full strength and its size", function(draw)
	check_mirror(draw, FORWARD_PASSES, 12)
end)

T.Test3DRayTracing("Graphics render3d a perfect mirror traced by the radiance pass reflects the sun disc at full strength and its size", function(draw)
	check_mirror(draw, RADIANCE_PASSES, 60)
end)

T.Test3DRayTracing("Graphics render3d a rough floor traced by the radiance pass shows no speckle of the sun disc", function(draw)
	local passes = {}

	for i, path in ipairs(RADIANCE_PASSES) do
		local module = import(path)
		passes[i] = module.pass or module
	end

	render3d.Initialize{passes = passes}
	local elevation = 25
	test_scene.Reset{sun = {elevation = elevation, azimuth = 0}}
	test_scene.Box{
		name = "floor",
		pos = Vec3(0, -0.1, 0),
		size = Vec3(4000, 0.2, 4000),
		material = shapes.Material{Color = Color(0.8, 0.8, 0.8, 1), Roughness = 0.3, Metallic = 0},
	}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(40))
	camera:SetPosition(Vec3(0, 3, 0))
	camera:SetAngles{x = math.rad(-elevation), y = 0, z = 0}

	for _ = 1, 90 do
		draw()
	end

	local scene = post_source.GetRawSceneSourceTexture():Download()
	local values = {}

	for y = math.floor(scene.height * 0.55), math.floor(scene.height * 0.95), 2 do
		for x = 0, scene.width - 1, 2 do
			values[#values + 1] = luminance(scene, x, y)
		end
	end

	table.sort(values)
	local median, peak = values[math.floor(#values / 2)], values[#values]
	test_scene.Reset()
	T(peak < median * 20)["=="](true)
end)
