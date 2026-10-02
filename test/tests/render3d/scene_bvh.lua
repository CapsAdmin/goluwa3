-- The per-visual cache, the stable per-visual ranges and the incrementally
-- updated top tree in scene_bvh are pure optimizations: they decide what to
-- recompute, not what the result is. So a warm (incremental) build and a
-- cold (full) build of the same
-- scene state must produce the same triangle soup, the same node count, the
-- same global bounds, and both node trees must be valid (every node's bounds
-- enclose its children). If that ever breaks, occlusion and shadows silently
-- diverge from what a full rebuild would produce.
local T = import("test/environment.lua")
local ffi = require("ffi")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
-- must match the node/triangle struct layout in scene_bvh
local TRI_BYTES = 64

-- every node's bounds must enclose the bounds of both children (internal
-- nodes only; a sentinel has inverted bounds and is never descended into).
-- an invalid tree means some ray could be culled that should have hit
local function tree_valid(nodes)
	local root = nodes[0]

	if root.bounds_max[0] < root.bounds_min[0] then return false end

	local stack = {}
	local top = 1
	stack[1] = 0
	local eps = 1e-4

	local function contains(parent, child)
		return child.bounds_min[0] >= parent.bounds_min[0] - eps and
			child.bounds_min[1] >= parent.bounds_min[1] - eps and
			child.bounds_min[2] >= parent.bounds_min[2] - eps and
			child.bounds_max[0] <= parent.bounds_max[0] + eps and
			child.bounds_max[1] <= parent.bounds_max[1] + eps and
			child.bounds_max[2] <= parent.bounds_max[2] + eps
	end

	while top > 0 do
		local node = nodes[stack[top]]
		top = top - 1

		if node.bounds_max[0] >= node.bounds_min[0] and node.count == 0 then
			local left = node.left_first
			local lc = nodes[left]
			local rc = nodes[left + 1]

			if lc.bounds_max[0] >= lc.bounds_min[0] and not contains(node, lc) then
				return false
			end

			if rc.bounds_max[0] >= rc.bounds_min[0] and not contains(node, rc) then
				return false
			end

			stack[top + 1] = left
			stack[top + 2] = left + 1
			top = top + 2
		end
	end

	return true
end

