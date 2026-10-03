local Vec3 = import("goluwa/structs/vec3.lua")
local orientation = library()
orientation.RIGHT_VECTOR = Vec3(1, 0, 0)
orientation.UP_VECTOR = Vec3(0, 1, 0)
orientation.FORWARD_VECTOR = Vec3(0, 0, -1)
orientation.PROJECTION_Y_FLIP = -1
orientation.CULL_MODE = "front"
orientation.FRONT_FACE = "counter_clockwise"
return orientation
