local Vec3 = import("goluwa/structs/vec3.lua")
local sample_points = {}
local DIAGONAL = 0.7071067811865476
local SPHERE_RINGS = {
	{horizontal = 0.5, vertical = 0.8660254037844386},
	{horizontal = DIAGONAL, vertical = DIAGONAL},
	{horizontal = 0.8660254037844386, vertical = 0.5},
}
local PLANAR_DIRECTIONS = {
	Vec3(1, 0, 0),
	Vec3(-1, 0, 0),
	Vec3(0, 0, 1),
	Vec3(0, 0, -1),
	Vec3(DIAGONAL, 0, DIAGONAL),
	Vec3(-DIAGONAL, 0, DIAGONAL),
	Vec3(DIAGONAL, 0, -DIAGONAL),
	Vec3(-DIAGONAL, 0, -DIAGONAL),
}
local BOX_SUPPORT_SAMPLES_X = {-1, -0.75, -0.5, 0, 0.5, 0.75, 1}
local BOX_SUPPORT_SAMPLES_Z = {-1, 0, 1}
local CAPSULE_DIAGONAL = 0.7071
local CAPSULE_VERTICAL = 0.2929

function sample_points.BuildBoxCornerPoints(extents)
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	return {
		Vec3(-ex, -ey, -ez),
		Vec3(ex, -ey, -ez),
		Vec3(ex, ey, -ez),
		Vec3(-ex, ey, -ez),
		Vec3(-ex, -ey, ez),
		Vec3(ex, -ey, ez),
		Vec3(ex, ey, ez),
		Vec3(-ex, ey, ez),
	}
end

function sample_points.BuildBoxCollisionPoints(extents)
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	local points = sample_points.BuildBoxCornerPoints(extents)
	points[#points + 1] = Vec3(0, -ey, 0)
	points[#points + 1] = Vec3(0, ey, 0)
	points[#points + 1] = Vec3(ex, 0, 0)
	points[#points + 1] = Vec3(-ex, 0, 0)
	points[#points + 1] = Vec3(0, 0, ez)
	points[#points + 1] = Vec3(0, 0, -ez)
	return points
end

function sample_points.BuildFlatBottomSupportPoints(extents)
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	return {
		Vec3(-ex, -ey, -ez),
		Vec3(ex, -ey, -ez),
		Vec3(ex, -ey, ez),
		Vec3(-ex, -ey, ez),
		Vec3(0, -ey, 0),
	}
end

function sample_points.BuildBoxSupportGridPoints(extents, samples_x, samples_z)
	samples_x = samples_x or BOX_SUPPORT_SAMPLES_X
	samples_z = samples_z or BOX_SUPPORT_SAMPLES_Z
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	local points = {}

	for _, sx in ipairs(samples_x) do
		for _, sz in ipairs(samples_z) do
			points[#points + 1] = Vec3(ex * sx, -ey, ez * sz)
		end
	end

	return points
end

function sample_points.BuildSphereCollisionPoints(radius)
	local diagonal = radius * DIAGONAL
	return {
		Vec3(0, -radius, 0),
		Vec3(0, radius, 0),
		Vec3(radius, 0, 0),
		Vec3(-radius, 0, 0),
		Vec3(0, 0, radius),
		Vec3(0, 0, -radius),
		Vec3(diagonal, diagonal, 0),
		Vec3(-diagonal, diagonal, 0),
		Vec3(diagonal, -diagonal, 0),
		Vec3(-diagonal, -diagonal, 0),
		Vec3(diagonal, 0, diagonal),
		Vec3(-diagonal, 0, diagonal),
		Vec3(diagonal, 0, -diagonal),
		Vec3(-diagonal, 0, -diagonal),
		Vec3(0, diagonal, diagonal),
		Vec3(0, -diagonal, diagonal),
		Vec3(0, diagonal, -diagonal),
		Vec3(0, -diagonal, -diagonal),
	}
end

function sample_points.BuildSphereSupportPoints(radius)
	local points = {Vec3(0, -radius, 0)}

	for _, ring in ipairs(SPHERE_RINGS) do
		for _, dir in ipairs(PLANAR_DIRECTIONS) do
			points[#points + 1] = Vec3(
				dir.x * radius * ring.horizontal,
				-radius * ring.vertical,
				dir.z * radius * ring.horizontal
			)
		end
	end

	return points
end

local function append_capsule_lower_hemisphere_points(points, radius, cylinder_half_height)
	points[#points + 1] = Vec3(radius * CAPSULE_DIAGONAL, -cylinder_half_height - radius * CAPSULE_VERTICAL, radius * CAPSULE_DIAGONAL)
	points[#points + 1] = Vec3(-radius * CAPSULE_DIAGONAL, -cylinder_half_height - radius * CAPSULE_VERTICAL, radius * CAPSULE_DIAGONAL)
	points[#points + 1] = Vec3(radius * CAPSULE_DIAGONAL, -cylinder_half_height - radius * CAPSULE_VERTICAL, -radius * CAPSULE_DIAGONAL)
	points[#points + 1] = Vec3(-radius * CAPSULE_DIAGONAL, -cylinder_half_height - radius * CAPSULE_VERTICAL, -radius * CAPSULE_DIAGONAL)
	return points
end

function sample_points.BuildCapsuleCollisionPoints(radius, cylinder_half_height)
	local points = {
		Vec3(0, -(cylinder_half_height + radius), 0),
		Vec3(0, cylinder_half_height + radius, 0),
		Vec3(radius, -cylinder_half_height, 0),
		Vec3(-radius, -cylinder_half_height, 0),
		Vec3(0, -cylinder_half_height, radius),
		Vec3(0, -cylinder_half_height, -radius),
		Vec3(radius, cylinder_half_height, 0),
		Vec3(-radius, cylinder_half_height, 0),
		Vec3(0, cylinder_half_height, radius),
		Vec3(0, cylinder_half_height, -radius),
	}
	return append_capsule_lower_hemisphere_points(points, radius, cylinder_half_height)
end

function sample_points.BuildCapsuleSupportPoints(radius, cylinder_half_height)
	local points = {
		Vec3(0, -(cylinder_half_height + radius), 0),
		Vec3(radius, -cylinder_half_height, 0),
		Vec3(-radius, -cylinder_half_height, 0),
		Vec3(0, -cylinder_half_height, radius),
		Vec3(0, -cylinder_half_height, -radius),
	}
	return append_capsule_lower_hemisphere_points(points, radius, cylinder_half_height)
end

return sample_points
