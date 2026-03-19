local prototype = import("goluwa/prototype.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local mass_properties = import("goluwa/physics/shapes/mass_properties.lua")
local physics = import("goluwa/physics.lua")
local sample_points = import("goluwa/physics/shapes/sample_points.lua")
local support_contacts = import("goluwa/physics/shapes/support_contacts.lua")
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
	local cylinder_volume = math.pi * radius * radius * cylinder_height
	local sphere_volume = (4 / 3) * math.pi * radius * radius * radius
	local mass = mass_properties.ResolveBodyMass(body, (cylinder_volume + sphere_volume) * body:GetDensity())
	local zero_mass, zero_inertia = mass_properties.ZeroIfStatic(mass)

	if zero_mass then return zero_mass, zero_inertia end

	local total_volume = cylinder_volume + sphere_volume
	local cylinder_mass = total_volume > 0 and
		mass * (cylinder_volume / total_volume)
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

function META:BuildCollisionLocalPoints()
	return sample_points.BuildCapsuleCollisionPoints(self:GetRadius(), self:GetCylinderHalfHeight())
end

function META:BuildSupportLocalPoints()
	return sample_points.BuildCapsuleSupportPoints(self:GetRadius(), self:GetCylinderHalfHeight())
end

function META:SolveSupportContacts(body, dt)
	local cast_up, cast_distance = support_contacts.GetCastDistances(body, dt)
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

	if not hit then return end

	support_contacts.ApplyWorldSupportContact(
		body,
		normal,
		contact_position,
		self:GetSupportRadiusAlongNormal(body, normal),
		hit,
		dt
	)
end

return META:Register()
