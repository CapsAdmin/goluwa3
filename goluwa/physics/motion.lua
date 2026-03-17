local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local motion = {}

function motion.IntegrateRotation(rotation, angular_velocity, dt)
	if angular_velocity:GetLength() == 0 then return rotation:Copy() end

	local delta = Quat(angular_velocity.x, angular_velocity.y, angular_velocity.z, 0) * rotation
	return Quat(
		rotation.x + 0.5 * dt * delta.x,
		rotation.y + 0.5 * dt * delta.y,
		rotation.z + 0.5 * dt * delta.z,
		rotation.w + 0.5 * dt * delta.w
	):GetNormalized()
end

function motion.ShiftBodyPosition(body, delta)
	if
		body.HasSolverMass and
		body:HasSolverMass() and
		delta:GetLength() > 0.01 and
		body.Wake
	then
		body:Wake()
	end

	body.Position = body.Position + delta
	body.PreviousPosition = body.PreviousPosition + delta
end

function motion.SetBodyVelocityFromCurrentPosition(body, velocity, dt)
	body.Velocity = velocity:Copy()
end

function motion.SetBodyAngularVelocityFromCurrentRotation(body, angular_velocity, dt)
	if body.IsSolverImmovable and body:IsSolverImmovable() then return end

	body.AngularVelocity = angular_velocity:Copy()
end

function motion.SetBodyMotionFromCurrentState(body, linear_velocity, angular_velocity, dt)
	if body.IsSolverImmovable and body:IsSolverImmovable() then return end

	motion.SetBodyVelocityFromCurrentPosition(body, linear_velocity, dt)
	motion.SetBodyAngularVelocityFromCurrentRotation(body, angular_velocity, dt)
end

function motion.GetAngularVelocityFromRotationDelta(previous_rotation, rotation, dt)
	local delta = (rotation * previous_rotation:GetConjugated()):GetNormalized()
	local angular_velocity = Vec3(delta.x * 2 / dt, delta.y * 2 / dt, delta.z * 2 / dt)

	if delta.w < 0 then angular_velocity = angular_velocity * -1 end

	return angular_velocity
end

function motion.ApplyBodyMotionDelta(body, previous_position, previous_rotation, dt)
	if body.IsSolverImmovable and body:IsSolverImmovable() then return end

	if not dt or dt <= 0 then dt = 1 / 60 end

	body.Velocity = body.Velocity + (body.Position - previous_position) / dt
	body.AngularVelocity = body.AngularVelocity + motion.GetAngularVelocityFromRotationDelta(previous_rotation, body.Rotation, dt)
end

function motion.GetPointVelocity(body, linear_velocity, angular_velocity, point)
	if not point then return linear_velocity end

	return linear_velocity + angular_velocity:GetCross(point - body:GetPosition())
end

function motion.ApplyImpulseToMotion(body, linear_velocity, angular_velocity, impulse, point)
	if body.IsSolverImmovable and body:IsSolverImmovable() then
		return linear_velocity, angular_velocity
	end

	linear_velocity = linear_velocity + impulse * body.InverseMass

	if point then
		angular_velocity = angular_velocity + body:GetAngularVelocityDelta((point - body:GetPosition()):GetCross(impulse))
	end

	return linear_velocity, angular_velocity
end

return motion