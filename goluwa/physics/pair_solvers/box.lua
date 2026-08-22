local Vec3 = import("goluwa/structs/vec3.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_face_clipping = import("goluwa/physics/convex_face_clipping.lua")
local convex_sat = import("goluwa/physics/convex_sat.lua")
local polyhedron_solver = import("goluwa/physics/pair_solvers/polyhedron.lua")
local stats = import("goluwa/physics/stats.lua")
local box = {}
local EPSILON = physics_constants.EPSILON
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
local SAT_DELTA = Vec3(0, 0, 0)
local SAT_CROSS = Vec3(0, 0, 0)
local BOX_FACE_SLOT_A = {}
local BOX_FACE_SLOT_B = {}
local BOX_FACE_SLOTS = {BOX_FACE_SLOT_A, BOX_FACE_SLOT_B}
local box_face_slot_index = 1
local FACE_REF_LOCAL = Vec3(0, 0, 0)
local SUPPORT_LOCAL_POINT = Vec3(0, 0, 0)
local FACE_POINT_REFERENCE = {}
local FACE_POINT_INCIDENT = {}
local REDUCED_LOCAL_POINTS = {}
local SWEPT_BOX_BOX_POINT_CALLBACK_CONTEXT = {
	static_body = nil,
}

local function evaluate_swept_box_box_point(context, start_world, end_world)
	if not (context and context.static_body) then
		end_world = start_world
		start_world = context
		context = SWEPT_BOX_BOX_POINT_CALLBACK_CONTEXT
	end

	return pair_solver_helpers.SweepPointAgainstBox(context.static_body, start_world, end_world)
end

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

local function add_box_contact_point(contacts, point_a, point_b, separation)
	return convex_manifold.AddContactPoint(contacts, point_a, point_b, 0.12, separation)
end

local function fill_cached_box_faces(polyhedron, world_vertices, out)
	out = out or {}
	local faces = polyhedron.faces

	for face_index = 1, #faces do
		local face = faces[face_index]
		local cached_face = out[face_index]

		if not cached_face then
			cached_face = {points = {}}
			out[face_index] = cached_face
		end

		local points = cached_face.points
		local indices = face.indices

		for i = 1, #indices do
			points[i] = world_vertices[indices[i]]
		end

		for i = #indices + 1, #points do
			points[i] = nil
		end
	end

	for i = #faces + 1, #out do
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
	local best_alignment = -math.huge

	for i = 1, 3 do
		local dot = axes[i]:Dot(desired_normal)
		local abs_dot = math.abs(dot)

		if abs_dot > best_alignment then
			best_alignment = abs_dot
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

	local face = BOX_FACE_SLOTS[box_face_slot_index]
	box_face_slot_index = box_face_slot_index % 2 + 1
	local normal = face.normal or Vec3(0, 0, 0)
	face.normal = normal
	normal.x = axis.x * sign
	normal.y = axis.y * sign
	normal.z = axis.z * sign
	face.axis_index = axis_index
	face.sign = sign
	face.plane = sign * get_component(extents, axis_index)
	face.tangent_u_index = tangent_u_index
	face.tangent_v_index = tangent_v_index
	face.tangent_u_extent = get_component(extents, tangent_u_index)
	face.tangent_v_extent = get_component(extents, tangent_v_index)
	face.points = world_points
	return face
end

local function get_body_world_vertices(body)
	local polyhedron = body:GetBodyPolyhedron()

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

local FACE_A_CANDIDATE = {kind = "face", reference_body = "a"}
local FACE_B_CANDIDATE = {kind = "face", reference_body = "b"}
local EDGE_CANDIDATE = {kind = "edge"}
local BOX_SAT_BEST = convex_sat.CreateBestAxisTracker()
local SKIP_FRICTION_OPTIONS = {skip_friction = true}
local OB_AXIS_NORMAL = Vec3()

local function project_box_radius(extents, axes, normal)
	return extents.x * math.abs(normal:Dot(axes[1])) + extents.y * math.abs(normal:Dot(axes[2])) + extents.z * math.abs(normal:Dot(axes[3]))
end

local function cross_into(out, a, b)
	out.x = a.y * b.z - a.z * b.y
	out.y = a.z * b.x - a.x * b.z
	out.z = a.x * b.y - a.y * b.x
	return out
end

local function test_obb_axis(axis, delta, extents_a, axes_a, extents_b, axes_b, best, candidate)
	local axis_length = axis:GetLength()

	if axis_length <= EPSILON then return true end

	local normal = OB_AXIS_NORMAL:CopyFrom(axis):Scale(1 / axis_length)
	local distance = delta:Dot(normal)
	local abs_distance = math.abs(distance)
	local radius_a = project_box_radius(extents_a, axes_a, normal)
	local radius_b = project_box_radius(extents_b, axes_b, normal)
	local overlap = radius_a + radius_b - abs_distance

	if overlap <= 0 then return false end

	-- candidate doubles as the resolved result; UpdateBestAxis copies values
	candidate.overlap = overlap
	candidate.normal = convex_sat.SetOrientedNormal(candidate.normal, normal, distance)
	convex_sat.UpdateBestAxis(best, candidate)
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
	local local_center = static_body:WorldToLocal(dynamic_body:GetPosition(), nil, nil, SUPPORT_LOCAL_POINT)
	local margin = 0.01
	local center_u = get_component(local_center, support_face.tangent_u_index)
	local center_v = get_component(local_center, support_face.tangent_v_index)
	return math.abs(center_u) > support_face.tangent_u_extent + margin or
		math.abs(center_v) > support_face.tangent_v_extent + margin
end

local function is_support_contact_near_static_face_edge(body_a, body_b, normal, contacts)
	local static_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

	if not (static_body and contacts and contacts[1]) then return false end

	local support_normal = static_body == body_a and normal or -normal
	local support_face = get_box_face(static_body, support_normal)
	local sum_u = 0
	local sum_v = 0
	local count = 0

	for _, pair in ipairs(contacts) do
		local support_point = static_body == body_a and pair.point_a or pair.point_b

		if support_point then
			local local_point = static_body:WorldToLocal(support_point, nil, nil, SUPPORT_LOCAL_POINT)
			sum_u = sum_u + get_component(local_point, support_face.tangent_u_index)
			sum_v = sum_v + get_component(local_point, support_face.tangent_v_index)
			count = count + 1
		end
	end

	if count == 0 then return false end

	local edge_margin = 0.08
	local avg_u = math.abs(sum_u / count)
	local avg_v = math.abs(sum_v / count)
	return avg_u >= support_face.tangent_u_extent - edge_margin or
		avg_v >= support_face.tangent_v_extent - edge_margin
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
	local position = reference_body.Position
	local rotation = reference_body.Rotation

	for _, local_point in ipairs(clipped) do
		local separation = reference_face.sign * (
				get_component(local_point, reference_face.axis_index) - reference_face.plane
			)

		if separation <= FACE_CONTACT_SEPARATION_TOLERANCE then
			ranked_count = ranked_count + 1
			local entry = ranked_contacts[ranked_count] or {}
			local reference_point = FACE_POINT_REFERENCE[ranked_count] or Vec3(0, 0, 0)
			FACE_POINT_REFERENCE[ranked_count] = reference_point
			local incident_point = FACE_POINT_INCIDENT[ranked_count] or Vec3(0, 0, 0)
			FACE_POINT_INCIDENT[ranked_count] = incident_point
			FACE_REF_LOCAL.x = local_point.x
			FACE_REF_LOCAL.y = local_point.y
			FACE_REF_LOCAL.z = local_point.z

			if reference_face.axis_index == 1 then
				FACE_REF_LOCAL.x = reference_face.plane
			elseif reference_face.axis_index == 2 then
				FACE_REF_LOCAL.y = reference_face.plane
			else
				FACE_REF_LOCAL.z = reference_face.plane
			end

			entry.separation = separation
			entry.local_point = local_point
			entry.point_reference = reference_body:LocalToWorld(FACE_REF_LOCAL, position, rotation, reference_point)
			entry.point_incident = reference_body:LocalToWorld(local_point, position, rotation, incident_point)
			ranked_contacts[ranked_count] = entry
		end
	end

	for i = ranked_count + 1, #ranked_contacts do
		ranked_contacts[i] = nil
	end

	ranked_contacts = convex_face_clipping.SelectFaceContactEntries(ranked_contacts, reference_face, 4, BOX_FACE_CONTACT_SCRATCH)
	local contacts = BOX_CONTACT_OUTPUT_SCRATCH.face_contacts

	for i = 1, #contacts do
		contacts[i] = nil
	end

	for i = 1, math.min(ranked_count, 4) do
		local entry = ranked_contacts[i]

		if reference_is_a then
			add_box_contact_point(contacts, entry.point_reference, entry.point_incident, entry.separation)
		else
			add_box_contact_point(contacts, entry.point_incident, entry.point_reference, entry.separation)
		end
	end

	return contacts
end

local function build_edge_contacts(body_a, body_b, candidate)
	local normal = candidate.normal
	local edge_a_start, edge_a_end = get_support_edge(body_a, candidate.edge_axis_a, normal)
	local edge_b_start, edge_b_end = get_support_edge(body_b, candidate.edge_axis_b, -normal)
	local point_a, point_b = convex_manifold.ClosestPointsOnSegments(edge_a_start, edge_a_end, edge_b_start, edge_b_end)
	return convex_manifold.BuildSingleContact(BOX_CONTACT_OUTPUT_SCRATCH.edge_contacts, point_a, point_b)
end

local AVERAGE_SUM = Vec3(0, 0, 0)

local function average_localized_support_points(points, out)
	out = out or Vec3(0, 0, 0)

	if not points[1] then
		out.x = 0
		out.y = 0
		out.z = 0
		return out
	end

	local sum = AVERAGE_SUM
	sum.x = 0
	sum.y = 0
	sum.z = 0

	for _, point in ipairs(points) do
		sum.x = sum.x + point.x
		sum.y = sum.y + point.y
		sum.z = sum.z + point.z
	end

	local inv_count = 1 / #points
	out.x = sum.x * inv_count
	out.y = sum.y * inv_count
	out.z = sum.z * inv_count
	return out
end

local function reduce_contacts_for_support_polygon(body_a, body_b, normal, contacts)
	local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

	if not static_body or #contacts < 3 then return contacts, false end

	local support_is_a = static_body == body_a
	local support_face = get_box_face(static_body, support_is_a and normal or -normal)
	local dynamic_center_local = static_body:WorldToLocal(dynamic_body:GetPosition(), nil, nil, SUPPORT_LOCAL_POINT)
	local position = static_body.Position
	local rotation = static_body.Rotation
	local tolerance = 0.02
	local min_u = math.huge
	local max_u = -math.huge
	local min_v = math.huge
	local max_v = -math.huge
	local localized = BOX_SUPPORT_REDUCTION_SCRATCH.localized
	local localized_count = 0

	for index, contact in ipairs(contacts) do
		local support_point = support_is_a and contact.point_a or contact.point_b
		local local_point = REDUCED_LOCAL_POINTS[index] or Vec3(0, 0, 0)
		REDUCED_LOCAL_POINTS[index] = local_point
		static_body:WorldToLocal(support_point, position, rotation, local_point)
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
			local average_separation = 0

			for _, contact in ipairs(reduced) do
				average_a = average_a + contact.point_a
				average_b = average_b + contact.point_b
				average_separation = average_separation + (contact.separation or 0)
			end

			local averaged = BOX_SUPPORT_REDUCTION_SCRATCH.averaged
			local reduced_contacts = convex_manifold.BuildSingleContact(averaged, average_a / reduced_count, average_b / reduced_count)
			reduced_contacts[1].separation = average_separation / reduced_count
			return reduced_contacts, true
		end

		return reduced, true
	end

	return contacts, false
end

local function solve_swept_box_box_collision(dynamic_body, static_body, dt)
	if not pair_solver_helpers.ShouldUsePairCCD(dynamic_body, static_body) then
		return false
	end

	if not pair_solver_helpers.IsSolverImmovable(static_body) then
		return false
	end

	local sweep = pair_solver_helpers.GetBodySweepMotion(dynamic_body)
	local previous_position = sweep.previous_position
	local current_position = sweep.current_position
	local movement = sweep.movement

	if movement:GetLength() <= EPSILON then return false end

	SWEPT_BOX_BOX_POINT_CALLBACK_CONTEXT.static_body = static_body
	local earliest_hit = pair_solver_helpers.FindEarliestBodyPointSweepHit(
		dynamic_body,
		previous_position,
		sweep.previous_rotation,
		current_position,
		sweep.current_rotation,
		dynamic_body:GetCollisionLocalPoints(),
		evaluate_swept_box_box_point,
		nil,
		SWEPT_BOX_BOX_POINT_CALLBACK_CONTEXT
	)
	SWEPT_BOX_BOX_POINT_CALLBACK_CONTEXT.static_body = nil

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(static_body, dynamic_body, previous_position, movement, earliest_hit, dt)
end

function box.SolveBoxPairCollision(body_a, body_b, dt)
	local _has_rotation

	if (body_a:BodyHasSignificantRotation() or body_b:BodyHasSignificantRotation()) then
		_has_rotation = true
	end

	if _has_rotation and pair_solver_helpers.ShouldUsePairCCD(body_a, body_b) then
		local temporal = polyhedron_solver.SolveTemporalPolyhedronPairCollision(
			body_a,
			body_b,
			body_a:GetBodyPolyhedron(),
			body_b:GetBodyPolyhedron(),
			dt
		)

		if temporal then return true end
	end

	local center_a = body_a:GetPosition()
	local center_b = body_b:GetPosition()
	SAT_DELTA.x = center_b.x - center_a.x
	SAT_DELTA.y = center_b.y - center_a.y
	SAT_DELTA.z = center_b.z - center_a.z
	local delta = SAT_DELTA
	local extents_a = body_a:GetPhysicsShape():GetExtents()
	local extents_b = body_b:GetPhysicsShape():GetExtents()
	local axes_a = body_a:GetPhysicsShape():GetAxes(body_a)
	local axes_b = body_b:GetPhysicsShape():GetAxes(body_b)
	local best = BOX_SAT_BEST
	convex_sat.ResetBestAxisTracker(best)
	stats:PushTime("box_sat")
	local separated = false
	local swept

	for i = 1, 3 do
		if
			not test_obb_axis(axes_a[i], delta, extents_a, axes_a, extents_b, axes_b, best, FACE_A_CANDIDATE)
		or
			not test_obb_axis(axes_b[i], delta, extents_a, axes_a, extents_b, axes_b, best, FACE_B_CANDIDATE)
		then
			separated = true
			local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

			if static_body then
				swept = solve_swept_box_box_collision(dynamic_body, static_body, dt)
			end

			break
		end
	end

	if not separated then
		for i = 1, 3 do
			for j = 1, 3 do
				EDGE_CANDIDATE.edge_axis_a = i
				EDGE_CANDIDATE.edge_axis_b = j

				if
					not test_obb_axis(
						cross_into(SAT_CROSS, axes_a[i], axes_b[j]),
						delta,
						extents_a,
						axes_a,
						extents_b,
						axes_b,
						best,
						EDGE_CANDIDATE
					)
				then
					separated = true
					local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

					if static_body then
						swept = solve_swept_box_box_collision(dynamic_body, static_body, dt)
					end

					break
				end
			end

			if separated then break end
		end
	end

	stats:PopTime()

	if separated then
		if swept ~= nil then return swept end

		return
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

	if best.kind == "face" then
		stats:PushTime("box_face_contacts")
		contacts = build_face_contacts(body_a, body_b, best)
		local reduced_for_support
		contacts, reduced_for_support = reduce_contacts_for_support_polygon(body_a, body_b, best.normal, contacts)

		if
			reduced_for_support and
			raw_best and
			raw_best.kind == "edge" and
			is_support_contact_near_static_face_edge(body_a, body_b, best.normal, contacts)
		then
			local edge_contacts = build_edge_contacts(body_a, body_b, raw_best)

			if edge_contacts and edge_contacts[1] then
				best = raw_best
				contacts = edge_contacts
				resolve_options = SKIP_FRICTION_OPTIONS
			end
		end
		stats:PopTime()
	else
		stats:PushTime("box_edge_contacts")
		contacts = build_edge_contacts(body_a, body_b, best)
		stats:PopTime()

		if
			is_outside_static_support_face(body_a, body_b, best.normal) and
			is_support_contact_near_static_face_edge(body_a, body_b, best.normal, contacts) and
			math.abs(best.normal.y) < 0.35
		then
			resolve_options = SKIP_FRICTION_OPTIONS
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

return box
