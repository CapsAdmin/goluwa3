local T = import("test/environment.lua")
local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")

-- mean of each channel of the screen gi, sampled on a coarse grid
local function gi_mean()
	local downloaded = ddgi.GetScreenTexture():Download()
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

T.Test3D("Graphics render3d ddgi produces a screen gi texture", function(draw)
	local original_backend = render3d.gi_backend
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local created = {}
	-- build a bundle that routes GI through DDGI
	render3d.gi_backend = "ddgi"
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/ddgi.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	local function restore()
		for _, e in ipairs(created) do
			if e:IsValid() then e:Remove() end
		end

		render3d.gi_backend = original_backend
		render3d.Initialize{
			passes = {
				import("goluwa/render3d/passes/gbuffer.lua"),
				import("goluwa/render3d/passes/blit.lua"),
			},
		}
		polygon3d:Remove()
	end

	local ok, err = pcall(function()
		render3d.camera:SetPosition(Vec3(0, 4, 10))
		render3d.camera:SetAngles{x = -15, y = 0, z = 0}
		local ent = Entity.New{Name = "ddgi_box"}
		created[#created + 1] = ent
		ent:AddComponent("transform")
		ent.transform:SetPosition(Vec3(0, 0, 0))
		ent.transform:SetScale(Vec3(2, 2, 2))
		ent:AddComponent("visual")
		local p = Entity.New{Name = "ddgi_box_p", Parent = ent}
		created[#created + 1] = p
		p:AddComponent("transform")
		p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
		p.visual_primitive:SetMaterial(Material.New{Color = Color(0.8, 0.8, 0.8, 1), Roughness = 0.9})
		ent.visual:BuildAABB()
		import("goluwa/render3d/scene_bvh.lua").Build()
		T(render3d.GetGIProvider() == ddgi)["=="](true)
		T(ddgi.IsActive())["=="](true)
		T(render3d.pipelines.ddgi_irradiance ~= nil)["=="](true)
		T(render3d.pipelines.ddgi_resolve ~= nil)["=="](true)
		draw()
		T(ddgi.GetScreenTexture() ~= nil)["=="](true)
		-- a single box under open sky: most of what the probes see is sky
		local _, _, _, sky_visibility = gi_mean()
		T(sky_visibility > 0)["=="](true)
	end)
	restore()

	if not ok then error(err, 0) end
end)

do
	local function use_ddgi()
		render3d.gi_backend = "ddgi"
		render3d.Initialize{
			passes = {
				import("goluwa/render3d/passes/gbuffer.lua"),
				import("goluwa/render3d/passes/ddgi.lua"),
				import("goluwa/render3d/passes/lighting.lua"),
				import("goluwa/render3d/passes/blit.lua"),
			},
		}
	end

	local function restore(original_backend)
		render3d.gi_backend = original_backend
		render3d.Initialize{
			passes = {
				import("goluwa/render3d/passes/gbuffer.lua"),
				import("goluwa/render3d/passes/blit.lua"),
			},
		}
	end

	-- a slab from the unit cube (which spans -1..1) covering min..max
	local function add_slab(polygon3d, created, min, max)
		local ent = Entity.New{Name = "ddgi_slab"}
		created[#created + 1] = ent
		ent:AddComponent("transform")
		ent.transform:SetPosition((min + max) * 0.5)
		ent.transform:SetScale((max - min) * 0.5)
		ent:AddComponent("visual")
		local p = Entity.New{Name = "ddgi_slab_p", Parent = ent}
		p:AddComponent("transform")
		p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
		p.visual_primitive:SetMaterial(Material.New{ColorMultiplier = Color(0.8, 0.8, 0.8, 1)})
		ent.visual:BuildAABB()
	end

	T.Test3D("Graphics render3d ddgi rays hit scene geometry", function(draw)
		if not ddgi.RTSupported() then return end

		local original_backend = render3d.gi_backend
		local polygon3d = Polygon3D.New()
		polygon3d:CreateCube(1)
		polygon3d:BuildBoundingBox()
		polygon3d:Upload()
		local created = {}
		use_ddgi()
		render3d.camera:SetPosition(Vec3(0, 4, 10))
		add_slab(polygon3d, created, Vec3(-100, -1, -100), Vec3(100, 0, 100))
		import("goluwa/render3d/scene_bvh.lua").Build()
		local ok, err = pcall(function()
			draw()
			local state = ddgi.GetFrameState()
			local P = ddgi.PROBES_PER_AXIS
			local hits = ffi.cast("float*", ddgi.GetRayHitBuffer():Map(0, ddgi.GetRayHitBuffer():GetSize()))
			-- the probe at world coordinate (0, 2, 0) sits this high above the floor
			local height = 2 * ddgi.PROBE_SPACING
			local probe = 0 + P * (2 + P * 0)

			for ray = 0, ddgi.RAYS_PER_PROBE - 1 do
				local _, dy = ddgi.GetRayDirection(ray, state.rotation)
				local hit_t = hits[(probe * ddgi.RAYS_PER_PROBE + ray) * 2]

				-- rays shallow enough to run off the 100 m floor's edge are skipped
				if dy < -0.1 then
					T(hit_t)["~"](height / -dy, 0.01 * height / -dy)
				elseif dy > 1e-3 then
					T(hit_t)["=="](-1)
				end
			end
		end)

		for _, e in ipairs(created) do
			e:Remove()
		end

		restore(original_backend)
		polygon3d:Remove()

		if not ok then error(err, 0) end
	end)

	-- Light must not reach the inside of a closed box through its walls, while
	-- the same box with its roof removed is lit by the sky.
	T.Test3D("Graphics render3d ddgi does not leak into a sealed box", function(draw)
		if not ddgi.RTSupported() then return end

		local original_backend = render3d.gi_backend
		local polygon3d = Polygon3D.New()
		polygon3d:CreateCube(1)
		polygon3d:BuildBoundingBox()
		polygon3d:Upload()
		local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
		local created = {}
		use_ddgi()
		render3d.camera:SetPosition(Vec3(0, 3, 2))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-3.5, -0.5, -3.5), Vec3(3.5, 0, 3.5))
		add_slab(polygon3d, created, Vec3(-3.5, 0, -3.5), Vec3(-3, 6, 3.5))
		add_slab(polygon3d, created, Vec3(3, 0, -3.5), Vec3(3.5, 6, 3.5))
		add_slab(polygon3d, created, Vec3(-3, 0, -3.5), Vec3(3, 6, -3))
		add_slab(polygon3d, created, Vec3(-3, 0, 3), Vec3(3, 6, 3.5))
		add_slab(polygon3d, created, Vec3(-3.5, 6, -3.5), Vec3(3.5, 6.5, 3.5))
		local roof = created[#created]
		scene_bvh.Build()

		local function gi_average()
			for _ = 1, 4 do
				draw()
			end

			local r, g, b = gi_mean()
			return r + g + b
		end

		local ok, err = pcall(function()
			local sealed = gi_average()
			roof:Remove()
			scene_bvh.Build()
			local open = gi_average()
			T(open > 0)["=="](true)
			T(sealed <= open * 0.01)["=="](true)
		end)

		for _, e in ipairs(created) do
			if e:IsValid() then e:Remove() end
		end

		restore(original_backend)
		polygon3d:Remove()

		if not ok then error(err, 0) end
	end)
end

return T
