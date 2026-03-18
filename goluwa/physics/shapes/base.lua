local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local META = prototype.CreateTemplate("physics_shape_base")

function META.New(data)
	return META:CreateObject(data or {})
end

function META:GetTypeName()
	return "base"
end

function META:OnBodyGeometryChanged(body)
	self.Body = body or self.Body
end

function META:GetResolvedHull()
	return nil
end

function META:GetPolyhedron()
	return nil
end

function META:GetHalfExtents()
	return Vec3(0.5, 0.5, 0.5)
end

function META:GetMassProperties()
	return 0, Matrix33():SetZero()
end

function META:GeometryLocalToWorld(body, local_pos, position, rotation)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	return position + rotation:VecMul(local_pos)
end

function META:BuildCollisionLocalPoints()
	local extents = self:GetHalfExtents()
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
		Vec3(0, -ey, 0),
		Vec3(0, ey, 0),
		Vec3(ex, 0, 0),
		Vec3(-ex, 0, 0),
		Vec3(0, 0, ez),
		Vec3(0, 0, -ez),
	}
end

function META:GetCollisionLocalPoints(body)
	return self:BuildCollisionLocalPoints(body)
end

function META:BuildSupportLocalPoints()
	local extents = self:GetHalfExtents()
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

function META:GetSupportLocalPoints(body)
	return self:BuildSupportLocalPoints(body)
end

function META:GetBroadphaseAABB(body, position, rotation)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	local points = self:GetCollisionLocalPoints(body)

	if not (points and points[1]) then
		local half = self:GetHalfExtents(body)
		return AABB(
			position.x - half.x,
			position.y - half.y,
			position.z - half.z,
			position.x + half.x,
			position.y + half.y,
			position.z + half.z
		)
	end

	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, point in ipairs(points) do
		bounds:ExpandVec3(self:GeometryLocalToWorld(body, point, position, rotation))
	end

	return bounds
end

function META:SolveSupportContacts(body, dt, solve_contact)
	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * dt)
	local cast_up = body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local cast_distance = cast_up + downward + body:GetCollisionProbeDistance() + body:GetCollisionMargin()

	for _, local_point in ipairs(body:GetSupportLocalPoints()) do
		local point = body:GeometryLocalToWorld(local_point)
		local hit = physics.Sweep(
			point + physics.Up * cast_up,
			physics.Up * -cast_distance,
			0,
			body:GetOwner(),
			body:GetFilterFunction()
		)

		if hit then solve_contact(body, point, hit, dt) end
	end
end

function META:OnGroundedVelocityUpdate() end

function META:TraceAgainstBody()
	return nil
end

return META:Register()