local Vec3 = import("goluwa/structs/vec3.lua")
local constants = {
	EPSILON = 0.000001,
	DEFAULT_COLLISION_MARGIN = 0.02,
	-- L1 pose distance within which the cached world support contacts stay
	-- valid inside a substep. Iteration corrections are penetration-sized
	-- (sub-millimeter for resting bodies), so small movements re-project the
	-- cached contacts instead of re-sweeping. Bodies moving more than this
	-- per iteration (fast falls) keep re-detecting exactly as before.
	SUPPORT_POSE_TOLERANCE = 0.005,
	UP = Vec3(0, 1, 0),
}
return constants
