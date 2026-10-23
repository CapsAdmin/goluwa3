local physics = import("goluwa/physics.lua")
local system = import("goluwa/system.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local grid_nav = {}
grid_nav.__index = grid_nav
grid_nav.CacheLifetime = 60
local MIN_NORMAL_Y = 0.7
local DIRS_X = {1, -1, 0, 0, 1, 1, -1, -1}
local DIRS_Z = {0, 0, 1, -1, 1, -1, 1, -1}
local OPPOSITE = {2, 1, 4, 3, 8, 7, 6, 5}
local DIAGONAL = 1.4142
local CLIMB_COST = 0.5
local SMOOTH_LOOKAHEAD = 12
local DOWN = Vec3(0, -1, 0)
local ground_delta = Vec3(0, -1, 0)
local sweep_from, sweep_delta = Vec3(), Vec3()
local ground_from = Vec3()
local body_bounds = AABB(0, 0, 0, 0, 0, 0)
local shared = {}

function grid_nav.New(radius, height, step, drop)
	return setmetatable(
		{
			cell = 0.5,
			radius = radius,
			height = height,
			step = step,
			drop = drop,
			max_nodes = 3000,
			ground = {},
			edges = {},
			built = system.GetElapsedTime(),
			world_version = RigidBody.WorldGeometryVersion,
		},
		grid_nav
	)
end

function grid_nav.Get(radius, height, step, drop)
	local key = radius .. ":" .. height .. ":" .. step .. ":" .. drop
	local nav = shared[key]

	if not nav then
		nav = grid_nav.New(radius, height, step, drop)
		shared[key] = nav
	end

	return nav
end

function grid_nav.IsObstacle(body)
	return true
end

function grid_nav.InvalidateAll()
	for _, nav in pairs(shared) do
		nav:Invalidate()
	end
end

function grid_nav.FindGround(x, y, z, distance)
	ground_from.x, ground_from.y, ground_from.z = x, y, z
	local hit = physics.RayCast(ground_from, DOWN, distance)

	if hit and hit.normal.y >= MIN_NORMAL_Y then return y - hit.distance end
end

function grid_nav:Invalidate()
	self.ground = {}
	self.edges = {}
	self.built = system.GetElapsedTime()
	self.world_version = RigidBody.WorldGeometryVersion
end

local function column_key(ix, iz)
	return (ix + 8192) * 16384 + (iz + 8192)
end

local function node_key(ix, iz, y)
	return column_key(ix, iz) * 256 + (math.floor(y * 2) + 128) % 256
end

grid_nav.ColumnKey = column_key

function grid_nav:GetColumn(x, z)
	return math.floor(x / self.cell + 0.5), math.floor(z / self.cell + 0.5)
end

function grid_nav:GetGround(ix, iz, from_y)
	local key = column_key(ix, iz) * 512 + (math.floor(from_y / self.step) % 512)
	local cached = self.ground[key]

	if cached ~= nil then return cached or nil end

	ground_from.x, ground_from.y, ground_from.z = ix * self.cell, from_y + self.step, iz * self.cell
	ground_delta.y = -(self.step + self.drop)
	local hit = physics.Sweep(ground_from, ground_delta, 0)

	if not hit or hit.distance <= 0 or hit.normal.y < MIN_NORMAL_Y then
		self.ground[key] = false
		return nil
	end

	local y = from_y + self.step - hit.distance
	self.ground[key] = y
	return y
end

function grid_nav:GetRandomPoint(around, radius, tries)
	for _ = 1, tries do
		local angle = math.random() * math.pi * 2
		local distance = math.sqrt(math.random()) * radius
		local x, z = around.x + math.cos(angle) * distance, around.z + math.sin(angle) * distance
		local y = grid_nav.FindGround(x, around.y + self.height, z, self.height + 30)

		if y then return Vec3(x, y, z) end
	end
end

function grid_nav:WorldEdgeClear(x0, y0, z0, x1, y1, z1)
	sweep_from.x, sweep_from.y, sweep_from.z = x0, math.max(y0, y1) + self.step + self.radius, z0
	sweep_delta.x, sweep_delta.y, sweep_delta.z = x1 - x0, 0, z1 - z0
	return not physics.Sweep(sweep_from, sweep_delta, self.radius)
end

function grid_nav:CollectObstacles(ignore_entity)
	local list, count = {}, 0
	local radius = self.radius

	for _, body in ipairs(RigidBody.Instances) do
		if
			body.WorldGeometry ~= true and
			body.CollisionEnabled and
			body.Owner ~= ignore_entity and
			grid_nav.IsObstacle(body)
		then
			body:GetBroadphaseAABB(nil, nil, body_bounds)

			if body_bounds.max_y - body_bounds.min_y > self.step then
				count = count + 1
				list[count] = {
					body_bounds.min_x - radius,
					body_bounds.min_y,
					body_bounds.min_z - radius,
					body_bounds.max_x + radius,
					body_bounds.max_y,
					body_bounds.max_z + radius,
				}
			end
		end
	end

	return list
end

function grid_nav:ObstacleBlocks(obstacles, x0, y0, z0, x1, y1, z1)
	local low = math.min(y0, y1) + self.step
	local high = math.max(y0, y1) + self.height
	local dx, dz = x1 - x0, z1 - z0

	for i = 1, #obstacles do
		local o = obstacles[i]

		if o[5] > low and o[2] < high then
			local t0, t1 = 0, 1
			local inside = true

			if math.abs(dx) < 1e-9 then
				inside = x0 >= o[1] and x0 <= o[4]
			else
				local a, b = (o[1] - x0) / dx, (o[4] - x0) / dx

				if a > b then a, b = b, a end

				t0, t1 = math.max(t0, a), math.min(t1, b)
			end

			if inside then
				if math.abs(dz) < 1e-9 then
					inside = z0 >= o[3] and z0 <= o[6]
				else
					local a, b = (o[3] - z0) / dz, (o[6] - z0) / dz

					if a > b then a, b = b, a end

					t0, t1 = math.max(t0, a), math.min(t1, b)
				end
			end

			if inside and t0 <= t1 then return true end
		end
	end

	return false
end

function grid_nav:EdgeClear(obstacles, ax, ay, az, bx, by, bz, key)
	local clear = key and self.edges[key]

	if clear == nil then
		clear = self:WorldEdgeClear(ax, ay, az, bx, by, bz)

		if key then self.edges[key] = clear end
	end

	return clear and not self:ObstacleBlocks(obstacles, ax, ay, az, bx, by, bz)
end

local function heap_push(heap, f, id)
	local n = #heap + 1
	heap[n] = {f, id}

	while n > 1 do
		local p = math.floor(n / 2)

		if heap[p][1] <= heap[n][1] then break end

		heap[p], heap[n] = heap[n], heap[p]
		n = p
	end
end

local function heap_pop(heap)
	local top = heap[1]
	local last = table.remove(heap)
	local n = #heap

	if n == 0 then return top end

	heap[1] = last
	local i = 1

	while true do
		local l, r, m = i * 2, i * 2 + 1, i

		if l <= n and heap[l][1] < heap[m][1] then m = l end

		if r <= n and heap[r][1] < heap[m][1] then m = r end

		if m == i then break end

		heap[i], heap[m] = heap[m], heap[i]
		i = m
	end

	return top
end

local function heuristic(search, ix, iz)
	local dx, dz = math.abs(ix - search.gx), math.abs(iz - search.gz)
	return (dx + dz + (DIAGONAL - 2) * math.min(dx, dz)) * search.nav.cell
end

local function offer(search, node, other, dir, g)
	if g < other.g then
		other.g, other.parent, other.dir, other.checked = g, node, dir, false
		heap_push(search.open, g + heuristic(search, other.ix, other.iz), other.key)
	end
end

function grid_nav:BeginSearch(from, to, ignore_entity, blocked)
	if
		RigidBody.WorldGeometryVersion ~= self.world_version or
		system.GetElapsedTime() - self.built > grid_nav.CacheLifetime
	then
		self:Invalidate()
	end

	local sx, sz = self:GetColumn(from.x, from.z)
	local gx, gz = self:GetColumn(to.x, to.z)
	local sy = self:GetGround(sx, sz, from.y) or from.y
	local key = node_key(sx, sz, sy)
	local start = {ix = sx, iz = sz, y = sy, g = 0, key = key}
	local search = {
		nav = self,
		gx = gx,
		gz = gz,
		goal = to,
		nodes = {[key] = start},
		open = {},
		expanded = 0,
		seconds = 0,
		blocked = blocked,
		obstacles = self:CollectObstacles(ignore_entity),
		best = start,
		best_h = heuristic({gx = gx, gz = gz, nav = self}, sx, sz),
	}
	heap_push(search.open, search.best_h, key)
	return search
end

function grid_nav:Reparent(search, node)
	local cell = self.cell
	node.g, node.parent = math.huge, nil

	for d = 1, 8 do
		local nx, nz = node.ix + DIRS_X[d], node.iz + DIRS_Z[d]
		local y = self:GetGround(nx, nz, node.y)

		if y then
			local other = search.nodes[node_key(nx, nz, y)]

			if other and other.closed and other.g < math.huge then
				local back = OPPOSITE[d]

				if
					self:EdgeClear(
						search.obstacles,
						other.ix * cell,
						other.y,
						other.iz * cell,
						node.ix * cell,
						node.y,
						node.iz * cell,
						other.key * 8 + back
					)
				then
					offer(
						search,
						other,
						node,
						back,
						other.g + (
								d > 4 and
								DIAGONAL or
								1
							) * cell + math.abs(node.y - other.y) * CLIMB_COST
					)
				end
			end
		end
	end
end

function grid_nav:Smooth(path, obstacles)
	local points = path.points
	local out = {points[1]}
	local count = #points
	local i = 1
	local cell = self.cell

	while i < count do
		local j = math.min(count, i + SMOOTH_LOOKAHEAD)

		while j > i + 1 do
			local a, b = points[i], points[j]
			local ok = true
			local samples = math.ceil(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) / cell)
			local y = a.y

			for k = 1, samples do
				local x0, z0 = a.x + (b.x - a.x) * (k - 1) / samples, a.z + (b.z - a.z) * (k - 1) / samples
				local x1, z1 = a.x + (b.x - a.x) * k / samples, a.z + (b.z - a.z) * k / samples
				local ix, iz = self:GetColumn(x1, z1)
				local next_y = self:GetGround(ix, iz, y)

				if not next_y or not self:EdgeClear(obstacles, x0, y, z0, x1, next_y, z1) then
					ok = false

					break
				end

				y = next_y
			end

			if ok then break end

			j = j - 1
		end

		out[#out + 1] = points[j]
		i = j
	end

	path.points = out
end

function grid_nav:Step(search, seconds)
	local cell = self.cell
	local started = os.clock()
	local open, nodes, blocked = search.open, search.nodes, search.blocked

	while #open > 0 and search.expanded < self.max_nodes do
		if os.clock() - started > seconds then
			search.seconds = search.seconds + os.clock() - started
			return false
		end

		local node = nodes[heap_pop(open)[2]]

		if node.closed or node.g == math.huge then goto continue end

		local parent = node.parent

		if parent and not node.checked then
			if
				not self:EdgeClear(
					search.obstacles,
					parent.ix * cell,
					parent.y,
					parent.iz * cell,
					node.ix * cell,
					node.y,
					node.iz * cell,
					parent.key * 8 + node.dir
				)
			then
				self:Reparent(search, node)

				goto continue
			end

			node.checked = true
		end

		node.closed = true
		search.expanded = search.expanded + 1
		local h = heuristic(search, node.ix, node.iz)

		if h < search.best_h then search.best, search.best_h = node, h end

		if node.ix == search.gx and node.iz == search.gz then
			search.found = node

			break
		end

		for d = 1, 8 do
			local ix, iz = node.ix + DIRS_X[d], node.iz + DIRS_Z[d]

			if not (blocked and blocked[column_key(ix, iz)]) then
				local y = self:GetGround(ix, iz, node.y)

				if y then
					local key = node_key(ix, iz, y)
					local other = nodes[key]

					if not other then
						other = {ix = ix, iz = iz, y = y, key = key, g = math.huge}
						nodes[key] = other
					end

					if not other.closed and self.edges[node.key * 8 + d] ~= false then
						offer(
							search,
							node,
							other,
							d,
							node.g + (d > 4 and DIAGONAL or 1) * cell + math.abs(y - node.y) * CLIMB_COST
						)
					end
				end
			end
		end

		::continue::
	end

	local goal = search.found or search.best
	local count = 0
	local walker = goal

	while walker do
		count = count + 1
		walker = walker.parent
	end

	local points = {}
	walker = goal

	for i = count, 1, -1 do
		points[i] = Vec3(walker.ix * cell, walker.y, walker.iz * cell)
		walker = walker.parent
	end

	local path = {
		points = points,
		complete = search.found ~= nil,
		exhausted = #open == 0 and search.found == nil,
		expanded = search.expanded,
		length = goal.g,
	}
	self:Smooth(path, search.obstacles)

	if path.complete then
		local last = path.points[#path.points]
		last.x, last.z = search.goal.x, search.goal.z
	end

	search.seconds = search.seconds + os.clock() - started
	path.seconds = search.seconds
	search.path = path
	return true
end

function grid_nav:FindPath(from, to, ignore_entity, blocked)
	local search = self:BeginSearch(from, to, ignore_entity, blocked)
	self:Step(search, math.huge)
	return search.path
end

return grid_nav
