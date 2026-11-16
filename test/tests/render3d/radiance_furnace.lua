local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local path_trace = import("goluwa/render3d/path_trace.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local pvars = import("goluwa/cli/pvars.lua")
local PASSES = {"gbuffer", "radiance_cache", "radiance", "lighting", "path_trace", "blit"}
local W, D, H, THICKNESS = 16, 12, 6, 0.2
local ROUGHNESS = {0, 0.25, 0.5, 0.75, 1}

local function add_box(polygon3d, created, min, max, material)
	local ent = Entity.New{Name = "furnace_box"}
	created[#created + 1] = ent
	ent:AddComponent("transform")
	ent.transform:SetPosition((min + max) * 0.5)
	ent.transform:SetScale((max - min) * 0.5)
	ent:AddComponent("visual")
	local p = Entity.New{Name = "furnace_box_p", Parent = ent}
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
	p.visual_primitive:SetMaterial(material)
	ent.visual:BuildAABB()
	return ent
end

local function disc_mean(texture, cx, cy, radius)
	local sum, count = 0, 0

	for y = math.floor(cy - radius), math.ceil(cy + radius) do
		for x = math.floor(cx - radius), math.ceil(cx + radius) do
			if
				x >= 0 and
				y >= 0 and
				x < texture.width and
				y < texture.height and
				(
					x - cx
				) ^ 2 + (
					y - cy
				) ^ 2 <= radius ^ 2
			then
				local r, g, b = texture:GetPixelFloat(x, y)
				sum = sum + r * 0.2126 + g * 0.7152 + b * 0.0722
				count = count + 1
			end
		end
	end

	return sum / math.max(count, 1)
end

T.Test3DRayTracing("Graphics render3d radiance a white metal in a furnace of emitters keeps the light at every roughness", function(draw)
	local settings = {
		r_pass_path_trace = true,
		path_trace_bounces = 8,
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
	local ok, err = pcall(function()
		local wall = Material.New{
			Roughness = 1,
			MetallicMultiplier = 0,
			ColorMultiplier = Color(0.5, 0.5, 0.5, 1),
			AlbedoAlphaIsEmissive = true,
			EmissiveMultiplier = Color(1, 1, 1, 1),
		}
		local half_w, half_d = W / 2, D / 2
		add_box(
			polygon3d,
			created,
			Vec3(-half_w - THICKNESS, -THICKNESS, -half_d - THICKNESS),
			Vec3(half_w + THICKNESS, 0, half_d + THICKNESS),
			wall
		)
		add_box(
			polygon3d,
			created,
			Vec3(-half_w - THICKNESS, H, -half_d - THICKNESS),
			Vec3(half_w + THICKNESS, H + THICKNESS, half_d + THICKNESS),
			wall
		)
		add_box(
			polygon3d,
			created,
			Vec3(-half_w - THICKNESS, 0, -half_d - THICKNESS),
			Vec3(-half_w, H, half_d + THICKNESS),
			wall
		)
		add_box(
			polygon3d,
			created,
			Vec3(half_w, 0, -half_d - THICKNESS),
			Vec3(half_w + THICKNESS, H, half_d + THICKNESS),
			wall
		)
		add_box(
			polygon3d,
			created,
			Vec3(-half_w, 0, half_d),
			Vec3(half_w, H, half_d + THICKNESS),
			wall
		)
		add_box(
			polygon3d,
			created,
			Vec3(-half_w, 0, -half_d - THICKNESS),
			Vec3(half_w, H, -half_d),
			wall
		)
		local spheres = {}

		for i, roughness in ipairs(ROUGHNESS) do
			local x = ((#ROUGHNESS - 1) / 2 - (i - 1)) * 2.6

			for row = 0, 1 do
				local metal = Material.New{
					Roughness = roughness,
					RoughnessMultiplier = roughness,
					MetallicMultiplier = row == 0 and 1 or 0,
					ColorMultiplier = Color(1, 1, 1, 1),
				}
				local sphere = shapes.Sphere{
					Name = "furnace_sphere",
					Position = Vec3(x, 3.6 - row * 2.2, 3),
					Radius = 0.9,
					Material = metal,
					Collision = false,
					RigidBody = false,
				}
				created[#created + 1] = sphere
				spheres[#spheres + 1] = {x = x, y = 3.6 - row * 2.2, roughness = roughness, metal = row == 0}
			end
		end

		render3d.camera:SetPosition(Vec3(0, 3, -4.5))
		render3d.camera:SetAngles{x = 0, y = math.rad(180), z = 0}

		for _ = 1, tonumber(os.getenv("FRAMES") or 120) do
			draw()
		end

		local path = path_trace.GetTexture():Download()
		local raster = path_trace.GetRasterTexture():Download()
		local camera = render3d.camera
		local wall_mean = disc_mean(path, path.width * 0.5, path.height * 0.1, 30)

		for _, sphere in ipairs(spheres) do
			local center = camera:WorldPositionToScreenUnjittered(Vec3(sphere.x, sphere.y, 3), path.width, path.height, true)
			local distance = (camera:GetPosition() - Vec3(sphere.x, sphere.y, 3)):GetLength()
			local radius = 0.9 / distance * (path.height * 0.5) / math.tan(camera:GetFOV() * 0.5) * 0.55
			local p = disc_mean(path, center.x, center.y, radius)
			local r = disc_mean(raster, center.x, center.y, radius)
			local ratio = r / math.max(p, 1e-9)
			logf(
				"furnace %s roughness %.2f: raster/path %.3f (path/wall %.3f)\n",
				sphere.metal and "metal" or "diffuse",
				sphere.roughness,
				ratio,
				p / math.max(wall_mean, 1e-9)
			)
			T(p / wall_mean)["~"](0.97, 0.05)

			if sphere.metal then
				T(ratio > 0.92)["=="](true)
				T(ratio < 1.03)["=="](true)
			end
		end
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
end)
