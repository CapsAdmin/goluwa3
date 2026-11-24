local system = import("goluwa/system.lua")
local fish = {}
local SCARE_DISTANCE = 10
local LOOK_AHEAD = 1
local PROBE_DISTANCE = 2
local OBSTACLE_WEIGHT = 10
local GROUND_INTERVAL = 0.3
local PROBE_INTERVAL = 0.25
local SURFACE_MARGIN = 0.2

function fish.Spawn(flock, definition, origin)
	local water = flock:GetWaterLevel()

	if not water then return end

	local radius = flock.Radius
	local x, z = origin.x + math.randomf(-radius, radius), origin.z + math.randomf(-radius, radius)
	local hit = flock:TraceDown(x, water, z, water - origin.y + radius + definition.HeightMax, true)
	local bottom = hit and hit.position.y or origin.y - radius

	if bottom > water - SURFACE_MARGIN * 2 then return end

	local y = math.randomf(bottom + SURFACE_MARGIN, water - SURFACE_MARGIN)
	local angle = math.randomf(0, math.pi * 2)
	local boid = flock:SpawnBoid(definition, x, y, z, math.cos(angle), 0, math.sin(angle))
	boid.speed = math.randomf(definition.MinSpeed, definition.MaxSpeed)
	boid.ground_y = bottom
	boid.ground_time = math.randomf(0, GROUND_INTERVAL)
	boid.probe_time = math.randomf(0, PROBE_INTERVAL)
	boid.avoid_x, boid.avoid_y, boid.avoid_z = 0, 0, 0
	flock:SetPose(boid, 0)
	return boid
end

local function random_center(flock, origin)
	local t = system.GetElapsedTime() * 0.2
	local radius = flock.Radius
	return origin.x + radius * math.sin(t * 0.913) * math.cos(t * 1.12),
	origin.y + 0.4 * radius * math.sin(t * 1.045) * math.cos(t * 0.962),
	origin.z - radius * math.sin(t * 0.931) * math.cos(t * 0.971)
end

function fish.Update(flock, boid, definition, origin, dt, smooth)
	local accel = definition.RandomAccel
	local ax, ay, az = math.randomf(-accel, accel), math.randomf(-accel, accel), math.randomf(-accel, accel)
	local target_speed = (definition.MaxSpeed + definition.MinSpeed) / 2
	local slow = (boid.speed - target_speed) * 0.2
	ax, ay, az = ax - boid.hx * slow, ay - boid.hy * slow, az - boid.hz * slow

	if definition.Align ~= 0 then
		local sx, sy, sz, alx, aly, alz, cx, cy, cz = flock:Flocking(boid, definition)
		ax = ax + alx * definition.Align + cx * definition.Cohesion + sx
		ay = ay + aly * definition.Align + cy * definition.Cohesion + sy
		az = az + alz * definition.Align + cz * definition.Cohesion + sz
	end

	local water = flock:GetWaterLevel() or boid.y + 1

	if boid.y > water - 1 then
		local v = 1 - (water - boid.y)
		ay = ay - v * v * definition.AvoidLand
	end

	boid.ground_time = boid.ground_time - dt

	if boid.ground_time <= 0 then
		boid.ground_time = GROUND_INTERVAL
		local hit = flock:TraceDown(boid.x, water, boid.z, water - boid.y + definition.HeightMax + 10, true)
		boid.ground_y = hit and hit.position.y or boid.y - definition.HeightMax
	end

	local height = boid.y - boid.ground_y

	if height < definition.HeightMin then
		local v = 1 - height / (definition.HeightMin + 0.01)
		local w = v * v * definition.AvoidLand
		ay = ay + w
		local brake = (boid.speed - 0.1) * w
		ax, ay, az = ax - boid.hx * brake, ay - boid.hy * brake, az - boid.hz * brake
		ax, ay, az = ax + (origin.x - boid.x) * w,
		ay + (origin.y - boid.y) * w,
		az + (origin.z - boid.z) * w
	end

	if math.abs(boid.hy) > 0.5 then ay = ay - boid.hy * 0.8 end

	local cx, cy, cz = random_center(flock, origin)
	ax = ax + (cx - boid.x) * definition.OriginFactor
	ay = ay + (cy - boid.y) * definition.OriginFactor
	az = az + (cz - boid.z) * definition.OriginFactor
	boid.probe_time = boid.probe_time - dt

	if boid.probe_time <= 0 then
		boid.probe_time = PROBE_INTERVAL
		boid.avoid_x, boid.avoid_y, boid.avoid_z = 0, 0, 0

		if definition.ObstacleAvoidance or boid.ground_y >= boid.y - LOOK_AHEAD then
			local dx = boid.hx * PROBE_DISTANCE + math.randomf(-0.8, 0.8)
			local dz = boid.hz * PROBE_DISTANCE + math.randomf(-0.8, 0.8)
			local dy = boid.hy * PROBE_DISTANCE
			local length = math.sqrt(dx * dx + dy * dy + dz * dz)
			local hit = flock:TraceAhead(boid.x, boid.y, boid.z, dx, dy, dz, length, true)

			if hit and hit.distance > 0 then
				local n = hit.normal
				local dot = boid.hx * n.x + boid.hy * n.y + boid.hz * n.z
				local rx, ry, rz = boid.hx - 2 * dot * n.x, boid.hy - 2 * dot * n.y, boid.hz - 2 * dot * n.z
				local r = math.sqrt(rx * rx + ry * ry + rz * rz)
				local w = 1 - hit.distance / length
				w = w * w * definition.AvoidLand * OBSTACLE_WEIGHT
				boid.avoid_x, boid.avoid_y, boid.avoid_z = (rx / r + n.x) * w, (ry / r + n.y) * 0.2 * w, (rz / r + n.z) * w
			end
		end
	end

	ax, ay, az = ax + boid.avoid_x, ay + boid.avoid_y, az + boid.avoid_z
	local threats = flock.threats

	for t = 1, flock.threat_count, 3 do
		local dx, dy, dz = boid.x - threats[t], boid.y - threats[t + 1], boid.z - threats[t + 2]
		local distance2 = dx * dx + dy * dy + dz * dz

		if distance2 < SCARE_DISTANCE * SCARE_DISTANCE then
			local length = math.sqrt(distance2) + 0.0001
			local w = (
					1 - distance2 / (
						SCARE_DISTANCE * SCARE_DISTANCE
					)
				) * definition.AvoidLand / length
			ax, az = ax + dx * w, az + dz * w
		end
	end

	flock:Move(boid, definition, ax, ay, az, dt, smooth)

	if boid.y > water - SURFACE_MARGIN then
		boid.y = water - SURFACE_MARGIN
	elseif boid.y < boid.ground_y + SURFACE_MARGIN then
		boid.y = boid.ground_y + SURFACE_MARGIN
	end

	flock:SetPose(boid, 0)
end

return fish
