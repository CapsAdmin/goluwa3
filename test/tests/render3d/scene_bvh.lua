-- The per-visual cache and the lazy top tree in scene_bvh are pure
-- optimizations: they decide what to recompute, not what the result is. So
-- a warm (incremental, lazy top) build and a cold (full) build of the same
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
		ffi.string(scene_bvh.triangles, scene_bvh.triangle_count * TRI_BYTES)
	end

	-- cold build: the cache is empty, everything is derived from scratch and
	-- the top tree gets a fresh sah
	scene_bvh.visual_cache = {}
	scene_bvh.Build()
	local nodes_a = snapshot()
	T(scene_bvh.triangle_count == 72)["=="](true)
	T(tree_valid(scene_bvh.debug_nodes))["=="](true)
	-- move the mover, then a warm build: static visuals reuse their cached
	-- blocks, the mover is re-derived, and the top tree takes the lazy path
	-- (bounds re-derived, split structure kept)
	mover.transform:SetPosition(Vec3(6, 4, -6))
	scene_bvh.Build()
	local nodes_b, tris_b = snapshot()
	local node_count_b = scene_bvh.debug_node_count
	local root_bounds_b = ffi.string(ffi.cast("float*", scene_bvh.debug_nodes) + 2, 24)
	T(scene_bvh.top_lazy_count == 1)["=="](true)
	T(tree_valid(scene_bvh.debug_nodes))["=="](true)
	-- full rebuild of the same scene state (forced, bypasses the lazy path)
	scene_bvh.Build(true)
	local nodes_c, tris_c = snapshot()
	local node_count_c = scene_bvh.debug_node_count
	local root_bounds_c = ffi.string(ffi.cast("float*", scene_bvh.debug_nodes) + 2, 24)
	T(scene_bvh.top_lazy_count == 0)["=="](true)
	T(tree_valid(scene_bvh.debug_nodes))["=="](true)
	-- the triangle soup is independent of the top tree shape
	T(tris_b == tris_c)["=="](true)
	-- both trees cover the same geometry
	T(node_count_b == node_count_c)["=="](true)
	T(root_bounds_b == root_bounds_c)["=="](true)
	-- the lazy tree is not required to match the fresh sah byte for byte,
	-- but the move must have changed the tree
	T(nodes_b ~= nodes_a)["=="](true)

	for _, ent in ipairs(ents) do
		ent:Remove()
	end
end)
