local fluid = import("goluwa/physics/fluid.lua")
local ground = {}
local AVOID_FACTOR = 10
local SCARE_FACTOR = 10
local OBSTACLE_WEIGHT = 10
local MIN_REST_TIME = 2
local MAX_REST_TIME = 4
local MAX_WALK_TIME = 5
local PROBE_INTERVAL = 0.1
local STEP_INTERVAL = 0.1
local STEP_HEIGHT = 0.4
local DROP_HEIGHT = 1.5
local SPAWN_HEIGHT = 5
local IDLE_SOUND_RATE = 0.12
local SCARED_IDLE_SOUND_RATE = 0.24
local SCARED_SOUND_RATE = 0.23

local function start_walking(boid, definition)
	boid.idle = false
	boid.action_time = 0
	boid.max_walk = math.randomf(0, MAX_WALK_TIME)
	boid.speed = definition.MinSpeed
end

local function start_idling(flock, boid, definition)
	boid.idle = true
	boid.action_time = 0
	boid.max_idle = math.randomf(MIN_REST_TIME, MAX_REST_TIME)
	boid.speed = 0
	boid.ax, boid.az = 0, 0
	flock:Play(boid, definition.IdleClips[math.random(#definition.IdleClips)], 1)
end

function ground.Spawn(flock, definition, origin)
	local angle = math.randomf(0, math.pi * 2)
	local distance = math.sqrt(math.random()) * flock.Radius
	local x, z = origin.x + math.cos(angle) * distance, origin.z + math.sin(angle) * distance
	local bottom = origin.y - SPAWN_HEIGHT
	local hit = flock:TraceDown(x, origin.y + SPAWN_HEIGHT, z, SPAWN_HEIGHT * 2)

	-- look through roofs and shelves above the flock
	while hit and hit.position.y > origin.y + STEP_HEIGHT do
		local top = hit.position.y - 0.05
		hit = flock:TraceDown(x, top, z, top - bottom)
	end

	if not hit or hit.normal.y < flock.MinGroundNormalY then return end

	local yaw = math.randomf(0, math.pi * 2)
	local boid = flock:SpawnBoid(definition, x, hit.position.y, z, -math.sin(yaw), 0, -math.cos(yaw))
	boid.tx, boid.tz = x, z
	boid.avoid_x, boid.avoid_z = 0, 0
	boid.probe_time = math.randomf(0, PROBE_INTERVAL)
	boid.step_time = 0
	boid.ground_y = hit.position.y
	start_idling(flock, boid, definition)
	boid.action_time = math.randomf(0, boid.max_idle)
	flock:SetPose(boid, 0)
	return boid
end

function ground.Update(flock, boid, definition, origin, dt, smooth)
	local x, z = boid.x, boid.z
	local ax = -boid.hx * (boid.speed - definition.MinSpeed) * 0.4
	local az = -boid.hz * (boid.speed - definition.MinSpeed) * 0.4
	local scared = false

	if math.random() < dt then
		local radius = flock.Radius
		boid.tx = origin.x + math.randomf(-radius, radius)
		boid.tz = origin.z + math.randomf(-radius, radius)
	end

	ax = ax + (boid.tx - x) * definition.OriginFactor
	az = az + (boid.tz - z) * definition.OriginFactor

	if definition.Align ~= 0 then
		local sx, _, sz, alx, _, alz, cx, _, cz = flock:Flocking(boid, definition)
		ax = ax + alx * definition.Align + cx * definition.Cohesion + sx
		az = az + alz * definition.Align + cz * definition.Cohesion + sz
	end

	local scare_distance = definition.ScareDistance
	local threats = flock.threats

	for t = 1, flock.threat_count, 3 do
		local dx, dz = x - threats[t], z - threats[t + 2]
		local distance2 = dx * dx + dz * dz

		if distance2 < scare_distance * scare_distance then
			dx, dz = dx + math.randomf(-2, 2), dz + math.randomf(-2, 2)
			local length = math.sqrt(dx * dx + dz * dz) + 0.0001
			local factor = (1 - distance2 / (scare_distance * scare_distance)) * AVOID_FACTOR / length
			ax, az = ax + dx * factor, az + dz * factor
			scared = true
		end
	end

	if flock.scare_ratio > 0 then
		local dx, dz = x - flock.scare_x, z - flock.scare_z
		local distance2 = dx * dx + dz * dz
		local radius2 = flock.scare_radius * flock.scare_radius

		if distance2 < radius2 then
			local length = math.sqrt(distance2) + 0.0001
			local factor = (1 - distance2 / radius2) * SCARE_FACTOR / length
			ax, az = ax + dx * factor, az + dz * factor
			scared = true
		end
	end

	if not boid.idle and definition.ObstacleAvoidance then
		boid.probe_time = boid.probe_time - dt

		if boid.probe_time <= 0 then
			boid.probe_time = PROBE_INTERVAL
			local reach = definition.Size.z
			local dx, dz = boid.hx * reach + math.randomf(-0.25, 0.25),
			boid.hz * reach + math.randomf(-0.25, 0.25)
			local length = math.sqrt(dx * dx + dz * dz)
			local hit = flock:TraceAhead(
				x + boid.hx * reach * 0.5,
				boid.y + definition.Center.y,
				z + boid.hz * reach * 0.5,
				dx,
				0,
				dz,
				length
			)

			if hit and hit.distance > 0 then
				local nx, nz = hit.normal.x, hit.normal.z
				local dot = boid.hx * nx + boid.hz * nz
				local weight = (1 - hit.distance / length) * AVOID_FACTOR * OBSTACLE_WEIGHT
				local rx, rz = boid.hx - 2 * dot * nx + nx, boid.hz - 2 * dot * nz + nz
				boid.avoid_x = boid.avoid_x * smooth + rx * weight * (1 - smooth)
				boid.avoid_z = boid.avoid_z * smooth + rz * weight * (1 - smooth)
			end
		end
	end

	ax, az = ax + boid.avoid_x, az + boid.avoid_z
	boid.avoid_x, boid.avoid_z = boid.avoid_x * smooth, boid.avoid_z * smooth

	if definition.FreezeWhenScared then
		if scared then
			if not boid.idle then start_idling(flock, boid, definition) end

			boid.action_time = 0
		elseif boid.scared then
			start_walking(boid, definition)
		end
	elseif scared and boid.idle then
		start_walking(boid, definition)
	end

	if definition.Sounds then
		if scared and not boid.scared and definition.FreezeWhenScared then
			flock:PlaySound(boid, "Scared")
		elseif
			scared and
			not definition.FreezeWhenScared and
			math.random() < dt * SCARED_SOUND_RATE
		then
			flock:PlaySound(boid, "Scared")
		end

		if math.random() < dt * (scared and SCARED_IDLE_SOUND_RATE or IDLE_SOUND_RATE) then
			flock:PlaySound(boid, "Idle")
		end
	end

	boid.scared = scared
	boid.action_time = boid.action_time + dt

	if boid.idle then
		if boid.action_time > boid.max_idle then start_walking(boid, definition) end
	elseif boid.action_time > boid.max_walk and not scared then
		start_idling(flock, boid, definition)
	end

	if boid.idle then return end

	boid.step_time = boid.step_time - dt

	-- walls and ground are traced a step ahead, the step the boid covers until the next check
	if boid.step_time <= 0 then
		boid.step_time = STEP_INTERVAL
		local ahead = math.max(boid.speed, definition.MinSpeed) * STEP_INTERVAL
		local blocked = flock:TraceAhead(
			x,
			boid.y + definition.Center.y,
			z,
			boid.hx,
			0,
			boid.hz,
			ahead + definition.Size.z * 0.5
		)
		local ahead_x, ahead_z = x + boid.hx * ahead, z + boid.hz * ahead
		local ground_y = not blocked and
			flock:FindGround(ahead_x, boid.y + STEP_HEIGHT, ahead_z, STEP_HEIGHT + DROP_HEIGHT)

		if
			ground_y and
			(
				not definition.AvoidWater or
				not fluid.HasRegions()
				or
				(
					fluid.GetDepth(ahead_x, ground_y + 0.05, ahead_z) or
					0
				) <= 0
			)
		then
			boid.ground_y = ground_y
		else
			boid.hx, boid.hz = -boid.hx, -boid.hz
			boid.ax, boid.az = 0, 0
			boid.tx, boid.tz = origin.x, origin.z
			boid.ground_y = boid.y
		end
	end

	flock:Move(boid, definition, ax, 0, az, dt, smooth, definition.TurnRate)
	boid.hy = 0
	boid.y = boid.y + (boid.ground_y - boid.y) * math.min(dt / (boid.step_time + dt), 1)
	local rate = definition.ClipSpeed and
		boid.speed / definition.ClipSpeed or
		(
			(
				boid.speed - definition.MinSpeed
			) / math.max(definition.MaxSpeed - definition.MinSpeed, 0.0001) * 0.6 + 0.4
		) * definition.AnimSpeed
	flock:Play(boid, definition.WalkClip, math.min(rate, definition.MaxClipRate))
	flock:SetPose(boid, 0)
end

return ground
