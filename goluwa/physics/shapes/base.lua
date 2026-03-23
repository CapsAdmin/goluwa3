local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local mass_properties = import("goluwa/physics/shapes/mass_properties.lua")
local sample_points = import("goluwa/physics/shapes/sample_points.lua")
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

function META:GetAutomaticMass()
	return 0
end

function META:ResolveBodyMass(body, automatic_mass)
	return mass_properties.ResolveBodyMass(body, automatic_mass)
end

function META:ZeroMassInertia(mass)
	return mass_properties.ZeroIfStatic(mass)
end

function META:BuildBoxInertia(mass, sx, sy, sz)
	return mass_properties.BuildBoxInertia(mass, sx, sy, sz)
end

function META:BuildSphereInertia(mass, radius)
	return mass_properties.BuildSphereInertia(mass, radius)
end

function META:BuildInertia(mass)
	local zero_mass, zero_inertia = self:ZeroMassInertia(mass)

	if zero_mass then return zero_mass, zero_inertia end

	return mass, Matrix33():SetZero()
end

function META:GetMassProperties(body)
	local mass = self:ResolveBodyMass(body, self:GetAutomaticMass(body))
	return self:BuildInertia(mass, body)
end

function META:GeometryLocalToWorld(body, local_pos, position, rotation, out)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	out = rotation:VecMul(local_pos, out)
	out.x = out.x + position.x
	out.y = out.y + position.y
	out.z = out.z + position.z
	return out
end

function META:BuildCollisionLocalPoints()
	return sample_points.BuildBoxCollisionPoints(self:GetHalfExtents())
end

function META:GetCollisionLocalPoints(body)
	return self:BuildCollisionLocalPoints(body)
end

function META:BuildSupportLocalPoints()
	return sample_points.BuildFlatBottomSupportPoints(self:GetHalfExtents())
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

	for i = 1, #points do
		local world_point = self:GeometryLocalToWorld(body, points[i], position, rotation)

		if world_point.x < bounds.min_x then bounds.min_x = world_point.x end

		if world_point.y < bounds.min_y then bounds.min_y = world_point.y end

		if world_point.z < bounds.min_z then bounds.min_z = world_point.z end

		if world_point.x > bounds.max_x then bounds.max_x = world_point.x end

		if world_point.y > bounds.max_y then bounds.max_y = world_point.y end

		if world_point.z > bounds.max_z then bounds.max_z = world_point.z end
	end

	return bounds
end

function META:OnGroundedVelocityUpdate() end

function META:TraceAgainstBody()
	return nil
end

function META:SweepPointAgainstBody()
	return nil
end

function META:SweepColliderAgainstBody()
	return nil
end

function META:SolveSupportContacts()
	return nil
end

return META:Register()
