local prototype = import("goluwa/prototype.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local mass_properties = import("goluwa/physics/shapes/mass_properties.lua")
local physics = import("goluwa/physics.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
local support_contacts = import("goluwa/physics/shapes/support_contacts.lua")
local META = prototype.CreateTemplate("physics_shape_convex")
META.Base = BaseShape
META:GetSet("ConvexHull", nil)
local CONVEX_SUPPORT_CONTACT_CONTEXT = {
	best = nil,
}

local function collect_convex_support_contact(context, target_body, point, hit, contact_dt)
	if not (hit and hit.normal and hit.position and point) then return end

	local margin = target_body:GetCollisionMargin() or 0
	local depth = (hit.position + hit.normal * margin - point):Dot(hit.normal)
	local support_tolerance = (target_body:GetCollisionProbeDistance() or 0) + margin

	if depth < -support_tolerance then return end

	local best = context.best

	if
		not best or
		depth > best.depth or
		(
			math.abs(depth - best.depth) <= physics.EPSILON and
			hit.normal.y > best.hit.normal.y
		)
	then
		context.best = {
			body = target_body,
			point = point,
			hit = hit,
			dt = contact_dt,
			depth = depth,
		}
	end
end

function META.New(hull)
	local shape = META:CreateObject()
	shape:SetConvexHull(hull)
	return shape
end

function META:GetTypeName()
	return "convex"
end

function META:OnBodyGeometryChanged(body)
	BaseShape.OnBodyGeometryChanged(self, body)
	self.ResolvedHull = nil
end

function META:GetResolvedHull(body)
	if self.ResolvedHull then return self.ResolvedHull end

	local hull = self:GetConvexHull()
	local owner = body and body.GetOwner and body:GetOwner() or body and body.Owner

	if not hull and owner and owner.model then
		hull = convex_hull.BuildHullFromModel(owner.model)
	end

	if hull then hull = convex_hull.Normalize(hull) end

	self.ResolvedHull = hull
	return hull
end

function META:GetPolyhedron(body)
	return self:GetResolvedHull(body)
end

function META:GetHalfExtents(body)
	local hull = self:GetResolvedHull(body)

	if hull and hull.bounds_min and hull.bounds_max then
		return (hull.bounds_max - hull.bounds_min) * 0.5
	end

	return Vec3(0.5, 0.5, 0.5)
end

function META:GetMassProperties(body)
	local bounds_size = self:GetHalfExtents(body) * 2
	local automatic_mass = bounds_size.x * bounds_size.y * bounds_size.z * body:GetDensity()

	if body:GetAutomaticMass() then
		local hull = self:GetResolvedHull(body)

		if hull and hull.bounds_min and hull.bounds_max then
			bounds_size = hull.bounds_max - hull.bounds_min
			automatic_mass = math.max(bounds_size.x * bounds_size.y * bounds_size.z * body:GetDensity() * 0.75, 0)
		end
	end

	local mass = mass_properties.ResolveBodyMass(body, automatic_mass)
	return mass_properties.BuildBoxInertia(mass, bounds_size.x, bounds_size.y, bounds_size.z)
end

function META:BuildCollisionLocalPoints(body)
	local hull = self:GetResolvedHull(body)

	if hull and hull.vertices and hull.vertices[1] then return hull.vertices end

	return BaseShape.BuildCollisionLocalPoints(self, body)
end

function META:BuildSupportLocalPoints(body)
	local hull = self:GetResolvedHull(body)

	if hull and hull.vertices and hull.vertices[1] then
		local min_y = math.huge
		local support = {}
		local tolerance = 0.08

		for _, point in ipairs(hull.vertices) do
			min_y = math.min(min_y, point.y)
		end

		for _, point in ipairs(hull.vertices) do
			if math.abs(point.y - min_y) <= tolerance then support[#support + 1] = point end
		end

		if support[1] then
			local center = Vec3(0, 0, 0)
			local points = {}

			for _, point in ipairs(support) do
				center = center + point
				points[#points + 1] = point
			end

			center = center / #support

			for _, point in ipairs(support) do
				points[#points + 1] = (point + center) * 0.5
			end

			points[#points + 1] = center
			return points
		end
	end

	return BaseShape.BuildSupportLocalPoints(self, body)
end

function META:GetSupportRadiusAlongNormal(body, normal)
	normal = normal and normal:GetNormalized() or Vec3(0, 1, 0)
	local max_projection = 0

	for _, local_point in ipairs(body:GetSupportLocalPoints() or {}) do
		local world_point = body:GeometryLocalToWorld(local_point)
		max_projection = math.max(max_projection, (world_point - body:GetPosition()):Dot(normal))
	end

	return max_projection
end

function META:SolveSupportContacts(body, dt)
	CONVEX_SUPPORT_CONTACT_CONTEXT.best = nil

	BaseShape.SolveSupportContacts(
		self,
		body,
		dt,
		collect_convex_support_contact,
		CONVEX_SUPPORT_CONTACT_CONTEXT
	)
	local best = CONVEX_SUPPORT_CONTACT_CONTEXT.best
	CONVEX_SUPPORT_CONTACT_CONTEXT.best = nil

	if not best then return end

	support_contacts.ApplyPointWorldSupportContact(
		best.body,
		best.hit.normal,
		best.hit.position,
		best.point,
		best.hit,
		best.dt
	)
end

return META:Register()
