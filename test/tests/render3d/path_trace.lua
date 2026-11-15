local T = import("test/environment.lua")
local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local weather = import("goluwa/render3d/weather.lua")
local path_trace = import("goluwa/render3d/path_trace.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local pvars = import("goluwa/cli/pvars.lua")

local function add_slab(polygon3d, created, min, max, material)
	local ent = Entity.New{Name = "path_trace_slab"}
	created[#created + 1] = ent
	ent:AddComponent("transform")
	ent.transform:SetPosition((min + max) * 0.5)
	ent.transform:SetScale((max - min) * 0.5)
	ent:AddComponent("visual")
	local p = Entity.New{Name = "path_trace_slab_p", Parent = ent}
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
	p.visual_primitive:SetMaterial(
		material or
			Material.New{ColorMultiplier = Color(0.6, 0.6, 0.6, 1), MetallicMultiplier = 0}
	)
	ent.visual:BuildAABB()
	return ent
end

local function with_scene(settings, build, check)
	local saved = {}

	for key, value in pairs(settings) do
		saved[key] = pvars.Get(key)
		pvars.SetSession(key, value)
	end

	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local created = {}
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/path_trace.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	local ok, err = pcall(function()
		build(polygon3d, created)
		check()
	end)

	for _, e in ipairs(created) do
		if e:IsValid() then e:Remove() end
	end

	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	polygon3d:Remove()

	for key, value in pairs(saved) do
		pvars.SetSession(key, value)
	end

	if not ok then error(err, 0) end
end

T.Test3DRayTracing("Graphics render3d path tracer direct light matches the raster direct light", function(draw)
	with_scene({
		r_pass_path_trace = true,
		path_trace_bounces = 0,
		path_trace_view = "path",
		lighting_debug_direct = true,
		screen_space_shadows = false,
	}, function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 3, 8))
		render3d.camera:SetAngles{x = math.rad(-20), y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-200, -1, -200), Vec3(200, 0, 200))
		local sun = Entity.New{
			Name = "path_trace_sun",
			transform = {},
			light_sun = {Color = Color(1, 0.95, 0.9), Lux = 100000},
		}
		sun.transform:SetRotation(weather.GetSunRotationFromDirection(Vec3(0.3, 0.7, 0.4):GetNormalized()))
		created[#created + 1] = sun
	end, function()
		for _ = 1, 6 do
			draw()
		end

		local result = path_trace.Compare()
		T(result.pixels > 0)["=="](true)
		T(result.path > 0)["=="](true)
		T(result.ratio)["~"](1, 0.02)
		T(result.relative_error < 0.02)["=="](true)
		T(path_trace.GetSampleCount() > 1)["=="](true)
		render3d.camera:SetPosition(Vec3(0, 3, 9))
		draw()
		T(path_trace.GetSampleCount())["=="](1)
	end)
end)

T.Test3DRayTracing("Graphics render3d path tracer lights a sealed room only from its emitter", function(draw)
	local emitter

	with_scene({r_pass_path_trace = true, path_trace_bounces = 8, path_trace_view = "path"}, function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 3, 2))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-6, -3, -6), Vec3(6, 0, 6))
		add_slab(polygon3d, created, Vec3(-6, 0, -6), Vec3(-3, 6, 6))
		add_slab(polygon3d, created, Vec3(3, 0, -6), Vec3(6, 6, 6))
		add_slab(polygon3d, created, Vec3(-3, 0, -6), Vec3(3, 6, -3))
		add_slab(polygon3d, created, Vec3(-3, 0, 3), Vec3(3, 6, 6))
		add_slab(polygon3d, created, Vec3(-6, 6, -6), Vec3(6, 9, 6))
		emitter = add_slab(
			polygon3d,
			created,
			Vec3(-0.25, 1.25, -0.25),
			Vec3(0.25, 1.75, 0.25),
			Material.New{
				ColorMultiplier = Color(1, 1, 1, 1),
				MetallicMultiplier = 0,
				AlbedoAlphaIsEmissive = true,
				EmissiveMultiplier = Color(1, 1, 1, 30),
			}
		)
	end, function()
		local function path_mean(position)
			emitter.transform:SetPosition(position)
			path_trace.Reset()

			for _ = 1, 8 do
				draw()
			end

			return path_trace.Compare().path
		end

		local dark = path_mean(Vec3(0, 1.5, -1000))
		local lit = path_mean(Vec3(0, 1.5, 0))
		T(lit > 0)["=="](true)
		T(dark)["=="](0)
	end)
