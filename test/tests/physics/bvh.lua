-- BuildFast finds each node's median with quickselect instead of sorting. The
-- tree has to hold every item exactly once, every node's bounds have to hold the
-- items under it, and a box query has to find what testing every item finds
local T = import("test/environment.lua")
local bvh = import("goluwa/physics/bvh.lua")

local function make_items(count, seed)
	local items = {}

	local function random()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end

	for i = 1, count do
		local x, y, z = random() * 500, random() * 80, random() * 500
		local sx, sy, sz = random() * 8, random() * 8, random() * 8

		-- duplicated centroids and flat extents are what make a median split hard
		if i % 7 == 0 then x, y, z, sx, sy, sz = 10, 10, 10, 1, 1, 1 end

		items[i] = {
			id = i,
			bounds = {
				min_x = x,
				min_y = y,
				min_z = z,
				max_x = x + sx,
				max_y = y + sy,
				max_z = z + sz,
			},
		}
	end

	return items, random
end

local function get_bounds(item)
	return item.bounds
end

local function get_centroid(item)
	local b = item.bounds
	return (b.min_x + b.max_x) / 2, (b.min_y + b.max_y) / 2, (b.min_z + b.max_z) / 2
end

local function check_tree(tree, count)
	local seen = {}
	local stack = {tree.root}

	while stack[1] do
		local node = table.remove(stack)

		if node.first then
			for i = node.first, node.last do
				local item = tree.items[i]
				T(seen[item.id])["=="](nil)
				seen[item.id] = true
				local b, a = item.bounds, node.aabb
				T(
					b.min_x >= a.min_x and
						b.min_y >= a.min_y and
						b.min_z >= a.min_z and
						b.max_x <= a.max_x and
						b.max_y <= a.max_y and
						b.max_z <= a.max_z
				)["=="](true)
			end
		else
			for _, child in ipairs{node.left, node.right} do
				local c, a = child.aabb, node.aabb
				T(
					c.min_x >= a.min_x and
						c.min_y >= a.min_y and
						c.min_z >= a.min_z and
						c.max_x <= a.max_x and
						c.max_y <= a.max_y and
						c.max_z <= a.max_z
				)["=="](true)
				stack[#stack + 1] = child
			end
		end
	end

	local found = 0

	for _ in pairs(seen) do
		found = found + 1
	end

	T(found)["=="](count)
end

local function visit_leaf(node, context, result)
	for i = node.first, node.last do
		local item = context.items[i]

		if bvh.AABBIntersects(context.box, item.bounds) then result[item.id] = true end
	end

	return result
end

T.Test("physics bvh BuildFast holds every item once and answers box queries", function()
	for _, count in ipairs{1, 2, 8, 9, 100, 3000} do
		local items, random = make_items(count, 4242 + count)
		local tree = bvh.BuildFast(items, get_bounds, get_centroid, 8)
		check_tree(tree, count)

		for _ = 1, 20 do
			local x, y, z = random() * 500, random() * 80, random() * 500
			local box = {
				min_x = x,
				min_y = y,
				min_z = z,
				max_x = x + random() * 120,
				max_y = y + random() * 60,
				max_z = z + random() * 120,
			}
			local expected = {}

			for _, item in ipairs(tree.items) do
				if bvh.AABBIntersects(box, item.bounds) then expected[item.id] = true end
			end

			local context = {items = tree.items, box = box, node_stack = {}}
			local result = bvh.TraverseAABB(box, tree.root, visit_leaf, context, {})

			for id in pairs(expected) do
				T(result[id])["=="](true)
			end

			for id in pairs(result) do
				T(expected[id])["=="](true)
			end
		end
	end
end)

T.Test("physics bvh BuildFast of nothing is nil", function()
	T(bvh.BuildFast({}, get_bounds, get_centroid, 8))["=="](nil)
end)
