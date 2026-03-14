local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local physics = import("goluwa/physics/shared.lua")
local META = prototype.CreateTemplate("physics_shape_capsule")
META.Base = BaseShape
META:GetSet("Radius", 0.5)
META:GetSet("Height", 2)

local function clamp_height(radius, height)
	return math.max(height or radius * 2, radius * 2)
end

function META.New(radius, height)
	local shape = META:CreateObject()
	shape:SetRadius(radius or 0.5)
	shape:SetHeight(clamp_height(radius or 0.5, height or 2))
	return shape
end

function META:GetTypeName()
	return "capsule"
end

function META:OnBodyGeometryChanged(body)
	BaseShape.OnBodyGeometryChanged(self, body)
	self:SetHeight(clamp_height(self:GetRadius(), self:GetHeight()))
end

function META:GetCylinderHeight()
	return math.max(0, self:GetHeight() - self:GetRadius() * 2)
end

function META:GetCylinderHalfHeight()
	return self:GetCylinderHeight() * 0.5
end

function META:GetHalfExtents()
	return Vec3(self:GetRadius(), self:GetHeight() * 0.5, self:GetRadius())
end

function META:GetBottomSphereCenterLocal()
	return Vec3(0, -self:GetCylinderHalfHeight(), 0)
end

function META:GetTopSphereCenterLocal()
	return Vec3(0, self:GetCylinderHalfHeight(), 0)
end

function META:GetMassProperties(body)
	local radius = self:GetRadius()
	local cylinder_height = self:GetCylinderHeight()
	local mass = body.Mass or 0

	if body.IsDynamic and not body:IsDynamic() then
		mass = 0
	elseif body.AutomaticMass then
		local cylinder_volume = math.pi * radius * radius * cylinder_height
		local sphere_volume = (4 / 3) * math.pi * radius * radius * radius
		mass = (cylinder_volume + sphere_volume) * body.Density
	end

	if mass <= 0 then return 0, Vec3(0, 0, 0) end

	local total_volume = math.pi * radius * radius * cylinder_height + (
			4 / 3
		) * math.pi * radius * radius * radius
	local cylinder_mass = total_volume > 0 and
		mass * (
			(
				math.pi * radius * radius * cylinder_height
			) / total_volume
		)
		or
		0
	local sphere_mass = mass - cylinder_mass
	local iyy = 0.5 * cylinder_mass * radius * radius + (2 / 5) * sphere_mass * radius * radius
	local ixx = (
			1 / 12
		) * cylinder_mass * (
			3 * radius * radius + cylinder_height * cylinder_height
		) + (
			2 / 5
		) * sphere_mass * radius * radius + sphere_mass * (
			cylinder_height * cylinder_height
		) * 0.25
	local izz = ixx
	return mass,
	Vec3(ixx > 0 and 1 / ixx or 0, iyy > 0 and 1 / iyy or 0, izz > 0 and 1 / izz or 0)
end

function META:GetBroadphaseAABB(body, position, rotation)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, point in ipairs(self:BuildCollisionLocalPoints(body)) do
		bounds:ExpandVec3(position + rotation:VecMul(point))
	end

	return bounds
end

function META:BuildCollisionLocalPoints()
	local radius = self:GetRadius()
	local cylinder_half_height = self:GetCylinderHalfHeight()
	return {
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
		Vec3(radius * 0.7071, -cylinder_half_height - radius * 0.2929, radius * 0.7071),
		Vec3(-radius * 0.7071, -cylinder_half_height - radius * 0.2929, radius * 0.7071),
		Vec3(radius * 0.7071, -cylinder_half_height - radius * 0.2929, -radius * 0.7071),
		Vec3(-radius * 0.7071, -cylinder_half_height - radius * 0.2929, -radius * 0.7071),
	}
end

function META:BuildSupportLocalPoints()
	local radius = self:GetRadius()
	local cylinder_half_height = self:GetCylinderHalfHeight()
	return {
		Vec3(0, -(cylinder_half_height + radius), 0),
		Vec3(radius, -cylinder_half_height, 0),
		Vec3(-radius, -cylinder_half_height, 0),
		Vec3(0, -cylinder_half_height, radius),
		Vec3(0, -cylinder_half_height, -radius),
		Vec3(radius * 0.7071, -cylinder_half_height - radius * 0.2929, radius * 0.7071),
		Vec3(-radius * 0.7071, -cylinder_half_height - radius * 0.2929, radius * 0.7071),
		Vec3(radius * 0.7071, -cylinder_half_height - radius * 0.2929, -radius * 0.7071),
		Vec3(-radius * 0.7071, -cylinder_half_height - radius * 0.2929, -radius * 0.7071),
	}
end

function META:SolveSupportContacts(body, dt)
	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * dt)
	local cast_up = body.CollisionProbeDistance + body.CollisionMargin
	local cast_distance = cast_up + downward + body.CollisionProbeDistance + body.CollisionMargin
	local radius = self:GetRadius()
	local bottom_center = body:LocalToWorld(self:GetBottomSphereCenterLocal())
	local hit = physics.TraceDown(
		bottom_center + physics.Up * cast_up,
		0,
		body.Owner,
		cast_distance + radius,
		body.FilterFunction
	)
	local normal = physics.GetHitNormal(hit, bottom_center)

	if not (hit and normal) then return end

	local target_center = hit.position + normal * (radius + body.CollisionMargin)
	local correction = target_center - bottom_center
	local depth = correction:Dot(normal)

	if depth <= 0 then return end

	body:ApplyCorrection(0, normal * depth, bottom_center - normal * radius, nil, nil, dt)

	if normal.y >= body.MinGroundNormalY then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end

	if physics.RecordWorldCollision then
		physics.RecordWorldCollision(body, hit, normal, depth)
	end
end

function META:TraceDownAgainstBody(body, origin, max_distance)
	local distance_limit = max_distance or math.huge
	local movement_world = physics.Up * -distance_limit
	local radius = self:GetRadius()
	local local_origin = body:WorldToLocal(origin)
	local cylinder_half_height = self:GetCylinderHalfHeight()
	local bottom = Vec3(0, -cylinder_half_height, 0)
	local top = Vec3(0, cylinder_half_height, 0)
	local best_distance = nil
	local best_position = nil
	local best_normal = nil

	for _, center in ipairs({bottom, top}) do
		local offset = local_origin - center
		local c = offset:Dot(offset) - radius * radius

		if not (c > 0 and offset.y <= 0) then
			local discriminant = offset.y * offset.y - c

			if discriminant >= 0 then
				local distance = offset.y - math.sqrt(discriminant)

				if distance < 0 then distance = offset.y + math.sqrt(discriminant) end

				if
					distance >= 0 and
					distance <= distance_limit and
					(
						not best_distance or
						distance < best_distance
					)
				then
					local position = origin + movement_world:GetNormalized() * distance
					local sphere_center = body:LocalToWorld(center)
					local normal = (position - sphere_center):GetNormalized()

					if normal.y >= 0 then
						best_distance = distance
						best_position = position
						best_normal = normal
					end
				end
			end
		end
	end

	if not best_distance then return nil end

	return {
		entity = body.Owner,
		distance = best_distance,
		position = best_position,
		normal = best_normal,
		rigid_body = body,
	}
end

return META:Register()