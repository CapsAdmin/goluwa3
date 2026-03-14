local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
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

	local physics = import("goluwa/physics/shared.lua")
	local hull = self:GetConvexHull()

	if not hull and body and body.Owner and body.Owner.model then
		hull = physics.BuildConvexHullFromModel(body.Owner.model)
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
	local mass = body.Mass or 0
	local bounds_size = self:GetHalfExtents(body) * 2

	if body.IsDynamic and not body:IsDynamic() then
		mass = 0
	elseif body.AutomaticMass then
		local hull = self:GetResolvedHull(body)

		if hull and hull.bounds_min and hull.bounds_max then
			bounds_size = hull.bounds_max - hull.bounds_min
			mass = math.max(bounds_size.x * bounds_size.y * bounds_size.z * body.Density * 0.75, 0)
		else
			mass = bounds_size.x * bounds_size.y * bounds_size.z * body.Density
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

function META:TraceDownAgainstBody(body, origin, max_distance)
	local physics = import("goluwa/physics/shared.lua")
	local hull = self:GetResolvedHull(body)

	if not (hull and hull.vertices and hull.faces and hull.faces[1]) then
		return nil
	end

	local distance_limit = max_distance or math.huge
	local movement_world = physics.Up * -distance_limit
	local start_local = body:WorldToLocal(origin)
	local end_local = body:WorldToLocal(origin + movement_world)
	local movement_local = end_local - start_local
	local t_enter = 0
	local t_exit = 1
	local hit_normal_local = nil

	for _, face in ipairs(hull.faces or {}) do
		local plane_point = hull.vertices[face.indices[1]]
		local plane_distance = face.normal:Dot(plane_point)
		local start_distance = face.normal:Dot(start_local) - plane_distance
		local delta_distance = face.normal:Dot(movement_local)

		if math.abs(delta_distance) <= 0.00001 then
			if start_distance > 0 then return nil end
		else
			local hit_t = -start_distance / delta_distance

			if delta_distance < 0 then
				if hit_t > t_enter then
					t_enter = hit_t
					hit_normal_local = face.normal
				end
			else
				if hit_t < t_exit then t_exit = hit_t end
			end

			if t_enter > t_exit then return nil end
		end
	end

	if not hit_normal_local or t_enter < 0 or t_enter > 1 then return nil end

	local position = origin + movement_world * t_enter
	local normal = body:GetRotation():VecMul(hit_normal_local):GetNormalized()

	if normal.y < 0 then return nil end

	return {
		entity = body.Owner,
		distance = distance_limit * t_enter,
		position = position,
		normal = normal,
		rigid_body = body,
	}
end

return META:Register()