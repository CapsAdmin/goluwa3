local frog = {}
local GRAVITY = 10
local MIN_REST_TIME = 2
local MAX_REST_TIME = 7
local SPAWN_HEIGHT = 5
local STEP_HEIGHT = 0.5
local OBSTACLE_RETRIES = 4
local IDLE_SOUND_RATE = 0.12

local function land(flock, boid, definition)
	boid.on_ground = true
	boid.speed = 0
	boid.vx, boid.vy, boid.vz = 0, 0, 0
	flock:Play(boid, definition.IdleClips[math.random(#definition.IdleClips)], 1)
end

function frog.Spawn(flock, definition, origin)
	local angle = math.randomf(0, math.pi * 2)
	local distance = math.sqrt(math.random()) * flock.Radius
	local x, z = origin.x + math.cos(angle) * distance, origin.z + math.sin(angle) * distance
	local y = flock:FindGround(x, origin.y + SPAWN_HEIGHT, z, SPAWN_HEIGHT * 2)

	if not y then return end

	local boid = flock:SpawnBoid(definition, x, y, z, -math.sin(angle), 0, -math.cos(angle))
	boid.rest = math.randomf(0, MAX_REST_TIME)
	land(flock, boid, definition)
	flock:SetPose(boid, 0)
	return boid
end

local function jump(flock, boid, definition, origin, from_x, from_z)
	local hx, hz

	if from_x then
		hx, hz = boid.x - from_x, boid.z - from_z
	else
		hx, hz = boid.hx, boid.hz
		local dx, dz = boid.x - origin.x, boid.z - origin.z

		if dx * dx + dz * dz > flock.Radius * flock.Radius then
			local radius = flock.Radius
			hx = origin.x + math.randomf(-radius, radius) - boid.x
			hz = origin.z + math.randomf(-radius, radius) - boid.z
		end
	end

	local length = math.sqrt(hx * hx + hz * hz)

	if length < 0.0001 then
		local angle = math.randomf(0, math.pi * 2)
		hx, hz, length = math.cos(angle), math.sin(angle), 1
	end

	hx, hz = hx / length + math.randomf(-0.4, 0.4), hz / length + math.randomf(-0.4, 0.4)

	for _ = 1, OBSTACLE_RETRIES do
		local reach = definition.Size.z * 5

		if
			not definition.ObstacleAvoidance or
			not flock:TraceAhead(boid.x, boid.y + definition.Size.y, boid.z, hx, 0, hz, reach)
		then
			break
		end

		local angle = math.randomf(0, math.pi * 2)
		hx, hz = math.cos(angle), math.sin(angle)
	end

	local up = 0.5 + math.randomf(0, 0.6)
	length = math.sqrt(hx * hx + up * up + hz * hz)
	local speed = math.randomf(definition.MinSpeed, definition.MaxSpeed)
	boid.vx, boid.vy, boid.vz = hx / length * speed, up / length * speed, hz / length * speed
	local horizontal = math.sqrt(hx * hx + hz * hz)
	boid.hx, boid.hy, boid.hz = hx / horizontal, 0, hz / horizontal
	boid.speed = speed
	boid.on_ground = false
	boid.rest = math.randomf(MIN_REST_TIME, MAX_REST_TIME)
	flock:Play(boid, definition.WalkClip, definition.AnimSpeed, false)
end

function frog.Update(flock, boid, definition, origin, dt)
	if boid.on_ground then
		boid.rest = boid.rest - dt
		local scare_distance2 = definition.ScareDistance * definition.ScareDistance
		local threats = flock.threats

		for t = 1, flock.threat_count, 3 do
			local dx, dz = boid.x - threats[t], boid.z - threats[t + 2]

			if dx * dx + dz * dz < scare_distance2 then
				if definition.Sounds and math.random() < 0.5 then
					flock:PlaySound(boid, "Scared")
				end

				jump(flock, boid, definition, origin, threats[t], threats[t + 2])
				return
			end
		end

		if flock.scare_ratio > 0 then
			local dx, dz = boid.x - flock.scare_x, boid.z - flock.scare_z

			if dx * dx + dz * dz < flock.scare_radius * flock.scare_radius then
				jump(flock, boid, definition, origin, flock.scare_x, flock.scare_z)
				return
			end
		end

		if boid.rest <= 0 then jump(flock, boid, definition, origin) end

		if definition.Sounds and math.random() < dt * IDLE_SOUND_RATE then
			flock:PlaySound(boid, "Idle")
		end

		return
	end

	local x, y, z = boid.x, boid.y, boid.z
	boid.vy = boid.vy - GRAVITY * dt
	local nx, ny, nz = x + boid.vx * dt, y + boid.vy * dt, z + boid.vz * dt

	if
		flock:TraceAhead(
			x,
			y + definition.Size.y,
			z,
			boid.vx,
			0,
			boid.vz,
			math.sqrt(boid.vx * boid.vx + boid.vz * boid.vz) * dt + definition.Size.z * 0.5
		)
	then
		nx, nz = x, z
		boid.vx, boid.vz = 0, 0
	end

	local ground = flock:FindGround(nx, math.max(y, ny) + STEP_HEIGHT, nz, STEP_HEIGHT + math.max(y - ny, 0) + 1)
	boid.x, boid.y, boid.z = nx, ny, nz

	if ground and ny <= ground then
		boid.y = ground
		land(flock, boid, definition)
	elseif not ground and ny < y - 50 then
		boid.x, boid.y, boid.z = x, y, z
		land(flock, boid, definition)
	end

	flock:SetPose(boid, 0)
end

return frog