T.Test3D("Graphics render3d scene bvh incremental build matches full rebuild", function(draw)
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local ents = {}

	local function add_box(name, pos, scale, emissive)
		local ent = Entity.New{Name = name}
		ent:AddComponent("transform")
		ent.transform:SetPosition(pos)
		ent.transform:SetScale(Vec3(scale, scale, scale))
		ent:AddComponent("visual")
		local p = Entity.New{Name = name .. "_p", Parent = ent}
		p:AddComponent("transform")
		p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
		local config = {
			Color = Color(0.8, 0.8, 0.8, 1),
			Roughness = 0.9,
		}

		if emissive then
			config.AlbedoAlphaIsEmissive = true
			config.EmissiveMultiplier = Color(1, 0.5, 0.2, 8)
		end

		p.visual_primitive:SetMaterial(Material.New(config))
		ent.visual:BuildAABB()
		ents[#ents + 1] = ent
		return ent
	end

	add_box("sbvh_static_a", Vec3(0, 0, 0), 2)
	add_box("sbvh_static_b", Vec3(4, 1, 0), 1)
	add_box("sbvh_static_c", Vec3(-4, 0, 2), 1.5)
	add_box("sbvh_static_d", Vec3(8, 0, -3), 3)
	add_box("sbvh_static_e", Vec3(-8, 2, -4), 2, true)
	local mover = add_box("sbvh_mover", Vec3(0, 0, 10), 1)
	draw()

	local function snapshot()
		return ffi.string(scene_bvh.debug_nodes, scene_bvh.debug_node_count * 32),
		ffi.string(scene_bvh.triangles, scene_bvh.soup_triangle_count * TRI_BYTES)
	end

	-- cold build: the soup is laid out from scratch and the top tree gets a
	-- fresh sah
	scene_bvh.Build(true)
	local nodes_a = snapshot()
	T(scene_bvh.triangle_count == 72)["=="](true)
	T(tree_valid(scene_bvh.debug_nodes))["=="](true)
	-- move the mover, then a warm build: static visuals keep their blocks,
	-- the mover is baked again in place, and the top tree is refitted (split
	-- structure kept)
	mover.transform:SetPosition(Vec3(6, 4, -6))
	scene_bvh.Build()
	local nodes_b, tris_b = snapshot()
	local node_count_b = scene_bvh.debug_node_count
	local root_bounds_b = ffi.string(ffi.cast("float*", scene_bvh.debug_nodes) + 2, 24)
	T(scene_bvh.top_incremental_count == 1)["=="](true)
	T(tree_valid(scene_bvh.debug_nodes))["=="](true)
	-- full rebuild of the same scene state
	scene_bvh.Build(true)
	local nodes_c, tris_c = snapshot()
	local node_count_c = scene_bvh.debug_node_count
	local root_bounds_c = ffi.string(ffi.cast("float*", scene_bvh.debug_nodes) + 2, 24)
	T(scene_bvh.top_incremental_count == 0)["=="](true)
	T(tree_valid(scene_bvh.debug_nodes))["=="](true)
	-- the triangle soup is independent of the top tree shape
	T(tris_b == tris_c)["=="](true)
	-- both trees cover the same geometry
	T(node_count_b == node_count_c)["=="](true)
	T(root_bounds_b == root_bounds_c)["=="](true)
	-- the refitted tree is not required to match the fresh sah byte for byte,
	-- but the move must have changed the tree
	T(nodes_b ~= nodes_a)["=="](true)

	for _, ent in ipairs(ents) do
		ent:Remove()
	end
end)

-- instances of one mesh share their local soup and child tree, so each block
-- has to come out of the bake with its own transform and material
T.Test3D("Graphics render3d scene bvh instances share shapes but keep their transforms", function(draw)
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local plain = Material.New{Color = Color(0.8, 0.8, 0.8, 1)}
	local glowing = Material.New{
		Color = Color(0.8, 0.8, 0.8, 1),
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 0.5, 0.2, 8),
	}
	local cases = {
		{pos = Vec3(0, 0, 0), scale = 2, material = plain},
		{pos = Vec3(10, 3, -2), scale = 1, material = glowing},
		{pos = Vec3(-6, 1, 5), scale = 4, material = plain},
	}

	for i, case in ipairs(cases) do
		local ent = Entity.New{Name = "sbvh_instance_" .. i}
		ent:AddComponent("transform")
		ent.transform:SetPosition(case.pos)
		ent.transform:SetScale(Vec3(case.scale, case.scale, case.scale))
		ent:AddComponent("visual")
		local p = Entity.New{Name = "sbvh_instance_p_" .. i, Parent = ent}
		p:AddComponent("transform")
		p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
		p.visual_primitive:SetMaterial(case.material)
		ent.visual:BuildAABB()
		case.ent = ent
	end

	draw()

	local function check()
		local shape

		for _, case in ipairs(cases) do
			local vc = scene_bvh.visual_cache[case.ent.visual]
			shape = shape or vc.shape
			T(vc.shape == shape)["=="](true)
			local min_x, min_y, min_z = math.huge, math.huge, math.huge
			local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
			local emissive = 0

			for i = 0, vc.total - 1 do
				local tri = scene_bvh.triangles[vc.tri_base + i]

				for _, c in ipairs{0, 1, 2} do
					for _, v in ipairs{
						tri.v0[c],
						tri.v0[c] + tri.e1[c],
						tri.v0[c] + tri.e2[c],
					} do
						if c == 0 then
							min_x, max_x = math.min(min_x, v), math.max(max_x, v)
						elseif c == 1 then
							min_y, max_y = math.min(min_y, v), math.max(max_y, v)
						else
							min_z, max_z = math.min(min_z, v), math.max(max_z, v)
						end
					end
				end

				emissive = emissive + tri.emissive[0]
			end

			local pos = case.ent.transform:GetPosition()
			local half = case.scale
			T(math.abs(min_x - (pos.x - half)) < 1e-3)["=="](true)
			T(math.abs(max_x - (pos.x + half)) < 1e-3)["=="](true)
			T(math.abs(min_y - (pos.y - half)) < 1e-3)["=="](true)
			T(math.abs(max_y - (pos.y + half)) < 1e-3)["=="](true)
			T(math.abs(min_z - (pos.z - half)) < 1e-3)["=="](true)
			T(math.abs(max_z - (pos.z + half)) < 1e-3)["=="](true)
		end
	end

	scene_bvh.Build(true)
	check()
	cases[1].ent.transform:SetPosition(Vec3(3, -2, 7))
	scene_bvh.Build()
	check()

	for _, case in ipairs(cases) do
		case.ent:Remove()
	end
end)

