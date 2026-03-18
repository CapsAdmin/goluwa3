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

	local slice = {}

	for i = first, last do
		slice[#slice + 1] = items[i]
	end

	table.sort(slice, function(a, b)
		local ax, ay, az = get_centroid(a)
		local bx, by, bz = get_centroid(b)

		if axis == "x" then return ax < bx end

		if axis == "y" then return ay < by end

		return az < bz
	end)

	for i = 1, #slice do
		items[first + i - 1] = slice[i]
	end

	local mid = math.floor((first + last) / 2)
	return {
		aabb = bounds,
		left = build_node(items, first, mid, get_bounds, get_centroid, leaf_item_count),
		right = build_node(items, mid + 1, last, get_bounds, get_centroid, leaf_item_count),
	}
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

	if not bvh.AABBIntersects(bounds, node.aabb) then return result end

	local node_stack = context and context.node_stack or {}
	node_stack[1] = node
	local stack_size = 1

	while stack_size > 0 do
		local current = node_stack[stack_size]
		node_stack[stack_size] = nil
		stack_size = stack_size - 1

		if bvh.AABBIntersects(bounds, current.aabb) then
			if current.first then
				result = visit_leaf(current, context, result)
			else
				local left = current.left
				local right = current.right

				if right and bvh.AABBIntersects(bounds, right.aabb) then
					stack_size = stack_size + 1
					node_stack[stack_size] = right
				end

				if left and bvh.AABBIntersects(bounds, left.aabb) then
					stack_size = stack_size + 1
					node_stack[stack_size] = left
				end
			end
		end
	end

	return result
end

return bvh
