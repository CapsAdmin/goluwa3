local ecs = require("ecs.ecs")
local Vec3 = require("structs.vec3")
local AABB = require("structs.aabb")
local ffi = require("ffi")
local raycast = library()

local function create_ray(origin, direction, max_distance)
	local tbl = {}
	tbl.origin = origin
	tbl.direction = direction:GetNormalized()
	tbl.max_distance = max_distance or math.huge
	tbl.inv_direction = Vec3(
		tbl.direction.x ~= 0 and 1 / tbl.direction.x or math.huge,
		tbl.direction.y ~= 0 and 1 / tbl.direction.y or math.huge,
		tbl.direction.z ~= 0 and 1 / tbl.direction.z or math.huge
	)
	return tbl
end

local function ray_aabb_intersection(ray, aabb)
	local tx1 = (aabb.min_x - ray.origin.x) * ray.inv_direction.x
	local tx2 = (aabb.max_x - ray.origin.x) * ray.inv_direction.x
	local tmin = math.min(tx1, tx2)
	local tmax = math.max(tx1, tx2)
	local ty1 = (aabb.min_y - ray.origin.y) * ray.inv_direction.y
	local ty2 = (aabb.max_y - ray.origin.y) * ray.inv_direction.y
	tmin = math.max(tmin, math.min(ty1, ty2))
	tmax = math.min(tmax, math.max(ty1, ty2))
	local tz1 = (aabb.min_z - ray.origin.z) * ray.inv_direction.z
	local tz2 = (aabb.max_z - ray.origin.z) * ray.inv_direction.z
	tmin = math.max(tmin, math.min(tz1, tz2))
	tmax = math.min(tmax, math.max(tz1, tz2))
	return tmax >= tmin and tmax >= 0 and tmin <= ray.max_distance, tmin, tmax
end

local function ray_triangle_intersection(ray, v0, v1, v2)
	local epsilon = 0.0000001
	local edge1 = v1 - v0
	local edge2 = v2 - v0
	local h = ray.direction:GetCross(edge2)
	local a = edge1:Dot(h)

	if a > -epsilon and a < epsilon then return false, math.huge, 0, 0 end

	local f = 1.0 / a
	local s = ray.origin - v0
	local u = f * s:Dot(h)

	if u < 0.0 or u > 1.0 then return false, math.huge, 0, 0 end

	local q = s:GetCross(edge1)
	local v = f * ray.direction:Dot(q)

	if v < 0.0 or u + v > 1.0 then return false, math.huge, 0, 0 end

	local t = f * edge2:Dot(q)

	if t > epsilon and t <= ray.max_distance then return true, t, u, v end

	-- Line intersection but not ray intersection
	return false, math.huge, 0, 0
end

-- Get vertices from a mesh
-- Returns vertices as an array of Vec3 positions
local function get_mesh_vertices(poly3d)
	if not poly3d or not poly3d.Vertices then return nil end

	return poly3d.Vertices
end

-- Test ray against a single triangle
-- Returns hit info if successful
local function test_triangle(ray, vertices, indices, tri_idx, primitive_idx, entity)
	-- Get vertex indices (note: indices are 0-based from submesh)
	local i0 = indices[tri_idx * 3 + 1] + 1 -- Convert to 1-based
	local i1 = indices[tri_idx * 3 + 2] + 1
	local i2 = indices[tri_idx * 3 + 3] + 1
	-- Get vertices
	local v0_data = vertices[i0]
	local v1_data = vertices[i1]
	local v2_data = vertices[i2]

	if not (v0_data and v1_data and v2_data) then return nil end

	-- Extract positions
	local v0 = v0_data.pos
	local v1 = v1_data.pos
	local v2 = v2_data.pos
	-- Test intersection
	local hit, distance, u, v = ray_triangle_intersection(ray, v0, v1, v2)

	if hit then
		local result = {}
		result.entity = entity
		result.distance = distance or math.huge
		result.position = ray.origin + ray.direction * distance
		result.primitive_index = primitive_idx
		result.triangle_index = tri_idx

		if v0_data.normal and v1_data.normal and v2_data.normal then
			local w = 1.0 - u - v
			result.normal = (v0_data.normal * w + v1_data.normal * u + v2_data.normal * v):GetNormalized()
		else
			local edge1 = v1 - v0
			local edge2 = v2 - v0
			result.normal = edge1:Cross(edge2):GetNormalized()
		end

		return result
	end

	return nil
end

