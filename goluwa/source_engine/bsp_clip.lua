local brush_geometry = import("goluwa/source_engine/brush_geometry.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local bsp_clip = {}
local EPSILON = 0.01

-- Clips geometry against the BSP tree of a map: whatever ends up in a leaf for which is_removed(leaf) is true is cut away.
-- Surfaces that lie in a node's plane only stay where neither side of it is removed.
-- nodes are {plane number, front child, back child}, a negative child is minus the leaf number
function bsp_clip.New(nodes, planes, leafs, headnode, is_removed)
	local self = {nodes = nodes, planes = planes, leafs = leafs, headnode = headnode}
	local bounds_cache = {}

	-- the box around everything that is removed below a child, false when nothing is. Geometry that does not touch this box
	-- does not have to be split any further.
	local function removed_bounds(child)
		if child < 0 then
			local leaf = leafs[-child]

			if not is_removed(leaf) then return false end

			return {leaf.mins.x, leaf.mins.y, leaf.mins.z, leaf.maxs.x, leaf.maxs.y, leaf.maxs.z}
		end

		local cached = bounds_cache[child]

		if cached ~= nil then return cached end

		local node = nodes[child + 1]
		local front, back = removed_bounds(node[2]), removed_bounds(node[3])
		local result

		if front and back then
			result = {
				math.min(front[1], back[1]),
				math.min(front[2], back[2]),
				math.min(front[3], back[3]),
				math.max(front[4], back[4]),
				math.max(front[5], back[5]),
				math.max(front[6], back[6]),
			}
		else
			result = front or back
		end

		bounds_cache[child] = result
		return result
	end

	self.is_removed = is_removed
	self.removed_bounds = removed_bounds
	return setmetatable(self, {__index = bsp_clip})
end

-- whether the box of a list of points overlaps a removed_bounds box
local function overlaps(bounds, points_a, points_b)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for _, point in ipairs(points_a) do
		point = point.pos or point
		min_x, min_y, min_z = math.min(min_x, point.x), math.min(min_y, point.y), math.min(min_z, point.z)
		max_x, max_y, max_z = math.max(max_x, point.x), math.max(max_y, point.y), math.max(max_z, point.z)
	end

	return min_x <= bounds[4] and
		max_x >= bounds[1] and
		min_y <= bounds[5] and
		max_y >= bounds[2] and
		min_z <= bounds[6] and
		max_z >= bounds[3]
end

-- a vertex is {pos = Vec3, attributes = {numbers}}, attributes are interpolated when an edge is cut
local function lerp_vertex(a, b, t)
	local attributes = {}

	for i = 1, #a.attributes do
		attributes[i] = a.attributes[i] + (b.attributes[i] - a.attributes[i]) * t
	end

	return {pos = a.pos + (b.pos - a.pos) * t, attributes = attributes}
end

local function split_polygon(polygon, plane, distances)
	local front, back = {}, {}
	local count = #polygon
	local previous, previous_distance = polygon[count], distances[count]

	for i = 1, count do
		local vertex, distance = polygon[i], distances[i]

		if
			(
				previous_distance > EPSILON and
				distance < -EPSILON
			)
			or
			(
				previous_distance < -EPSILON and
				distance > EPSILON
			)
		then
			local cut = lerp_vertex(previous, vertex, previous_distance / (previous_distance - distance))
			front[#front + 1] = cut
			back[#back + 1] = cut
		end

		if distance >= -EPSILON then front[#front + 1] = vertex end

		if distance <= EPSILON then back[#back + 1] = vertex end

		previous, previous_distance = vertex, distance
	end

	return front, back
end

-- Returns the fragments of a convex polygon that are not removed, a list of polygons. The polygon itself is returned in
-- the list when nothing was cut off.
function bsp_clip:ClipPolygon(polygon)
	local nodes, planes, leafs = self.nodes, self.planes, self.leafs
	local removed_bounds, is_removed = self.removed_bounds, self.is_removed

	local function descend(child, polygon, out)
		if child < 0 then
			if not is_removed(leafs[-child]) then out[#out + 1] = polygon end

			return
		end

		local bounds = removed_bounds(child)

		if not bounds or not overlaps(bounds, polygon) then
			out[#out + 1] = polygon
			return
		end

		local node = nodes[child + 1]
		local plane = planes[node[1] + 1]
		local normal, dist = plane.normal, plane.dist
		local distances = {}
		local min_distance, max_distance = math.huge, -math.huge

		for i, vertex in ipairs(polygon) do
			local distance = normal:Dot(vertex.pos) - dist
			distances[i] = distance
			min_distance = math.min(min_distance, distance)
			max_distance = math.max(max_distance, distance)
		end

		if min_distance >= -EPSILON and max_distance <= EPSILON then
			-- in the plane, which is the boundary between the two sides: it only stays where neither side removes it
			local front = {}
			descend(node[2], polygon, front)

			for _, fragment in ipairs(front) do
				descend(node[3], fragment, out)
			end
		elseif min_distance >= -EPSILON then
			descend(node[2], polygon, out)
		elseif max_distance <= EPSILON then
			descend(node[3], polygon, out)
		else
			local front, back = split_polygon(polygon, plane, distances)

			if #front >= 3 then descend(node[2], front, out) end

			if #back >= 3 then descend(node[3], back, out) end
		end
	end

	local out = {}
	descend(self.headnode, polygon, out)
	return out
end

-- Returns the pieces of a convex brush that are not removed, a list of side lists. A side is {normal, dist, ...}, the
-- brush is the volume where normal . x <= dist for all of them. Cuts add sides without any extra fields.
function bsp_clip:ClipBrush(sides)
	local out = {}
	local nodes, planes, leafs = self.nodes, self.planes, self.leafs
	local removed_bounds, is_removed = self.removed_bounds, self.is_removed

	local function descend(child, sides)
		if child < 0 then
			if not is_removed(leafs[-child]) then out[#out + 1] = sides end

			return
		end

		local bounds = removed_bounds(child)

		if not bounds then
			out[#out + 1] = sides
			return
		end

		local node = nodes[child + 1]
		local plane = planes[node[1] + 1]
		local normal, dist = plane.normal, plane.dist
		local min_distance, max_distance = math.huge, -math.huge
		local points = {}

		for side_index in ipairs(sides) do
			local polygon = brush_geometry.ClipSide(sides, side_index)

			if polygon then
				for _, point in ipairs(polygon) do
					points[#points + 1] = point
					local distance = normal:Dot(point) - dist
					min_distance = math.min(min_distance, distance)
					max_distance = math.max(max_distance, distance)
				end
			end
		end

		if not overlaps(bounds, points) then
			out[#out + 1] = sides
			return
		end

		if min_distance >= -EPSILON then
			descend(node[2], sides)
		elseif max_distance <= EPSILON then
			descend(node[3], sides)
		else
			local front, back = {}, {}

			for i, side in ipairs(sides) do
				front[i], back[i] = side, side
			end

			front[#front + 1] = {normal = normal * -1, dist = -dist}
			back[#back + 1] = {normal = normal, dist = dist}
			descend(node[2], front)
			descend(node[3], back)
		end
	end

	descend(self.headnode, sides)
	return out
end

return bsp_clip
