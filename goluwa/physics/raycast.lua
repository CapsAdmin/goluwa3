local Vec3 = import("goluwa/structs/vec3.lua")
local BVH = import("goluwa/physics/bvh.lua")
local Model = import("goluwa/ecs/components/3d/model.lua")
local system = import("goluwa/system.lua")
local raycast = library()
local BVH_BUILD_TRIANGLE_THRESHOLD = 8
local BVH_LEAF_TRIANGLE_COUNT = 8
local MODEL_BVH_LEAF_ITEM_COUNT = 8
local MODEL_PRIMITIVE_BVH_THRESHOLD = 16
local MODEL_PRIMITIVE_BVH_LEAF_ITEM_COUNT = 8
local model_acceleration = {
	dirty = true,
	tree = nil,
	items = {},
	dynamic_models = {},
	frame = -1,
	model_count = 0,
}
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

function raycast.InvalidateModelAcceleration()
	model_acceleration.dirty = true
	model_acceleration.tree = nil
end

local function has_model_geometry(model)
	return model and model.Primitives and #model.Primitives > 0 and model.AABB ~= nil
end

local function is_dynamic_model(model)
	local owner = model and model.Owner

	if owner and owner.rigid_body then return true end

	local transform = owner and owner.transform
	return transform and transform.IsFrameDynamic and transform:IsFrameDynamic() or false
end

local function add_model_acceleration_item(items, model, bounds)
	if not bounds then return end

	items[#items + 1] = {
		model = model,
		min_x = bounds.min_x,
		min_y = bounds.min_y,
		min_z = bounds.min_z,
		max_x = bounds.max_x,
		max_y = bounds.max_y,
		max_z = bounds.max_z,
		centroid_x = (bounds.min_x + bounds.max_x) * 0.5,
		centroid_y = (bounds.min_y + bounds.max_y) * 0.5,
		centroid_z = (bounds.min_z + bounds.max_z) * 0.5,
	}
end

