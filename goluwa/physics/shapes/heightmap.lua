local objects = import("goluwa/objects/objects.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local ffi = require("ffi")
local META = objects.CreateTemplate("physics_shape_heightmap")
META.Base = BaseShape
META.IsHeightmap = true
local FloatArray = ffi.typeof("float[?]")
local HEIGHTMAP_BOUNDS_CORNERS = {
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
}
local SHARED_HEIGHTMAP_ENTRY = {
	polygon = nil,
	primitive = nil,
	primitive_index = nil,
	model = nil,
}
local HEIGHTMAP_ROTATED_CORNER = Vec3()
local TRACE_AGAINST_BODY_CONTEXT = {
	local_ray = nil,
	origin = nil,
	ray_direction = nil,
	trace_radius = 0,
	collider = nil,
	best_hit = nil,
	best_distance = math.huge,
}
local ray_triangle_intersection = triangle_geometry.RayIntersection

local function clamp_cell_index(value, max_value)
	if value < 0 then return 0 end

	if value > max_value then return max_value end

	return value
end

local function build_triangle_hit(
	collider,
	ray_origin,
	ray_direction,
	distance,
	trace_radius,
	triangle_index,
	v0,
	v1,
	v2
)
	local face_normal_local = (v1 - v0):Cross(v2 - v0):GetNormalized()

	if face_normal_local:GetLength() <= 0.00001 then return nil end

	local face_normal = collider:GetRotation():VecMul(face_normal_local):GetNormalized()

	if face_normal:Dot(ray_direction) > 0 then face_normal = face_normal * -1 end

	local position = ray_origin + ray_direction * distance
	local radius = math.max(trace_radius or 0, 0)

	if radius > 0 then position = position - face_normal * radius end

	return {
		entity = collider:GetOwner(),
		distance = distance,
		position = position,
		normal = face_normal,
		face_normal = face_normal,
		rigid_body = collider.GetBody and collider:GetBody() or collider,
		collider = collider,
		primitive = nil,
		primitive_index = nil,
		triangle_index = triangle_index,
		model = nil,
		poly = nil,
	}
end

local function collect_trace_triangle_hit(v0, v1, v2, triangle_index, context)
	local hit, distance = ray_triangle_intersection(context.local_ray, v0, v1, v2)

	if not hit or distance > context.best_distance then return end

	local candidate = build_triangle_hit(
		context.collider,
		context.origin,
		context.ray_direction,
		distance,
		context.trace_radius,
		triangle_index,
		v0,
		v1,
		v2
	)

	if candidate then
		context.best_hit = candidate
		context.best_distance = candidate.distance
	end
end

function META.SamplesFromFunction(samples_x, samples_z, callback)
	local samples = FloatArray(samples_x * samples_z)

	for z = 0, samples_z - 1 do
		for x = 0, samples_x - 1 do
			samples[z * samples_x + x] = callback(x, z)
		end
	end

	return samples
end

function META.New(data)
	local shape = META:CreateObject()
	shape.Samples = data.Samples
	shape.SamplesX = data.SamplesX
	shape.SamplesZ = data.SamplesZ
	shape.Size = data.Size
	return shape
end

function META:GetTypeName()
	return "mesh"
end

function META:OnBodyGeometryChanged(body)
	BaseShape.OnBodyGeometryChanged(self, body)
	self.HeightmapCache = nil
	self.LocalBounds = nil
	self.CollisionLocalPoints = nil
	self.SupportLocalPoints = nil
end

function META:BuildHeightmapCache()
	if self.HeightmapCache then return self.HeightmapCache end

	local samples = self.Samples
	local samples_x = self.SamplesX
	local samples_z = self.SamplesZ
	local size = self.Size
	local cells_x = samples_x - 1
	local cells_z = samples_z - 1
	local step_x = size.x / cells_x
	local step_z = size.y / cells_z
	local offset_x = -size.x * 0.5
	local offset_z = -size.y * 0.5
	local points = {}
	local min_y = math.huge
	local max_y = -math.huge

	for z = 0, cells_z do
		local local_z = offset_z + z * step_z

		for x = 0, cells_x do
			local height = samples[z * samples_x + x]
			points[z * samples_x + x + 1] = Vec3(offset_x + x * step_x, height, local_z)

			if height < min_y then min_y = height end

			if height > max_y then max_y = height end
		end
	end

	local cell_min_heights = FloatArray(cells_x * cells_z)
	local cell_max_heights = FloatArray(cells_x * cells_z)

	for z = 0, cells_z - 1 do
		for x = 0, cells_x - 1 do
			local h00 = samples[z * samples_x + x]
			local h10 = samples[z * samples_x + x + 1]
			local h01 = samples[(z + 1) * samples_x + x]
			local h11 = samples[(z + 1) * samples_x + x + 1]
			cell_min_heights[z * cells_x + x] = math.min(h00, h10, h01, h11)
			cell_max_heights[z * cells_x + x] = math.max(h00, h10, h01, h11)
		end
	end

	local cache = {
		samples_x = samples_x,
		samples_z = samples_z,
		cells_x = cells_x,
		cells_z = cells_z,
		step_x = step_x,
		step_z = step_z,
		offset_x = offset_x,
		offset_z = offset_z,
		points = points,
		cell_min_heights = cell_min_heights,
		cell_max_heights = cell_max_heights,
		bounds = AABB(offset_x, min_y, offset_z, -offset_x, max_y, -offset_z),
	}
	local mid_x = math.floor(cells_x * 0.5)
	local mid_z = math.floor(cells_z * 0.5)
	local collision_points = {
		points[1],
		points[cells_x + 1],
		points[cells_z * samples_x + 1],
		points[cells_z * samples_x + cells_x + 1],
		points[mid_z * samples_x + mid_x + 1],
	}
	local support_points = {}

	for i = 1, #collision_points do
		local point = collision_points[i]

		if math.abs(point.y - min_y) <= 0.08 then
			support_points[#support_points + 1] = point
		end
	end

	cache.collision_points = collision_points
	cache.support_points = support_points[1] and support_points or collision_points
	self.HeightmapCache = cache
	return cache
end

function META:GetLocalBounds()
	if self.LocalBounds then return self.LocalBounds end

	self.LocalBounds = self:BuildHeightmapCache().bounds
	return self.LocalBounds
end

function META:GetHalfExtents()
	local bounds = self:GetLocalBounds()
	return Vec3(
		(bounds.max_x - bounds.min_x) * 0.5,
		(bounds.max_y - bounds.min_y) * 0.5,
		(bounds.max_z - bounds.min_z) * 0.5
	)
end

function META:GetMassProperties()
	return 0, Matrix33():SetZero()
end

function META:BuildCollisionLocalPoints()
	return self:BuildHeightmapCache().collision_points
end

function META:BuildSupportLocalPoints()
	return self:BuildHeightmapCache().support_points
end

function META:GetHeightAtLocal(x, z)
	local cache = self:BuildHeightmapCache()
	local fx = (x - cache.offset_x) / cache.step_x
	local fz = (z - cache.offset_z) / cache.step_z
	local cell_x = clamp_cell_index(math.floor(fx), cache.cells_x - 1)
	local cell_z = clamp_cell_index(math.floor(fz), cache.cells_z - 1)
	local tx = math.clamp(fx - cell_x, 0, 1)
	local tz = math.clamp(fz - cell_z, 0, 1)
	local samples = self.Samples
	local samples_x = cache.samples_x
	local h00 = samples[cell_z * samples_x + cell_x]
	local h10 = samples[cell_z * samples_x + cell_x + 1]
	local h01 = samples[(cell_z + 1) * samples_x + cell_x]
	local h11 = samples[(cell_z + 1) * samples_x + cell_x + 1]

	if tz >= tx then return h00 + (h11 - h01) * tx + (h01 - h00) * tz end

	return h00 + (h10 - h00) * tx + (h11 - h10) * tz
end

function META:GetBroadphaseAABB(body, position, rotation, out)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	local bounds = self:GetLocalBounds()
	local min_x = bounds.min_x
	local min_y = bounds.min_y
	local min_z = bounds.min_z
	local max_x = bounds.max_x
	local max_y = bounds.max_y
	local max_z = bounds.max_z
	local corners = HEIGHTMAP_BOUNDS_CORNERS
	corners[1].x, corners[1].y, corners[1].z = min_x, min_y, min_z
	corners[2].x, corners[2].y, corners[2].z = max_x, min_y, min_z
	corners[3].x, corners[3].y, corners[3].z = max_x, max_y, min_z
	corners[4].x, corners[4].y, corners[4].z = min_x, max_y, min_z
	corners[5].x, corners[5].y, corners[5].z = min_x, min_y, max_z
	corners[6].x, corners[6].y, corners[6].z = max_x, min_y, max_z
	corners[7].x, corners[7].y, corners[7].z = max_x, max_y, max_z
	corners[8].x, corners[8].y, corners[8].z = min_x, max_y, max_z
	local world_min_x = math.huge
	local world_min_y = math.huge
	local world_min_z = math.huge
	local world_max_x = -math.huge
	local world_max_y = -math.huge
	local world_max_z = -math.huge
	local rotated_corner = HEIGHTMAP_ROTATED_CORNER

	for i = 1, 8 do
		Quat.SetVecMul(rotated_corner, rotation, corners[i])
		local x = position.x + rotated_corner.x
		local y = position.y + rotated_corner.y
		local z = position.z + rotated_corner.z

		if x < world_min_x then world_min_x = x end

		if y < world_min_y then world_min_y = y end

		if z < world_min_z then world_min_z = z end

		if x > world_max_x then world_max_x = x end

		if y > world_max_y then world_max_y = y end

		if z > world_max_z then world_max_z = z end
	end

	if out then
		out.min_x = world_min_x
		out.min_y = world_min_y
		out.min_z = world_min_z
		out.max_x = world_max_x
		out.max_y = world_max_y
		out.max_z = world_max_z
		return out
	end

	return AABB(world_min_x, world_min_y, world_min_z, world_max_x, world_max_y, world_max_z)
end

function META:ForEachOverlappingTriangle(body, local_bounds, callback, context)
	local cache = self:BuildHeightmapCache()

	if not callback then return end

	local cells_x = cache.cells_x
	local cells_z = cache.cells_z
	local samples_x = cache.samples_x
	local min_cell_x = 0
	local max_cell_x = cells_x - 1
	local min_cell_z = 0
	local max_cell_z = cells_z - 1

	if local_bounds then
		local bounds = cache.bounds

		if
			local_bounds.max_x < bounds.min_x or
			local_bounds.min_x > bounds.max_x or
			local_bounds.max_z < bounds.min_z or
			local_bounds.min_z > bounds.max_z or
			local_bounds.max_y < bounds.min_y or
			local_bounds.min_y > bounds.max_y
		then
			return
		end

		min_cell_x = clamp_cell_index(math.floor((local_bounds.min_x - cache.offset_x) / cache.step_x), cells_x - 1)
		max_cell_x = clamp_cell_index(math.floor((local_bounds.max_x - cache.offset_x) / cache.step_x), cells_x - 1)
		min_cell_z = clamp_cell_index(math.floor((local_bounds.min_z - cache.offset_z) / cache.step_z), cells_z - 1)
		max_cell_z = clamp_cell_index(math.floor((local_bounds.max_z - cache.offset_z) / cache.step_z), cells_z - 1)
	end

	local previous_entry = context and context.entry or nil

	if context then context.entry = SHARED_HEIGHTMAP_ENTRY end

	local points = cache.points
	local cell_min_heights = cache.cell_min_heights
	local cell_max_heights = cache.cell_max_heights

	for z = min_cell_z, max_cell_z do
		for x = min_cell_x, max_cell_x do
			local cell_index = z * cells_x + x

			if
				not local_bounds or
				(
					cell_max_heights[cell_index] >= local_bounds.min_y and
					cell_min_heights[cell_index] <= local_bounds.max_y
				)
			then
				local p00 = points[z * samples_x + x + 1]
				local p10 = points[z * samples_x + x + 2]
				local p01 = points[(z + 1) * samples_x + x + 1]
				local p11 = points[(z + 1) * samples_x + x + 2]
				callback(p00, p11, p01, cell_index * 2 + 1, context)
				callback(p00, p10, p11, cell_index * 2 + 2, context)
			end
		end
	end

	if context then context.entry = previous_entry end
end

function META:TraceAgainstBody(collider, origin, direction, max_distance, trace_radius)
	local ray_direction = direction:GetNormalized()

	if ray_direction:GetLength() <= 0.00001 then return nil end

	local distance_limit = max_distance or math.huge
	local local_origin = collider:WorldToLocal(origin)
	local local_direction = collider:GetRotation():GetConjugated():VecMul(ray_direction):GetNormalized()
	local local_end = local_origin + local_direction * distance_limit
	local radius = math.max(trace_radius or 0, 0)
	local local_bounds = AABB(
		math.min(local_origin.x, local_end.x) - radius,
		math.min(local_origin.y, local_end.y) - radius,
		math.min(local_origin.z, local_end.z) - radius,
		math.max(local_origin.x, local_end.x) + radius,
		math.max(local_origin.y, local_end.y) + radius,
		math.max(local_origin.z, local_end.z) + radius
	)
	TRACE_AGAINST_BODY_CONTEXT.local_ray = {
		origin = local_origin,
		direction = local_direction,
		max_distance = distance_limit,
	}
	TRACE_AGAINST_BODY_CONTEXT.origin = origin
	TRACE_AGAINST_BODY_CONTEXT.ray_direction = ray_direction
	TRACE_AGAINST_BODY_CONTEXT.trace_radius = trace_radius
	TRACE_AGAINST_BODY_CONTEXT.collider = collider
	TRACE_AGAINST_BODY_CONTEXT.best_hit = nil
	TRACE_AGAINST_BODY_CONTEXT.best_distance = distance_limit
	self:ForEachOverlappingTriangle(collider, local_bounds, collect_trace_triangle_hit, TRACE_AGAINST_BODY_CONTEXT)
	local best_hit = TRACE_AGAINST_BODY_CONTEXT.best_hit
	TRACE_AGAINST_BODY_CONTEXT.local_ray = nil
	TRACE_AGAINST_BODY_CONTEXT.origin = nil
	TRACE_AGAINST_BODY_CONTEXT.ray_direction = nil
	TRACE_AGAINST_BODY_CONTEXT.trace_radius = 0
	TRACE_AGAINST_BODY_CONTEXT.collider = nil
	TRACE_AGAINST_BODY_CONTEXT.best_hit = nil
	TRACE_AGAINST_BODY_CONTEXT.best_distance = math.huge
	return best_hit
end

return META:Register()