-- the frustum walk of the top tree marks a subtree inside the planes from a
-- cached run of its leaves. it has to mark exactly the blocks a test of every
-- block's bounds against the planes does, after the tree grew, lost blocks
-- and had blocks moved
T.Test3D("Graphics render3d scene bvh frustum marks match testing every block", function(draw)
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local material = Material.New{Color = Color(0.8, 0.8, 0.8, 1)}
	local ents = {}
	local seed = 12345

	local function random()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end

	local function add(i)
		local ent = Entity.New{Name = "sbvh_frustum_" .. i}
		ent:AddComponent("transform")
		ent.transform:SetPosition(Vec3(random() * 400 - 200, random() * 60, random() * 400 - 200))
		local s = 1 + random() * 6
		ent.transform:SetScale(Vec3(s, s, s))
		ent:AddComponent("visual")
		local p = Entity.New{Name = "sbvh_frustum_p_" .. i, Parent = ent}
		p:AddComponent("transform")
		p:AddComponent("visual_primitive"):SetPolygon3D(polygon3d)
		p.visual_primitive:SetMaterial(material)
		ent.visual:BuildAABB()
		ents[#ents + 1] = ent
	end

	for i = 1, 300 do
		add(i)
	end

	draw()

	local function check(label)
		local count = #scene_bvh.blocks

		for frustum = 1, 12 do
			local planes = ffi.new("float[24]")

			for p = 0, 5 do
				local nx, ny, nz = random() - 0.5, random() - 0.5, random() - 0.5
				local length = math.sqrt(nx * nx + ny * ny + nz * nz)
				nx, ny, nz = nx / length, ny / length, nz / length
				-- a point inside a box that holds the scene, the planes
				-- cut it at random, a few cut away little of it
				local px, py, pz = random() * 500 - 250, random() * 100 - 20, random() * 500 - 250
				local push = frustum <= 4 and 400 or 0
				planes[p * 4], planes[p * 4 + 1], planes[p * 4 + 2] = nx, ny, nz
				planes[p * 4 + 3] = -(nx * px + ny * py + nz * pz) + push
			end

			scene_bvh.MarkVisibleBlocks(planes)
			local marked = 0

			for i = 0, count - 1 do
				local b = scene_bvh.raster_bounds + i * 6
				local inside = true

				for p = 0, 5 do
					local a, bb, c, d = planes[p * 4], planes[p * 4 + 1], planes[p * 4 + 2], planes[p * 4 + 3]
					local x = a > 0 and b[3] or b[0]
					local y = bb > 0 and b[4] or b[1]
					local z = c > 0 and b[5] or b[2]

					if a * x + bb * y + c * z + d < 0 then
						inside = false

						break
					end
				end

				local got = scene_bvh.raster_visible[i] ~= 0
				scene_bvh.raster_visible[i] = 0
				T(got)["=="](inside)

				if got then marked = marked + 1 end
			end
		end
	end

	scene_bvh.Build(true)
	check("built")

	for i = 1, 100 do
		ents[i]:Remove()
	end

	scene_bvh.Build()
	check("after removing")

	for i = 101, 160 do
		ents[i].transform:SetPosition(Vec3(random() * 400 - 200, random() * 60, random() * 400 - 200))
	end

	scene_bvh.Build()
	check("after moving")

	for i = 301, 360 do
		add(i)
	end

	scene_bvh.Build()
	check("after adding")

	for _, ent in ipairs(ents) do
		if ent:IsValid() then ent:Remove() end
	end
end)
