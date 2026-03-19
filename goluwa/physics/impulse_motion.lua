local motion = import("goluwa/physics/motion.lua")
local impulse_motion = {}

function impulse_motion.CaptureBodyMotion(body)
	return {
		body = body,
		linear_velocity = body:GetVelocity():Copy(),
		angular_velocity = body:GetAngularVelocity():Copy(),
	}
end

function impulse_motion.GetPointVelocity(state, point)
	return motion.GetPointVelocity(state.body, state.linear_velocity, state.angular_velocity, point)
end

function impulse_motion.GetRelativePointVelocity(state_a, point_a, state_b, point_b)
	return impulse_motion.GetPointVelocity(state_b, point_b) - impulse_motion.GetPointVelocity(state_a, point_a)
end

function impulse_motion.ApplyImpulse(state, impulse, point)
	state.linear_velocity, state.angular_velocity = motion.ApplyImpulseToMotion(
		state.body,
		state.linear_velocity,
		state.angular_velocity,
		impulse,
		point
	)
	return state
end

function impulse_motion.ApplyPairImpulse(state_a, state_b, impulse, point_a, point_b)
	impulse_motion.ApplyImpulse(state_a, impulse * -1, point_a)
	impulse_motion.ApplyImpulse(state_b, impulse, point_b)
	return state_a, state_b
end

function impulse_motion.CommitBodyMotion(state, dt)
	motion.SetBodyMotionFromCurrentState(state.body, state.linear_velocity, state.angular_velocity, dt)
end

function impulse_motion.CommitPairMotion(state_a, state_b, dt)
	impulse_motion.CommitBodyMotion(state_a, dt)
	impulse_motion.CommitBodyMotion(state_b, dt)
end

return impulse_motion
