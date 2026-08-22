local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local motion = {}
local ROTATION_INTEGRATION_DELTA = Quat()
local POSITION_DELTA = Vec3()

function motion.IntegrateRotation(rotation, angular_velocity, dt)
	if angular_velocity:GetLengthSquared() == 0 then return rotation end

	local delta = ROTATION_INTEGRATION_DELTA
	delta.x, delta.y, delta.z, delta.w = angular_velocity.x, angular_velocity.y, angular_velocity.z, 0
	Quat.SetMul(delta, delta, rotation)
	local half_dt = 0.5 * dt
	rotation.x = rotation.x + half_dt * delta.x
	rotation.y = rotation.y + half_dt * delta.y
	rotation.z = rotation.z + half_dt * delta.z
	rotation.w = rotation.w + half_dt * delta.w
	rotation:Normalize()
	return rotation
end

function motion.ShiftBodyPosition(body, delta)
	if body:HasSolverMass() and delta:GetLength() > 0.01 then body:Wake() end

	body.Position:Add(delta)
	body.PreviousPosition:Add(delta)
end

function motion.SetBodyVelocityFromCurrentPosition(body, velocity, dt)
	body.Velocity = velocity:Copy()
end

function motion.SetBodyAngularVelocityFromCurrentRotation(body, angular_velocity, dt)
	if body:IsSolverImmovable() then return end

	body.AngularVelocity = angular_velocity:Copy()
end

function motion.SetBodyMotionFromCurrentState(body, linear_velocity, angular_velocity, dt)
	if body:IsSolverImmovable() then return end

	if body:HasSolverMass() and not body:GetAwake() then
		local linear_threshold = math.max(body.SleepLinearThreshold or 0, 0)
		local angular_threshold = math.max(body.SleepAngularThreshold or 0, 0)

		if
			linear_velocity:GetLength() > linear_threshold or
			angular_velocity:GetLength() > angular_threshold
		then
			body:Wake()
		end
	end

	motion.SetBodyVelocityFromCurrentPosition(body, linear_velocity, dt)
	motion.SetBodyAngularVelocityFromCurrentRotation(body, angular_velocity, dt)
end

local ROTATION_DELTA = Quat()
local ROTATION_DELTA_CONJUGATE = Quat()

function motion.GetAngularVelocityFromRotationDelta(previous_rotation, rotation, dt)
	Quat.SetConjugated(ROTATION_DELTA_CONJUGATE, previous_rotation)
	Quat.SetMul(ROTATION_DELTA, rotation, ROTATION_DELTA_CONJUGATE)
	ROTATION_DELTA:Normalize()
	local angular_velocity = Vec3(ROTATION_DELTA.x * 2 / dt, ROTATION_DELTA.y * 2 / dt, ROTATION_DELTA.z * 2 / dt)

	if ROTATION_DELTA.w < 0 then angular_velocity:Scale(-1) end

	return angular_velocity
end

function motion.ApplyBodyMotionDelta(body, previous_position, previous_rotation, dt)
	if body:IsSolverImmovable() then return end

	if not dt or dt <= 0 then dt = 1 / 60 end

	Vec3.SetSub(POSITION_DELTA, body.Position, previous_position)
	POSITION_DELTA:Scale(1 / dt)
	body.Velocity:Add(POSITION_DELTA)
	body.AngularVelocity:Add(motion.GetAngularVelocityFromRotationDelta(previous_rotation, body.Rotation, dt))
end

function motion.GetPointVelocity(body, linear_velocity, angular_velocity, point)
	if not point then return linear_velocity end

	return linear_velocity + angular_velocity:GetCross(point - body:GetPosition())
end

function motion.ApplyImpulseToMotion(body, linear_velocity, angular_velocity, impulse, point)
	if body:IsSolverImmovable() then return linear_velocity, angular_velocity end

	linear_velocity = linear_velocity + impulse * body.InverseMass

	if point then
		angular_velocity = angular_velocity + body:GetAngularVelocityDelta((point - body:GetPosition()):GetCross(impulse))
	end

	return linear_velocity, angular_velocity
end

return motion
