local ffi = require("ffi")
local bvh = library()
bvh.DefaultLeafItemCount = bvh.DefaultLeafItemCount or 8

function bvh.CreateEmptyBounds()
	return {
		min_x = math.huge,
		min_y = math.huge,
		min_z = math.huge,
		max_x = -math.huge,
		max_y = -math.huge,
		max_z = -math.huge,
	}
end

function bvh.ExpandBounds(bounds, min_x, min_y, min_z, max_x, max_y, max_z)
	if min_x < bounds.min_x then bounds.min_x = min_x end

	if min_y < bounds.min_y then bounds.min_y = min_y end

	if min_z < bounds.min_z then bounds.min_z = min_z end

	if max_x > bounds.max_x then bounds.max_x = max_x end

	if max_y > bounds.max_y then bounds.max_y = max_y end

	if max_z > bounds.max_z then bounds.max_z = max_z end

	return bounds
end

function bvh.GetLongestAxis(bounds)
	local size_x = bounds.max_x - bounds.min_x
	local size_y = bounds.max_y - bounds.min_y
	local size_z = bounds.max_z - bounds.min_z

	if size_x >= size_y and size_x >= size_z then return "x", size_x end

	if size_y >= size_z then return "y", size_y end

	return "z", size_z
end

function bvh.RayAABBIntersection(ray, bounds)
	local tx1 = (bounds.min_x - ray.origin.x) * ray.inv_direction.x
	local tx2 = (bounds.max_x - ray.origin.x) * ray.inv_direction.x
	local tmin = math.min(tx1, tx2)
	local tmax = math.max(tx1, tx2)
	local ty1 = (bounds.min_y - ray.origin.y) * ray.inv_direction.y
	local ty2 = (bounds.max_y - ray.origin.y) * ray.inv_direction.y
	tmin = math.max(tmin, math.min(ty1, ty2))
	tmax = math.min(tmax, math.max(ty1, ty2))
	local tz1 = (bounds.min_z - ray.origin.z) * ray.inv_direction.z
	local tz2 = (bounds.max_z - ray.origin.z) * ray.inv_direction.z
	tmin = math.max(tmin, math.min(tz1, tz2))
	tmax = math.min(tmax, math.max(tz1, tz2))
	return tmax >= tmin and tmax >= 0 and tmin <= ray.max_distance, tmin, tmax
end

function bvh.AABBIntersects(a, b)
	if not (a and b) then return false end

	if a.min_x > b.max_x or b.min_x > a.max_x then return false end

	if a.min_y > b.max_y or b.min_y > a.max_y then return false end

	if a.min_z > b.max_z or b.min_z > a.max_z then return false end

	return true
end

local function compare_sort_entry(a, b)
	return a.value < b.value
end

local sort_scratch = {}

local function sort_items_by_centroid(items, first, last, axis, get_centroid)
	local count = last - first + 1

	for i = 1, count do
		local item = items[first + i - 1]
		local cx, cy, cz = get_centroid(item)
		local pair = sort_scratch[i]

		if not pair then
			pair = {}
			sort_scratch[i] = pair
		end

		if axis == "x" then
			pair.value = cx
		elseif axis == "y" then
			pair.value = cy
		else
			pair.value = cz
		end

		pair.item = item
	end

	for i = count + 1, #sort_scratch do
		sort_scratch[i] = nil
	end

	table.sort(sort_scratch, compare_sort_entry)

	for i = 1, count do
		items[first + i - 1] = sort_scratch[i].item
	end
end

local function build_node(items, first, last, get_bounds, get_centroid, leaf_item_count)
	local bounds = bvh.CreateEmptyBounds()
	local centroid_bounds = bvh.CreateEmptyBounds()

	for i = first, last do
		local item = items[i]
		local item_bounds = get_bounds(item)
		local centroid_x, centroid_y, centroid_z = get_centroid(item)
		bvh.ExpandBounds(
			bounds,
			item_bounds.min_x,
			item_bounds.min_y,
			item_bounds.min_z,
			item_bounds.max_x,
			item_bounds.max_y,
			item_bounds.max_z
		)
		bvh.ExpandBounds(
			centroid_bounds,
			centroid_x,
			centroid_y,
			centroid_z,
			centroid_x,
			centroid_y,
			centroid_z
		)
	end

	local count = last - first + 1

	if count <= leaf_item_count then
		return {aabb = bounds, first = first, last = last}
	end

	local axis, extent = bvh.GetLongestAxis(centroid_bounds)

	if extent <= 0 then return {aabb = bounds, first = first, last = last} end

	sort_items_by_centroid(items, first, last, axis, get_centroid)
	local mid = math.floor((first + last) / 2)
	return {
		aabb = bounds,
		left = build_node(items, first, mid, get_bounds, get_centroid, leaf_item_count),
		right = build_node(items, mid + 1, last, get_bounds, get_centroid, leaf_item_count),
	}
