local Vec3 = import("goluwa/structs/vec3.lua")
local navmesh = {}
navmesh.__index = navmesh
navmesh.CELL_SIZE = 4
navmesh.HEIGHT_TOLERANCE = 1.5
navmesh.SNAP_DISTANCE = 3
local EPSILON = 1e-5
local floor, sqrt, abs, huge = math.floor, math.sqrt, math.abs, math.huge
local EMPTY = {}

function navmesh.New()
	return setmetatable({areas = {}, areas_by_id = {}, grid = {}, built = false, search_id = 0}, navmesh)
end

local function cell_key(cx, cz)
	return (cx + 32768) * 65536 + cz + 32768
end

function navmesh:AddArea(info)
	local polygon = info.Polygon
	local count = #polygon
	assert(count >= 3, "a navigation area needs at least 3 points")
	local signed = 0

	for i = 1, count do
		local a, b = polygon[i], polygon[i % count + 1]
		signed = signed + a.x * b.z - b.x * a.z
	end

	local points = {}
	local min_x, min_y, min_z, max_x, max_y, max_z = huge, huge, huge, -huge, -huge, -huge
	local sum_x, sum_y, sum_z = 0, 0, 0

	for i = 1, count do
		local point = polygon[signed >= 0 and i or count - i + 1]
		points[#points + 1] = point.x
		points[#points + 1] = point.y
		points[#points + 1] = point.z
		min_x, max_x = math.min(min_x, point.x), math.max(max_x, point.x)
		min_y, max_y = math.min(min_y, point.y), math.max(max_y, point.y)
		min_z, max_z = math.min(min_z, point.z), math.max(max_z, point.z)
		sum_x, sum_y, sum_z = sum_x + point.x, sum_y + point.y, sum_z + point.z
	end

	local area = {
		Index = #self.areas + 1,
		Id = info.Id or #self.areas + 1,
		Flags = info.Flags or 0,
		Cost = info.Cost or 1,
		Blocked = info.Blocked or false,
		Data = info.Data,
		points = points,
		count = count,
		surface = abs(signed) / 2,
		min_x = min_x,
		min_y = min_y,
		min_z = min_z,
		max_x = max_x,
		max_y = max_y,
		max_z = max_z,
		center_x = sum_x / count,
		center_y = sum_y / count,
		center_z = sum_z / count,
		links = {},
		search = 0,
	}
	self.areas[area.Index] = area
	self.areas_by_id[area.Id] = area
	self.built = false
	return area
end

function navmesh:GetArea(id)
	return self.areas_by_id[id]
end

function navmesh:GetAreas()
	return self.areas
end

function navmesh:Connect(from, to, a, b)
	local mid_x, mid_y, mid_z = (a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2
	local dx, dz = mid_x - from.center_x, mid_z - from.center_z
	local left, right = a, b

	if dx * (a.z - mid_z) - dz * (a.x - mid_x) < 0 then left, right = b, a end

	local link = {
		area = to,
		left_x = left.x,
		left_y = left.y,
		left_z = left.z,
		right_x = right.x,
		right_y = right.y,
		right_z = right.z,
		mid_x = mid_x,
		mid_y = mid_y,
		mid_z = mid_z,
		rise = self:GetHeight(to, mid_x, mid_z) - self:GetHeight(from, mid_x, mid_z),
	}
	from.links[#from.links + 1] = link
	return link
end

function navmesh:Build()
	local size = navmesh.CELL_SIZE
	self.grid = {}

	for _, area in ipairs(self.areas) do
		for cx = floor(area.min_x / size), floor(area.max_x / size) do
			for cz = floor(area.min_z / size), floor(area.max_z / size) do
				local key = cell_key(cx, cz)
				local cell = self.grid[key]

				if not cell then
					cell = {}
					self.grid[key] = cell
				end

				cell[#cell + 1] = area
			end
		end
	end

	self.built = true
end

function navmesh:GetHeight(area, x, z)
	local p = area.points
	local ax, ay, az = p[1], p[2], p[3]
	local best_y, best_outside = area.center_y, huge

	for i = 2, area.count - 1 do
		local o = (i - 1) * 3
		local bx, by, bz = p[o + 1], p[o + 2], p[o + 3]
		local cx, cy, cz = p[o + 4], p[o + 5], p[o + 6]
		local d = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)

		if abs(d) > EPSILON * EPSILON then
			local l1 = ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / d
			local l2 = ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / d
			local l3 = 1 - l1 - l2
			local outside = -math.min(l1, l2, l3)

			if outside < best_outside then
				best_outside = outside
				best_y = l1 * ay + l2 * by + l3 * cy

				if outside <= 0 then break end
			end
		end
	end

	return best_y
end

local function contains(area, x, z)
	if x < area.min_x or x > area.max_x or z < area.min_z or z > area.max_z then
		return false
	end

	local p = area.points
	local count = area.count

	for i = 0, count - 1 do
		local o = i * 3
		local n = (i + 1) % count * 3
		local ex, ez = p[n + 1] - p[o + 1], p[n + 3] - p[o + 3]

		if ex * (z - p[o + 3]) - ez * (x - p[o + 1]) < -EPSILON then return false end
	end

	return true
end

function navmesh:GetClosestPoint(area, x, z)
	if contains(area, x, z) then return x, self:GetHeight(area, x, z), z end

	local p = area.points
	local count = area.count
	local best_x, best_z, best = x, z, huge

	for i = 0, count - 1 do
		local o = i * 3
		local n = (i + 1) % count * 3
		local ax, az = p[o + 1], p[o + 3]
		local ex, ez = p[n + 1] - ax, p[n + 3] - az
		local length = ex * ex + ez * ez
		local t = length > 0 and math.clamp(((x - ax) * ex + (z - az) * ez) / length, 0, 1) or 0
		local px, pz = ax + ex * t, az + ez * t
		local distance = (px - x) ^ 2 + (pz - z) ^ 2

		if distance < best then best_x, best_z, best = px, pz, distance end
	end

	return best_x, self:GetHeight(area, best_x, best_z), best_z
end

local stamp = 0
local near = {}

local function collect(self, min_x, min_z, max_x, max_z)
	if not self.built then self:Build() end

	local size = navmesh.CELL_SIZE
	local grid = self.grid
	stamp = stamp + 1
	local count = 0

	for cx = floor(min_x / size), floor(max_x / size) do
		for cz = floor(min_z / size), floor(max_z / size) do
			local cell = grid[cell_key(cx, cz)]

			if cell then
				for i = 1, #cell do
					local area = cell[i]

					if area.collected ~= stamp then
						area.collected = stamp
						count = count + 1
						near[count] = area
					end
				end
			end
		end
	end

	return count
end

function navmesh:GetAreasNear(position, radius)
	local count = collect(self, position.x - radius, position.z - radius, position.x + radius, position.z + radius)
	local out = {}

	for i = 1, count do
		out[i] = near[i]
	end

	return out
end

function navmesh:GetAreaAt(position, tolerance)
	tolerance = tolerance or navmesh.HEIGHT_TOLERANCE
	local x, y, z = position.x, position.y, position.z
	local count = collect(self, x, z, x, z)
	local best, best_distance = nil, huge

	for i = 1, count do
		local area = near[i]

		if
			not area.Blocked and
			y >= area.min_y - tolerance and
			y <= area.max_y + tolerance and
			contains(area, x, z)
		then
			local distance = abs(self:GetHeight(area, x, z) - y)

			if distance <= tolerance and distance < best_distance then
				best, best_distance = area, distance
			end
		end
	end

	return best
end

function navmesh:GetNearestArea(position, max_distance)
	max_distance = max_distance or navmesh.SNAP_DISTANCE
	local x, y, z = position.x, position.y, position.z
	local count = collect(self, x - max_distance, z - max_distance, x + max_distance, z + max_distance)
	local best, best_distance, best_x, best_y, best_z = nil, max_distance * max_distance, 0, 0, 0

	for i = 1, count do
		local area = near[i]

		if not area.Blocked then
			local px, py, pz = self:GetClosestPoint(area, x, z)
			local distance = (px - x) ^ 2 + (py - y) ^ 2 + (pz - z) ^ 2

			if distance < best_distance then
				best, best_distance, best_x, best_y, best_z = area, distance, px, py, pz
			end
		end
	end

	return best, best_x, best_y, best_z
end

function navmesh:GetRandomPoint(around, radius, allowed)
	local candidates, total = {}, 0

	if around then
		local count = collect(self, around.x - radius, around.z - radius, around.x + radius, around.z + radius)

		for i = 1, count do
			local area = near[i]

			if not area.Blocked and (not allowed or allowed[area]) then
				candidates[#candidates + 1] = area
				total = total + area.surface
			end
		end
	else
		for _, area in ipairs(self.areas) do
			if not area.Blocked and (not allowed or allowed[area]) then
				candidates[#candidates + 1] = area
				total = total + area.surface
			end
		end
	end

	for _ = 1, around and 8 or 1 do
		if total == 0 then return nil end

		local pick = math.random() * total
		local area = candidates[#candidates]

		for _, candidate in ipairs(candidates) do
			pick = pick - candidate.surface

			if pick <= 0 then
				area = candidate

				break
			end
		end

		local p = area.points
		local x, z

		local weights, sum = {}, 0

		for i = 2, area.count - 1 do
			local o = (i - 1) * 3
			local surface = abs((p[o + 1] - p[1]) * (p[o + 6] - p[3]) - (p[o + 4] - p[1]) * (p[o + 3] - p[3])) / 2
			sum = sum + surface
			weights[i] = surface
		end

		pick = math.random() * sum
		local triangle = area.count - 1

		for i = 2, area.count - 1 do
			pick = pick - weights[i]

			if pick <= 0 then
				triangle = i

				break
			end
		end

		local o = (triangle - 1) * 3
		local r1, r2 = sqrt(math.random()), math.random()
		x = (1 - r1) * p[1] + r1 * (1 - r2) * p[o + 1] + r1 * r2 * p[o + 4]
		z = (1 - r1) * p[3] + r1 * (1 - r2) * p[o + 3] + r1 * r2 * p[o + 6]
		local dx, dz = around and x - around.x or 0, around and z - around.z or 0

		if not around or dx * dx + dz * dz <= radius * radius then
			return Vec3(x, self:GetHeight(area, x, z), z), area
		end
	end
end

local function is_passable(link, blocked, max_climb, max_drop)
	local other = link.area
	return not other.Blocked and
		not blocked[other] and
		not blocked[link] and
		link.rise <= max_climb and
		-link.rise <= max_drop
end

function navmesh:GetReachableAreas(from, options)
	options = options or EMPTY
	local start = self:GetAreaAt(from) or self:GetNearestArea(from, options.SnapDistance or navmesh.SNAP_DISTANCE)

	if not start then return nil end

	local blocked = options.Blocked or EMPTY
	local max_climb = options.MaxClimb or huge
	local max_drop = options.MaxDrop or huge
	local reached = {[start] = true}
	local stack, count = {start}, 1

	while count > 0 do
		local area = stack[count]
		stack[count] = nil
		count = count - 1

		for _, link in ipairs(area.links) do
			if not reached[link.area] and is_passable(link, blocked, max_climb, max_drop) then
				reached[link.area] = true
				count = count + 1
				stack[count] = link.area
			end
		end
	end

	return reached
end

local open_keys, open_areas, open_count = {}, {}, 0

local function open_push(key, area)
	open_count = open_count + 1
	local i = open_count

	while i > 1 do
		local parent = floor(i / 2)

		if open_keys[parent] <= key then break end

		open_keys[i], open_areas[i] = open_keys[parent], open_areas[parent]
		i = parent
	end

	open_keys[i], open_areas[i] = key, area
end

local function open_pop()
	local top = open_areas[1]
	local key, area = open_keys[open_count], open_areas[open_count]
	open_areas[open_count] = nil
	open_count = open_count - 1

	if open_count > 0 then
		local i = 1

		while true do
			local child = i * 2

			if child > open_count then break end

			if child < open_count and open_keys[child + 1] < open_keys[child] then
				child = child + 1
			end

			if open_keys[child] >= key then break end

			open_keys[i], open_areas[i] = open_keys[child], open_areas[child]
			i = child
		end

		open_keys[i], open_areas[i] = key, area
	end

	return top
end

local function triangle_area(ax, az, bx, bz, cx, cz)
	return (cx - ax) * (bz - az) - (bx - ax) * (cz - az)
end

local portal_left_x, portal_left_z, portal_right_x, portal_right_z = {}, {}, {}, {}
local portal_left_y, portal_right_y = {}, {}

local function pull_string(points, count)
	local apex_x, apex_y, apex_z = portal_left_x[1], portal_left_y[1], portal_left_z[1]
	local left_x, left_y, left_z = apex_x, apex_y, apex_z
	local right_x, right_y, right_z = apex_x, apex_y, apex_z
	local apex_index, left_index, right_index = 1, 1, 1
	points[1] = Vec3(apex_x, apex_y, apex_z)
	local i = 2

	while i <= count do
		local new_left_x, new_left_z = portal_left_x[i], portal_left_z[i]
		local new_right_x, new_right_z = portal_right_x[i], portal_right_z[i]
		local restarted = false

		if triangle_area(apex_x, apex_z, right_x, right_z, new_right_x, new_right_z) <= 0 then
			if
				(apex_x == right_x and apex_z == right_z) or
				triangle_area(apex_x, apex_z, left_x, left_z, new_right_x, new_right_z) > 0
			then
				right_x, right_y, right_z = new_right_x, portal_right_y[i], new_right_z
				right_index = i
			else
				points[#points + 1] = Vec3(left_x, left_y, left_z)
				apex_x, apex_y, apex_z = left_x, left_y, left_z
				apex_index = left_index
				left_x, left_y, left_z = apex_x, apex_y, apex_z
				right_x, right_y, right_z = apex_x, apex_y, apex_z
				left_index, right_index = apex_index, apex_index
				i = apex_index + 1
				restarted = true
			end
		end

		if not restarted then
			if triangle_area(apex_x, apex_z, left_x, left_z, new_left_x, new_left_z) >= 0 then
				if
					(apex_x == left_x and apex_z == left_z) or
					triangle_area(apex_x, apex_z, right_x, right_z, new_left_x, new_left_z) < 0
				then
					left_x, left_y, left_z = new_left_x, portal_left_y[i], new_left_z
					left_index = i
				else
					points[#points + 1] = Vec3(right_x, right_y, right_z)
					apex_x, apex_y, apex_z = right_x, right_y, right_z
					apex_index = right_index
					left_x, left_y, left_z = apex_x, apex_y, apex_z
					right_x, right_y, right_z = apex_x, apex_y, apex_z
					left_index, right_index = apex_index, apex_index
					i = apex_index + 1
					restarted = true
				end
			end
		end

		if not restarted then i = i + 1 end
	end

	local last = points[#points]

	if last.x ~= portal_left_x[count] or last.z ~= portal_left_z[count] then
		points[#points + 1] = Vec3(portal_left_x[count], portal_left_y[count], portal_left_z[count])
	end
end

function navmesh:FindPath(from, to, options)
	options = options or EMPTY
	local snap = options.SnapDistance or navmesh.SNAP_DISTANCE
	local start_area = self:GetAreaAt(from) or self:GetNearestArea(from, snap)

	if not start_area then return nil, "start is not on the navigation mesh" end

	local goal_area = self:GetAreaAt(to)
	local goal_x, goal_y, goal_z = to.x, to.y, to.z

	if not goal_area then
		goal_area, goal_x, goal_y, goal_z = self:GetNearestArea(to, snap)
	end

	if not goal_area then return nil, "goal is not on the navigation mesh" end

	local blocked = options.Blocked or EMPTY
	local max_climb = options.MaxClimb or huge
	local max_drop = options.MaxDrop or huge
	self.search_id = self.search_id + 1
	local search = self.search_id
	open_count = 0
	start_area.search = search
	start_area.g = 0
	start_area.parent = nil
	start_area.entry_x, start_area.entry_y, start_area.entry_z = from.x, from.y, from.z
	start_area.closed = false
	open_push(0, start_area)
	local found = false

	while open_count > 0 do
		local area = open_pop()

		if not area.closed then
			area.closed = true

			if area == goal_area then
				found = true

				break
			end

			local entry_x, entry_y, entry_z = area.entry_x, area.entry_y, area.entry_z
			local g = area.g

			for i = 1, #area.links do
				local link = area.links[i]
				local other = link.area

				if is_passable(link, blocked, max_climb, max_drop) then
					if other.search ~= search then
						other.search = search
						other.g = huge
						other.closed = false
					end

					if not other.closed then
						local dx, dy, dz = link.mid_x - entry_x, link.mid_y - entry_y, link.mid_z - entry_z
						local new_g = g + sqrt(dx * dx + dy * dy + dz * dz) * area.Cost

						if new_g < other.g then
							other.g = new_g
							other.parent = area
							other.link = link
							other.entry_x, other.entry_y, other.entry_z = link.mid_x, link.mid_y, link.mid_z
							local hx, hy, hz = goal_x - link.mid_x, goal_y - link.mid_y, goal_z - link.mid_z
							open_push(new_g + sqrt(hx * hx + hy * hy + hz * hz), other)
						end
					end
				end
			end
		end
	end

	if not found then return nil, "no path" end

	local areas = {}
	local area = goal_area

	while area do
		table.insert(areas, 1, area)
		area = area.parent
	end

	local points = {}
	local links = {}
	local count = #areas
	local length = 0

	for i = 2, count do
		links[i - 1] = areas[i].link
	end

	if count == 1 then
		points[1] = Vec3(from.x, from.y, from.z)
		points[2] = Vec3(goal_x, goal_y, goal_z)
	else
		local radius = options.Radius or 0
		portal_left_x[1], portal_left_y[1], portal_left_z[1] = from.x, from.y, from.z
		portal_right_x[1], portal_right_y[1], portal_right_z[1] = from.x, from.y, from.z

		for i = 2, count do
			local link = areas[i].link
			local lx, ly, lz = link.left_x, link.left_y, link.left_z
			local rx, ry, rz = link.right_x, link.right_y, link.right_z

			if radius > 0 then
				local dx, dy, dz = rx - lx, ry - ly, rz - lz
				local width = sqrt(dx * dx + dy * dy + dz * dz)
				local inset = math.min(radius, width / 2)

				if width > 0 then
					local t = inset / width
					lx, ly, lz = lx + dx * t, ly + dy * t, lz + dz * t
					rx, ry, rz = rx - dx * t, ry - dy * t, rz - dz * t
				end
			end

			portal_left_x[i], portal_left_y[i], portal_left_z[i] = lx, ly, lz
			portal_right_x[i], portal_right_y[i], portal_right_z[i] = rx, ry, rz
		end

		portal_left_x[count + 1], portal_left_y[count + 1], portal_left_z[count + 1] = goal_x, goal_y, goal_z
		portal_right_x[count + 1], portal_right_y[count + 1], portal_right_z[count + 1] = goal_x, goal_y, goal_z
		pull_string(points, count + 1)
	end

	for i = 2, #points do
		length = length + points[i - 1]:Distance(points[i])
	end

	return {points = points, areas = areas, links = links, length = length}
end

return navmesh
