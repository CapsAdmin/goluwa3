local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local META = prototype.CreateTemplate("physics_shape_heightmap")
META.Base = BaseShape
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
local HEIGHTMAP_LOCAL_AABB_TRANSFORM_PROXY = {
	collider = nil,
	position = nil,
	rotation = nil,
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

function HEIGHTMAP_LOCAL_AABB_TRANSFORM_PROXY:TransformVector(point)
	return self.collider:WorldToLocal(point, self.position, self.rotation)
end

local function get_raw_height(tex, x, y, pow)
	local r, g, b, a = tex:GetRawPixelColor(x, y)
	return (((r + g + b + a) / 4) / 255) ^ pow
end

local function ray_triangle_intersection(ray, v0, v1, v2)
	local epsilon = 0.0000001
	local edge1 = v1 - v0
	local edge2 = v2 - v0
	local h = ray.direction:GetCross(edge2)
	local a = edge1:Dot(h)

	if a > -epsilon and a < epsilon then return false end

	local f = 1.0 / a
	local s = ray.origin - v0
	local u = f * s:Dot(h)

	if u < 0.0 or u > 1.0 then return false end

	local q = s:GetCross(edge1)
	local v = f * ray.direction:Dot(q)

	if v < 0.0 or u + v > 1.0 then return false end

	local t = f * edge2:Dot(q)

	if t > epsilon and t <= ray.max_distance then return true, t end

	return false
end

local function build_ray(origin, direction, max_distance)
	local ray = {
		origin = origin,
		direction = direction:GetNormalized(),
		max_distance = max_distance or math.huge,
	}
	return ray
end

local function get_cache_sample(cache, x, y)
	return cache.samples[(y * cache.sample_stride) + x + 1]
end

local function get_sample_from_array(samples, sample_stride, x, y)
	return samples[(y * sample_stride) + x + 1]
end

local function get_cache_point(cache, x, y)
	return cache.points[(y * cache.sample_stride) + x + 1]
end

local function get_cell_index(cache, x, y)
	return (y * cache.resolution_x) + x + 1
end

local function get_cell_triangle_base(cache, x, y)
	return ((x * cache.resolution_y) + y) * 4
end

local function build_cache_key(self, tex, size, resolution_x, resolution_y, height, pow)
	return table.concat(
		{
			tostring(tex),
			string.format("%.6f", size.x),
			string.format("%.6f", size.y),
			tostring(resolution_x),
			tostring(resolution_y),
			string.format("%.6f", height),
			string.format("%.6f", pow),
		},
		":"
	)
end

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

function META.New(data)
	local shape = META:CreateObject()
	data = data or {}
	shape.Heightmap = data.Heightmap
	shape.Size = data.Size
	shape.Resolution = data.Resolution
	shape.Height = data.Height
	shape.Pow = data.Pow
	return shape
end

function META:GetTypeName()
	return "mesh"
end

function META:OnBodyGeometryChanged(body)
	BaseShape.OnBodyGeometryChanged(self, body)
	self.HeightmapCache = nil
	self.HeightmapCacheKey = nil
	self.LocalBounds = nil
	self.CollisionLocalPoints = nil
	self.SupportLocalPoints = nil
end

function META:BuildHeightmapCache(body)
	local tex = self.Heightmap
	local size = self.Size or Vec2(1024, 1024)
	local resolution = self.Resolution or Vec2(64, 64)
	local resolution_x = math.max(1, math.floor((resolution.x or 0) + 0.5))
	local resolution_y = math.max(1, math.floor((resolution.y or 0) + 0.5))
	local height = self.Height

	if height == nil then height = 64 end

	local pow = self.Pow

	if pow == nil then pow = 1 end

	local cache_key = build_cache_key(self, tex, size, resolution_x, resolution_y, height, pow)

	if self.HeightmapCache and self.HeightmapCacheKey == cache_key then
		return self.HeightmapCache
	end

	local texture_size = tex:GetSize()
	local step = Vec2(size.x / resolution_x, size.y / resolution_y)
	local half_step = step / 2
	local offset = -Vec3(size.x, height, size.y) / 2
	local sample_stride = resolution_x + 1
	local samples = {}
	local points = {}
	local min_y = math.huge
	local max_y = -math.huge

	for y = 0, resolution_y do
		local sample_y = (y / resolution_y) * texture_size.y
		local local_z = offset.z + y * step.y

		for x = 0, resolution_x do
			local sample_x = (x / resolution_x) * texture_size.x
			local local_height = get_raw_height(tex, sample_x, sample_y, pow) * height + offset.y
			local index = (y * sample_stride) + x + 1
			samples[index] = local_height
			points[index] = Vec3(offset.x + x * step.x, local_height, local_z)
			min_y = math.min(min_y, local_height)
			max_y = math.max(max_y, local_height)
		end
	end

	local cell_centers = {}
	local cell_min_heights = {}
	local cell_max_heights = {}

	for y = 0, resolution_y - 1 do
		local z0 = offset.z + y * step.y
		local zc = z0 + half_step.y

		for x = 0, resolution_x - 1 do
			local top_left = get_sample_from_array(samples, sample_stride, x, y)
			local top_right = get_sample_from_array(samples, sample_stride, x + 1, y)
			local bottom_left = get_sample_from_array(samples, sample_stride, x, y + 1)
			local bottom_right = get_sample_from_array(samples, sample_stride, x + 1, y + 1)
			local center_height = (top_left + top_right + bottom_left + bottom_right) * 0.25
			local cell_index = (y * resolution_x) + x + 1
			cell_centers[cell_index] = Vec3(offset.x + x * step.x + half_step.x, center_height, zc)
			cell_min_heights[cell_index] = math.min(top_left, top_right, bottom_left, bottom_right, center_height)
			cell_max_heights[cell_index] = math.max(top_left, top_right, bottom_left, bottom_right, center_height)
		end
	end

	local cache = {
		tex = tex,
		size = size,
		resolution = Vec2(resolution_x, resolution_y),
		resolution_x = resolution_x,
		resolution_y = resolution_y,
		height = height,
		pow = pow,
		step = step,
		half_step = half_step,
		offset = offset,
		samples = samples,
		points = points,
		sample_stride = sample_stride,
		cell_centers = cell_centers,
		cell_min_heights = cell_min_heights,
		cell_max_heights = cell_max_heights,
		bounds = AABB(-size.x / 2, min_y, -size.y / 2, size.x / 2, max_y, size.y / 2),
	}
	local mid_x = math.floor(resolution_x * 0.5)
	local mid_y = math.floor(resolution_y * 0.5)
	local collision_points = {
		get_cache_point(cache, 0, 0),
		get_cache_point(cache, resolution_x, 0),
		get_cache_point(cache, 0, resolution_y),
		get_cache_point(cache, resolution_x, resolution_y),
		get_cache_point(cache, mid_x, mid_y),
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
	self.HeightmapCacheKey = cache_key
	return cache
end

function META:GetLocalBounds(body)
	if self.LocalBounds then return self.LocalBounds end

	local cache = self:BuildHeightmapCache(body)
	self.LocalBounds = cache.bounds
	return self.LocalBounds
end

function META:GetHalfExtents(body)
	local bounds = self:GetLocalBounds(body)
	return Vec3(
		(bounds.max_x - bounds.min_x) * 0.5,
		(bounds.max_y - bounds.min_y) * 0.5,
		(bounds.max_z - bounds.min_z) * 0.5
	)
end

function META:GetMassProperties()
	return 0, Matrix33():SetZero()
end

function META:BuildCollisionLocalPoints(body)
	return self:BuildHeightmapCache(body).collision_points
end

function META:BuildSupportLocalPoints(body)
	return self:BuildHeightmapCache(body).support_points
end

function META:GetBroadphaseAABB(body, position, rotation)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	local bounds = self:GetLocalBounds(body)
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
		rotation:VecMul(corners[i], rotated_corner)
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

	return AABB(world_min_x, world_min_y, world_min_z, world_max_x, world_max_y, world_max_z)
end

function META:GetTriangleWorldVertices(collider, position, rotation, v0, v1, v2)
	return collider:LocalToWorld(v0, position, rotation),
	collider:LocalToWorld(v1, position, rotation),
	collider:LocalToWorld(v2, position, rotation)
end

function META:BuildSweptLocalAABB(collider, position, rotation, world_aabb)
	if not (collider and world_aabb) then return nil end

	HEIGHTMAP_LOCAL_AABB_TRANSFORM_PROXY.collider = collider
	HEIGHTMAP_LOCAL_AABB_TRANSFORM_PROXY.position = position
	HEIGHTMAP_LOCAL_AABB_TRANSFORM_PROXY.rotation = rotation
	local local_aabb = AABB.BuildLocalAABBFromWorldAABB(world_aabb, HEIGHTMAP_LOCAL_AABB_TRANSFORM_PROXY)
	HEIGHTMAP_LOCAL_AABB_TRANSFORM_PROXY.collider = nil
	HEIGHTMAP_LOCAL_AABB_TRANSFORM_PROXY.position = nil
	HEIGHTMAP_LOCAL_AABB_TRANSFORM_PROXY.rotation = nil
	return local_aabb
end

function META:ForEachOverlappingTriangle(body, local_bounds, callback, context)
	local cache = self:BuildHeightmapCache(body)

	if not callback then return end

	local min_cell_x = 0
	local max_cell_x = cache.resolution_x - 1
	local min_cell_y = 0
	local max_cell_y = cache.resolution_y - 1

	if local_bounds then
		if
			local_bounds.max_x < cache.bounds.min_x or
			local_bounds.min_x > cache.bounds.max_x or
			local_bounds.max_z < cache.bounds.min_z or
			local_bounds.min_z > cache.bounds.max_z or
			local_bounds.max_y < cache.bounds.min_y or
			local_bounds.min_y > cache.bounds.max_y
		then
			return
		end

		min_cell_x = clamp_cell_index(
			math.floor((local_bounds.min_x - cache.offset.x) / cache.step.x),
			cache.resolution_x - 1
		)
		max_cell_x = clamp_cell_index(
			math.floor((local_bounds.max_x - cache.offset.x) / cache.step.x),
			cache.resolution_x - 1
		)
		min_cell_y = clamp_cell_index(
			math.floor((local_bounds.min_z - cache.offset.z) / cache.step.y),
			cache.resolution_y - 1
		)
		max_cell_y = clamp_cell_index(
			math.floor((local_bounds.max_z - cache.offset.z) / cache.step.y),
			cache.resolution_y - 1
		)
	end

	local previous_entry = context and context.entry or nil

	if context then context.entry = SHARED_HEIGHTMAP_ENTRY end

	for x = min_cell_x, max_cell_x do
		local x0 = cache.offset.x + x * cache.step.x
		local x1 = x0 + cache.step.x

		for y = min_cell_y, max_cell_y do
			local z0 = cache.offset.z + y * cache.step.y
			local z1 = z0 + cache.step.y
			local cell_index = get_cell_index(cache, x, y)

			if local_bounds then
				local cell_min_y = cache.cell_min_heights[cell_index]
				local cell_max_y = cache.cell_max_heights[cell_index]

				if
					x1 < local_bounds.min_x or
					x0 > local_bounds.max_x or
					z1 < local_bounds.min_z or
					z0 > local_bounds.max_z or
					cell_max_y < local_bounds.min_y or
					cell_min_y > local_bounds.max_y
				then
					goto continue
				end
			end

			local triangle_base = get_cell_triangle_base(cache, x, y)
			local top_left = get_cache_point(cache, x, y)
			local top_right = get_cache_point(cache, x + 1, y)
			local bottom_left = get_cache_point(cache, x, y + 1)
			local bottom_right = get_cache_point(cache, x + 1, y + 1)
			local center = cache.cell_centers[cell_index]
			callback(bottom_left, center, bottom_right, triangle_base + 1, context)
			callback(bottom_left, top_left, center, triangle_base + 2, context)
			callback(top_left, top_right, center, triangle_base + 3, context)
			callback(center, top_right, bottom_right, triangle_base + 4, context)

			::continue::
		end
	end

	if context then context.entry = previous_entry end
end

function META:TraceAgainstBody(collider, origin, direction, max_distance, trace_radius)
	local ray_direction = direction and direction:GetNormalized() or Vec3(0, 0, 0)

	if ray_direction:GetLength() <= 0.00001 then return nil end

	local distance_limit = max_distance or math.huge
	local local_origin = collider:WorldToLocal(origin)
	local local_direction = collider:GetRotation():GetConjugated():VecMul(ray_direction):GetNormalized()
	local local_ray = build_ray(local_origin, local_direction, distance_limit)
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
	TRACE_AGAINST_BODY_CONTEXT.local_ray = local_ray
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
