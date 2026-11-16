local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local weather = import("goluwa/render3d/weather.lua")
local path_trace = import("goluwa/render3d/path_trace.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local pvars = import("goluwa/cli/pvars.lua")

local function luminance(image, x, y)
	local r, g, b = image:GetPixelFloat(x, y)
	return r * 0.2126 + g * 0.7152 + b * 0.0722
end

local function window_mean(image, cx, cy, radius)
	local sum, count = 0, 0

	for y = cy - radius, cy + radius do
		for x = cx - radius, cx + radius do
			if x >= 0 and y >= 0 and x < image.width and y < image.height then
				sum = sum + luminance(image, x, y)
				count = count + 1
			end
		end
	end

	return sum / count
end

local function brightest(image, x0, y0, x1, y1)
	local best_x, best_y, best = x0, y0, -1

	for y = y0, y1, 2 do
		for x = x0, x1, 2 do
			local level = window_mean(image, x, y, 1)

			if level > best then best_x, best_y, best = x, y, level end
		end
	end

	return best_x, best_y, best
end

local function with_ball(settings, passes, build, check)
	local saved = {}

	for key, value in pairs(settings) do
		saved[key] = pvars.Get(key)
		pvars.SetSession(key, value)
	end

	local modules = {}

	for i, name in ipairs(passes) do
		modules[i] = import("goluwa/render3d/passes/" .. name .. ".lua")
	end

	render3d.Initialize{passes = modules}
	local created = {
		shapes.Box{
			Name = "caustics_ground",
			Position = Vec3(0, -0.5, 0),
			Size = Vec3(40, 1, 40),
			Material = shapes.Material{Color = Color(0.7, 0.7, 0.7, 1), Roughness = 0.9, Metallic = 0},
			Collision = false,
			RigidBody = false,
		},
		(
			shapes.Sphere{
				Name = "caustics_ball",
				Position = Vec3(0, 0.5, 0),
				Radius = 0.5,
				Material = shapes.Material{
					Color = Color(1, 1, 1, 1),
					Roughness = 0,
					Metallic = 0,
					Refraction = 1,
					IndexOfRefraction = 1.5,
				},
				Collision = false,
				RigidBody = false,
			}
		),
	}
	local ok, err = pcall(function()
		build(created)
		check()
	end)

	for _, entity in ipairs(created) do
		if entity:IsValid() then entity:Remove() end
	end

	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	for key, value in pairs(saved) do
		pvars.SetSession(key, value)
	end

	if not ok then error(err, 0) end
end

local function add_sun(created, direction)
	local sun = Entity.New{
		Name = "caustics_sun",
		transform = {},
		light_sun = {Color = Color(1, 1, 1), Lux = 100000},
	}
	sun.transform:SetRotation(weather.GetSunRotationFromDirection(direction:GetNormalized()))
	created[#created + 1] = sun
end

local function check_against_path(draw, open_tolerance)
	for _ = 1, 32 do
		draw()
	end

	local path = path_trace.GetTexture():Download()
	local raster = path_trace.GetRasterTexture():Download()
	local focus_x, focus_y = brightest(raster, 0, 0, raster.width - 1, raster.height - 1)
	local open_x, open_y = math.floor(path.width * 0.1), math.floor(path.height * 0.9)
	local spot = math.floor(path.width * 0.08)
	local path_open = window_mean(path, open_x, open_y, 6)
	local raster_open = window_mean(raster, open_x, open_y, 6)
	T(window_mean(path, focus_x, focus_y, 1) > path_open * 3)["=="](true)
	T(window_mean(raster, focus_x, focus_y, 1) > raster_open * 3)["=="](true)
	T(
		window_mean(raster, focus_x, focus_y, spot) / window_mean(path, focus_x, focus_y, spot)
	)["~"](1, 0.15)
	T(raster_open / path_open)["~"](1, open_tolerance)
end

local PATH_PASSES = {"gbuffer", "caustics", "lighting", "path_trace", "translucent", "blit"}
local PATH_SETTINGS = {
	r_pass_caustics = true,
	r_pass_path_trace = true,
	path_trace_view = "raster",
	path_trace_bounces = 1,
}

T.Test3DRayTracing("Graphics render3d caustics of a glass ball agree with the path traced photons", function(draw)
	with_ball(
		PATH_SETTINGS,
		PATH_PASSES,
		function(created)
			render3d.camera:SetPosition(Vec3(0, 3, 3))
			render3d.camera:SetAngles{x = math.rad(-50), y = 0, z = 0}
			add_sun(created, Vec3(0.2, 0.9, -0.3))
		end,
		function()
			check_against_path(draw, 0.05)
		end
	)
end)

T.Test3DRayTracing("Graphics render3d caustics of a lamp through a glass ball agree with the path traced photons", function(draw)
	with_ball(
		PATH_SETTINGS,
		PATH_PASSES,
		function(created)
			render3d.camera:SetPosition(Vec3(0, 3, 3))
			render3d.camera:SetAngles{x = math.rad(-50), y = 0, z = 0}
			local lamp = Entity.New{
				Name = "caustics_lamp",
				transform = {},
				light_point = {Color = Color(1, 1, 1, 1), Lumen = 5000000, SourceRadius = 0.02},
			}
			lamp.transform:SetPosition(Vec3(-1.2, 2.2, -1.2))
			created[#created + 1] = lamp
		end,
		function()
			check_against_path(draw, 0.1)
		end
	)
end)

T.Test3DRayTracing("Graphics render3d caustics show in a mirror through the world grid", function(draw)
	with_ball(
		{r_pass_caustics = true},
		{"gbuffer", "radiance_cache", "radiance", "caustics", "lighting", "blit"},
		function(created)
			render3d.camera:SetPosition(Vec3(-1.2, 2.2, 0))
			render3d.camera:SetAngles{x = math.rad(-89), y = 0, z = 0}
			add_sun(created, Vec3(0.5, 1, 0))
			created[#created + 1] = (
				shapes.Polygon{
					Name = "caustics_mirror",
					Position = Vec3(-1.2, 0.6, 0),
					Polygon = function(poly)
						shapes.BuildPlane(poly, Vec3(0, 0, 0), Vec3(0.92, 0.38, 0), 0.4, 0.4)
					end,
					Material = shapes.Material{Color = Color(1, 1, 1, 1), Metallic = 1, Roughness = 0.02, DoubleSided = true},
					Collision = false,
					RigidBody = false,
				}
			)
		end,
		function()
			local function mirror_peak(world)
				pvars.SetSession("r_caustics_world", world)

				for _ = 1, 40 do
					draw()
				end

				local image = render3d.pipelines.lighting:GetFramebuffer(1):GetAttachment(1):Download()
				local w, h = image.width, image.height
				local _, _, peak = brightest(
					image,
					math.floor(w * 0.35),
					math.floor(h * 0.35),
					math.floor(w * 0.65),
					math.floor(h * 0.65)
				)
				return peak
			end

			local saved = pvars.Get("r_caustics_world")
			local without = mirror_peak(false)
			local with = mirror_peak(true)
			pvars.SetSession("r_caustics_world", saved)
			T(with > without * 1.5)["=="](true)
		end
	)
end)
