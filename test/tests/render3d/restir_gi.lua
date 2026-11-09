local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local pvars = import("goluwa/cli/pvars.lua")
local gi = import("goluwa/render3d/gi.lua")

local function gi_mean()
	local downloaded = gi.GetScreenTexture():Download()
	local sum = {0, 0, 0, 0}
	local count = 0

	for y = 0, downloaded.height - 1, 8 do
		for x = 0, downloaded.width - 1, 8 do
			local r, g, b, a = downloaded:GetPixelFloat(x, y)
			sum[1], sum[2], sum[3], sum[4] = sum[1] + r, sum[2] + g, sum[3] + b, sum[4] + a
			count = count + 1
		end
	end

	return sum[1] / count, sum[2] / count, sum[3] / count, sum[4] / count
end

local function add_slab(polygon3d, created, min, max, material)
	local ent = Entity.New{Name = "restir_slab"}
	created[#created + 1] = ent
	ent:AddComponent("transform")
	ent.transform:SetPosition((min + max) * 0.5)
	ent.transform:SetScale((max - min) * 0.5)
	ent:AddComponent("visual")
	local p = Entity.New{Name = "restir_slab_p", Parent = ent}
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
	p.visual_primitive:SetMaterial(
		material or
			Material.New{ColorMultiplier = Color(0.8, 0.8, 0.8, 1), MetallicMultiplier = 0}
	)
	ent.visual:BuildAABB()
	return ent
end

local function with_scene(build, check)
	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local created = {}
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/ddgi.lua"),
			import("goluwa/render3d/passes/restir_gi.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
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

	if not ok then error(err, 0) end
end

T.Test3DRayTracing("Graphics render3d restir gi produces a screen gi texture over the world cache", function(draw)
	with_scene(function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 4, 10))
		render3d.camera:SetAngles{x = -15, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-50, -1, -50), Vec3(50, 0, 50))
		add_slab(polygon3d, created, Vec3(-1, 0, -1), Vec3(1, 2, 1))
	end, function()
		T(gi.IsPerPixel())["=="](true)
		T(gi.GetMode())["=="]("ddgi")
		T(gi.GetScreenSpecularTexture() == nil)["=="](true)

		for _ = 1, 8 do
			draw()
		end

		local r, g, b, sky_visibility = gi_mean()
		T(r + g + b > 0)["=="](true)
		T(sky_visibility > 0.5)["=="](true)
	end)
end)

T.Test3DRayTracing("Graphics render3d restir gi lights a sealed room from a small emitter and nothing else", function(draw)
	local emitter

	with_scene(function(polygon3d, created)
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
			Vec3(-0.05, 1.45, -0.05),
			Vec3(0.05, 1.55, 0.05),
			Material.New{
				ColorMultiplier = Color(1, 1, 1, 1),
				MetallicMultiplier = 0,
				AlbedoAlphaIsEmissive = true,
				EmissiveMultiplier = Color(1, 1, 1, 30),
			}
		)
	end, function()
		local function gi_sum(position)
			emitter.transform:SetPosition(position)
			gi.ResetHistory()

			for _ = 1, 12 do
				draw()
			end

			local r, g, b = gi_mean()
			return r + g + b
		end

		local outside = Vec3(0, 1.5, -1000)
		gi_sum(outside)
		local dark = gi_sum(outside)
		local lit = gi_sum(Vec3(0, 1.5, 0))
		T(lit > 0)["=="](true)
		T(dark < lit * 0.02)["=="](true)
	end)
end)

T.Slow(T.Test3DRayTracing, "Graphics render3d restir gi reuse adds no light and loses none against plain rays", function(draw)
	local keys = {
		"restir_gi_temporal",
		"restir_gi_spatial",
		"restir_gi_filter",
		"restir_gi_accumulation",
	}
	local saved = {}

	for _, key in ipairs(keys) do
		saved[key] = pvars.Get(key)
	end

	with_scene(function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 2, 6))
		render3d.camera:SetAngles{x = -10, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-30, -0.5, -30), Vec3(30, 0, 30))
		add_slab(polygon3d, created, Vec3(-4, 0, -2), Vec3(4, 4, -1.6))
		add_slab(polygon3d, created, Vec3(-1, 0, 0), Vec3(0, 1, 1))
		add_slab(polygon3d, created, Vec3(1.5, 0, -1.6), Vec3(2, 3, 1))
	end, function()
		local function converged(reuse)
			pvars.SetSession("restir_gi_temporal", reuse)
			pvars.SetSession("restir_gi_spatial", reuse)
			pvars.SetSession("restir_gi_filter", false)
			pvars.SetSession("restir_gi_accumulation", 100000)
			gi.ResetHistory()

			for _ = 1, 300 do
				draw()
			end

			local r, g, b = gi_mean()
			return r + g + b
		end

		local plain = converged(false)
		local reused = converged(true)
		T(plain > 0)["=="](true)
		T(reused)["~"](plain, plain * 0.06)
	end)

	for _, key in ipairs(keys) do
		pvars.SetSession(key, saved[key])
	end
end)