end

local DoubleArray = ffi.typeof("double[?]")
local IntArray = ffi.typeof("int32_t[?]")

local function select_nth(order, keys, lo, hi, k)
	while hi > lo do
		local a, b, c = keys[order[lo]], keys[order[math.floor((lo + hi) / 2)]], keys[order[hi]]
		local pivot

		if a < b then
			if b < c then
				pivot = b
			elseif a < c then
				pivot = c
			else
				pivot = a
			end
		else
			if a < c then
				pivot = a
			elseif b < c then
				pivot = c
			else
				pivot = b
			end
		end

		local i, j = lo, hi

		while i <= j do
			while keys[order[i]] < pivot do
				i = i + 1
			end

			while keys[order[j]] > pivot do
				j = j - 1
			end

			if i <= j then
				order[i], order[j] = order[j], order[i]
				i = i + 1
				j = j - 1
			end
		end

		if k <= j then hi = j elseif k >= i then lo = i else return end
	end
end

local function build_fast_node(data, first, last)
	local order = data.order
	local min_x_a, min_y_a, min_z_a = data.min_x, data.min_y, data.min_z
	local max_x_a, max_y_a, max_z_a = data.max_x, data.max_y, data.max_z
	local cx_a, cy_a, cz_a = data.cx, data.cy, data.cz
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge
	local cmin_x, cmin_y, cmin_z = math.huge, math.huge, math.huge
	local cmax_x, cmax_y, cmax_z = -math.huge, -math.huge, -math.huge

	for p = first, last do
		local i = order[p]

		if min_x_a[i] < min_x then min_x = min_x_a[i] end

		if min_y_a[i] < min_y then min_y = min_y_a[i] end

		if min_z_a[i] < min_z then min_z = min_z_a[i] end

		if max_x_a[i] > max_x then max_x = max_x_a[i] end

		if max_y_a[i] > max_y then max_y = max_y_a[i] end

		if max_z_a[i] > max_z then max_z = max_z_a[i] end

		if cx_a[i] < cmin_x then cmin_x = cx_a[i] end

		if cx_a[i] > cmax_x then cmax_x = cx_a[i] end

		if cy_a[i] < cmin_y then cmin_y = cy_a[i] end

		if cy_a[i] > cmax_y then cmax_y = cy_a[i] end

		if cz_a[i] < cmin_z then cmin_z = cz_a[i] end

		if cz_a[i] > cmax_z then cmax_z = cz_a[i] end
	end

	local bounds = {
		min_x = min_x,
		min_y = min_y,
		min_z = min_z,
		max_x = max_x,
		max_y = max_y,
		max_z = max_z,
	}

	if last - first + 1 <= data.leaf_item_count then
		return {aabb = bounds, first = first + 1, last = last + 1}
	end

	local size_x, size_y, size_z = cmax_x - cmin_x, cmax_y - cmin_y, cmax_z - cmin_z
	local keys, extent

	if size_x >= size_y and size_x >= size_z then
		keys, extent = cx_a, size_x
	elseif size_y >= size_z then
		keys, extent = cy_a, size_y
	else
		keys, extent = cz_a, size_z
	end

	if extent <= 0 then
		return {aabb = bounds, first = first + 1, last = last + 1}
	end

	local mid = math.floor((first + last) / 2)
	select_nth(order, keys, first, last, mid)
	return {
		aabb = bounds,
		left = build_fast_node(data, first, mid),
		right = build_fast_node(data, mid + 1, last),
	}
end

