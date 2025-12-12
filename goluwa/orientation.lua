-- ORIENTATION / TRANSFORMATION
-- Coordinate system configuration - change these to switch between coordinate systems
-- This module defines the fundamental orientation for the entire engine
local orientation = {}
-- Current configuration: Y-up, X-right, Z-forward (right-handed)
-- This is the compile-time coordinate system definition
-- Primary axis vectors (as {x, y, z} tables)
orientation.UP_VECTOR = {0, 1, 0}
orientation.DOWN_VECTOR = {0, -1, 0}
orientation.RIGHT_VECTOR = {1, 0, 0}
orientation.LEFT_VECTOR = {-1, 0, 0}
orientation.FORWARD_VECTOR = {0, 0, 1}
orientation.BACKWARD_VECTOR = {0, 0, -1}
-- Axis indices (0=X, 1=Y, 2=Z) for use in rotation functions
orientation.UP_AXIS = 1 -- Y axis
orientation.RIGHT_AXIS = 0 -- X axis
orientation.FORWARD_AXIS = 2 -- Z axis
-- Rotation axis names to indices mapping
orientation.PITCH_AXIS = orientation.RIGHT_AXIS -- Rotation around X (right) axis
orientation.YAW_AXIS = orientation.UP_AXIS -- Rotation around Y (up) axis  
orientation.ROLL_AXIS = orientation.FORWARD_AXIS -- Rotation around Z (forward) axis
-- Graphics API specific: does the projection need to flip Y for NDC?
-- Vulkan uses Y-down NDC, so we flip Y for Y-up worlds
orientation.PROJECTION_Y_FLIP = -1 -- Set to 1 for Y-up NDC (OpenGL), -1 for Y-down NDC (Vulkan)
-- Face winding order for culling
orientation.CULL_MODE = "front"
orientation.FRONT_FACE = "counter_clockwise"

-- Helper to get axis vector as unpacked x, y, z
function orientation.GetUpVector()
	return orientation.UP_VECTOR[1],
	orientation.UP_VECTOR[2],
	orientation.UP_VECTOR[3]
end

function orientation.GetDownVector()
	return orientation.DOWN_VECTOR[1],
	orientation.DOWN_VECTOR[2],
	orientation.DOWN_VECTOR[3]
end

function orientation.GetRightVector()
	return orientation.RIGHT_VECTOR[1],
	orientation.RIGHT_VECTOR[2],
	orientation.RIGHT_VECTOR[3]
end

function orientation.GetLeftVector()
	return orientation.LEFT_VECTOR[1],
	orientation.LEFT_VECTOR[2],
	orientation.LEFT_VECTOR[3]
end

function orientation.GetForwardVector()
	return orientation.FORWARD_VECTOR[1],
	orientation.FORWARD_VECTOR[2],
	orientation.FORWARD_VECTOR[3]
end

function orientation.GetBackwardVector()
	return orientation.BACKWARD_VECTOR[1],
	orientation.BACKWARD_VECTOR[2],
	orientation.BACKWARD_VECTOR[3]
end

return orientation
