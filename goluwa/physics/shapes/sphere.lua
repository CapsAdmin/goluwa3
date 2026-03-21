local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local sample_points = import("goluwa/physics/shapes/sample_points.lua")
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

function META:GetAutomaticMass(body)
	local radius = self:GetRadius()
	return (4 / 3) * math.pi * radius * radius * radius * body:GetDensity()
end

function META:BuildInertia(mass)
	return self:BuildSphereInertia(mass, self:GetRadius())
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
	return sample_points.BuildSphereCollisionPoints(self:GetRadius())
end

function META:BuildSupportLocalPoints()
	return sample_points.BuildSphereSupportPoints(self:GetRadius())
end

function META:SolveSupportContacts(body, dt, support_contacts)
	local radius = self:GetRadius()
	local hit = support_contacts.SweepSphere(body, dt, radius)
	local normal = hit and hit.normal or nil
	local contact_position = hit and hit.position or nil

	if not hit then return end

	support_contacts.ApplyWorldSupportContact(body, normal, contact_position, radius, hit, dt)
end

function META:OnGroundedVelocityUpdate(body, dt)
	local radius = self:GetRadius()

	if radius <= 0 then return end

	local normal_velocity = body.GroundNormal * body.Velocity:Dot(body.GroundNormal)
	local tangent_velocity = body.Velocity - normal_velocity
	local tangent_speed = tangent_velocity:GetLength()
	local rolling_friction = math.max(body:GetGroundRollingFriction() or 0, 0)

	if tangent_speed > 0.0001 and rolling_friction > 0 and dt and dt > 0 then
		local damping = math.exp(-rolling_friction * dt)
		tangent_velocity = tangent_velocity * damping
		body.Velocity = normal_velocity + tangent_velocity
		tangent_speed = tangent_velocity:GetLength()
	end

	local rolling_angular = body.GroundNormal:GetCross(tangent_velocity) / radius
	local normal_angular = body.GroundNormal * body.AngularVelocity:Dot(body.GroundNormal)

	if tangent_speed <= 0.0001 then
		body.AngularVelocity = normal_angular
		return
	end

	body.AngularVelocity = rolling_angular + normal_angular
end

function META:TraceAgainstBody(body, origin, direction, max_distance, trace_radius)
	local owner = body:GetOwner()
	local center = owner and
		owner.transform and
		owner.transform:GetPosition() or
		body:GetPosition()
	local ray_direction = direction and direction:GetNormalized() or Vec3(0, 0, 0)

	if ray_direction:GetLength() <= 0.00001 then return nil end

	local sphere_radius = self:GetRadius() + math.max(trace_radius or 0, 0)
	local offset = origin - center
	local b = offset:Dot(ray_direction)
	local c = offset:Dot(offset) - sphere_radius * sphere_radius
	local discriminant = b * b - c

	if discriminant < 0 then return nil end

	local distance = -b - math.sqrt(discriminant)

	if distance < 0 then distance = -b + math.sqrt(discriminant) end

	if distance < 0 or distance > (max_distance or math.huge) then return nil end

	local expanded_position = origin + ray_direction * distance
	local normal = (expanded_position - center):GetNormalized()
	local position = expanded_position - normal * math.max(trace_radius or 0, 0)
	return {
		entity = owner,
		distance = distance,
		position = position,
		normal = normal,
		rigid_body = body.GetBody and body:GetBody() or body,
	}
end

return META:Register()
