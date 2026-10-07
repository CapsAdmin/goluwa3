local Vec3 = import("goluwa/structs/vec3.lua")
local units = {
	meters = 0.01905,
	phy_to_meters = 0.01905 / 0.0254,
}

function units.PositionToEngine(position)
	return Vec3(-position.y, position.z, -position.x) * units.meters
end

function units.PositionFromEngine(position)
	return Vec3(-position.z, -position.x, position.y) / units.meters
end

function units.PlaneToEngine(plane)
	return {
		normal = Vec3(-plane.normal.y, plane.normal.z, -plane.normal.x),
		dist = plane.dist * units.meters,
	}
end

function units.LengthToEngine(length)
	return length * units.meters
end

return units
