local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local raycast = import("goluwa/physics/raycast.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local RigidBodyComponent = import("goluwa/ecs/components/3d/rigid_body.lua")
local TRIANGLE_FEATURE_EPSILON = 0.0001
local TRIANGLE_SEAM_DISTANCE_EPSILON = 0.0001
local TRIANGLE_SEAM_NORMAL_DOT = 0.5

local function filter(entity, ignore_entity, filter_fn, ignore_kinematic, ignore_rigid)
	if entity == ignore_entity then return false end

	if entity.PhysicsNoCollision or entity.NoPhysicsCollision then return false end

	if
		ignore_kinematic and
		entity.rigid_body and
		entity.rigid_body.IsKinematic and
		entity.rigid_body:IsKinematic()
	then
		return false
	end

	if ignore_rigid and entity.rigid_body then return false end

	if filter_fn and not filter_fn(entity) then return false end

	return true
end

local function cast_with_filter(
	origin,
	direction,
	max_distance,
	ignore_entity,
	filter_fn,
	options,
	ignore_rigid_override
)
	local cast_options = options or {}
	local ignore_kinematic = cast_options.IgnoreKinematicBodies ~= false
	local ignore_rigid = cast_options.IgnoreRigidBodies ~= false
	local world_source = cast_options.WorldSource

	if ignore_rigid_override ~= nil then ignore_rigid = ignore_rigid_override end

	if world_source == nil and physics.GetWorldTraceSource then
		world_source = physics.GetWorldTraceSource()
	end

	local use_render_meshes = cast_options.UseRenderMeshes

	if use_render_meshes == nil then use_render_meshes = world_source == nil end

	if cast_options.ClosestOnly ~= false then
		if world_source then
			local hit = raycast.CastClosestFromSource(
				world_source,
				origin,
				direction,
				max_distance or math.huge,
				filter,
				ignore_entity,
				filter_fn,
				ignore_kinematic,
				ignore_rigid
			)
			return hit and {hit} or {}
		end

		if not use_render_meshes then return {} end

		local hit = raycast.CastClosest(
			origin,
			direction,
			max_distance or math.huge,
			filter,
			ignore_entity,
			filter_fn,
			ignore_kinematic,
			ignore_rigid
		)
		return hit and {hit} or {}
	end

	if world_source then
		return raycast.CastFromSource(
			world_source,
			origin,
			direction,
			max_distance or math.huge,
			filter,
			ignore_entity,
			filter_fn,
			ignore_kinematic,
			ignore_rigid
		)
	end

	if not use_render_meshes then return {} end

	local hits = raycast.Cast(
		origin,
		direction,
		max_distance or math.huge,
		filter,
		ignore_entity,
		filter_fn,
		ignore_kinematic,
		ignore_rigid
	)
	return hits
end

local function is_straight_down(direction)
	return direction and
		math.abs(direction.x) <= 0.00001 and
		direction.y < -0.00001 and
		math.abs(direction.z) <= 0.00001
end

local function pick_best_world_hit(hits, direction)
	if not (hits and hits[1]) then return nil end

	if is_straight_down(direction) then
		for _, hit in ipairs(hits) do
			if hit.normal and hit.normal.y >= 0 then return hit end
		end
	end

	return hits[1]
end

function physics.Trace(origin, direction, max_distance, ignore_entity, filter_fn, options)
	options = options or {}
	local allow_rigid = options.IgnoreRigidBodies == false
	local downward_trace = is_straight_down(direction)
	local hits = cast_with_filter(
		origin,
		direction,
		max_distance,
		ignore_entity,
		filter_fn,
		options,
		allow_rigid and true or nil
	)
	local best_hit = pick_best_world_hit(hits, direction)

	if allow_rigid then
		local trace_radius = options.TraceRadius or 0

		for _, body in ipairs(RigidBodyComponent.Instances or {}) do
			if not (physics.IsActiveRigidBody(body) and body.Owner ~= ignore_entity) then
				goto continue
			end

			if body.Owner and (body.Owner.PhysicsNoCollision or body.Owner.NoPhysicsCollision) then
				goto continue
			end

			if
				options.IgnoreKinematicBodies ~= false and
				body.IsKinematic and
				body:IsKinematic()
			then
				goto continue
			end

			if filter_fn and not filter_fn(body.Owner) then goto continue end

			for _, collider in ipairs(body.GetColliders and body:GetColliders() or {}) do
				local hit = collider:GetPhysicsShape():TraceAgainstBody(collider, origin, direction, max_distance, trace_radius)

				if hit and (not best_hit or hit.distance < best_hit.distance) then
					best_hit = hit
				end
			end

			::continue::
		end
	end

	return best_hit
end

local function get_hit_triangle_indices(poly, triangle_index)
	if not (poly and poly.Vertices and triangle_index ~= nil) then return nil end

	local base = triangle_index * 3
	local indices = poly.indices

	if indices then
		return indices[base + 1] + 1, indices[base + 2] + 1, indices[base + 3] + 1
	end

	return base + 1, base + 2, base + 3
end

local function get_triangle_world_vertices(poly, triangle_index, entity)
	if not (poly and poly.Vertices) then return nil end

	local i0, i1, i2 = get_hit_triangle_indices(poly, triangle_index)

	if not (i0 and i1 and i2) then return nil end

	local vertices = poly.Vertices
	local v0 = vertices[i0] and vertices[i0].pos
	local v1 = vertices[i1] and vertices[i1].pos
	local v2 = vertices[i2] and vertices[i2].pos

	if not (v0 and v1 and v2) then return nil end

	if entity and entity.transform then
		local world = entity.transform:GetWorldMatrix()
		v0 = Vec3(world:TransformVector(v0.x, v0.y, v0.z))
		v1 = Vec3(world:TransformVector(v1.x, v1.y, v1.z))
		v2 = Vec3(world:TransformVector(v2.x, v2.y, v2.z))
	end

	return v0, v1, v2, i0, i1, i2
end

local function get_hit_face_normal(hit)
	if hit and hit.face_normal then return hit.face_normal end

	if
		not (
			hit and
			hit.primitive and
			hit.primitive.polygon3d and
			hit.triangle_index ~= nil
		)
	then
		return hit and hit.normal or nil
	end

	local v0, v1, v2 = get_triangle_world_vertices(hit.primitive.polygon3d, hit.triangle_index, hit.entity)

	if not (v0 and v1 and v2) then return hit.normal end

	return triangle_geometry.GetTriangleNormal(v0, v1, v2)
end

local function get_hit_triangle_world_vertices(hit)
	if
		not (
			hit and
			hit.primitive and
			hit.primitive.polygon3d and
			hit.triangle_index ~= nil
		)
	then
		return nil
	end

	return get_triangle_world_vertices(hit.primitive.polygon3d, hit.triangle_index, hit.entity)
end

local function on_segment(a, b, point)
	local ab = b - a
	local length_squared = ab:Dot(ab)

	if length_squared <= TRIANGLE_FEATURE_EPSILON then return false end

	local t = (point - a):Dot(ab) / length_squared

	if t <= TRIANGLE_FEATURE_EPSILON or t >= 1 - TRIANGLE_FEATURE_EPSILON then
		return false
	end

	local projected = a + ab * t
	return (projected - point):GetLength() <= TRIANGLE_FEATURE_EPSILON
end

local function get_triangle_feature_indices(closest_point, v0, v1, v2, i0, i1, i2)
	if (closest_point - v0):GetLength() <= TRIANGLE_FEATURE_EPSILON then
		return "vertex", {i0}
	end

	if (closest_point - v1):GetLength() <= TRIANGLE_FEATURE_EPSILON then
		return "vertex", {i1}
	end

	if (closest_point - v2):GetLength() <= TRIANGLE_FEATURE_EPSILON then
		return "vertex", {i2}
	end

	if on_segment(v0, v1, closest_point) then return "edge", {i0, i1} end

	if on_segment(v1, v2, closest_point) then return "edge", {i1, i2} end

	if on_segment(v2, v0, closest_point) then return "edge", {i2, i0} end

	return "face", nil
end

local function get_polygon_triangle_count(poly)
	if not (poly and poly.Vertices) then return 0 end

	if poly.indices then return math.floor(#poly.indices / 3) end

	return math.floor(#poly.Vertices / 3)
end

local function triangle_contains_feature(poly, triangle_index, feature_indices)
	if not feature_indices then return false end

	local i0, i1, i2 = get_hit_triangle_indices(poly, triangle_index)

	if not (i0 and i1 and i2) then return false end

	local present = {
		[i0] = true,
		[i1] = true,
		[i2] = true,
	}

	for _, index in ipairs(feature_indices) do
		if not present[index] then return false end
	end

	return true
end

local function get_triangle_feature_positions(v0, v1, v2, i0, i1, i2, feature_indices)
	if not feature_indices then return nil end

	local by_index = {
		[i0] = v0,
		[i1] = v1,
		[i2] = v2,
	}
	local positions = {}

	for _, index in ipairs(feature_indices) do
		local position = by_index[index]

		if not position then return nil end

		positions[#positions + 1] = position
	end

	return positions
end

local function positions_match(a, b)
	return a and b and (a - b):GetLength() <= TRIANGLE_FEATURE_EPSILON
end

local function triangle_contains_feature_positions(v0, v1, v2, feature_positions)
	if not feature_positions then return false end

	local triangle_positions = {v0, v1, v2}

	for _, feature_position in ipairs(feature_positions) do
		local matched = false

		for _, triangle_position in ipairs(triangle_positions) do
			if positions_match(feature_position, triangle_position) then
				matched = true

				break
			end
		end

		if not matched then return false end
	end

	return true
end

local function get_mesh_triangle_feature_contact(hit, reference_point)
	if
		not (
			reference_point and
			hit and
			hit.primitive and
			hit.primitive.polygon3d and
			hit.triangle_index ~= nil
		)
	then
		return nil
	end

	local poly = hit.primitive.polygon3d
	local triangle_count = get_polygon_triangle_count(poly)

	if triangle_count <= 0 then return nil end

	local v0, v1, v2, i0, i1, i2 = get_triangle_world_vertices(poly, hit.triangle_index, hit.entity)

	if not (v0 and v1 and v2 and i0 and i1 and i2) then return nil end

	local primary_face_normal = get_hit_face_normal(hit)
	local primary_closest_point = triangle_geometry.ClosestPointOnTriangle(reference_point, v0, v1, v2)
	local feature_kind, feature_indices = get_triangle_feature_indices(primary_closest_point, v0, v1, v2, i0, i1, i2)
	local feature_positions = get_triangle_feature_positions(v0, v1, v2, i0, i1, i2, feature_indices)
	local best_position = primary_closest_point
	local best_face_normal = primary_face_normal
	local best_distance_squared = (
		reference_point - primary_closest_point
	):Dot(reference_point - primary_closest_point)
	local candidate_normals = {primary_face_normal}

	if feature_kind == "face" or not feature_indices then
		return {
			position = best_position,
			normal = primary_face_normal,
		}
	end

	for triangle_index = 0, triangle_count - 1 do
		if
			triangle_index ~= hit.triangle_index and
			triangle_contains_feature(poly, triangle_index, feature_indices)
		then
			local av0, av1, av2 = get_triangle_world_vertices(poly, triangle_index, hit.entity)

			if av0 and av1 and av2 then
				local candidate_face_normal = (av1 - av0):GetCross(av2 - av0):GetNormalized()

				if
					candidate_face_normal:GetLength() > TRIANGLE_FEATURE_EPSILON and
					primary_face_normal and
					primary_face_normal:Dot(candidate_face_normal) >= TRIANGLE_SEAM_NORMAL_DOT
				then
					local candidate_position = triangle_geometry.ClosestPointOnTriangle(reference_point, av0, av1, av2)
					local delta = reference_point - candidate_position
					local distance_squared = delta:Dot(delta)

					if distance_squared + TRIANGLE_SEAM_DISTANCE_EPSILON < best_distance_squared then
						best_distance_squared = distance_squared
						best_position = candidate_position
						best_face_normal = candidate_face_normal
						candidate_normals = {candidate_face_normal}
					elseif
						math.abs(distance_squared - best_distance_squared) <= TRIANGLE_SEAM_DISTANCE_EPSILON
					then
						candidate_normals[#candidate_normals + 1] = candidate_face_normal
					end
				end
			end
		end
	end

	local model = hit.model

	if model and model.Primitives and feature_positions then
		for primitive_index, primitive in ipairs(model.Primitives) do
			if primitive ~= hit.primitive and primitive and primitive.polygon3d then
				local primitive_triangle_count = get_polygon_triangle_count(primitive.polygon3d)

				for triangle_index = 0, primitive_triangle_count - 1 do
					local av0, av1, av2 = get_triangle_world_vertices(primitive.polygon3d, triangle_index, hit.entity)

					if
						av0 and
						av1 and
						av2 and
						triangle_contains_feature_positions(av0, av1, av2, feature_positions)
					then
						local candidate_face_normal = (av1 - av0):GetCross(av2 - av0):GetNormalized()

						if
							candidate_face_normal:GetLength() > TRIANGLE_FEATURE_EPSILON and
							primary_face_normal and
							primary_face_normal:Dot(candidate_face_normal) >= TRIANGLE_SEAM_NORMAL_DOT
						then
							local candidate_position = triangle_geometry.ClosestPointOnTriangle(reference_point, av0, av1, av2)
							local delta = reference_point - candidate_position
							local distance_squared = delta:Dot(delta)

							if distance_squared + TRIANGLE_SEAM_DISTANCE_EPSILON < best_distance_squared then
								best_distance_squared = distance_squared
								best_position = candidate_position
								best_face_normal = candidate_face_normal
								candidate_normals = {candidate_face_normal}
							elseif
								math.abs(distance_squared - best_distance_squared) <= TRIANGLE_SEAM_DISTANCE_EPSILON
							then
								candidate_normals[#candidate_normals + 1] = candidate_face_normal
							end
						end
					end
				end
			end
		end
	end

	local summed_normal = Vec3(0, 0, 0)

	for _, normal in ipairs(candidate_normals) do
		if normal then summed_normal = summed_normal + normal end
	end

	if summed_normal:GetLength() <= TRIANGLE_FEATURE_EPSILON then
		summed_normal = best_face_normal
	end

	return {
		position = best_position,
		normal = summed_normal:GetNormalized(),
	}
end

local function get_hit_triangle_feature_contact(hit, reference_point)
	if not reference_point then return nil end

	local mesh_contact = get_mesh_triangle_feature_contact(hit, reference_point)

	if mesh_contact then
		local delta = reference_point - mesh_contact.position
		local distance = delta:GetLength()

		if distance > 0.00001 then
			mesh_contact.normal = delta / distance
		elseif mesh_contact.normal:GetLength() <= 0.00001 then
			mesh_contact.normal = get_hit_face_normal(hit)
		end

		return mesh_contact
	end

	local v0, v1, v2 = get_hit_triangle_world_vertices(hit)

	if not (v0 and v1 and v2) then return nil end

	local closest_point = triangle_geometry.ClosestPointOnTriangle(reference_point, v0, v1, v2)
	local delta = reference_point - closest_point
	local distance = delta:GetLength()
	local normal = distance > 0.00001 and (delta / distance) or get_hit_face_normal(hit)

	if not normal then return nil end

	return {
		position = closest_point,
		normal = normal,
	}
end

local function get_hit_brush_feature_normal(hit, reference_point)
	if
		not (
			hit and
			reference_point and
			hit.primitive and
			hit.primitive.brush_planes and
			hit.primitive.brush_planes[1]
		)
	then
		return nil
	end

	local max_signed_distance = -math.huge
	local signed_distances = {}

	for i, plane in ipairs(hit.primitive.brush_planes) do
		local signed_distance = reference_point:Dot(plane.normal) - plane.dist
		signed_distances[i] = signed_distance

		if signed_distance > max_signed_distance then
			max_signed_distance = signed_distance
		end
	end

	local blend_epsilon = 0.05
	local summed = Vec3(0, 0, 0)
	local count = 0

	for i, plane in ipairs(hit.primitive.brush_planes) do
		if signed_distances[i] >= max_signed_distance - blend_epsilon then
			summed = summed + plane.normal
			count = count + 1
		end
	end

	if count == 0 or summed:GetLength() <= 0.00001 then return nil end

	return summed:GetNormalized()
end

function physics.GetHitNormal(hit, reference_point)
	local contact = physics.GetHitSurfaceContact(hit, reference_point)
	local normal = contact and contact.normal or nil

	if not normal then return nil end

	if hit and hit.normal then
		if normal:Dot(hit.normal) < 0 then normal = normal * -1 end
	elseif reference_point and hit and hit.position then
		if (reference_point - hit.position):Dot(normal) < 0 then normal = normal * -1 end
	end

	return normal
end

function physics.GetHitSurfaceContact(hit, reference_point)
	local triangle_contact = get_hit_triangle_feature_contact(hit, reference_point)

	if triangle_contact then
		local normal = triangle_contact.normal

		if hit and hit.normal then
			if normal:Dot(hit.normal) < 0 then normal = normal * -1 end
		elseif reference_point and triangle_contact.position then
			if (reference_point - triangle_contact.position):Dot(normal) < 0 then
				normal = normal * -1
			end
		end

		triangle_contact.normal = normal
		return triangle_contact
	end

	local normal = get_hit_brush_feature_normal(hit, reference_point) or get_hit_face_normal(hit)

	if not (hit and normal) then return nil end

	if hit and hit.normal then
		if normal:Dot(hit.normal) < 0 then normal = normal * -1 end
	elseif reference_point and hit and hit.position then
		if (reference_point - hit.position):Dot(normal) < 0 then normal = normal * -1 end
	end

	return {
		position = hit.position,
		normal = normal,
	}
end

return physics