local bird = {}
local PROBE_INTERVAL = 0.2
local PROBE_DISTANCE = 10
local GROUND_INTERVAL = 0.5
local MAX_CLIMB = math.sin(math.pi / 4)
local BANK_RATE = 10

function bird.Spawn(flock, definition, origin)
	local radius = flock.Radius
	local x, z = origin.x + math.randomf(-radius, radius), origin.z + math.randomf(-radius, radius)
	local y = origin.y + math.randomf(definition.HeightMin, definition.HeightMax)
	local angle = math.randomf(0, math.pi * 2)
	local boid = flock:SpawnBoid(definition, x, y, z, math.cos(angle), 0, math.sin(angle))
	boid.speed = math.randomf(definition.MinSpeed, definition.MaxSpeed)
	boid.desired_y = origin.y + math.randomf(definition.HeightMin, definition.HeightMax)
	boid.tx, boid.ty, boid.tz = origin.x, origin.y, origin.z
	boid.bank = 0
	boid.ground_y = -math.huge
	boid.ground_time = 0
	boid.probe_time = math.randomf(0, PROBE_INTERVAL)
	boid.avoid_x, boid.avoid_y, boid.avoid_z = 0, 0, 0
	flock:SetPose(boid, 0)
	return boid
end

function bird.Update(flock, boid, definition, origin, dt, smooth)
	local target_speed = (definition.MaxSpeed + definition.MinSpeed) / 2
	local ax = -boid.hx * (boid.speed - target_speed) * 0.5
	local az = -boid.hz * (boid.speed - target_speed) * 0.5
	local dh = boid.desired_y - boid.y
	local ay = math.exp(-(dh * dh) / 9) * definition.KeepHeight

	if definition.Align ~= 0 then
		local sx, sy, sz, alx, aly, alz, cx, cy, cz = flock:Flocking(boid, definition)
		local separation = definition.Separation
		ax = ax + alx * definition.Align + cx * definition.Cohesion + sx * separation
		ay = ay + aly * definition.Align + cy * definition.Cohesion + sy * separation
		az = az + alz * definition.Align + cz * definition.Cohesion + sz * separation
	end

	local height = boid.y - origin.y

	if height < definition.HeightMin then
		local v = 1 - height / math.max(definition.HeightMin, 0.0001)
		ay = ay + v * v * definition.AvoidLand
	elseif height > definition.HeightMax then
		ay = ay - (height - definition.HeightMax) * 0.1
	else
		ay = -(boid.hy * boid.hy * boid.hy * 100)
	end

	if math.random() < dt then
		local radius = flock.Radius
		boid.tx = origin.x + math.randomf(-radius, radius)
		boid.ty = math.max(origin.y + math.randomf(-radius, radius), boid.ground_y + definition.HeightMin)
		boid.tz = origin.z + math.randomf(-radius, radius)
	end

	ax = ax + (boid.tx - boid.x) * definition.OriginFactor
	ay = ay + (boid.ty - boid.y) * definition.OriginFactor
	az = az + (boid.tz - boid.z) * definition.OriginFactor

	if definition.ObstacleAvoidance then
		boid.probe_time = boid.probe_time - dt

		if boid.probe_time <= 0 then
			boid.probe_time = PROBE_INTERVAL
			local hit = flock:TraceAhead(boid.x, boid.y, boid.z, boid.hx, boid.hy, boid.hz, PROBE_DISTANCE, true)
			boid.avoid_x, boid.avoid_y, boid.avoid_z = 0, 0, 0

			if hit then
				local w = 1 - hit.distance / PROBE_DISTANCE
				w = w * w * definition.AvoidLand
				boid.avoid_x, boid.avoid_y, boid.avoid_z = hit.normal.x * w, hit.normal.y * w, hit.normal.z * w
			end
		end

		ax, ay, az = ax + boid.avoid_x, ay + boid.avoid_y, az + boid.avoid_z
	end

	local prev_ax, prev_az = boid.ax, boid.az
	flock:Move(boid, definition, ax, ay, az, dt, smooth)

	if boid.hy > MAX_CLIMB then
		local horizontal = math.sqrt(boid.hx * boid.hx + boid.hz * boid.hz)
		local scale = math.cos(math.pi / 4) / math.max(horizontal, 0.0001)
		boid.hx, boid.hy, boid.hz = boid.hx * scale, MAX_CLIMB, boid.hz * scale
	end

	boid.ground_time = boid.ground_time - dt

	if boid.ground_time <= 0 then
		boid.ground_time = GROUND_INTERVAL
		local hit = flock:TraceDown(boid.x, boid.y + 1, boid.z, definition.HeightMax * 2 + 50, true)
		boid.ground_y = hit and hit.position.y or -math.huge
	end

	local floor = math.max(boid.ground_y, flock:GetWaterLevel() or -math.huge) - 0.2

	if boid.y < floor then boid.y = floor end

	local side_x, side_z = -boid.hz, boid.hx
	local side_length = math.sqrt(side_x * side_x + side_z * side_z)
	local accel_length = math.sqrt(prev_ax * prev_ax + prev_az * prev_az)
	local bank_target = 0

	if side_length > 0.0001 and accel_length > 0.0001 then
		bank_target = (prev_ax * side_x + prev_az * side_z) / (side_length * accel_length)
	end

	boid.bank = boid.bank + (bank_target - boid.bank) * math.min(dt * BANK_RATE, 1)
	local range = math.max(definition.MaxSpeed - definition.MinSpeed, 0.0001)
	local rate = ((boid.speed - definition.MinSpeed) / range * 0.6 + 0.4) * definition.AnimSpeed
	flock:Play(boid, definition.WalkClip, rate)
	flock:SetPose(boid, -boid.bank * 0.5)
end

return bird
