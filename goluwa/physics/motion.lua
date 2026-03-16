local Quat = import("goluwa/structs/quat.lua")
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
	body:SetVelocity(velocity)
	body.PreviousPosition = body.Position - velocity * dt
end

function motion.SetBodyAngularVelocityFromCurrentRotation(body, angular_velocity, dt)
	if body.IsSolverImmovable and body:IsSolverImmovable() then return end

	body.AngularVelocity = angular_velocity:Copy()
	body.PreviousRotation = motion.IntegrateRotation(body.Rotation, angular_velocity, -dt)
end

function motion.SetBodyMotionFromCurrentState(body, linear_velocity, angular_velocity, dt)
	if body.IsSolverImmovable and body:IsSolverImmovable() then return end

	motion.SetBodyVelocityFromCurrentPosition(body, linear_velocity, dt)
	motion.SetBodyAngularVelocityFromCurrentRotation(body, angular_velocity, dt)
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