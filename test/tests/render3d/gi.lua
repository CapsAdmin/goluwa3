local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local gi = import("goluwa/render3d/gi.lua")
local BACKENDS = {
	{name = "ddgi", pass = "goluwa/render3d/passes/ddgi.lua", min_frames = 0},
	{
		name = "surfels",
		pass = "goluwa/render3d/passes/surfel_gi.lua",
		min_frames = 40,
	},
}

local function gi_mean()
	local downloaded = gi.GetScreenTexture():Download()
	local sum = {0, 0, 0, 0}
	local count = 0

	for y = 0, downloaded.height - 1, 16 do
		for x = 0, downloaded.width - 1, 16 do
			local r, g, b, a = downloaded:GetPixelFloat(x, y)
			sum[1], sum[2], sum[3], sum[4] = sum[1] + r, sum[2] + g, sum[3] + b, sum[4] + a
			count = count + 1
		end
	end

	return sum[1] / count, sum[2] / count, sum[3] / count, sum[4] / count
end

local function gi_sum(draw, frames)
	for _ = 1, frames do
		draw()
	end

	local r, g, b = gi_mean()
	return r + g + b
end

local function add_slab(polygon3d, created, min, max)
	local ent = Entity.New{Name = "gi_slab"}
	created[#created + 1] = ent
	ent:AddComponent("transform")
	ent.transform:SetPosition((min + max) * 0.5)
	ent.transform:SetScale((max - min) * 0.5)
	ent:AddComponent("visual")
	local p = Entity.New{Name = "gi_slab_p", Parent = ent}
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
	p.visual_primitive:SetMaterial(Material.New{ColorMultiplier = Color(0.8, 0.8, 0.8, 1), MetallicMultiplier = 0})
	ent.visual:BuildAABB()
	return ent
end

local function add_plane_room(created, polygons, center, half, height, double_sided, albedo)
	local planes = {
		{Vec3(0, 0, 0), Vec3(0, 1, 0), half, half},
		{Vec3(0, height, 0), Vec3(0, -1, 0), half, half},
		{Vec3(0, height / 2, -half), Vec3(0, 0, 1), half, height / 2},
		{Vec3(0, height / 2, half), Vec3(0, 0, -1), half, height / 2},
		{Vec3(-half, height / 2, 0), Vec3(1, 0, 0), half, height / 2},
		{Vec3(half, height / 2, 0), Vec3(-1, 0, 0), half, height / 2},
	}
	local material = Material.New{
		ColorMultiplier = Color(albedo, albedo, albedo, 1),
		MetallicMultiplier = 0,
		DoubleSided = double_sided,
	}
	local ceiling

	for i, plane in ipairs(planes) do
		local polygon3d = Polygon3D.New()
		shapes.BuildPlane(polygon3d, Vec3(0, 0, 0), plane[2], plane[3], plane[4])
		polygon3d:BuildBoundingBox()
		polygon3d:Upload()
		polygons[#polygons + 1] = polygon3d
		local ent = Entity.New{Name = "gi_plane"}
		created[#created + 1] = ent
		ent:AddComponent("transform")
		ent.transform:SetPosition(center + plane[1])
		ent:AddComponent("visual")
		local p = Entity.New{Name = "gi_plane_p", Parent = ent}
		p:AddComponent("transform")
		p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
		p.visual_primitive:SetMaterial(material)
		ent.visual:BuildAABB()

		if i == 2 then ceiling = ent end
	end

	return ceiling
end

local function add_light(created)
	local light = Entity.New{Name = "gi_test_light"}
	created[#created + 1] = light
	light:AddComponent("transform")
	light:AddComponent("light_point"):SetLumen(2000000)
	return light
end

for _, backend in ipairs(BACKENDS) do
	local function test(name, build, check, with_ambient_occlusion)
		T.Test3DRayTracing("Graphics render3d gi " .. backend.name .. " " .. name, function(draw)
			local passes = {import("goluwa/render3d/passes/gbuffer.lua")}

			if with_ambient_occlusion then
				passes[#passes + 1] = import("goluwa/render3d/passes/ambient_occlusion.lua")
			end

			passes[#passes + 1] = import(backend.pass)
			passes[#passes + 1] = import("goluwa/render3d/passes/lighting.lua")
			passes[#passes + 1] = import("goluwa/render3d/passes/blit.lua")
			render3d.Initialize{passes = passes}
			local polygon3d = Polygon3D.New()
			shapes.BuildCube(polygon3d, 1)
			polygon3d:BuildBoundingBox()
			polygon3d:Upload()
			local created, polygons = {}, {}
			local ok, err = pcall(function()
				T(gi.GetMode())["=="](backend.name)
				local scene = build(polygon3d, created, polygons)

				check(
					function(frames)
						return gi_sum(draw, math.max(frames, backend.min_frames))
					end,
					scene,
					draw
				)
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

			for _, p in ipairs(polygons) do
				p:Remove()
			end

			if not ok then error(err, 0) end
		end)
	end

	test("does not leak into a sealed box", function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 3, 2))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-3.5, -0.5, -3.5), Vec3(3.5, 0, 3.5))
		add_slab(polygon3d, created, Vec3(-3.5, 0, -3.5), Vec3(-3, 6, 3.5))
		add_slab(polygon3d, created, Vec3(3, 0, -3.5), Vec3(3.5, 6, 3.5))
		add_slab(polygon3d, created, Vec3(-3, 0, -3.5), Vec3(3, 6, -3))
		add_slab(polygon3d, created, Vec3(-3, 0, 3), Vec3(3, 6, 3.5))
		return add_slab(polygon3d, created, Vec3(-3.5, 6, -3.5), Vec3(3.5, 6.5, 3.5))
	end, function(gi_average, roof)
		local sealed = gi_average(5)
		roof:Remove()
		local open = gi_average(5)
		T(open > 0)["=="](true)
		T(sealed <= open * 0.01)["=="](true)
	end)

	test("does not leak through thin walls standing on the ground", function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 1.5, 2))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-50, -1, -50), Vec3(50, 0, 50))
		add_slab(polygon3d, created, Vec3(-3, 0, -3), Vec3(3, 0.1, 3))
		add_slab(polygon3d, created, Vec3(-3.03, 0, -3.03), Vec3(-3, 3, 3.03))
		add_slab(polygon3d, created, Vec3(3, 0, -3.03), Vec3(3.03, 3, 3.03))
		add_slab(polygon3d, created, Vec3(-3, 0, -3.03), Vec3(3, 3, -3))
		add_slab(polygon3d, created, Vec3(-3, 0, 3), Vec3(3, 3, 3.03))
		return add_slab(polygon3d, created, Vec3(-3.03, 3, -3.03), Vec3(3.03, 3.03, 3.03))
	end, function(gi_average, roof)
		local sealed = gi_average(5)
		roof:Remove()
		local open = gi_average(5)
		T(open > 0)["=="](true)
		T(sealed <= open * 0.01)["=="](true)
	end)

	test("point light outside a sealed room does not light it", function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 3, 2))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-6, -3, -6), Vec3(6, 0, 6))
		add_slab(polygon3d, created, Vec3(-6, 0, -6), Vec3(-3, 6, 6))
		add_slab(polygon3d, created, Vec3(3, 0, -6), Vec3(6, 6, 6))
		add_slab(polygon3d, created, Vec3(-3, 0, -6), Vec3(3, 6, -3))
		add_slab(polygon3d, created, Vec3(-3, 0, 3), Vec3(3, 6, 6))
		add_slab(polygon3d, created, Vec3(-6, 6, -6), Vec3(6, 9, 6))
		return add_light(created)
	end, function(gi_average, light)
		local function lit_by(position)
			light.transform:SetPosition(position)
			gi.ResetHistory()
			return gi_average(4)
		end

		local none = lit_by(Vec3(0, 3, -1000))
		local outside = lit_by(Vec3(0, 3, -7))
		local inside = lit_by(Vec3(0, 3, -2))
		T(inside > none)["=="](true)
		T(outside - none <= inside * 0.02)["=="](true)
	end)

	test("light behind a thin partition does not light the room next to it", function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(3, 2, 3))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		local t = 0.15
		add_slab(polygon3d, created, Vec3(-6, -t, -4), Vec3(6, 0, 4))
		add_slab(polygon3d, created, Vec3(-6, 4, -4), Vec3(6, 4 + t, 4))
		add_slab(polygon3d, created, Vec3(-6, 0, -4), Vec3(6, 4, -4 + t))
		add_slab(polygon3d, created, Vec3(-6, 0, 4 - t), Vec3(6, 4, 4))
		add_slab(polygon3d, created, Vec3(-6, 0, -4), Vec3(-6 + t, 4, 4))
		add_slab(polygon3d, created, Vec3(6 - t, 0, -4), Vec3(6, 4, 4))
		add_slab(polygon3d, created, Vec3(-t / 2, 0, -4), Vec3(t / 2, 4, 4))
		return add_light(created)
	end, function(gi_average, light)
		local function lit_by(position)
			light.transform:SetPosition(position)
			gi.ResetHistory()
			return gi_average(8)
		end

		local none = lit_by(Vec3(0, 3, -1000))
		local behind = lit_by(Vec3(-0.5, 2, 0))
		local inside = lit_by(Vec3(3, 2, 0))
		T(inside > none)["=="](true)
		T(behind - none <= inside * 0.02)["=="](true)
	end)

	local function plane_room(name, center, double_sided, half, height, on_ground, max_ratio)
		test(name, function(polygon3d, created, polygons)
			render3d.camera:SetPosition(center + Vec3(0, 2, 2))
			render3d.camera:SetAngles{x = 0, y = 0, z = 0}

			if on_ground then
				render3d.camera:SetPosition(center + Vec3(0, 4, 12))
				render3d.camera:SetAngles(Ang3(-0.3, 0, 0))
				add_slab(polygon3d, created, Vec3(-50, -1, -50), Vec3(50, 0, 50))
			end

			return add_plane_room(created, polygons, center, half, height, double_sided, on_ground and 0.4 or 0.8)
		end, function(gi_average, ceiling)
			if on_ground then
				gi_average(60)
				render3d.camera:SetPosition(center + Vec3(-3.22, 2, 2.72))
				render3d.camera:SetAngles(Ang3(-0.173, -0.833, 0))
			end

			local sealed = gi_average(60)
			ceiling:Remove()
			local open = gi_average(60)
			T(open > 0)["=="](true)
			T(sealed <= open * (max_ratio or 0.002))["=="](true)
		end)
	end

	plane_room(
		"does not leak into a sealed room of planes on the grid",
		Vec3(0, 0, 0),
		false,
		4,
		4
	)
	plane_room(
		"does not leak into a sealed room of planes between the grid",
		Vec3(0.13, 0.07, -0.21),
		false,
		4,
		4
	)
	plane_room(
		"does not leak into a sealed room of double sided planes",
		Vec3(0.13, 0.07, -0.21),
		true,
		4,
		4
	)
	plane_room(
		"does not leak into a big sealed room of double sided planes",
		Vec3(0.13, 0.07, -0.21),
		true,
		14,
		10
	)
	plane_room(
		"does not leak into a sealed room of planes on the ground entered from outside",
		Vec3(0.13, 0.01, -0.21),
		false,
		4,
		5,
		true,
		1e-5
	)

	test(
		"ambient occlusion under a ceiling is not black",
		function(polygon3d, created)
			render3d.camera:SetPosition(Vec3(0, 1, 0))
			render3d.camera:SetAngles{x = -80, y = 0, z = 0}
			add_slab(polygon3d, created, Vec3(-4, 3, -4), Vec3(4, 3.5, 4))
		end,
		function(gi_average)
			gi_average(20)
			local downloaded = render3d.pipelines.ambient_occlusion:GetFramebuffer(1):GetAttachment(1):Download()
			local sum, count = 0, 0

			for y = downloaded.height * 0.25, downloaded.height * 0.75, 8 do
				for x = downloaded.width * 0.25, downloaded.width * 0.75, 8 do
					local _, _, _, ao = downloaded:GetPixelFloat(math.floor(x), math.floor(y))
					sum = sum + ao
					count = count + 1
				end
			end

			T(sum / count > 0.5)["=="](true)
		end,
		true
	)
end
