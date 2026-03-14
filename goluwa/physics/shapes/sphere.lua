local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local physics = import("goluwa/physics/shared.lua")
local META = prototype.CreateTemplate("physics_shape_sphere")
META.Base = BaseShape
META:GetSet("Radius", 0.5)

function META.New(radius)
	local shape = META:CreateObject()
	shape:SetRadius(radius or 0.5)
	return shape
end

function META:GetTypeName()
	return "sphere"
end

function META:GetHalfExtents()
	local radius = self:GetRadius()
	return Vec3(radius, radius, radius)
end

function META:GetMassProperties(body)
	local radius = self:GetRadius()
	local mass = body.Mass or 0

	if body.IsDynamic and not body:IsDynamic() then
		mass = 0
	elseif body.AutomaticMass then
		mass = (4 / 3) * math.pi * radius * radius * radius * body.Density
	end

	if mass <= 0 then return 0, Vec3(0, 0, 0) end

	local inertia = (2 / 5) * mass * radius * radius
	local inv = inertia > 0 and 1 / inertia or 0
	return mass, Vec3(inv, inv, inv)
end

function META:GeometryLocalToWorld(body, local_pos, position)
	position = position or body:GetPosition()
	return position + local_pos
end

function META:GetBroadphaseAABB(body, position)
	position = position or body:GetPosition()
	local radius = self:GetRadius()
	return AABB(
		position.x - radius,
		position.y - radius,
		position.z - radius,
		position.x + radius,
		position.y + radius,
		position.z + radius
	)
end

function META:BuildCollisionLocalPoints()
	local radius = self:GetRadius()
	return {
		Vec3(0, -radius, 0),
		Vec3(0, radius, 0),
		Vec3(radius, 0, 0),
		Vec3(-radius, 0, 0),
		Vec3(0, 0, radius),
		Vec3(0, 0, -radius),
	}
end

function META:BuildSupportLocalPoints()
	local radius = self:GetRadius()
	return {
		Vec3(0, -radius, 0),
		Vec3(radius * 0.7, -radius * 0.7, 0),
		Vec3(-radius * 0.7, -radius * 0.7, 0),
		Vec3(0, -radius * 0.7, radius * 0.7),
		Vec3(0, -radius * 0.7, -radius * 0.7),
	}
end

function META:SolveSupportContacts(body, dt)
	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * dt)
	local cast_up = body.CollisionProbeDistance + body.CollisionMargin
	local cast_distance = cast_up + downward + body.CollisionProbeDistance + body.CollisionMargin
	local radius = self:GetRadius()
	local center = body:GetPosition()
	local hit = physics.TraceDown(
		center + physics.Up * cast_up,
		0,
		body.Owner,
		cast_distance + radius,
		body.FilterFunction
	)
	local normal = physics.GetHitNormal(hit, center)

	if not (hit and normal) then return end

	local target_center = hit.position + normal * (radius + body.CollisionMargin)
	local correction = target_center - center
	local depth = correction:Dot(normal)

	if depth <= 0 then return end

	body:ApplyCorrection(0, normal * depth, center - normal * radius, nil, nil, dt)

	if normal.y >= body.MinGroundNormalY then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end
end

function META:OnGroundedVelocityUpdate(body)
	local radius = self:GetRadius()

	if radius <= 0 then return end

	local tangent_velocity = body.Velocity - body.GroundNormal * body.Velocity:Dot(body.GroundNormal)
	local tangent_speed = tangent_velocity:GetLength()

	if tangent_speed <= 0.0001 then return end

	local rolling_angular = body.GroundNormal:GetCross(tangent_velocity) / radius
	local normal_angular = body.GroundNormal * body.AngularVelocity:Dot(body.GroundNormal)
	body.AngularVelocity = rolling_angular + normal_angular
end

function META:TraceDownAgainstBody(body, origin, max_distance)
	local center = body.Owner and
		body.Owner.transform and
		body.Owner.transform:GetPosition() or
		body:GetPosition()
	local offset = origin - center
	local sphere_radius = self:GetRadius()
	local c = offset:Dot(offset) - sphere_radius * sphere_radius

	if c > 0 and offset.y <= 0 then return nil end

	local discriminant = offset.y * offset.y - c

	if discriminant < 0 then return nil end

	local distance = offset.y - math.sqrt(discriminant)

	if distance < 0 then distance = offset.y + math.sqrt(discriminant) end

	if distance < 0 or distance > (max_distance or math.huge) then return nil end

	local position = origin + Vec3(0, -distance, 0)
	local normal = (position - center):GetNormalized()

	if normal.y < 0 then return nil end

	return {
		entity = body.Owner,
		distance = distance,
		position = position,
		normal = normal,
		rigid_body = body,
	}
end

return META:Register()