local Vec3 = import("goluwa/structs/vec3.lua")
local planet = import("goluwa/planet.lua")
local units = {}

function units.ToEngine(vec)
	return Vec3(vec.x, vec.z, -vec.y)
end

function units.PositionToEngine(vec)
	local position = units.ToEngine(vec)
	position.y = position.y - planet.GetDrop(position.x, position.z)
	return position
end

return units
