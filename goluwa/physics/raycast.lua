local Vec3 = import("goluwa/structs/vec3.lua")
local BVH = import("goluwa/physics/bvh.lua")
local Model = import("goluwa/ecs/components/3d/model.lua")
local raycast = library()
local BVH_BUILD_TRIANGLE_THRESHOLD = 128
local BVH_LEAF_TRIANGLE_COUNT = 8
import.loaded["goluwa/physics/raycast.lua"] = raycast
import.loaded["goluwa/physics/raycast.lua"] = raycast

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

local function transform_ray(ray, world_to_local)
	if not world_to_local then return ray end

	local local_origin = Vec3(world_to_local:TransformVector(ray.origin.x, ray.origin.y, ray.origin.z))
	local m = world_to_local
	local dx, dy, dz = ray.direction.x, ray.direction.y, ray.direction.z
	local local_dir_x = m.m00 * dx + m.m10 * dy + m.m20 * dz
	local local_dir_y = m.m01 * dx + m.m11 * dy + m.m21 * dz
	local local_dir_z = m.m02 * dx + m.m12 * dy + m.m22 * dz
	local local_direction = Vec3(local_dir_x, local_dir_y, local_dir_z):GetNormalized()
	return create_ray(local_origin, local_direction, ray.max_distance)
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

	return false, math.huge, 0, 0
end

