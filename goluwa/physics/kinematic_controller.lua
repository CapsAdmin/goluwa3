local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics/shared.lua")
local module = {}

local function approach_vec(current, target, delta)
	local diff = target - current
	local length = diff:GetLength()

	if length == 0 or delta <= 0 then return current end

	if length <= delta then return target end

	return current + diff / length * delta
end

local function get_trace_radius(body)
	local shape = body:GetPhysicsShape()

	if shape and shape.GetRadius then return shape:GetRadius() end

	local half_extents = body:GetHalfExtents()
	return math.max(0, math.min(half_extents.x, half_extents.z))
end

function module.UpdateBody(body, dt, gravity)
	if not body then return end

	local owner = body.Owner
	local controller = body.GetKinematicController and body:GetKinematicController() or nil

	if not (owner and controller and controller.Enabled) then return end

	local controlled_body = controller.GetRigidBody and controller:GetRigidBody() or nil

	if controlled_body ~= body then return end

	if controller.EnsureKinematicBody then controller:EnsureKinematicBody() end

	if not (body.IsKinematic and body:IsKinematic()) then return end

	local velocity = controller.GetVelocity and
		controller:GetVelocity():Copy() or
		body:GetVelocity():Copy()
	local grounded = body:GetGrounded()
	local desired = controller:GetDesiredVelocity() or Vec3(0, 0, 0)
	local horizontal

	if grounded then
		horizontal = desired:Copy()
	else
		horizontal = Vec3(velocity.x, 0, velocity.z)
		local accel = controller.AirAcceleration or controller.Acceleration
		horizontal = approach_vec(horizontal, desired, accel * dt)
	end

	velocity.x = horizontal.x
	velocity.z = horizontal.z

	if grounded and desired:GetLength() < 0.001 then
		local damping = math.exp(-body.LinearDamping * dt)
		velocity.x = velocity.x * damping
		velocity.z = velocity.z * damping
	end

	if controller.MaxFallSpeed and velocity.y < -controller.MaxFallSpeed then
		velocity.y = -controller.MaxFallSpeed
	end

	if grounded then
		if velocity.y < 0 then velocity.y = 0 end
	elseif body.GravityScale ~= 0 then
		velocity = velocity + gravity * (body.GravityScale * dt)
	end

	if controller.SetVelocity then controller:SetVelocity(velocity) end

	body.Velocity = velocity
	body:SetGrounded(false)
	body:SetGroundNormal(physics.Up)
	local radius = get_trace_radius(body)
	local predicted = body:GetPosition() + velocity * dt
	local fall_distance = math.max(0, -velocity.y * dt)
	local cast_up = radius + math.max(1.5, fall_distance + controller.GroundSnapDistance)
	local cast_origin = predicted + physics.Up * cast_up
	local cast_distance = cast_up + radius + controller.GroundSnapDistance + fall_distance + 0.25
	local hit = physics.TraceDown(
		cast_origin,
		radius,
		owner,
		cast_distance,
		body.FilterFunction,
		{
			IgnoreRigidBodies = false,
			IgnoreKinematicBodies = true,
		}
	)
	local hit_normal = physics.GetHitNormal(hit, predicted)

	if hit and hit_normal and hit_normal.y >= body.MinGroundNormalY then
		local target = hit.position + hit_normal * (radius + body.CollisionMargin)
		local max_snap = controller.GroundSnapDistance + fall_distance

		if velocity.y <= 0 and predicted.y <= target.y + max_snap then
			predicted = target
			velocity.y = 0

			if controller.SetVelocity then controller:SetVelocity(velocity) end

			body.Velocity = velocity
			body:SetGrounded(true)
			body:SetGroundNormal(hit_normal)
		end
	end

	body.Position = predicted
end

return module