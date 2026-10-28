local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local gi = import("goluwa/render3d/gi.lua")

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

local function use_surfels()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/surfel_gi.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
end

local function restore()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
end

local function add_slab(polygon3d, created, min, max)
	local ent = Entity.New{Name = "surfel_slab"}
	created[#created + 1] = ent
	ent:AddComponent("transform")
	ent.transform:SetPosition((min + max) * 0.5)
	ent.transform:SetScale((max - min) * 0.5)
	ent:AddComponent("visual")
	local p = Entity.New{Name = "surfel_slab_p", Parent = ent}
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
	p.visual_primitive:SetMaterial(Material.New{ColorMultiplier = Color(0.8, 0.8, 0.8, 1), MetallicMultiplier = 0})
	ent.visual:BuildAABB()
	return ent
end

local function with_scene(draw, build, check)
	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local created = {}
	use_surfels()
	local ok, err = pcall(function()
		build(polygon3d, created)
		check()
	end)

	for _, e in ipairs(created) do
		if e:IsValid() then e:Remove() end
	end

	restore()
	polygon3d:Remove()

	if not ok then error(err, 0) end
end

T.Test3DRayTracing("Graphics render3d surfel gi produces a screen gi texture", function(draw)
	with_scene(draw, function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 4, 10))
		render3d.camera:SetAngles{x = -15, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-50, -1, -50), Vec3(50, 0, 50))
		add_slab(polygon3d, created, Vec3(-1, 0, -1), Vec3(1, 2, 1))
	end, function()
		T(render3d.IsPassEnabled("surfel_gi"))["=="](true)
		T(render3d.IsPassEnabled("ddgi"))["=="](false)
		T(gi.GetMode())["=="]("surfels")

		for _ = 1, 8 do
			draw()
		end

		T(gi.GetScreenTexture() ~= nil)["=="](true)
		local r, g, b, sky_visibility = gi_mean()
		T(r + g + b > 0)["=="](true)
		T(sky_visibility > 0.5)["=="](true)
	end)
end)

T.Test3DRayTracing("Graphics render3d surfel gi does not leak into a sealed box", function(draw)
	local roof

	local function gi_average()
		for _ = 1, 40 do
			draw()
		end

		local r, g, b = gi_mean()
		return r + g + b
	end

	with_scene(draw, function(polygon3d, created)
		render3d.camera:SetPosition(Vec3(0, 3, 2))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-3.5, -0.5, -3.5), Vec3(3.5, 0, 3.5))
		add_slab(polygon3d, created, Vec3(-3.5, 0, -3.5), Vec3(-3, 6, 3.5))
		add_slab(polygon3d, created, Vec3(3, 0, -3.5), Vec3(3.5, 6, 3.5))
		add_slab(polygon3d, created, Vec3(-3, 0, -3.5), Vec3(3, 6, -3))
		add_slab(polygon3d, created, Vec3(-3, 0, 3), Vec3(3, 6, 3.5))
		roof = add_slab(polygon3d, created, Vec3(-3.5, 6, -3.5), Vec3(3.5, 6.5, 3.5))
	end, function()
		local sealed = gi_average()
		roof:Remove()
		local open = gi_average()
		T(open > 0)["=="](true)
		T(sealed <= open * 0.01)["=="](true)
	end)
end)