local function get_index_buffer(poly3d, vertices, indices)
	if indices then return indices, math.floor(#indices / 3) end

	local vertex_count = #vertices
	local triangle_count = math.floor(vertex_count / 3)

	if
		poly3d.raycast_sequential_indices and
		poly3d.raycast_sequential_vertex_count == vertex_count
	then
		return poly3d.raycast_sequential_indices, triangle_count
	end

	local sequential = {}

	for i = 1, vertex_count do
		sequential[i] = i - 1
	end

	poly3d.raycast_sequential_indices = sequential
	poly3d.raycast_sequential_vertex_count = vertex_count
	return sequential, triangle_count
end

local function test_triangle_vertices(ray, vertices, i0, i1, i2, tri_idx, primitive_idx, entity)
	local v0_data = vertices[i0]
	local v1_data = vertices[i1]
	local v2_data = vertices[i2]

	if not (v0_data and v1_data and v2_data) then return nil end

	local v0 = v0_data.pos
	local v1 = v1_data.pos
	local v2 = v2_data.pos
	local hit, distance, u, v = ray_triangle_intersection(ray, v0, v1, v2)

	if not hit then return nil end

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

local function build_triangle_acceleration(vertices, indices, triangle_count)
	local triangles = {}

	for tri_idx = 0, triangle_count - 1 do
		local base = tri_idx * 3
		local i0 = indices[base + 1] + 1
		local i1 = indices[base + 2] + 1
		local i2 = indices[base + 3] + 1
		local v0_data = vertices[i0]
		local v1_data = vertices[i1]
		local v2_data = vertices[i2]

		if v0_data and v1_data and v2_data and v0_data.pos and v1_data.pos and v2_data.pos then
			local v0 = v0_data.pos
			local v1 = v1_data.pos
			local v2 = v2_data.pos
			local min_x = math.min(v0.x, v1.x, v2.x)
			local min_y = math.min(v0.y, v1.y, v2.y)
			local min_z = math.min(v0.z, v1.z, v2.z)
			local max_x = math.max(v0.x, v1.x, v2.x)
			local max_y = math.max(v0.y, v1.y, v2.y)
			local max_z = math.max(v0.z, v1.z, v2.z)
			triangles[#triangles + 1] = {
				tri_idx = tri_idx,
				i0 = i0,
				i1 = i1,
				i2 = i2,
				min_x = min_x,
				min_y = min_y,
				min_z = min_z,
				max_x = max_x,
				max_y = max_y,
				max_z = max_z,
				centroid_x = (v0.x + v1.x + v2.x) / 3,
				centroid_y = (v0.y + v1.y + v2.y) / 3,
				centroid_z = (v0.z + v1.z + v2.z) / 3,
			}
		end
	end

	if #triangles == 0 then return nil end

	local tree = BVH.Build(
		triangles,
		function(tri)
			return tri
		end,
		function(tri)
			return tri.centroid_x, tri.centroid_y, tri.centroid_z
		end,
		BVH_LEAF_TRIANGLE_COUNT
	)

	if not tree then return nil end

	tree.triangles = tree.items
	tree.items = nil
	return tree
end

local function get_triangle_acceleration(primitive, vertices, indices, triangle_count)
	if triangle_count < BVH_BUILD_TRIANGLE_THRESHOLD then return nil end

	local accel = primitive.raycast_acceleration

	if
		accel and
		accel.vertices == vertices and
		accel.indices == indices and
		accel.triangle_count == triangle_count
	then
		return accel
	end

	local built = build_triangle_acceleration(vertices, indices, triangle_count)

	if not built then
		primitive.raycast_acceleration = nil
		return nil
	end

	built.vertices = vertices
	built.indices = indices
	built.triangle_count = triangle_count
	primitive.raycast_acceleration = built
	return built
end

local function get_mesh_vertices(poly3d)
	if not poly3d or not poly3d.Vertices then return nil end

	return poly3d.Vertices
end

local function test_triangle(ray, vertices, indices, tri_idx, primitive_idx, entity)
	local i0 = indices[tri_idx * 3 + 1] + 1
	local i1 = indices[tri_idx * 3 + 2] + 1
	local i2 = indices[tri_idx * 3 + 3] + 1
	return test_triangle_vertices(ray, vertices, i0, i1, i2, tri_idx, primitive_idx, entity)
end

local function visit_triangle_bvh_leaf(node, context, best_hit, best_distance)
	for i = node.first, node.last do
		local tri = context.acceleration.triangles[i]
		local hit = test_triangle_vertices(
			context.local_ray,
			context.vertices,
			tri.i0,
			tri.i1,
			tri.i2,
			tri.tri_idx,
			context.primitive_idx,
			context.entity
		)

		if hit and hit.distance < best_distance then
			best_hit = hit
			best_distance = hit.distance
		end
	end

	return best_hit, best_distance
end

local function test_primitive(ray, local_ray, primitive, primitive_idx, entity, local_to_world)
	local poly3d = primitive.polygon3d

	if not poly3d then return nil end

	local vertices = get_mesh_vertices(poly3d)

	if not vertices then return nil end

	if primitive.aabb then
		local aabb_hit = BVH.RayAABBIntersection(local_ray, primitive.aabb)

		if not aabb_hit then return nil end
	end

	local closest_hit = nil
	local indices, triangle_count = get_index_buffer(poly3d, vertices, poly3d.indices)
	local acceleration = get_triangle_acceleration(primitive, vertices, indices, triangle_count)

	if acceleration then
		local traversal_context = {
			acceleration = acceleration,
			local_ray = local_ray,
			vertices = vertices,
			primitive_idx = primitive_idx,
			entity = entity,
		}
		closest_hit = select(
			1,
			BVH.TraverseRay(
				local_ray,
				acceleration.root,
				visit_triangle_bvh_leaf,
				traversal_context,
				nil,
				math.huge
			)
		)
	else
		for tri_idx = 0, triangle_count - 1 do
			local hit = test_triangle(local_ray, vertices, indices, tri_idx, primitive_idx, entity)

			if hit and (not closest_hit or hit.distance < closest_hit.distance) then
				closest_hit = hit
			end
		end
	end

	if closest_hit then
		closest_hit.poly = poly3d
		closest_hit.primitive = primitive
	end

	if closest_hit and local_to_world then
		closest_hit.position = Vec3(
			local_to_world:TransformVector(closest_hit.position.x, closest_hit.position.y, closest_hit.position.z)
		)
		local normal_end = closest_hit.position + closest_hit.normal
		local world_normal_end = Vec3(local_to_world:TransformVector(normal_end.x, normal_end.y, normal_end.z))
		closest_hit.normal = (world_normal_end - closest_hit.position):GetNormalized()
		closest_hit.distance = (closest_hit.position - ray.origin):GetLength()
		closest_hit.entity = entity
	end

	if closest_hit and closest_hit.normal and closest_hit.normal:Dot(ray.direction) > 0 then
		closest_hit.normal = closest_hit.normal * -1
	end

	return closest_hit
end

local function distance_sort(a, b)
	return a.distance < b.distance
end

function raycast.Cast(origin, direction, max_distance, filter_fn, a, b, c, d, e, f)
	max_distance = max_distance or math.huge
	local ray = create_ray(origin, direction, max_distance)
	local hits = {}
	local models = Model.Instances

	for _, model in ipairs(models) do
		if filter_fn and not filter_fn(model.Owner, a, b, c, d, e, f) then
			goto continue
		end

		if not model.Visible or #model.Primitives == 0 then goto continue end

		local world_to_local = nil
		local local_to_world = nil

		if model.Owner and model.Owner.transform then
			world_to_local = model.Owner.transform:GetWorldMatrixInverse()
			local_to_world = model.Owner.transform:GetWorldMatrix()
		end

		local local_ray = transform_ray(ray, world_to_local)

		if model.AABB then
			local aabb_hit = BVH.RayAABBIntersection(local_ray, model.AABB)

			if not aabb_hit then goto continue end
		end

		for prim_idx, primitive in ipairs(model.Primitives) do
			local hit = test_primitive(ray, local_ray, primitive, prim_idx, model.Owner, local_to_world)

			if hit then table.insert(hits, hit) end
		end

		::continue::
	end

	table.sort(hits, distance_sort)
	return hits
end

return raycast