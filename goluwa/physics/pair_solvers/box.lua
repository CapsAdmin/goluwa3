local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local solver = import("goluwa/physics/solver.lua")
local shape_accessors = import("goluwa/physics/shape_accessors.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_face_clipping = import("goluwa/physics/convex_face_clipping.lua")
local convex_sat = import("goluwa/physics/convex_sat.lua")
local polyhedron_solver = import("goluwa/physics/pair_solvers/polyhedron.lua")
local box = {}

local FACE_AXIS_RELATIVE_TOLERANCE = 1.05
local FACE_AXIS_ABSOLUTE_TOLERANCE = 0.03
local FACE_CONTACT_SEPARATION_TOLERANCE = 0.08
local BOX_FACE_CONTACT_SCRATCH = {}
local BOX_SUPPORT_CONTACT_SCRATCH = {}
local BOX_CONTACT_OUTPUT_SCRATCH = {
	face_contacts = {},
	edge_contacts = {
		{},
	},
}
local BOX_SUPPORT_REDUCTION_SCRATCH = {
	localized = {},
	reduced = {},
	averaged = {
		{},
	},
}

local function get_component(vec, axis_index)
	if axis_index == 1 then return vec.x end

	if axis_index == 2 then return vec.y end

	return vec.z
end

local function set_component(vec, axis_index, value)
	if axis_index == 1 then return Vec3(value, vec.y, vec.z) end

	if axis_index == 2 then return Vec3(vec.x, value, vec.z) end

	return Vec3(vec.x, vec.y, value)
end

local function get_other_axis_indices(axis_index)
	if axis_index == 1 then return 2, 3 end

	if axis_index == 2 then return 1, 3 end

	return 1, 2
end

local function add_box_contact_point(contacts, point_a, point_b)
	return convex_manifold.AddContactPoint(contacts, point_a, point_b, 0.12)
end

local function fill_cached_box_faces(polyhedron, world_vertices, out)
	out = out or {}

	for face_index, face in ipairs(polyhedron.faces or {}) do
		local cached_face = out[face_index] or {points = {}}
		local points = cached_face.points

		for i, vertex_index in ipairs(face.indices or {}) do
			points[i] = world_vertices[vertex_index]
		end

		for i = #(face.indices or {}) + 1, #points do
			points[i] = nil
		end

		out[face_index] = cached_face
	end

	for i = #(polyhedron.faces or {}) + 1, #out do
		out[i] = nil
	end

	return out
end

local function get_cached_box_faces(body)
	local shape = body:GetPhysicsShape()
	local polyhedron = shape.GetPolyhedron and shape:GetPolyhedron()

	if not polyhedron then return nil end

	local position = body:GetPosition()
	local rotation = body:GetRotation()
	local cache = body._PhysicsBoxFaceCache or {}
	body._PhysicsBoxFaceCache = cache

	if
		cache.polyhedron == polyhedron and
		cache.px == position.x and
		cache.py == position.y and
		cache.pz == position.z and
		cache.rx == rotation.x and
		cache.ry == rotation.y and
		cache.rz == rotation.z and
		cache.rw == rotation.w
	then
		return cache.faces
	end

	cache.polyhedron = polyhedron
	cache.px = position.x
	cache.py = position.y
	cache.pz = position.z
	cache.rx = rotation.x
	cache.ry = rotation.y
	cache.rz = rotation.z
	cache.rw = rotation.w
	cache.faces = fill_cached_box_faces(
		polyhedron,
		polyhedron_solver.GetPolyhedronWorldVertices(body, polyhedron),
		cache.faces
	)
	return cache.faces
end

local function get_box_face(body, desired_normal)
	local shape = body:GetPhysicsShape()
	local extents = shape:GetExtents()
	local axes = shape:GetAxes(body)
	local axis_index = 1
	local alignment = -math.huge

	for i = 1, 3 do
		local dot = axes[i]:Dot(desired_normal)
		local abs_dot = math.abs(dot)

		if abs_dot > alignment then
			alignment = abs_dot
			axis_index = i
		end
	end

	local axis = axes[axis_index]
	local sign = axis:Dot(desired_normal) >= 0 and 1 or -1
	local tangent_u_index, tangent_v_index = get_other_axis_indices(axis_index)
	local face_index = (axis_index - 1) * 2 + (sign > 0 and 1 or 2)
	local cached_faces = get_cached_box_faces(body)
	local world_points = cached_faces and cached_faces[face_index] and cached_faces[face_index].points

	if not world_points then
		local ex, ey, ez = extents.x, extents.y, extents.z

		if axis_index == 1 then
			world_points = {
				body:LocalToWorld(Vec3(sign * ex, -ey, -ez)),
				body:LocalToWorld(Vec3(sign * ex, ey, -ez)),
				body:LocalToWorld(Vec3(sign * ex, ey, ez)),
				body:LocalToWorld(Vec3(sign * ex, -ey, ez)),
			}
		elseif axis_index == 2 then
			world_points = {
				body:LocalToWorld(Vec3(-ex, sign * ey, -ez)),
				body:LocalToWorld(Vec3(ex, sign * ey, -ez)),
				body:LocalToWorld(Vec3(ex, sign * ey, ez)),
				body:LocalToWorld(Vec3(-ex, sign * ey, ez)),
			}
		else
			world_points = {
				body:LocalToWorld(Vec3(-ex, -ey, sign * ez)),
				body:LocalToWorld(Vec3(ex, -ey, sign * ez)),
				body:LocalToWorld(Vec3(ex, ey, sign * ez)),
				body:LocalToWorld(Vec3(-ex, ey, sign * ez)),
			}
		end
	end

	return {
		face_index = face_index,
		axis_index = axis_index,
		sign = sign,
		alignment = alignment,
		normal = axis * sign,
		tangent_u = axes[tangent_u_index],
		tangent_v = axes[tangent_v_index],
		plane = sign * get_component(extents, axis_index),
		tangent_u_index = tangent_u_index,
		tangent_v_index = tangent_v_index,
		tangent_u_extent = get_component(extents, tangent_u_index),
		tangent_v_extent = get_component(extents, tangent_v_index),
		center = world_points[1] and
			world_points[3] and
			(
				world_points[1] + world_points[3]
			) * 0.5 or
			body:GetPosition(),
		points = world_points,
	}
end

local function get_body_world_vertices(body)
	local polyhedron = shape_accessors.GetBodyPolyhedron(body)

	if not polyhedron then return {} end

	return polyhedron_solver.GetPolyhedronWorldVertices(body, polyhedron)
end

local function build_support_pair_contacts(body_a, body_b, normal)
	local vertices_a = get_body_world_vertices(body_a)
	local vertices_b = get_body_world_vertices(body_b)
	return convex_manifold.BuildSupportPairContacts(
		vertices_a,
		vertices_b,
		normal,
		{
			merge_distance = 0.12,
			max_contacts = 4,
			scratch = BOX_SUPPORT_CONTACT_SCRATCH,
		}
	)
end

local function project_box_radius(extents, axes, normal)
	return extents.x * math.abs(normal:Dot(axes[1])) + extents.y * math.abs(normal:Dot(axes[2])) + extents.z * math.abs(normal:Dot(axes[3]))
end

local function test_obb_axis(axis, delta, extents_a, axes_a, extents_b, axes_b, best, candidate)
	local axis_length = axis:GetLength()

	if axis_length <= physics.EPSILON then return true end

	local normal = axis / axis_length
	local distance = delta:Dot(normal)
	local abs_distance = math.abs(distance)
	local radius_a = project_box_radius(extents_a, axes_a, normal)
	local radius_b = project_box_radius(extents_b, axes_b, normal)
	local overlap = radius_a + radius_b - abs_distance

	if overlap <= 0 then return false end

	local resolved_candidate = {
		overlap = overlap,
		normal = convex_sat.OrientAxisNormal(normal, distance),
		kind = candidate.kind,
		reference_body = candidate.reference_body,
		axis_index = candidate.axis_index,
		edge_axis_a = candidate.edge_axis_a,
		edge_axis_b = candidate.edge_axis_b,
	}
	convex_sat.UpdateBestAxis(best, resolved_candidate)
	return true
end

local function choose_best_axis(best)
	return convex_sat.ChoosePreferredAxis(best, FACE_AXIS_RELATIVE_TOLERANCE, FACE_AXIS_ABSOLUTE_TOLERANCE)
end

local function is_outside_static_support_face(body_a, body_b, normal)
	local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

	if not static_body then return false end

	local support_normal = static_body == body_a and normal or -normal
	local support_face = get_box_face(static_body, support_normal)
	local local_center = static_body:WorldToLocal(dynamic_body:GetPosition())
	local margin = 0.02
	local center_u = get_component(local_center, support_face.tangent_u_index)
	local center_v = get_component(local_center, support_face.tangent_v_index)
	return math.abs(center_u) > support_face.tangent_u_extent + margin or
		math.abs(center_v) > support_face.tangent_v_extent + margin
end

local function get_support_edge(body, edge_axis_index, support_direction)
	local extents = body:GetPhysicsShape():GetExtents()
	local axes = body:GetPhysicsShape():GetAxes(body)
	local local_start = Vec3(0, 0, 0)
	local local_end = Vec3(0, 0, 0)

	for axis_index = 1, 3 do
		local extent = get_component(extents, axis_index)

		if axis_index == edge_axis_index then
			local_start = set_component(local_start, axis_index, -extent)
			local_end = set_component(local_end, axis_index, extent)
		else
			local_start = set_component(
				local_start,
				axis_index,
				axes[axis_index]:Dot(support_direction) >= 0 and extent or -extent
			)
			local_end = set_component(local_end, axis_index, get_component(local_start, axis_index))
		end
	end

	return body:LocalToWorld(local_start), body:LocalToWorld(local_end)
end

local function build_face_contacts(body_a, body_b, candidate)
	local reference_is_a = candidate.reference_body == "a"
	local reference_body = reference_is_a and body_a or body_b
	local incident_body = reference_is_a and body_b or body_a
	local reference_normal = reference_is_a and candidate.normal or -candidate.normal
	local reference_face = get_box_face(reference_body, reference_normal)
	local incident_face = get_box_face(incident_body, -reference_normal)
	local clipped = convex_face_clipping.ClipFacePolygonToReference(
		reference_body,
		reference_face,
		incident_face.points,
		BOX_FACE_CONTACT_SCRATCH
	)
	local ranked_contacts = BOX_FACE_CONTACT_SCRATCH.ranked_contacts or {}
	BOX_FACE_CONTACT_SCRATCH.ranked_contacts = ranked_contacts
	local ranked_count = 0

	for _, local_point in ipairs(clipped) do
		local separation = reference_face.sign * (
				get_component(local_point, reference_face.axis_index) - reference_face.plane
			)

		if separation <= FACE_CONTACT_SEPARATION_TOLERANCE then
			local reference_point = set_component(local_point, reference_face.axis_index, reference_face.plane)
			ranked_count = ranked_count + 1
			local entry = ranked_contacts[ranked_count] or {}
			entry.separation = separation
			entry.local_point = local_point
			entry.point_reference = reference_body:LocalToWorld(reference_point)
			entry.point_incident = reference_body:LocalToWorld(local_point)
			ranked_contacts[ranked_count] = entry
		end
	end

	for i = ranked_count + 1, #ranked_contacts do
		ranked_contacts[i] = nil
	end

	ranked_contacts = convex_face_clipping.SelectFaceContactEntries(ranked_contacts, reference_face, 4, BOX_FACE_CONTACT_SCRATCH)
	local contacts = BOX_CONTACT_OUTPUT_SCRATCH.face_contacts
	local contact_count = 0

	for _, entry in ipairs(ranked_contacts) do
		if reference_is_a then
			contact_count = convex_manifold.AddContactPointReused(
				contacts,
				contact_count,
				entry.point_reference,
				entry.point_incident,
				0.12
			)
		else
			contact_count = convex_manifold.AddContactPointReused(
				contacts,
				contact_count,
				entry.point_incident,
				entry.point_reference,
				0.12
			)
		end

		if contact_count >= 4 then break end
	end

	return convex_manifold.TrimContacts(contacts, contact_count)
end

local function build_edge_contacts(body_a, body_b, candidate)
	local edge_start_a, edge_end_a = get_support_edge(body_a, candidate.edge_axis_a, candidate.normal)
	local edge_start_b, edge_end_b = get_support_edge(body_b, candidate.edge_axis_b, -candidate.normal)
	local point_a, point_b = convex_manifold.ClosestPointsOnSegments(edge_start_a, edge_end_a, edge_start_b, edge_end_b)
	return convex_manifold.BuildSingleContact(BOX_CONTACT_OUTPUT_SCRATCH.edge_contacts, point_a, point_b)
end

local function reduce_contacts_for_support_polygon(body_a, body_b, normal, contacts)
	local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

	if not static_body or #contacts < 3 then return contacts, false end

	local support_is_a = static_body == body_a
	local support_face = get_box_face(static_body, support_is_a and normal or -normal)
	local dynamic_center_local = static_body:WorldToLocal(dynamic_body:GetPosition())
	local tolerance = 0.04
	local min_u = math.huge
	local max_u = -math.huge
	local min_v = math.huge
	local max_v = -math.huge
	local localized = BOX_SUPPORT_REDUCTION_SCRATCH.localized
	local localized_count = 0

	for index, contact in ipairs(contacts) do
		local support_point = support_is_a and contact.point_a or contact.point_b
		local local_point = static_body:WorldToLocal(support_point)
		localized_count = index
		local entry = localized[index] or {}
		entry.contact = contact
		entry.local_point = local_point
		entry.u = get_component(local_point, support_face.tangent_u_index)
		entry.v = get_component(local_point, support_face.tangent_v_index)
		localized[index] = entry
		min_u = math.min(min_u, entry.u)
		max_u = math.max(max_u, entry.u)
		min_v = math.min(min_v, entry.v)
		max_v = math.max(max_v, entry.v)
	end

	for i = localized_count + 1, #localized do
		localized[i] = nil
	end

	local target_u = nil
	local target_v = nil
	local center_u = get_component(dynamic_center_local, support_face.tangent_u_index)
	local center_v = get_component(dynamic_center_local, support_face.tangent_v_index)

	if center_u < min_u - tolerance then
		target_u = min_u
	elseif center_u > max_u + tolerance then
		target_u = max_u
	end

	if center_v < min_v - tolerance then
		target_v = min_v
	elseif center_v > max_v + tolerance then
		target_v = max_v
	end

	if not target_u and not target_v then return contacts, false end

	local reduced = BOX_SUPPORT_REDUCTION_SCRATCH.reduced
	local reduced_count = 0

	for _, entry in ipairs(localized) do
		local keep = true

		if target_u then keep = keep and math.abs(entry.u - target_u) <= tolerance end

		if target_v then keep = keep and math.abs(entry.v - target_v) <= tolerance end

		if keep then
			reduced_count = reduced_count + 1
			reduced[reduced_count] = entry.contact
		end
	end

	for i = reduced_count + 1, #reduced do
		reduced[i] = nil
	end

	if reduced[1] then
		if reduced_count > 1 and (target_u == nil) ~= (target_v == nil) then
			local average_a = Vec3(0, 0, 0)
			local average_b = Vec3(0, 0, 0)

			for _, contact in ipairs(reduced) do
				average_a = average_a + contact.point_a
				average_b = average_b + contact.point_b
			end

			local averaged = BOX_SUPPORT_REDUCTION_SCRATCH.averaged
			return convex_manifold.BuildSingleContact(averaged, average_a / reduced_count, average_b / reduced_count),
			true
		end

		return reduced, true
	end

	return contacts, false
end

local function solve_swept_box_box_collision(dynamic_body, static_body, dt)
	if
		not pair_solver_helpers.IsSolverImmovable(static_body) or
		not pair_solver_helpers.HasSolverMass(dynamic_body)
	then
		return false
	end

	local sweep = pair_solver_helpers.GetBodySweepMotion(dynamic_body)
	local previous_position = sweep.previous_position
	local current_position = sweep.current_position
	local movement = sweep.movement

	if movement:GetLength() <= physics.EPSILON then return false end

	local earliest_hit = pair_solver_helpers.FindEarliestBodyPointSweepHit(
		dynamic_body,
		previous_position,
		sweep.previous_rotation,
		current_position,
		sweep.current_rotation,
		dynamic_body:GetCollisionLocalPoints(),
		function(start_world, end_world)
			return pair_solver_helpers.SweepPointAgainstBox(static_body, start_world, end_world)
		end
	)

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(static_body, dynamic_body, previous_position, movement, earliest_hit, dt)
end

local function solve_box_pair_collision(body_a, body_b, dt)
	if
		shape_accessors.BodyHasSignificantRotation(body_a) or
		shape_accessors.BodyHasSignificantRotation(body_b)
	then
		local temporal = polyhedron_solver.SolveTemporalPolyhedronPairCollision(
			body_a,
			body_b,
			shape_accessors.GetBodyPolyhedron(body_a),
			shape_accessors.GetBodyPolyhedron(body_b),
			dt
		)

		if temporal then return true end
	end

	local center_a = body_a:GetPosition()
	local center_b = body_b:GetPosition()
	local delta = center_b - center_a
	local extents_a = body_a:GetPhysicsShape():GetExtents()
	local extents_b = body_b:GetPhysicsShape():GetExtents()
	local axes_a = body_a:GetPhysicsShape():GetAxes(body_a)
	local axes_b = body_b:GetPhysicsShape():GetAxes(body_b)
	local best = convex_sat.CreateBestAxisTracker()

	for i = 1, 3 do
		if
			not test_obb_axis(
				axes_a[i],
				delta,
				extents_a,
				axes_a,
				extents_b,
				axes_b,
				best,
				{kind = "face", reference_body = "a", axis_index = i}
			)
		then
			local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

			if static_body then
				return solve_swept_box_box_collision(dynamic_body, static_body, dt)
			end

			return
		end

		if
			not test_obb_axis(
				axes_b[i],
				delta,
				extents_a,
				axes_a,
				extents_b,
				axes_b,
				best,
				{kind = "face", reference_body = "b", axis_index = i}
			)
		then
			local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

			if static_body then
				return solve_swept_box_box_collision(dynamic_body, static_body, dt)
			end

			return
		end
	end

	for i = 1, 3 do
		for j = 1, 3 do
			if
				not test_obb_axis(
					axes_a[i]:GetCross(axes_b[j]),
					delta,
					extents_a,
					axes_a,
					extents_b,
					axes_b,
					best,
					{kind = "edge", edge_axis_a = i, edge_axis_b = j}
				)
			then
				local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

				if static_body then
					return solve_swept_box_box_collision(dynamic_body, static_body, dt)
				end

				return
			end
		end
	end

	local raw_best = best.any
	best = choose_best_axis(best)

	if
		raw_best and
		raw_best.kind == "edge" and
		best and
		best.kind == "face" and
		is_outside_static_support_face(body_a, body_b, best.normal)
	then
		best = raw_best
	end

	if not best.normal or best.overlap == math.huge then return end

	local contacts
	local resolve_options
	local is_overhang_edge = best.kind == "edge" and
		is_outside_static_support_face(body_a, body_b, best.normal)

	if best.kind == "face" then
		contacts = build_face_contacts(body_a, body_b, best)
		local reduced_for_support
		contacts, reduced_for_support = reduce_contacts_for_support_polygon(body_a, body_b, best.normal, contacts)

		if reduced_for_support and raw_best and raw_best.kind == "edge" then
			local edge_contacts = build_edge_contacts(body_a, body_b, raw_best)

			if edge_contacts and edge_contacts[1] then
				best = raw_best
				contacts = edge_contacts
				resolve_options = {skip_grounding = true}
			end
		end
	else
		contacts = build_edge_contacts(body_a, body_b, best)

		if is_overhang_edge then
			resolve_options = {
				skip_grounding = true,
				skip_friction = true,
			}
		end
	end

	if not contacts or not contacts[1] then
		contacts = build_support_pair_contacts(body_a, body_b, best.normal)
	end

	if contacts and contacts[1] then
		if resolve_options and resolve_options.skip_grounding and #contacts == 1 then
			return contact_resolution.ResolvePairPenetration(
				body_a,
				body_b,
				best.normal,
				best.overlap,
				dt,
				contacts[1].point_a,
				contacts[1].point_b,
				nil,
				resolve_options
			)
		end

		return contact_resolution.ResolvePairPenetration(
			body_a,
			body_b,
			best.normal,
			best.overlap,
			dt,
			nil,
			nil,
			contacts,
			resolve_options
		)
	end

	return contact_resolution.ResolvePairPenetration(body_a, body_b, best.normal, best.overlap, dt)
end

solver:RegisterPairHandler("box", "box", function(body_a, body_b, _, _, dt)
	return solve_box_pair_collision(body_a, body_b, dt)
end)

return box