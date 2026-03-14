local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local physics = import("goluwa/physics/shared.lua")
local META = prototype.CreateTemplate("physics_shape_convex")
META.Base = BaseShape
META:GetSet("ConvexHull", nil)

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
		hull = physics.BuildConvexHullFromModel(owner.model)
	end

	if hull then hull = physics.NormalizeConvexHull(hull) end

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
	local mass = body:GetMass()
	local bounds_size = self:GetHalfExtents(body) * 2

	if body.IsDynamic and not body:IsDynamic() then
		mass = 0
	elseif body:GetAutomaticMass() then
		local hull = self:GetResolvedHull(body)

		if hull and hull.bounds_min and hull.bounds_max then
			bounds_size = hull.bounds_max - hull.bounds_min
			mass = math.max(bounds_size.x * bounds_size.y * bounds_size.z * body:GetDensity() * 0.75, 0)
		else
			mass = bounds_size.x * bounds_size.y * bounds_size.z * body:GetDensity()
		end
	end

	if mass <= 0 then return 0, Vec3(0, 0, 0) end

	local sx, sy, sz = bounds_size.x, bounds_size.y, bounds_size.z
	local ix = (1 / 12) * mass * (sy * sy + sz * sz)
	local iy = (1 / 12) * mass * (sx * sx + sz * sz)
	local iz = (1 / 12) * mass * (sx * sx + sy * sy)
	return mass,
	Vec3(ix > 0 and 1 / ix or 0, iy > 0 and 1 / iy or 0, iz > 0 and 1 / iz or 0)
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

			for _, point in ipairs(support) do
				center = center + point
			end

			support[#support + 1] = center / #support
			return support
		end
	end

	return BaseShape.BuildSupportLocalPoints(self, body)
end

return META:Register()