end)

local function solid_texture(r, g, b, a)
	local size = 4
	local pixels = ffi.new("uint8_t[?]", size * size * 4)

	for i = 0, size * size - 1 do
		pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3] = r, g, b, a
	end

	return Texture.New{
		buffer = pixels,
		width = size,
		height = size,
		format = "r8g8b8a8_unorm",
		srgb = false,
	}
end

local function add_sun(created, direction)
	local sun = Entity.New{
		Name = "path_trace_sun",
		transform = {},
		light_sun = {Color = Color(1, 1, 1), Lux = 100000},
	}
	sun.transform:SetRotation(weather.GetSunRotationFromDirection(direction:GetNormalized()))
	created[#created + 1] = sun
end

T.Test3DRayTracing("Graphics render3d path tracer shades hits with their normal maps", function(draw)
	local wall_material = Material.New{ColorMultiplier = Color(0.8, 0.8, 0.8, 1), MetallicMultiplier = 0}
	local tilted = solid_texture(218, 128, 255, 255)

	with_scene({r_pass_path_trace = true, path_trace_bounces = 1, path_trace_view = "path"}, function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 2, 0))
		render3d.camera:SetAngles{x = math.rad(-60), y = 0, z = 0}
		add_slab(
			polygon3d,
			created,
			Vec3(-50, -1, -50),
			Vec3(50, 0, 50),
			Material.New{
				ColorMultiplier = Color(1, 1, 1, 1),
				MetallicMultiplier = 1,
				RoughnessMultiplier = 0.02,
			}
		)
		add_slab(polygon3d, created, Vec3(-100, 0, -16), Vec3(100, 100, -15), wall_material)
		add_sun(created, Vec3(1, 0.3, 0.3))
	end, function()
		local function reflected_wall(normal_texture)
			wall_material:SetNormalTexture(normal_texture)
			path_trace.Reset()

			for _ = 1, 8 do
				draw()
			end

			return path_trace.Compare().path
		end

		local flat = reflected_wall(nil)
		local bumped = reflected_wall(tilted)
		T(flat > 0)["=="](true)
		T(bumped > 0)["=="](true)
		T(math.abs(bumped - flat) > flat * 0.2)["=="](true)
	end)

	tilted:Remove()
end)

T.Test3DRayTracing("Graphics render3d path tracer shades terrain hits with their layer normal maps", function(draw)
	local weights = solid_texture(255, 0, 0, 0)
	local tilted = solid_texture(218, 128, 255, 255)
	local floor_material = Material.New{ColorMultiplier = Color(0.8, 0.8, 0.8, 1), MetallicMultiplier = 0}
	floor_material:SetTerrainMaterialTexture(weights)
	local fov = render3d.camera:GetFOV()

	with_scene({r_pass_path_trace = true, path_trace_bounces = 1, path_trace_view = "path"}, function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 4, 0))
		render3d.camera:SetAngles{x = math.rad(-15), y = 0, z = 0}
		render3d.camera:SetFOV(math.rad(30))
		add_slab(
			polygon3d,
			created,
			Vec3(-100, 0, -6),
			Vec3(100, 100, -5),
			Material.New{
				ColorMultiplier = Color(1, 1, 1, 1),
				MetallicMultiplier = 1,
				RoughnessMultiplier = 0.02,
			}
		)
		add_slab(polygon3d, created, Vec3(-100, -1, -5), Vec3(100, 0, 100), floor_material)
		add_sun(created, Vec3(1, 0.3, 0.3))
	end, function()
		local function reflected_floor(normal_texture)
			floor_material:SetTerrainLayer1NormalTexture(normal_texture)
			path_trace.Reset()

			for _ = 1, 8 do
				draw()
			end

			return path_trace.Compare().path
		end

		local flat = reflected_floor(nil)
		local bumped = reflected_floor(tilted)
		T(flat > 0)["=="](true)
		T(bumped > 0)["=="](true)
		T(math.abs(bumped - flat) > flat * 0.2)["=="](true)
	end)

	render3d.camera:SetFOV(fov)
	weights:Remove()
	tilted:Remove()
