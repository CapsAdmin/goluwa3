local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics/shared.lua")
local kinematic_body = import("goluwa/ecs/components/3d/kinematic_body.lua")

local function approach_vec(current, target, delta)
	local diff = target - current
	local length = diff:GetLength()

	if length == 0 or delta <= 0 then return current end

	if length <= delta then return target end

	return current + diff / length * delta
end

local function update_control_velocity(body, dt)
	local velocity = body:GetVelocity()
	local desired = body:GetDesiredVelocity() or Vec3(0, 0, 0)
	local horizontal = Vec3(velocity.x, 0, velocity.z)
	local accel = body:GetGrounded() and body.Acceleration or body.AirAcceleration
	horizontal = approach_vec(horizontal, desired, accel * dt)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	if body:GetGrounded() and desired:GetLength() < 0.001 then
		local damping = math.exp(-body.LinearDamping * dt)
		velocity.x = velocity.x * damping
		velocity.z = velocity.z * damping
	end

	body:SetVelocity(velocity)
end

function physics.UpdateKinematicBody(body, dt)
	if not body.Enabled then return end

	update_control_velocity(body, dt)
	local velocity = body:GetVelocity()

	if body.MaxFallSpeed and velocity.y < -body.MaxFallSpeed then
		velocity.y = -body.MaxFallSpeed
	end

	if body.GravityScale ~= 0 then
		velocity = velocity + physics.Gravity * (body.GravityScale * dt)
	end

	body:SetVelocity(velocity)
	local transform = body.Owner.transform
	local position = transform:GetPosition():Copy()
	local predicted = position + velocity * dt
	local fall_distance = math.max(0, -velocity.y * dt)
	local cast_up = body.Radius + math.max(1.5, fall_distance + body.GroundSnapDistance)
	local cast_origin = predicted + physics.Up * cast_up
	local cast_distance = cast_up + body.Radius + body.GroundSnapDistance + fall_distance + 0.25
	local hit = physics.TraceDown(
		cast_origin,
		body.Radius,
		body.Owner,
		cast_distance,
		body.FilterFunction,
		{IgnoreRigidBodies = false}
	)
	body:SetGrounded(false)
	body:SetGroundNormal(physics.Up)
	local hit_normal = physics.GetHitNormal(hit, predicted)

	if hit and hit_normal and hit_normal.y >= body.MinGroundNormalY then
		local target = hit.position + hit_normal * (body.Radius + body.Skin)
		local max_snap = body.GroundSnapDistance + fall_distance

		if velocity.y <= 0 and predicted.y <= target.y + max_snap then
			predicted = target
			velocity.y = 0
			body:SetVelocity(velocity)
			body:SetGrounded(true)
			body:SetGroundNormal(hit_normal)
		end
	end

	transform:SetPosition(predicted)
end

physics.UpdateBody = physics.UpdateKinematicBody

function physics.UpdateKinematicBodies(dt)
	if not dt or dt <= 0 then return end

	for i = #(kinematic_body.Instances or {}), 1, -1 do
		physics.UpdateKinematicBody(kinematic_body.Instances[i], dt)
	end
end

return physics