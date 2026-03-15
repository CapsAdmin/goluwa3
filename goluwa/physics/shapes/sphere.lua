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
	local mass = body:GetMass()

	if body.IsDynamic and not body:IsDynamic() then
		mass = 0
	elseif body:GetAutomaticMass() then
		mass = (4 / 3) * math.pi * radius * radius * radius * body:GetDensity()
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
	local points = {Vec3(0, -radius, 0)}
	local rings = {
		{horizontal = 0.5, vertical = 0.8660254037844386},
		{horizontal = 0.7071067811865476, vertical = 0.7071067811865476},
		{horizontal = 0.8660254037844386, vertical = 0.5},
	}
	local directions = {
		Vec3(1, 0, 0),
		Vec3(-1, 0, 0),
		Vec3(0, 0, 1),
		Vec3(0, 0, -1),
		Vec3(0.7071067811865476, 0, 0.7071067811865476),
		Vec3(-0.7071067811865476, 0, 0.7071067811865476),
		Vec3(0.7071067811865476, 0, -0.7071067811865476),
		Vec3(-0.7071067811865476, 0, -0.7071067811865476),
	}

	for _, ring in ipairs(rings) do
		for _, dir in ipairs(directions) do
			points[#points + 1] = Vec3(
				dir.x * radius * ring.horizontal,
				-radius * ring.vertical,
				dir.z * radius * ring.horizontal
			)
		end
	end

	return points
end

function META:SolveSupportContacts(body, dt)
	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * dt)
	local cast_up = body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local cast_distance = cast_up + downward + body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local radius = self:GetRadius()
	local center = body:GetPosition()
	local hit = physics.Trace(
		center + physics.Up * cast_up,
		physics.Up * -1,
		cast_distance + radius,
		body:GetOwner(),
		body:GetFilterFunction()
	)
	local normal = physics.GetHitNormal(hit, center)

	if not (hit and normal) then return end

	local target_center = hit.position + normal * (radius + body:GetCollisionMargin())
	local correction = target_center - center
	local depth = correction:Dot(normal)

	if depth <= 0 then return end

	body:ApplyCorrection(0, normal * depth, center - normal * radius, nil, nil, dt)

	if normal.y >= body:GetMinGroundNormalY() then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end

	if physics.RecordWorldCollision then
		physics.RecordWorldCollision(body, hit, normal, depth)
	end
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

	if tangent_speed <= 0.0001 then return end

	local rolling_angular = body.GroundNormal:GetCross(tangent_velocity) / radius
	local normal_angular = body.GroundNormal * body.AngularVelocity:Dot(body.GroundNormal)
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