local BVH = import("goluwa/physics/bvh.lua")
local stats = import("goluwa/physics/stats.lua")
local AABB = import("goluwa/structs/aabb.lua")
-- Spatial index over the colliders of a big static body (a map is one body
-- with a collider per brush group and displacement). Queries return only the
-- colliders whose bounds overlap an AABB; bodies that are small or can move
-- just hand back their collider list.
local collider_index = {}
local MIN_INDEXED_COLLIDERS = 16
local LEAF_ITEM_COUNT = 4
local BUILD_BOUNDS = AABB(0, 0, 0, 0, 0, 0)
local query_context = {node_stack = {}, aabb = nil, bounds = nil, items = nil, out = nil, count = 0}

local function get_item_bounds(collider)
	return collider.IndexBounds
end

local function get_item_centroid(collider)
	local bounds = collider.IndexBounds
	return (bounds.min_x + bounds.max_x) * 0.5,
	(bounds.min_y + bounds.max_y) * 0.5,
	(bounds.min_z + bounds.max_z) * 0.5
end

local function visit_leaf(node, context, result)
	local items = context.items
	local item_bounds = context.bounds
	local aabb = context.aabb
	local out = context.out
	local count = context.count

	for i = node.first, node.last do
		local bounds = item_bounds[i]

		if
			bounds.max_x >= aabb.min_x and
			bounds.min_x <= aabb.max_x and
			bounds.max_y >= aabb.min_y and
			bounds.min_y <= aabb.max_y and
			bounds.max_z >= aabb.min_z and
			bounds.min_z <= aabb.max_z
		then
			count = count + 1
			out[count] = items[i]
		end
	end

	context.count = count
	return result
end

local function is_index_current(index, body, colliders)
	local position = body.Position
	local rotation = body.Rotation
	return index.colliders == colliders and
		index.collider_count == #colliders and
		index.px == position.x and
		index.py == position.y and
		index.pz == position.z and
		index.rx == rotation.x and
		index.ry == rotation.y and
		index.rz == rotation.z and
		index.rw == rotation.w
end

local function build_index(body, colliders)
	local items = {}

	for i = 1, #colliders do
		local collider = colliders[i]
		local bounds = collider:GetBroadphaseAABB(collider:GetPosition(), collider:GetRotation(), BUILD_BOUNDS)
		collider.IndexBounds = AABB(bounds.min_x, bounds.min_y, bounds.min_z, bounds.max_x, bounds.max_y, bounds.max_z)
		items[i] = collider
	end

	local tree = BVH.Build(items, get_item_bounds, get_item_centroid, LEAF_ITEM_COUNT)
	local item_bounds = {}

	for i = 1, #tree.items do
		item_bounds[i] = tree.items[i].IndexBounds
	end

	local position = body.Position
	local rotation = body.Rotation
	local index = {
		tree = tree,
		bounds = item_bounds,
		colliders = colliders,
		collider_count = #colliders,
		px = position.x,
		py = position.y,
		pz = position.z,
		rx = rotation.x,
		ry = rotation.y,
		rz = rotation.z,
		rw = rotation.w,
	}
	body.ColliderIndex = index
	return index
end

-- Returns list, count. The list is body:GetColliders() itself or `out`, so
-- callers must not modify it and must read it before the next query that
-- uses the same `out`.
function collider_index.Query(body, aabb, out)
	local colliders = body:GetColliders()
	local total = #colliders

	if total < MIN_INDEXED_COLLIDERS or not body:IsStatic() then
		return colliders, total
	end

	local index = body.ColliderIndex

	if not (index and is_index_current(index, body, colliders)) then
		index = build_index(body, colliders)
	end

	local context = query_context
	context.aabb = aabb
	context.bounds = index.bounds
	context.items = index.tree.items
	context.out = out
	context.count = 0
	BVH.TraverseAABB(aabb, index.tree.root, visit_leaf, context, nil)
	local count = context.count

	for i = count + 1, #out do
		out[i] = nil
	end

	context.out = nil
	stats:Count("collider_index_queries")
	stats:Count("collider_index_total", total)
	stats:Count("collider_index_returned", count)
	return out, count
end

return collider_index
