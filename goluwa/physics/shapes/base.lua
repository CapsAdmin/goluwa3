local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local sample_points = import("goluwa/physics/shapes/sample_points.lua")
local support_contacts = import("goluwa/physics/shapes/support_contacts.lua")
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

	local min_x = math.huge
	local min_y = math.huge
	local min_z = math.huge
	local max_x = -math.huge
	local max_y = -math.huge
	local max_z = -math.huge

	for i = 1, #points do
		local world_point = self:GeometryLocalToWorld(body, points[i], position, rotation)
		local x = world_point.x
		local y = world_point.y
		local z = world_point.z

		if x < min_x then min_x = x end
		if y < min_y then min_y = y end
		if z < min_z then min_z = z end
		if x > max_x then max_x = x end
		if y > max_y then max_y = y end
		if z > max_z then max_z = z end
	end

	return AABB(min_x, min_y, min_z, max_x, max_y, max_z)
end

function META:SolveSupportContacts(body, dt, solve_contact, solve_contact_context)
	local cast_up, cast_distance = support_contacts.GetCastDistances(body, dt)
	local support_points = body:GetSupportLocalPoints()
	local owner = body:GetOwner()
	local filter_function = body:GetFilterFunction()
	local cast_origin_offset = physics.Up * cast_up
	local cast_delta = physics.Up * -cast_distance

	for i = 1, #support_points do
		local point = body:GeometryLocalToWorld(support_points[i])
		local hit = physics.Sweep(
			point + cast_origin_offset,
			cast_delta,
			0,
			owner,
			filter_function
		)

		if hit then
			if solve_contact_context ~= nil then
				solve_contact(solve_contact_context, body, point, hit, dt)
			else
				solve_contact(body, point, hit, dt)
			end
		end
	end
end

function META:OnGroundedVelocityUpdate() end

function META:TraceAgainstBody()
	return nil
end

return META:Register()
