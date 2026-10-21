local T = import("test/environment.lua")
local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")

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
	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local created = {}
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
		p.visual_primitive:SetMaterial(Material.New{Color = Color(0.8, 0.8, 0.8, 1), Roughness = 0.9, MetallicMultiplier = 0})
		ent.visual:BuildAABB()
		T(render3d.IsPassEnabled("ddgi"))["=="](true)
		T(render3d.pipelines.ddgi_irradiance ~= nil)["=="](true)
		T(render3d.pipelines.ddgi_resolve ~= nil)["=="](true)
		draw()
		T(ddgi.GetScreenTexture() ~= nil)["=="](true)
		local _, _, _, sky_visibility = gi_mean()
		T(sky_visibility > 0)["=="](true)
	end)
	restore()

	if not ok then error(err, 0) end
end)

do
	local function use_ddgi()
		render3d.Initialize{
			passes = {
				import("goluwa/render3d/passes/gbuffer.lua"),
				import("goluwa/render3d/passes/ddgi.lua"),
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
		local ent = Entity.New{Name = "ddgi_slab"}
		created[#created + 1] = ent
		ent:AddComponent("transform")
		ent.transform:SetPosition((min + max) * 0.5)
		ent.transform:SetScale((max - min) * 0.5)
		ent:AddComponent("visual")
		local p = Entity.New{Name = "ddgi_slab_p", Parent = ent}
		p:AddComponent("transform")
		p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
		p.visual_primitive:SetMaterial(Material.New{ColorMultiplier = Color(0.8, 0.8, 0.8, 1), MetallicMultiplier = 0})
		ent.visual:BuildAABB()
	end

	T.Test3D("Graphics render3d ddgi rays hit scene geometry", function(draw)
		local polygon3d = Polygon3D.New()
		shapes.BuildCube(polygon3d, 1)
		polygon3d:BuildBoundingBox()
		polygon3d:Upload()
		local created = {}
		use_ddgi()
		render3d.camera:SetPosition(Vec3(0, 4, 10))
		add_slab(polygon3d, created, Vec3(-100, -1, -100), Vec3(100, 0, 100))
		local ok, err = pcall(function()
			draw()
			local state = ddgi.GetFrameState()
			local hits = ffi.cast("float*", ddgi.GetRayHitBuffer():Map(0, ddgi.GetRayHitBuffer():GetSize()))
			local cascade = state.cascades[1]
			local height = 2 * cascade.spacing
			local probe = 0 + cascade.size.x * (2 + cascade.size.y * 0)

			for ray = 0, ddgi.GetUniformRays() - 1 do
				local _, dy = ddgi.GetRayDirection(ray, ddgi.GetUniformRays(), state.rotation)
				local hit_t = hits[(probe * (ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES) + ray) * 4]

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

		restore()
		polygon3d:Remove()

		if not ok then error(err, 0) end
	end)

	T.Test3D("Graphics render3d ddgi does not leak into a sealed box", function(draw)
		local polygon3d = Polygon3D.New()
		shapes.BuildCube(polygon3d, 1)
		polygon3d:BuildBoundingBox()
		polygon3d:Upload()
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
			local open = gi_average()
			T(open > 0)["=="](true)
			T(sealed <= open * 0.01)["=="](true)
		end)

		for _, e in ipairs(created) do
			if e:IsValid() then e:Remove() end
		end

		restore()
		polygon3d:Remove()

		if not ok then error(err, 0) end
	end)

	T.Test3D("Graphics render3d ddgi point light outside a sealed room does not light it", function(draw)
		local polygon3d = Polygon3D.New()
		shapes.BuildCube(polygon3d, 1)
		polygon3d:BuildBoundingBox()
		polygon3d:Upload()
		local created = {}
		use_ddgi()
		render3d.camera:SetPosition(Vec3(0, 3, 2))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-6, -3, -6), Vec3(6, 0, 6))
		add_slab(polygon3d, created, Vec3(-6, 0, -6), Vec3(-3, 6, 6))
		add_slab(polygon3d, created, Vec3(3, 0, -6), Vec3(6, 6, 6))
		add_slab(polygon3d, created, Vec3(-3, 0, -6), Vec3(3, 6, -3))
		add_slab(polygon3d, created, Vec3(-3, 0, 3), Vec3(3, 6, 6))
		add_slab(polygon3d, created, Vec3(-6, 6, -6), Vec3(6, 9, 6))
		local light = Entity.New{Name = "ddgi_test_light"}
		created[#created + 1] = light
		light:AddComponent("transform")
		light:AddComponent("light_point"):SetLumen(2000000)

		local function gi_average(position)
			light.transform:SetPosition(position)
			ddgi.ResetHistory()

			for _ = 1, 4 do
				draw()
			end

			local r, g, b = gi_mean()
			return r + g + b
		end

		local ok, err = pcall(function()
			local none = gi_average(Vec3(0, 3, -1000))
			local outside = gi_average(Vec3(0, 3, -7))
			local inside = gi_average(Vec3(0, 3, -2))
			T(inside > none)["=="](true)
			T(outside - none <= inside * 0.02)["=="](true)
		end)

		for _, e in ipairs(created) do
			if e:IsValid() then e:Remove() end
		end

		restore()
		polygon3d:Remove()

		if not ok then error(err, 0) end
	end)

	local function add_plane_room(created, polygons, center, half, height, double_sided)
		local planes = {
			{Vec3(0, 0, 0), Vec3(0, 1, 0), half, half},
			{Vec3(0, height, 0), Vec3(0, -1, 0), half, half},
			{Vec3(0, height / 2, -half), Vec3(0, 0, 1), half, height / 2},
			{Vec3(0, height / 2, half), Vec3(0, 0, -1), half, height / 2},
			{Vec3(-half, height / 2, 0), Vec3(1, 0, 0), half, height / 2},
			{Vec3(half, height / 2, 0), Vec3(-1, 0, 0), half, height / 2},
		}
		local material = Material.New{
			ColorMultiplier = Color(0.8, 0.8, 0.8, 1),
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
			local ent = Entity.New{Name = "ddgi_plane"}
			created[#created + 1] = ent
			ent:AddComponent("transform")
			ent.transform:SetPosition(center + plane[1])
			ent:AddComponent("visual")
			local p = Entity.New{Name = "ddgi_plane_p", Parent = ent}
			p:AddComponent("transform")
			p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
			p.visual_primitive:SetMaterial(material)
			ent.visual:BuildAABB()

			if i == 2 then ceiling = ent end
		end

		return ceiling
	end

	local function test_plane_room(name, center, double_sided, half, height)
		T.Test3D(name, function(draw)
			local created, polygons = {}, {}
			use_ddgi()
			render3d.camera:SetPosition(center + Vec3(0, 2, 2))
			render3d.camera:SetAngles{x = 0, y = 0, z = 0}
			local ceiling = add_plane_room(created, polygons, center, half, height, double_sided)

			local function gi_average()
				for _ = 1, 60 do
					draw()
				end

				local r, g, b = gi_mean()
				return r + g + b
			end

			local ok, err = pcall(function()
				local sealed = gi_average()
				ceiling:Remove()
				local open = gi_average()
				T(open > 0)["=="](true)
				T(sealed <= open * 0.002)["=="](true)
			end)

			for _, e in ipairs(created) do
				if e:IsValid() then e:Remove() end
			end

			restore()

			for _, polygon3d in ipairs(polygons) do
				polygon3d:Remove()
			end

			if not ok then error(err, 0) end
		end)
	end

	test_plane_room(
		"Graphics render3d ddgi does not leak into a sealed room of planes on the probe grid",
		Vec3(0, 0, 0),
		false,
		4,
		4
	)
	test_plane_room(
		"Graphics render3d ddgi does not leak into a sealed room of planes between the probes",
		Vec3(0.13, 0.07, -0.21),
		false,
		4,
		4
	)
	test_plane_room(
		"Graphics render3d ddgi does not leak into a sealed room of double sided planes",
		Vec3(0.13, 0.07, -0.21),
		true,
		4,
		4
	)
	test_plane_room(
		"Graphics render3d ddgi does not leak into a big sealed room of double sided planes",
		Vec3(0.13, 0.07, -0.21),
		true,
		14,
		10
	)

	T.Test3D("Graphics render3d ddgi light behind a thin partition does not light the room next to it", function(draw)
		local polygon3d = Polygon3D.New()
		shapes.BuildCube(polygon3d, 1)
		polygon3d:BuildBoundingBox()
		polygon3d:Upload()
		local created = {}
		use_ddgi()
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
		local light = Entity.New{Name = "ddgi_test_light"}
		created[#created + 1] = light
		light:AddComponent("transform")
		light:AddComponent("light_point"):SetLumen(2000000)

		local function gi_average(position)
			light.transform:SetPosition(position)
			ddgi.ResetHistory()

			for _ = 1, 8 do
				draw()
			end

			local r, g, b = gi_mean()
			return r + g + b
		end

		local ok, err = pcall(function()
			local none = gi_average(Vec3(0, 3, -1000))
			local behind = gi_average(Vec3(-0.5, 2, 0))
			local inside = gi_average(Vec3(3, 2, 0))
			T(inside > none)["=="](true)
			T(behind - none <= inside * 0.02)["=="](true)
		end)

		for _, e in ipairs(created) do
			if e:IsValid() then e:Remove() end
		end

		restore()
		polygon3d:Remove()

		if not ok then error(err, 0) end
	end)

	T.Test3D("Graphics render3d ddgi a room lit through a pinhole is as bright as its slow average", function(draw)
		local polygon3d = Polygon3D.New()
		shapes.BuildCube(polygon3d, 1)
		polygon3d:BuildBoundingBox()
		polygon3d:Upload()
		local created = {}
		use_ddgi()
		render3d.camera:SetPosition(Vec3(0, 2, 3))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		local gap = 0.1
		add_slab(polygon3d, created, Vec3(-30, -0.5, -30), Vec3(30, 0, 30))
		add_slab(polygon3d, created, Vec3(-6, 0, -6), Vec3(-5.6, 5, 6))
		add_slab(polygon3d, created, Vec3(5.6, 0, -6), Vec3(6, 5, 6))
		add_slab(polygon3d, created, Vec3(-5.6, 0, -6), Vec3(5.6, 5, -5.6))
		add_slab(polygon3d, created, Vec3(-5.6, 0, 5.6), Vec3(5.6, 5, 6))
		add_slab(polygon3d, created, Vec3(-6, 5, -6), Vec3(6, 5.4, -gap / 2))
		add_slab(polygon3d, created, Vec3(-6, 5, gap / 2), Vec3(6, 5.4, 6))
		add_slab(polygon3d, created, Vec3(-6, 5, -gap / 2), Vec3(-gap / 2, 5.4, gap / 2))
		add_slab(polygon3d, created, Vec3(gap / 2, 5, -gap / 2), Vec3(6, 5.4, gap / 2))
		local pvars = import("goluwa/cli/pvars.lua")

		local function gi_average(frames)
			ddgi.ResetHistory()

			for _ = 1, frames do
				draw()
			end

			local sum = 0

			for _ = 1, 12 do
				draw()
				local r, g, b = gi_mean()
				sum = sum + r + g + b
			end

			return sum / 12
		end

		local ok, err = pcall(function()
			local default = (gi_average(600) + gi_average(600) + gi_average(600)) / 3
			pvars.SetSession("ddgi_hysteresis", 0.998)
			pvars.SetSession("ddgi_change_power", 1)
			local slow = gi_average(1500)
			T(slow > 0)["=="](true)
			T(default >= slow * 0.7)["=="](true)
			T(default <= slow * 1.35)["=="](true)
		end)
		pvars.SetSession("ddgi_hysteresis", 0.99)
		pvars.SetSession("ddgi_change_power", 4)

		for _, e in ipairs(created) do
			if e:IsValid() then e:Remove() end
		end

		restore()
		polygon3d:Remove()

		if not ok then error(err, 0) end
	end)

	T.Test3D("Graphics render3d ddgi small emitter lights a sealed room", function(draw)
		local polygon3d = Polygon3D.New()
		shapes.BuildCube(polygon3d, 1)
		polygon3d:BuildBoundingBox()
		polygon3d:Upload()
		local created = {}
		use_ddgi()
		render3d.camera:SetPosition(Vec3(0, 3, 2))
		render3d.camera:SetAngles{x = 0, y = 0, z = 0}
		add_slab(polygon3d, created, Vec3(-6, -3, -6), Vec3(6, 0, 6))
		add_slab(polygon3d, created, Vec3(-6, 0, -6), Vec3(-3, 6, 6))
		add_slab(polygon3d, created, Vec3(3, 0, -6), Vec3(6, 6, 6))
		add_slab(polygon3d, created, Vec3(-3, 0, -6), Vec3(3, 6, -3))
		add_slab(polygon3d, created, Vec3(-3, 0, 3), Vec3(3, 6, 6))
		add_slab(polygon3d, created, Vec3(-6, 6, -6), Vec3(6, 9, 6))
		local emitter = Entity.New{Name = "ddgi_test_emitter"}
		created[#created + 1] = emitter
		emitter:AddComponent("transform")
		emitter.transform:SetPosition(Vec3(0, 1.5, 2.3))
		emitter.transform:SetScale(Vec3(0.05, 0.05, 0.05))
		emitter:AddComponent("visual")
		local p = Entity.New{Name = "ddgi_test_emitter_p", Parent = emitter}
		p:AddComponent("transform")
		p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
		p.visual_primitive:SetMaterial(
			Material.New{
				ColorMultiplier = Color(1, 1, 1, 1),
				MetallicMultiplier = 0,
				AlbedoAlphaIsEmissive = true,
				EmissiveMultiplier = Color(1, 1, 1, 30),
			}
		)
		emitter.visual:BuildAABB()

		local function gi_average(position, draws)
			emitter.transform:SetPosition(position)
			ddgi.ResetHistory()

			for _ = 1, draws do
				draw()
			end

			local r, g, b = gi_mean()
			return r + g + b
		end

		local ok, err = pcall(function()
			local outside = Vec3(0, 1.5, -1000)
			gi_average(outside, 6)
			local before = gi_average(outside, 3)
			local version = ddgi.GetEmitters().version
			local lit = gi_average(Vec3(0, 1.5, 2.3), 3)
			local emitters = ddgi.GetEmitters()
			T(emitters.version)["=="](version)
			local weight, count = import("goluwa/render3d/scene/emitters.lua").ReadBackHeader()
			T(emitters.count)["=="](12)
			T(count)["=="](12)
			T(weight)["~"](6 * 0.01 * 30, 1e-3)
			local after = gi_average(outside, 3)
			T(lit > math.max(before, after) * 3)["=="](true)
		end)

		for _, e in ipairs(created) do
			if e:IsValid() then e:Remove() end
		end

		restore()
		polygon3d:Remove()

		if not ok then error(err, 0) end
	end)
end

T.Test3D("Graphics render3d ddgi material buffer marks materials without an albedo texture", function(draw)
	local ffi = require("ffi")
	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local material = Material.New{ColorMultiplier = Color(0.25, 0.5, 0.75, 1)}
	local ent = Entity.New{Name = "ddgi_material_box"}
	ent:AddComponent("transform")
	ent:AddComponent("visual")
	local p = Entity.New{Name = "ddgi_material_box_p", Parent = ent}
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
	p.visual_primitive:SetMaterial(material)
	ent.visual:BuildAABB()
	local ok, err = pcall(function()
		local id = import("goluwa/render3d/scene/materials.lua").GetID(material)
		local releases = 0
		local pipeline = {
			GetTextureIndex = function()
				return 7
			end,
			GetTextureIndexReleases = function()
				return releases
			end,
		}
		local buffer = ddgi.WriteMaterialBuffer(pipeline)
		local entry = ffi.cast(ffi.typeof("$ *", ddgi.MaterialEntry), buffer:Map(0, buffer:GetSize())) + id
		T(entry.albedo[2])["=="](0.75)
		T(entry.albedo_tex)["=="](-1)
		T(entry.metallic)["=="](1)
		T(entry.metallic_tex)["=="](-1)
		material:SetMetallicMultiplier(0.5)
		ddgi.WriteMaterialBuffer(pipeline)
		T(entry.metallic)["=="](0.5)
		T(entry.roughness)["=="](1)
		T(entry.roughness_tex)["=="](-1)
		material:SetRoughnessMultiplier(0.25)
		ddgi.WriteMaterialBuffer(pipeline)
		T(entry.roughness)["=="](0.25)
		entry.double_sided = 99
		T(ddgi.WriteMaterialBuffer(pipeline) == buffer)["=="](true)
		T(entry.double_sided)["=="](99)
		material:SetColorMultiplier(Color(1, 0.5, 0.125, 1))
		ddgi.WriteMaterialBuffer(pipeline)
		T(entry.albedo[2])["=="](0.125)
		T(entry.double_sided)["=="](0)
		entry.double_sided = 99
		releases = releases + 1
		ddgi.WriteMaterialBuffer(pipeline)
		T(entry.double_sided)["=="](0)
	end)
	ent:Remove()
	polygon3d:Remove()

	if not ok then error(err, 0) end
end)

return T
