local T = import("test/environment.lua")
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
local PASSES = {"gbuffer", "radiance_cache", "radiance", "lighting", "path_trace", "blit"}

local function add_box(polygon3d, created, min, max, material)
	local ent = Entity.New{Name = "radiance_specular_box"}
	created[#created + 1] = ent
	ent:AddComponent("transform")
	ent.transform:SetPosition((min + max) * 0.5)
	ent.transform:SetScale((max - min) * 0.5)
	ent:AddComponent("visual")
	local p = Entity.New{Name = "radiance_specular_box_p", Parent = ent}
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
	p.visual_primitive:SetMaterial(material)
	ent.visual:BuildAABB()
	return ent
end

local function measure(draw, roughness, metallic, frames, build)
	local settings = {
		r_pass_path_trace = true,
		path_trace_bounces = 2,
		path_trace_view = "path",
		screen_space_shadows = false,
	}
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
	local modules = {}

	for i, name in ipairs(PASSES) do
		modules[i] = import("goluwa/render3d/passes/" .. name .. ".lua")
	end

	render3d.Initialize{passes = modules}
	local result
	local ok, err = pcall(function()
		if build then
			build(polygon3d, created)

			for _ = 1, frames do
				draw()
			end

			result = path_trace.Compare(2)
			return
		end

		render3d.camera:SetPosition(Vec3(0, 3, 9))
		render3d.camera:SetAngles{x = math.rad(-18), y = 0, z = 0}
		add_box(
			polygon3d,
			created,
			Vec3(-60, -1, -60),
			Vec3(60, 0, 60),
			Material.New{
				ColorMultiplier = Color(0.8, 0.8, 0.8, 1),
				RoughnessMultiplier = roughness,
				MetallicMultiplier = metallic,
			}
		)
		add_box(
			polygon3d,
			created,
			Vec3(-4, 0, -6),
			Vec3(-2, 3, -4),
			Material.New{ColorMultiplier = Color(0.9, 0.15, 0.1, 1), MetallicMultiplier = 0}
		)
		add_box(
			polygon3d,
			created,
			Vec3(1, 0, -7),
			Vec3(3.5, 2, -5),
			Material.New{ColorMultiplier = Color(0.1, 0.4, 0.9, 1), MetallicMultiplier = 0}
		)
		local sun = Entity.New{
			Name = "radiance_specular_sun",
			transform = {},
			light_sun = {Color = Color(1, 0.95, 0.9), Lux = 100000},
		}
		sun.transform:SetRotation(weather.GetSunRotationFromDirection(Vec3(0.3, 0.6, 0.5):GetNormalized()))
		created[#created + 1] = sun

		for _ = 1, frames do
			draw()
		end

		result = path_trace.Compare(2)
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

	return result
end

T.Test3DRayTracing("Graphics render3d radiance specular matches the path tracer", function(draw)
	for _, case in ipairs{
		{0, 1, 0.05},
		{0.1, 1, 0.05},
		{0.3, 1, 0.05},
		{0.6, 1, 0.04},
		{1, 1, 0.04},
		{0.05, 0, 0.03},
		{0.4, 0, 0.03},
		{0.9, 0, 0.03},
	} do
		local r = measure(draw, case[1], case[2], tonumber(os.getenv("FRAMES") or 90))
		logf(
			"radiance specular roughness %.2f metallic %d: raster/path %.3f, mean abs error %.1f%%\n",
			case[1],
			case[2],
			r.ratio,
			r.relative_error * 100
		)
		T(r.ratio)["~"](1, case[3])
	end
end)

T.Test3DRayTracing("Graphics render3d light bounced off a metal floor matches the path tracer", function(draw)
	local r = measure(
		draw,
		0,
		0,
		90,
		function(polygon3d, created)
			render3d.camera:SetPosition(Vec3(0, 1.5, 2))
			render3d.camera:SetAngles{x = math.rad(5), y = 0, z = 0}
			add_box(
				polygon3d,
				created,
				Vec3(-60, -1, -60),
				Vec3(60, 0, 60),
				Material.New{
					ColorMultiplier = Color(1.0, 0.78, 0.34, 1),
					RoughnessMultiplier = 0.4,
					MetallicMultiplier = 1,
				}
			)
			add_box(
				polygon3d,
				created,
				Vec3(-6, 0, -6.2),
				Vec3(6, 6, -5.8),
				Material.New{ColorMultiplier = Color(0.8, 0.8, 0.8, 1), MetallicMultiplier = 0}
			)
			local sun = Entity.New{
				Name = "radiance_specular_sun",
				transform = {},
				light_sun = {Color = Color(1, 0.95, 0.9), Lux = 100000},
			}
			sun.transform:SetRotation(weather.GetSunRotationFromDirection(Vec3(0.3, 0.55, 0.78)))
			created[#created + 1] = sun
		end
	)
	logf(
		"metal floor bounce: raster/path %.3f, mean abs error %.1f%%\n",
		r.ratio,
		r.relative_error * 100
	)
	T(r.ratio)["~"](1, 0.12)
end)
