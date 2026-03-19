local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local physics = import("goluwa/physics.lua")
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
	return capsule_geometry.GetCylinderHeight(self)
end

function META:GetCylinderHalfHeight()
	return capsule_geometry.GetCylinderHalfHeight(self)
end

function META:GetHalfExtents()
	return Vec3(self:GetRadius(), self:GetHeight() * 0.5, self:GetRadius())
end

function META:GetBottomSphereCenterLocal()
	return capsule_geometry.GetBottomSphereCenterLocal(self)
end

function META:GetTopSphereCenterLocal()
	return capsule_geometry.GetTopSphereCenterLocal(self)
end

function META:GetSupportRadiusAlongNormal(body, normal)
	normal = normal and normal:GetNormalized() or Vec3(0, 1, 0)
	local axis = body:GetRotation():VecMul(Vec3(0, 1, 0)):GetNormalized()
	return self:GetRadius() + self:GetCylinderHalfHeight() * math.abs(axis:Dot(normal))
end

function META:GetMassProperties(body)
	local radius = self:GetRadius()
	local cylinder_height = self:GetCylinderHeight()
	local mass = body:GetMass()

	if body.IsDynamic and not body:IsDynamic() then
		mass = 0
	elseif body:GetAutomaticMass() then
		local cylinder_volume = math.pi * radius * radius * cylinder_height
		local sphere_volume = (4 / 3) * math.pi * radius * radius * radius
		mass = (cylinder_volume + sphere_volume) * body:GetDensity()
	end

	if mass <= 0 then return 0, Matrix33():SetZero() end

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
	return mass, Matrix33():SetDiagonal(ixx, iyy, izz)
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
	local cast_up = body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local cast_distance = cast_up + downward + body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local center = body:GetPosition()
	local hit = physics.SweepCollider(
		body,
		center + physics.Up * cast_up,
		physics.Up * -cast_distance,
		body:GetOwner(),
		body:GetFilterFunction(),
		{
			Rotation = body:GetRotation(),
		}
	)
	local normal = hit and hit.normal or nil
	local contact_position = hit and hit.position or nil

	if not (hit and normal and contact_position) then return end

	local support_radius = self:GetSupportRadiusAlongNormal(body, normal)
	local target_center = contact_position + normal * (support_radius + body:GetCollisionMargin())
	local correction = target_center - center
	local depth = correction:Dot(normal)

	if depth <= 0 then return end

	body:ApplyCorrection(0, normal * depth, center - normal * support_radius, nil, nil, dt)

	if normal.y >= body:GetMinGroundNormalY() then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end

	physics.collision_pairs:RecordWorldCollision(body, hit, normal, depth)
end

return META:Register()
