local Vec3 = import("goluwa/structs/vec3.lua")
local units = {}

function units.ToEngine(vec)
	return Vec3(vec.x, vec.z, -vec.y)
end

return units