local function rebuild_model_acceleration()
	local items = {}
	local dynamic_models = {}

	for _, model in ipairs(Model.Instances or {}) do
		if has_model_geometry(model) then
			if is_dynamic_model(model) then
				dynamic_models[#dynamic_models + 1] = model
			else
				add_model_acceleration_item(items, model, model.GetWorldAABB and model:GetWorldAABB() or model.AABB)
			end
		end
	end

	model_acceleration.items = items
	model_acceleration.dynamic_models = dynamic_models
	model_acceleration.tree = #items > 0 and
		BVH.Build(
			items,
			function(item)
				return item
			end,
			function(item)
				return item.centroid_x, item.centroid_y, item.centroid_z
			end,
			MODEL_BVH_LEAF_ITEM_COUNT
		) or
		nil
	model_acceleration.dirty = false

	if model_acceleration.tree then
		model_acceleration.tree.models = model_acceleration.tree.items
		model_acceleration.tree.items = nil
		model_acceleration.tree.traversal_context = model_acceleration.tree.traversal_context or
			{
				acceleration = model_acceleration.tree,
				node_stack = {},
				tmin_stack = {},
			}
	end
end

local function build_static_model_source(models)
	local items = {}

	for _, model in ipairs(models or {}) do
		if has_model_geometry(model) then
			add_model_acceleration_item(items, model, model.GetWorldAABB and model:GetWorldAABB() or model.AABB)
		end
	end

	local source = {
		models = models or {},
		items = items,
		dynamic_models = {},
		tree = #items > 0 and
			BVH.Build(
				items,
				function(item)
					return item
				end,
				function(item)
					return item.centroid_x, item.centroid_y, item.centroid_z
				end,
				MODEL_BVH_LEAF_ITEM_COUNT
			) or
			nil,
	}

	if source.tree then
		source.tree.models = source.tree.items
		source.tree.items = nil
		source.tree.traversal_context = source.tree.traversal_context or
			{
				acceleration = source.tree,
				node_stack = {},
				tmin_stack = {},
			}
	else
		source.dynamic_models = source.models
	end

	return source
end

local function ensure_model_acceleration()
	local frame = system.GetFrameNumber and system.GetFrameNumber() or 0
	local model_count = #(Model.Instances or {})

	if
		model_acceleration.dirty or
		model_acceleration.frame ~= frame or
		model_acceleration.model_count ~= model_count
	then
		rebuild_model_acceleration()
		model_acceleration.frame = frame
		model_acceleration.model_count = model_count
	end

	return model_acceleration
end

local function get_model_transforms(model)
	local world_to_local = nil
	local local_to_world = nil

	if model.WorldSpaceVertices then return nil, nil end

	if model.Owner and model.Owner.transform then
		world_to_local = model.Owner.transform:GetWorldMatrixInverse()
		local_to_world = model.Owner.transform:GetWorldMatrix()
	end

	return world_to_local, local_to_world
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

	if u < 0.0 then return false end

	if u > 1.0 then return false end

	local q = s:GetCross(edge1)
	local v = f * ray.direction:Dot(q)

	if v < 0.0 then return false end

	if u + v > 1.0 then return false end

	local t = f * edge2:Dot(q)

	if t > epsilon and t <= ray.max_distance then return true, t, u, v end

	return false
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

local function test_triangle_vertices(ray, vertices, i0, i1, i2, tri_idx, primitive_idx, entity, cached_face_normal)
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
	result.face_normal = cached_face_normal or (v1 - v0):Cross(v2 - v0):GetNormalized()

	if v0_data.normal and v1_data.normal and v2_data.normal then
		local w = 1.0 - u - v
		result.normal = (v0_data.normal * w + v1_data.normal * u + v2_data.normal * v):GetNormalized()
	else
		result.normal = result.face_normal
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
			local face_normal = (v1 - v0):Cross(v2 - v0):GetNormalized()
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
				face_normal = face_normal,
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
	built.traversal_context = built.traversal_context or
		{
			acceleration = built,
			node_stack = {},
			tmin_stack = {},
		}
	primitive.raycast_acceleration = built
	return built
end

local function get_mesh_vertices(poly3d)
	if not poly3d or not poly3d.Vertices then return nil end

	return poly3d.Vertices
end

local function build_model_primitive_acceleration(model)
	local items = {}
	local uncached_indices = {}

	for primitive_idx, primitive in ipairs(model.Primitives or {}) do
		local bounds = primitive.aabb

		if bounds then
			items[#items + 1] = {
				primitive = primitive,
				primitive_idx = primitive_idx,
				min_x = bounds.min_x,
				min_y = bounds.min_y,
				min_z = bounds.min_z,
				max_x = bounds.max_x,
				max_y = bounds.max_y,
				max_z = bounds.max_z,
				centroid_x = (bounds.min_x + bounds.max_x) * 0.5,
				centroid_y = (bounds.min_y + bounds.max_y) * 0.5,
				centroid_z = (bounds.min_z + bounds.max_z) * 0.5,
			}
		else
			uncached_indices[#uncached_indices + 1] = primitive_idx
		end
	end

	if #items < MODEL_PRIMITIVE_BVH_THRESHOLD then return nil end

	local tree = BVH.Build(
		items,
		function(item)
			return item
		end,
		function(item)
			return item.centroid_x, item.centroid_y, item.centroid_z
		end,
		MODEL_PRIMITIVE_BVH_LEAF_ITEM_COUNT
	)

	if not tree then return nil end

	tree.primitives = tree.items
	tree.items = nil
	tree.traversal_context = tree.traversal_context or
		{
			acceleration = tree,
			node_stack = {},
			tmin_stack = {},
		}
	return {
		tree = tree,
		primitive_table = model.Primitives,
		primitive_count = #model.Primitives,
		uncached_indices = uncached_indices,
	}
end

local function get_model_primitive_acceleration(model)
	local accel = model.raycast_primitive_acceleration

	if
		accel and
		accel.primitive_table == model.Primitives and
		accel.primitive_count == #model.Primitives
	then
		return accel
	end

	accel = build_model_primitive_acceleration(model)
	model.raycast_primitive_acceleration = accel
	return accel
end

local function test_convex_plane_primitive(ray, planes, primitive_idx, entity, max_hit_distance)
	if not (planes and planes[1]) then return nil end

	local epsilon = 0.000001
	local origin_x = ray.origin.x
	local origin_y = ray.origin.y
	local origin_z = ray.origin.z
	local dir_x = ray.direction.x
	local dir_y = ray.direction.y
	local dir_z = ray.direction.z
	local t_enter = 0
	local t_exit = max_hit_distance or ray.max_distance or math.huge
	local enter_normal = nil
	local exit_normal = nil
	local origin_inside = true
	local nearest_inside_normal = nil
	local nearest_inside_distance = -math.huge

	for _, plane in ipairs(planes) do
		local normal = plane.normal
		local origin_distance = origin_x * normal.x + origin_y * normal.y + origin_z * normal.z
		local signed_distance = origin_distance - plane.dist
		local denom = dir_x * normal.x + dir_y * normal.y + dir_z * normal.z

		if signed_distance > epsilon then
			origin_inside = false
		elseif signed_distance > nearest_inside_distance then
			nearest_inside_distance = signed_distance
			nearest_inside_normal = normal
		end

		if math.abs(denom) <= epsilon then
			if signed_distance > epsilon then return nil end
		else
			local t = (plane.dist - origin_distance) / denom

			if denom < 0 then
				if t > t_enter then
					t_enter = t
					enter_normal = normal
				end
			else
				if t < t_exit then
					t_exit = t
					exit_normal = normal
				end
			end

			if t_enter - t_exit > epsilon then return nil end
		end
	end

	local distance = origin_inside and 0 or t_enter
	local face_normal = origin_inside and (nearest_inside_normal or exit_normal) or enter_normal

	if
		not distance or
		(
			not origin_inside and
			distance <= epsilon
		)
		or
		distance > (
			max_hit_distance or
			ray.max_distance or
			math.huge
		)
	then
		return nil
	end

	if not face_normal then return nil end

	return {
		entity = entity,
		distance = distance,
		position = ray.origin + ray.direction * distance,
		primitive_index = primitive_idx,
		face_normal = face_normal,
		normal = face_normal,
	}
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
			context.entity,
			tri.face_normal
		)

		if hit and hit.distance < best_distance then
			best_hit = hit
			best_distance = hit.distance
		end
	end

	return best_hit, best_distance
end

local function test_primitive_with_limit(
	ray,
	local_ray,
	primitive,
	primitive_idx,
	entity,
	local_to_world,
	max_hit_distance
)
	if primitive.aabb then
		local aabb_hit = BVH.RayAABBIntersection(local_ray, primitive.aabb)

		if not aabb_hit then return nil end
	end

	if primitive.brush_planes then
		local brush_hit = test_convex_plane_primitive(
			local_ray,
			primitive.brush_planes,
			primitive_idx,
			entity,
			max_hit_distance
		)

		if brush_hit then brush_hit.primitive = primitive end

		return brush_hit
	end

	local poly3d = primitive.polygon3d

	if not poly3d then return nil end

	local vertices = get_mesh_vertices(poly3d)

	if not vertices then return nil end

	local closest_hit = nil
	local indices, triangle_count = get_index_buffer(poly3d, vertices, poly3d.indices)
	local acceleration = get_triangle_acceleration(primitive, vertices, indices, triangle_count)

	if acceleration then
		local traversal_context = acceleration.traversal_context
		traversal_context.acceleration = acceleration
		traversal_context.local_ray = local_ray
		traversal_context.vertices = vertices
		traversal_context.primitive_idx = primitive_idx
		traversal_context.entity = entity
		closest_hit = select(
			1,
			BVH.TraverseRay(
				local_ray,
				acceleration.root,
				visit_triangle_bvh_leaf,
				traversal_context,
				nil,
				max_hit_distance or math.huge
			)
		)
	else
		for tri_idx = 0, triangle_count - 1 do
			local hit = test_triangle(local_ray, vertices, indices, tri_idx, primitive_idx, entity)

			if
				hit and
				hit.distance <= (
					max_hit_distance or
					math.huge
				)
				and
				(
					not closest_hit or
					hit.distance < closest_hit.distance
				)
			then
				closest_hit = hit
			end
		end
	end

	if closest_hit then
		closest_hit.poly = poly3d
		closest_hit.primitive = primitive
	end

	if closest_hit and local_to_world then
		local local_position = closest_hit.position
		closest_hit.position = Vec3(
			local_to_world:TransformVector(local_position.x, local_position.y, local_position.z)
		)
		local normal_end = local_position + closest_hit.normal
		local world_normal_end = Vec3(local_to_world:TransformVector(normal_end.x, normal_end.y, normal_end.z))
		closest_hit.normal = (world_normal_end - closest_hit.position):GetNormalized()

		if closest_hit.face_normal then
			local local_face_end = local_position + closest_hit.face_normal
			local world_face_end = Vec3(
				local_to_world:TransformVector(local_face_end.x, local_face_end.y, local_face_end.z)
			)
			closest_hit.face_normal = (world_face_end - closest_hit.position):GetNormalized()
		end

		closest_hit.distance = (closest_hit.position - ray.origin):GetLength()
		closest_hit.entity = entity
	end

	if closest_hit and closest_hit.normal and closest_hit.normal:Dot(ray.direction) > 0 then
		closest_hit.normal = closest_hit.normal * -1
	end

	if
		closest_hit and
		closest_hit.face_normal and
		closest_hit.face_normal:Dot(ray.direction) > 0
	then
		closest_hit.face_normal = closest_hit.face_normal * -1
	end

	return closest_hit
end

local function test_primitive(ray, local_ray, primitive, primitive_idx, entity, local_to_world)
	return test_primitive_with_limit(ray, local_ray, primitive, primitive_idx, entity, local_to_world, math.huge)
end

local function visit_primitive_bvh_leaf_closest(node, context, best_hit, best_distance)
	for i = node.first, node.last do
		local item = context.acceleration.primitives[i]
		local hit = test_primitive_with_limit(
			context.ray,
			context.local_ray,
			item.primitive,
			item.primitive_idx,
			context.entity,
			context.local_to_world,
			best_distance
		)

		if hit and hit.distance < best_distance then
			best_hit = hit
			best_distance = hit.distance
		end
	end

	return best_hit, best_distance
end

local function visit_primitive_bvh_leaf_collect(node, context, best_hit, best_distance)
	for i = node.first, node.last do
		local item = context.acceleration.primitives[i]
		local hit = test_primitive(
			context.ray,
			context.local_ray,
			item.primitive,
			item.primitive_idx,
			context.entity,
			context.local_to_world
		)

		if hit then context.hits[#context.hits + 1] = hit end
	end

	return best_hit, best_distance
end

local function test_model_closest(
	ray,
	model,
	filter_fn,
	a,
	b,
	c,
	d,
	e,
	f,
	closest_distance,
	skip_model_aabb
)
	if filter_fn and not filter_fn(model.Owner, a, b, c, d, e, f) then return nil end

	if not model.Visible or #model.Primitives == 0 then return nil end

	local world_to_local, local_to_world = get_model_transforms(model)
	local local_ray = transform_ray(ray, world_to_local)

	if not skip_model_aabb and model.AABB then
		local aabb_hit, model_tmin = BVH.RayAABBIntersection(local_ray, model.AABB)

		if not aabb_hit or model_tmin > closest_distance then return nil end
	end

	local closest_hit = nil
	local primitive_acceleration = get_model_primitive_acceleration(model)

	if primitive_acceleration and primitive_acceleration.tree then
		local traversal_context = primitive_acceleration.tree.traversal_context
		traversal_context.acceleration = primitive_acceleration.tree
		traversal_context.ray = ray
		traversal_context.local_ray = local_ray
		traversal_context.entity = model.Owner
		traversal_context.local_to_world = local_to_world
		closest_hit, closest_distance = BVH.TraverseRay(
			local_ray,
			primitive_acceleration.tree.root,
			visit_primitive_bvh_leaf_closest,
			traversal_context,
			nil,
			closest_distance
		)

		for _, primitive_idx in ipairs(primitive_acceleration.uncached_indices or {}) do
			local primitive = model.Primitives[primitive_idx]
			local hit = test_primitive_with_limit(
				ray,
				local_ray,
				primitive,
				primitive_idx,
				model.Owner,
				local_to_world,
				closest_distance
			)

			if hit and (not closest_hit or hit.distance < closest_hit.distance) then
				closest_hit = hit
				closest_distance = hit.distance
			end
		end

		return closest_hit
	end

	for prim_idx, primitive in ipairs(model.Primitives) do
		local hit = test_primitive_with_limit(
			ray,
			local_ray,
			primitive,
			prim_idx,
			model.Owner,
			local_to_world,
			closest_distance
		)

		if hit and (not closest_hit or hit.distance < closest_hit.distance) then
			closest_hit = hit
			closest_distance = hit.distance
		end
	end

	return closest_hit
end

local function collect_model_hits(ray, model, filter_fn, a, b, c, d, e, f, hits, skip_model_aabb)
	if filter_fn and not filter_fn(model.Owner, a, b, c, d, e, f) then return end

	if not model.Visible or #model.Primitives == 0 then return end

	local world_to_local, local_to_world = get_model_transforms(model)
	local local_ray = transform_ray(ray, world_to_local)

	if not skip_model_aabb and model.AABB then
		local aabb_hit = BVH.RayAABBIntersection(local_ray, model.AABB)

		if not aabb_hit then return end
	end

	local primitive_acceleration = get_model_primitive_acceleration(model)

	if primitive_acceleration and primitive_acceleration.tree then
		local traversal_context = primitive_acceleration.tree.traversal_context
		traversal_context.acceleration = primitive_acceleration.tree
		traversal_context.ray = ray
		traversal_context.local_ray = local_ray
		traversal_context.entity = model.Owner
		traversal_context.local_to_world = local_to_world
		traversal_context.hits = hits
		BVH.TraverseRay(
			local_ray,
			primitive_acceleration.tree.root,
			visit_primitive_bvh_leaf_collect,
			traversal_context,
			nil,
			math.huge
		)

		for _, primitive_idx in ipairs(primitive_acceleration.uncached_indices or {}) do
			local primitive = model.Primitives[primitive_idx]
			local hit = test_primitive(ray, local_ray, primitive, primitive_idx, model.Owner, local_to_world)

			if hit then hits[#hits + 1] = hit end
		end

		return
	end

	for prim_idx, primitive in ipairs(model.Primitives) do
		local hit = test_primitive(ray, local_ray, primitive, prim_idx, model.Owner, local_to_world)

		if hit then hits[#hits + 1] = hit end
	end
end

local function visit_model_bvh_leaf_closest(node, context, best_hit, best_distance)
	for i = node.first, node.last do
		local item = context.acceleration.models[i]
		local hit = test_model_closest(
			context.ray,
			item.model,
			context.filter_fn,
			context.a,
			context.b,
			context.c,
			context.d,
			context.e,
			context.f,
			best_distance,
			true
		)

		if hit and hit.distance < best_distance then
			best_hit = hit
			best_distance = hit.distance
		end
	end

	return best_hit, best_distance
end

local function visit_model_bvh_leaf_collect(node, context, best_hit, best_distance)
	for i = node.first, node.last do
		local item = context.acceleration.models[i]
		collect_model_hits(
			context.ray,
			item.model,
			context.filter_fn,
			context.a,
			context.b,
			context.c,
			context.d,
			context.e,
			context.f,
			context.hits,
			true
		)
	end

	return best_hit, best_distance
end

local find_closest_hit_in_source

local function find_closest_hit(ray, filter_fn, a, b, c, d, e, f)
	local acceleration = ensure_model_acceleration()
	return find_closest_hit_in_source(acceleration, ray, filter_fn, a, b, c, d, e, f)
end

find_closest_hit_in_source = function(source, ray, filter_fn, a, b, c, d, e, f)
	if not source then return nil end

	local closest_hit = nil
	local closest_distance = ray.max_distance or math.huge

	if source.tree then
		local traversal_context = source.tree.traversal_context
		traversal_context.acceleration = source.tree
		traversal_context.ray = ray
		traversal_context.filter_fn = filter_fn
		traversal_context.a = a
		traversal_context.b = b
		traversal_context.c = c
		traversal_context.d = d
		traversal_context.e = e
		traversal_context.f = f
		closest_hit, closest_distance = BVH.TraverseRay(
			ray,
			source.tree.root,
			visit_model_bvh_leaf_closest,
			traversal_context,
			nil,
			closest_distance
		)
	end

	for _, model in ipairs(source.dynamic_models or {}) do
		local hit = test_model_closest(ray, model, filter_fn, a, b, c, d, e, f, closest_distance, false)

		if hit and hit.distance < closest_distance then
			closest_hit = hit
			closest_distance = hit.distance
		end
	end

	return closest_hit
end

local function distance_sort(a, b)
	return a.distance < b.distance
end

local function collect_hits_in_source(source, ray, filter_fn, a, b, c, d, e, f)
	local hits = {}

	if not source then return hits end

	if source.tree then
		local traversal_context = source.tree.traversal_context
		traversal_context.acceleration = source.tree
		traversal_context.ray = ray
		traversal_context.filter_fn = filter_fn
		traversal_context.a = a
		traversal_context.b = b
		traversal_context.c = c
		traversal_context.d = d
		traversal_context.e = e
		traversal_context.f = f
		traversal_context.hits = hits
		BVH.TraverseRay(
			ray,
			source.tree.root,
			visit_model_bvh_leaf_collect,
			traversal_context,
			nil,
			math.huge
		)
	end

	for _, model in ipairs(source.dynamic_models or {}) do
		collect_model_hits(ray, model, filter_fn, a, b, c, d, e, f, hits, false)
	end

	table.sort(hits, distance_sort)
	return hits
end

function raycast.Cast(origin, direction, max_distance, filter_fn, a, b, c, d, e, f)
	max_distance = max_distance or math.huge
	local ray = create_ray(origin, direction, max_distance)
	local acceleration = ensure_model_acceleration()
	return collect_hits_in_source(acceleration, ray, filter_fn, a, b, c, d, e, f)
end

function raycast.CastClosest(origin, direction, max_distance, filter_fn, a, b, c, d, e, f)
	max_distance = max_distance or math.huge
	local ray = create_ray(origin, direction, max_distance)
	return find_closest_hit(ray, filter_fn, a, b, c, d, e, f)
end

function raycast.CreateModelSource(models)
	return build_static_model_source(models)
end

function raycast.CastFromSource(source, origin, direction, max_distance, filter_fn, a, b, c, d, e, f)
	max_distance = max_distance or math.huge
	local ray = create_ray(origin, direction, max_distance)
	return collect_hits_in_source(source, ray, filter_fn, a, b, c, d, e, f)
end

function raycast.CastClosestFromSource(source, origin, direction, max_distance, filter_fn, a, b, c, d, e, f)
	max_distance = max_distance or math.huge
	local ray = create_ray(origin, direction, max_distance)
	return find_closest_hit_in_source(source, ray, filter_fn, a, b, c, d, e, f)
end

return raycast