end)

T.Test3DRayTracing("Graphics render3d path tracer softens shadows by the light's source radius", function(draw)
	local light

	with_scene({r_pass_path_trace = true, path_trace_bounces = 0, path_trace_view = "path"}, function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 8, 0))
		render3d.camera:SetAngles{x = math.rad(-90), y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-20, -1, -20), Vec3(20, 0, 20))
		add_slab(polygon3d, created, Vec3(-1, 1.5, -1), Vec3(1, 1.7, 1))
		light = Entity.New{
			Name = "path_trace_light",
			transform = {},
			light_point = {Lumen = 30000},
		}
		light.transform:SetPosition(Vec3(0, 4, 0))
		created[#created + 1] = light
	end, function()
		local function render_with_radius(radius)
			light.light_point:SetSourceRadius(radius)
			path_trace.Reset()

			for _ = 1, 16 do
				draw()
			end

			local downloaded = path_trace.GetTexture():Download()
			local levels = {}
			local sum = 0

			for y = 0, downloaded.height - 1 do
				for x = 0, downloaded.width - 1 do
					local r, g, b = downloaded:GetPixelFloat(x, y)
					local level = r * 0.2126 + g * 0.7152 + b * 0.0722
					levels[#levels + 1] = level
					sum = sum + level
				end
			end

			return levels, sum
		end

		local hard, hard_sum = render_with_radius(0)
		local soft, soft_sum = render_with_radius(1)
		local changed = 0

		for i = 1, #hard do
			local brightest = math.max(hard[i], soft[i])

			if brightest > 0 and math.abs(hard[i] - soft[i]) > brightest * 0.25 then
				changed = changed + 1
			end
		end

		T(hard_sum > 0)["=="](true)
		T(changed > #hard * 0.01)["=="](true)
		T(soft_sum)["~"](hard_sum, hard_sum * 0.1)
	end)
end)

T.Test3DRayTracing("Graphics render3d ray traced shadows match the path traced direct light", function(draw)
	with_scene({
		r_pass_path_trace = true,
		r_ray_shadows = true,
		path_trace_bounces = 0,
		path_trace_view = "path",
		lighting_debug_direct = true,
	}, function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 6, 6))
		render3d.camera:SetAngles{x = math.rad(-45), y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-20, -1, -20), Vec3(20, 0, 20))
		add_slab(polygon3d, created, Vec3(-1, 0, -1), Vec3(-0.5, 2, 1))
		add_slab(polygon3d, created, Vec3(0.5, 1, -1), Vec3(1.5, 1.2, 0))
		local light = Entity.New{
			Name = "path_trace_light",
			transform = {},
			light_point = {Lumen = 30000},
		}
		light.transform:SetPosition(Vec3(0, 2.5, 0))
		created[#created + 1] = light
	end, function()
		for _ = 1, 16 do
			draw()
		end

		local result = path_trace.Compare()
		T(result.path > 0)["=="](true)
		T(result.ratio)["~"](1, 0.005)
		T(result.relative_error < 0.01)["=="](true)
	end)
end)