local function test_primitive(ray, primitive, primitive_idx, entity, world_to_local)
	local poly3d = primitive.polygon3d

	if not poly3d then return nil end

	local vertices = get_mesh_vertices(poly3d)

	if not vertices then return nil end

	local local_ray = ray

	if world_to_local then
		-- Transform origin (with translation)
		local local_origin = Vec3(world_to_local:TransformVector(ray.origin.x, ray.origin.y, ray.origin.z))
		-- Transform direction (without translation - use matrix multiplication for direction)
		-- For a direction, we want to apply only rotation/scale, not translation
		-- So we multiply the direction by the 3x3 upper-left part of the matrix
		local m = world_to_local
		local dx, dy, dz = ray.direction.x, ray.direction.y, ray.direction.z
		local local_dir_x = m.m00 * dx + m.m10 * dy + m.m20 * dz
		local local_dir_y = m.m01 * dx + m.m11 * dy + m.m21 * dz
		local local_dir_z = m.m02 * dx + m.m12 * dy + m.m22 * dz
		local local_direction = Vec3(local_dir_x, local_dir_y, local_dir_z):GetNormalized()
		local_ray = create_ray(local_origin, local_direction, ray.max_distance)
	end

	if primitive.aabb then
		local aabb_hit = ray_aabb_intersection(local_ray, primitive.aabb)

		if not aabb_hit then return nil end
	end

	local closest_hit = nil
	local vertices = poly3d:GetVertices()
	local indices = poly3d.indices

	if indices then
		local triangle_count = math.floor(#indices / 3)

		for tri_idx = 0, triangle_count - 1 do
			local hit = test_triangle(local_ray, vertices, indices, tri_idx, primitive_idx, entity)

			if hit and (not closest_hit or hit.distance < closest_hit.distance) then
				closest_hit = hit
				hit.poly = poly3d
				hit.primitive = primitive
			end
		end
	else
		-- Sequential vertices
		local vertex_count = #vertices
		local triangle_count = math.floor(vertex_count / 3)
		-- Create temporary indices for sequential test
		local dummy_indices = {}

		for i = 1, vertex_count do
			dummy_indices[i] = i - 1
		end

		for tri_idx = 0, triangle_count - 1 do
			local hit = test_triangle(
				local_ray,
				vertices,
				dummy_indices,
				tri_idx,
				primitive_idx,
				entity
			)

			if hit and (not closest_hit or hit.distance < closest_hit.distance) then
				closest_hit = hit
				hit.poly = poly3d
				hit.primitive = primitive
			end
		end
	end

	if closest_hit and world_to_local then
		local local_to_world = entity.transform:GetWorldMatrix()
		closest_hit.position = Vec3(
			local_to_world:TransformVector(closest_hit.position.x, closest_hit.position.y, closest_hit.position.z)
		)
		local normal_end = closest_hit.position + closest_hit.normal
		local world_normal_end = Vec3(local_to_world:TransformVector(normal_end.x, normal_end.y, normal_end.z))
		closest_hit.normal = (world_normal_end - closest_hit.position):GetNormalized()
		closest_hit.distance = (closest_hit.position - ray.origin):GetLength()
		closest_hit.entity = entity
	end

	return closest_hit
end

local function distance_sort(a, b)
	return a.distance < b.distance
end

function raycast.Cast(origin, direction, max_distance, filter_fn)
	max_distance = max_distance or math.huge
	local ray = create_ray(origin, direction, max_distance)
	local hits = {}
	local models = ecs.GetComponents("model")

	for _, model in ipairs(models) do
		if filter_fn and not filter_fn(model.Entity) then goto continue end

		if not model.Visible or #model.Primitives == 0 then goto continue end

		local world_to_local = nil

		if model.Entity and model.Entity:HasComponent("transform") then
			world_to_local = model.Entity.transform:GetWorldMatrixInverse()
		end

		if world_to_local then
			local local_ray_origin = Vec3(world_to_local:TransformVector(ray.origin.x, ray.origin.y, ray.origin.z))
			local m = world_to_local
			local dx, dy, dz = ray.direction.x, ray.direction.y, ray.direction.z
			local local_dir_x = m.m00 * dx + m.m10 * dy + m.m20 * dz
			local local_dir_y = m.m01 * dx + m.m11 * dy + m.m21 * dz
			local local_dir_z = m.m02 * dx + m.m12 * dy + m.m22 * dz
			local local_ray_direction = Vec3(local_dir_x, local_dir_y, local_dir_z):GetNormalized()
			local local_ray = create_ray(local_ray_origin, local_ray_direction, ray.max_distance)

			if model.AABB then
				local aabb_hit = ray_aabb_intersection(local_ray, model.AABB)

				if not aabb_hit then goto continue end
			end
		end

		for prim_idx, primitive in ipairs(model.Primitives) do
			local hit = test_primitive(ray, primitive, prim_idx, model.Entity, world_to_local)

			if hit then table.insert(hits, hit) end
		end

		::continue::
	end

	table.sort(hits, distance_sort)
	return hits
end

return raycast
