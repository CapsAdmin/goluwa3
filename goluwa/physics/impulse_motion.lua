local motion = import("goluwa/physics/motion.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local impulse_motion = {}
local MOTION_STATE_A = {linear_velocity = Vec3(), angular_velocity = Vec3()}
local MOTION_STATE_B = {linear_velocity = Vec3(), angular_velocity = Vec3()}
local RELATIVE_VELOCITY = Vec3()
local POINT_A_VELOCITY = Vec3()
local CROSS_IMPULSE = Vec3()

local function capture_body_motion(state, body)
	state.body = body
	-- position and immovability are invariant during the impulse pass, so
	-- capturing them here avoids re-fetching them per contact
	state.position = body:GetPosition()
	state.immovable = body:IsSolverImmovable()
	local linear = body:GetVelocity()
	local angular = body:GetAngularVelocity()
	local state_linear = state.linear_velocity
	state_linear.x, state_linear.y, state_linear.z = linear.x, linear.y, linear.z
	local state_angular = state.angular_velocity
	state_angular.x, state_angular.y, state_angular.z = angular.x, angular.y, angular.z
end

function impulse_motion.CapturePairMotion(body_a, body_b)
	capture_body_motion(MOTION_STATE_A, body_a)
	capture_body_motion(MOTION_STATE_B, body_b)
	return MOTION_STATE_A, MOTION_STATE_B
end

local function point_velocity_into(out, state, point)
	local linear = state.linear_velocity
	local angular = state.angular_velocity

	if not point then
		out.x, out.y, out.z = linear.x, linear.y, linear.z
		return out
	end

	local position = state.position
	local rx = point.x - position.x
	local ry = point.y - position.y
	local rz = point.z - position.z
	out.x = linear.x + angular.y * rz - angular.z * ry
	out.y = linear.y + angular.z * rx - angular.x * rz
	out.z = linear.z + angular.x * ry - angular.y * rx
	return out
end

function impulse_motion.GetRelativePointVelocity(state_a, point_a, state_b, point_b)
	point_velocity_into(RELATIVE_VELOCITY, state_b, point_b)
	point_velocity_into(POINT_A_VELOCITY, state_a, point_a)
	RELATIVE_VELOCITY.x = RELATIVE_VELOCITY.x - POINT_A_VELOCITY.x
	RELATIVE_VELOCITY.y = RELATIVE_VELOCITY.y - POINT_A_VELOCITY.y
	RELATIVE_VELOCITY.z = RELATIVE_VELOCITY.z - POINT_A_VELOCITY.z
	return RELATIVE_VELOCITY
end

local function apply_impulse_in_place(state, impulse, magnitude, point, sign)
	local body = state.body

	if state.immovable then return end

	local linear = state.linear_velocity
	local scale = sign * magnitude * body.InverseMass
	linear.x = linear.x + impulse.x * scale
	linear.y = linear.y + impulse.y * scale
	linear.z = linear.z + impulse.z * scale

	if not point then return end

	local angular = state.angular_velocity
	local position = state.position
	local cross = CROSS_IMPULSE
	cross.x, cross.y, cross.z = point.x - position.x, point.y - position.y, point.z - position.z
	Vec3.Cross(cross, impulse)
	local delta = body:GetAngularVelocityDelta(cross)
	local angular_scale = sign * magnitude
	angular.x = angular.x + angular_scale * delta.x
	angular.y = angular.y + angular_scale * delta.y
	angular.z = angular.z + angular_scale * delta.z
end

function impulse_motion.ApplyPairImpulse(state_a, state_b, impulse, magnitude, point_a, point_b)
	apply_impulse_in_place(state_a, impulse, magnitude, point_a, -1)
	apply_impulse_in_place(state_b, impulse, magnitude, point_b, 1)
	return state_a, state_b
end

function impulse_motion.CommitPairMotion(state_a, state_b, dt)
	motion.SetBodyMotionFromCurrentState(state_a.body, state_a.linear_velocity, state_a.angular_velocity, dt)
	motion.SetBodyMotionFromCurrentState(state_b.body, state_b.linear_velocity, state_b.angular_velocity, dt)
end

return impulse_motion