function bvh.BuildFast(items, get_bounds, get_centroid, leaf_item_count)
	local count = items and #items or 0

	if count == 0 then return nil end

	local data = {
		leaf_item_count = leaf_item_count or bvh.DefaultLeafItemCount,
		order = IntArray(count),
		min_x = DoubleArray(count),
		min_y = DoubleArray(count),
		min_z = DoubleArray(count),
		max_x = DoubleArray(count),
		max_y = DoubleArray(count),
		max_z = DoubleArray(count),
		cx = DoubleArray(count),
		cy = DoubleArray(count),
		cz = DoubleArray(count),
	}

	for i = 0, count - 1 do
		local item = items[i + 1]
		local item_bounds = get_bounds(item)
		data.min_x[i], data.min_y[i], data.min_z[i] = item_bounds.min_x, item_bounds.min_y, item_bounds.min_z
		data.max_x[i], data.max_y[i], data.max_z[i] = item_bounds.max_x, item_bounds.max_y, item_bounds.max_z
		data.cx[i], data.cy[i], data.cz[i] = get_centroid(item)
		data.order[i] = i
	end

	local root = build_fast_node(data, 0, count - 1)
	local ordered = {}

	for p = 0, count - 1 do
		ordered[p + 1] = items[data.order[p] + 1]
	end

	for i = 1, count do
		items[i] = ordered[i]
	end

	return {items = items, root = root}
end

function bvh.Build(items, get_bounds, get_centroid, leaf_item_count)
	if not items or #items == 0 then return nil end

	leaf_item_count = leaf_item_count or bvh.DefaultLeafItemCount
	return {
		items = items,
		root = build_node(items, 1, #items, get_bounds, get_centroid, leaf_item_count),
	}
end

function bvh.TraverseRay(ray, node, visit_leaf, context, closest_hit, closest_distance)
	closest_distance = closest_distance or math.huge
	local hit_node, node_tmin = bvh.RayAABBIntersection(ray, node.aabb)

	if not hit_node or node_tmin > closest_distance then
		return closest_hit, closest_distance
	end

	local node_stack = context and context.node_stack or {}
	local tmin_stack = context and context.tmin_stack or {}
	node_stack[1] = node
	tmin_stack[1] = node_tmin
	local stack_size = 1

	while stack_size > 0 do
		local current = node_stack[stack_size]
		local current_tmin = tmin_stack[stack_size]
		node_stack[stack_size] = nil
		tmin_stack[stack_size] = nil
		stack_size = stack_size - 1

		if current_tmin <= closest_distance then
			if current.first then
				closest_hit, closest_distance = visit_leaf(current, context, closest_hit, closest_distance)
			else
				local left = current.left
				local right = current.right
				local left_hit, left_tmin = bvh.RayAABBIntersection(ray, left.aabb)
				local right_hit, right_tmin = bvh.RayAABBIntersection(ray, right.aabb)

				if left_hit and left_tmin <= closest_distance then
					if right_hit and right_tmin <= closest_distance then
						if left_tmin <= right_tmin then
							stack_size = stack_size + 1
							node_stack[stack_size] = right
							tmin_stack[stack_size] = right_tmin
							stack_size = stack_size + 1
							node_stack[stack_size] = left
							tmin_stack[stack_size] = left_tmin
						else
							stack_size = stack_size + 1
							node_stack[stack_size] = left
							tmin_stack[stack_size] = left_tmin
							stack_size = stack_size + 1
							node_stack[stack_size] = right
							tmin_stack[stack_size] = right_tmin
						end
					else
						stack_size = stack_size + 1
						node_stack[stack_size] = left
						tmin_stack[stack_size] = left_tmin
					end
				elseif right_hit and right_tmin <= closest_distance then
					stack_size = stack_size + 1
					node_stack[stack_size] = right
					tmin_stack[stack_size] = right_tmin
				end
			end
		end
	end

	return closest_hit, closest_distance
end

function bvh.TraverseAABB(bounds, node, visit_leaf, context, result)
	if not (bounds and node and visit_leaf) then return result end

	local intersects = bvh.AABBIntersects

	if not intersects(bounds, node.aabb) then return result end

	local node_stack = context and context.node_stack or {}
	node_stack[1] = node
	local stack_size = 1

	while stack_size > 0 do
		local current = node_stack[stack_size]
		node_stack[stack_size] = nil
		stack_size = stack_size - 1

		if current.first then
			result = visit_leaf(current, context, result)
		else
			local left = current.left
			local right = current.right

			if right then
				if intersects(bounds, right.aabb) then
					stack_size = stack_size + 1
					node_stack[stack_size] = right
				end
			end

			if left then
				if intersects(bounds, left.aabb) then
					stack_size = stack_size + 1
					node_stack[stack_size] = left
				end
			end
		end
	end

	return result
end

return bvh
