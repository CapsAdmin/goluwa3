local Vec3 = require("structs.vec3")
-- ORIENTATION / TRANSFORMATION
local orientation = library()
-- Current configuration: Y-up, X-right, Z-forward (right-handed)
orientation.RIGHT_VECTOR = Vec3(1, 0, 0)
orientation.UP_VECTOR = Vec3(0, 1, 0)
orientation.FORWARD_VECTOR = Vec3(0, 0, -1)
orientation.PROJECTION_Y_FLIP = -1 -- Set to 1 for Y-up NDC (OpenGL), -1 for Y-down NDC (Vulkan)
orientation.CULL_MODE = "front"
orientation.FRONT_FACE = "counter_clockwise"
return orientation
