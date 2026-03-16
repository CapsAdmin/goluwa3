local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics = import("goluwa/physics.lua")
local solver = import("goluwa/physics/solver.lua")
local physics_solver = import("goluwa/physics/solver.lua")
local shape_accessors = import("goluwa/physics/shape_accessors.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_face_clipping = import("goluwa/physics/convex_face_clipping.lua")
local convex_sat = import("goluwa/physics/convex_sat.lua")
local polyhedron = {}
local EPSILON = physics_solver.EPSILON or 0.00001
local FACE_CONTACT_SEPARATION_TOLERANCE = 0.08
local FACE_AXIS_RELATIVE_TOLERANCE = 1.05
local FACE_AXIS_ABSOLUTE_TOLERANCE = 0.03

function polyhedron.GetPolyhedronWorldVertices(body, polyhedron_data)
	local out = {}

	for i, point in ipairs(polyhedron_data.vertices or {}) do
		out[i] = body:LocalToWorld(point)
	end

	return out
end

function polyhedron.ClosestPointOnTriangle(point, a, b, c)
	local ab = b - a
	local ac = c - a
	local ap = point - a
	local d1 = ab:Dot(ap)
	local d2 = ac:Dot(ap)

	if d1 <= 0 and d2 <= 0 then return a end

	local bp = point - b
	local d3 = ab:Dot(bp)
	local d4 = ac:Dot(bp)

	if d3 >= 0 and d4 <= d3 then return b end

	local vc = d1 * d4 - d3 * d2

	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		return a + ab * v
	end

	local cp = point - c
	local d5 = ab:Dot(cp)
	local d6 = ac:Dot(cp)

	if d6 >= 0 and d5 <= d6 then return c end

	local vb = d5 * d2 - d1 * d6

	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		return a + ac * w
	end

	local va = d3 * d6 - d5 * d4

	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w
	end

	local denom = 1 / (va + vb + vc)
	local v = vb * denom
	local w = vc * denom
	return a + ab * v + ac * w
end

local function local_to_world_at(position, rotation, local_point)
	return position + rotation:VecMul(local_point)
end

local function get_polyhedron_world_vertices_at(polyhedron, position, rotation)
	local out = {}

	for i, point in ipairs(polyhedron.vertices or {}) do
		out[i] = local_to_world_at(position, rotation, point)
	end

	return out
end

local function interpolate_position(previous, current, t)
	return previous + (current - previous) * t
end

local function interpolate_rotation(previous, current, t)
	local target = current

	if previous:Dot(current) < 0 then
		target = Quat(-current.x, -current.y, -current.z, -current.w)
	end

	return Quat(
		previous.x + (target.x - previous.x) * t,
		previous.y + (target.y - previous.y) * t,
		previous.z + (target.z - previous.z) * t,
		previous.w + (target.w - previous.w) * t
	):GetNormalized()
end

local function get_edge_direction(polyhedron, edge)
	if edge.direction then return edge.direction end

	local a = edge.a or edge[1]
	local b = edge.b or edge[2]
	return polyhedron.vertices[b] - polyhedron.vertices[a]
end

local function get_edge_indices(edge)
	return edge.a or edge[1], edge.b or edge[2]
end

local function build_polyhedron_contacts(vertices_a, vertices_b, normal)
	return convex_manifold.BuildSupportPairContacts(vertices_a, vertices_b, normal)
end

local function get_world_face(poly_data, world_vertices, rotation, face_index)
	local face = poly_data.faces and poly_data.faces[face_index]

	if not face then return nil end

	local points = {}

	for i, vertex_index in ipairs(face.indices or {}) do
		points[i] = world_vertices[vertex_index]
	end

	return {
		points = points,
		normal = rotation:VecMul(face.normal):GetNormalized(),
		face_index = face_index,
	}
end

local function find_incident_face_index(poly_data, rotation, reference_normal)
	local best_index = nil
	local best_dot = math.huge

	for face_index, face in ipairs(poly_data.faces or {}) do
		local world_normal = rotation:VecMul(face.normal):GetNormalized()
		local dot = world_normal:Dot(reference_normal)

		if dot < best_dot then
			best_dot = dot
			best_index = face_index
		end
	end

	return best_index
end

local function build_face_contacts_from_features(poly_a, vertices_a, rotation_a, poly_b, vertices_b, rotation_b, candidate)
	local reference_is_a = candidate.reference_body == "a"
	local reference_poly = reference_is_a and poly_a or poly_b
	local reference_vertices = reference_is_a and vertices_a or vertices_b
	local reference_rotation = reference_is_a and rotation_a or rotation_b
	local incident_poly = reference_is_a and poly_b or poly_a
	local incident_vertices = reference_is_a and vertices_b or vertices_a
	local incident_rotation = reference_is_a and rotation_b or rotation_a
	local reference_normal = reference_is_a and candidate.normal or -candidate.normal
	local reference_face = get_world_face(
		reference_poly,
		reference_vertices,
		reference_rotation,
		candidate.face_index
	)

	if not reference_face then return {} end

	local incident_face_index = find_incident_face_index(incident_poly, incident_rotation, reference_normal)
	local incident_face = get_world_face(incident_poly, incident_vertices, incident_rotation, incident_face_index)

	if not incident_face then return {} end

	local reference_descriptor = convex_face_clipping.BuildReferenceFace(reference_face.points, reference_normal)
	local entries = convex_face_clipping.BuildFaceContactEntries(reference_descriptor, incident_face.points, FACE_CONTACT_SEPARATION_TOLERANCE)
	entries = convex_face_clipping.SelectFaceContactEntries(entries, reference_descriptor, 4)
	local contacts = {}

	for _, entry in ipairs(entries) do
		if reference_is_a then
			convex_manifold.AddContactPoint(contacts, entry.point_reference, entry.point_incident)
		else
			convex_manifold.AddContactPoint(contacts, entry.point_incident, entry.point_reference)
		end
	end

	return contacts
end

local function build_edge_contacts_from_features(poly_a, vertices_a, poly_b, vertices_b, candidate)
	local edge_a = poly_a.edges and poly_a.edges[candidate.edge_index_a]
	local edge_b = poly_b.edges and poly_b.edges[candidate.edge_index_b]

	if not (edge_a and edge_b) then return {} end

	local a1, a2 = get_edge_indices(edge_a)
	local b1, b2 = get_edge_indices(edge_b)
	local point_a, point_b = convex_manifold.ClosestPointsOnSegments(vertices_a[a1], vertices_a[a2], vertices_b[b1], vertices_b[b2])
	return {
		{
			point_a = point_a,
			point_b = point_b,
		},
	}
end

local function closest_point_on_triangle(point, a, b, c)
	local ab = b - a
	local ac = c - a
	local ap = point - a
	local d1 = ab:Dot(ap)
	local d2 = ac:Dot(ap)

	if d1 <= 0 and d2 <= 0 then return a end

	local bp = point - b
	local d3 = ab:Dot(bp)
	local d4 = ac:Dot(bp)

	if d3 >= 0 and d4 <= d3 then return b end

	local vc = d1 * d4 - d3 * d2

	if vc <= 0 and d1 >= 0 and d3 <= 0 then
		local v = d1 / (d1 - d3)
		return a + ab * v
	end

	local cp = point - c
	local d5 = ab:Dot(cp)
	local d6 = ac:Dot(cp)

	if d6 >= 0 and d5 <= d6 then return c end

	local vb = d5 * d2 - d1 * d6

	if vb <= 0 and d2 >= 0 and d6 <= 0 then
		local w = d2 / (d2 - d6)
		return a + ac * w
	end

	local va = d3 * d6 - d5 * d4

	if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0 then
		local w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
		return b + (c - b) * w
	end

	local denom = 1 / (va + vb + vc)
	local v = vb * denom
	local w = vc * denom
	return a + ab * v + ac * w
end

local function solve_swept_polyhedron_polyhedron_collision(dynamic_body, static_body, static_polyhedron, dt)
	if
		not pair_solver_helpers.IsSolverImmovable(static_body) or
		not pair_solver_helpers.HasSolverMass(dynamic_body)
	then
		return false
	end

	local previous_position = dynamic_body:GetPreviousPosition()
	local current_position = dynamic_body:GetPosition()
	local movement = current_position - previous_position

	if movement:GetLength() <= EPSILON then return false end

	local earliest_hit

	for _, local_point in ipairs(dynamic_body:GetCollisionLocalPoints()) do
		local start_world = dynamic_body:GeometryLocalToWorld(local_point, previous_position, dynamic_body:GetPreviousRotation())
		local end_world = dynamic_body:GeometryLocalToWorld(local_point)
		local hit = pair_solver_helpers.SweepPointAgainstPolyhedron(static_body, static_polyhedron, start_world, end_world)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = hit
		end
	end

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(static_body, dynamic_body, previous_position, movement, earliest_hit, dt)
end

local function evaluate_polyhedron_pair_at_transforms(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b)
	local axes = {}

	for _, face in ipairs(poly_a.faces or {}) do
		convex_sat.AddUniqueAxis(axes, rotation_a:VecMul(face.normal))
	end

	for _, face in ipairs(poly_b.faces or {}) do
		convex_sat.AddUniqueAxis(axes, rotation_b:VecMul(face.normal))
	end

	for _, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = rotation_a:VecMul(get_edge_direction(poly_a, edge_a))

		for _, edge_b in ipairs(poly_b.edges or {}) do
			local dir_b = rotation_b:VecMul(get_edge_direction(poly_b, edge_b))
			convex_sat.AddUniqueAxis(axes, dir_a:GetCross(dir_b))
		end
	end

	if not axes[1] then return nil end

	local vertices_a = get_polyhedron_world_vertices_at(poly_a, position_a, rotation_a)
	local vertices_b = get_polyhedron_world_vertices_at(poly_b, position_b, rotation_b)
	local best = convex_sat.CreateBestAxisTracker()
	local center_delta = position_b - position_a

	for _, axis in ipairs(axes) do
		local min_a, max_a = convex_sat.ProjectVertices(vertices_a, axis)
		local min_b, max_b = convex_sat.ProjectVertices(vertices_b, axis)
		local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)

		if overlap <= 0 then return nil end
	end

	for face_index, face in ipairs(poly_a.faces or {}) do
		local axis = rotation_a:VecMul(face.normal)
		local min_a, max_a = convex_sat.ProjectVertices(vertices_a, axis)
		local min_b, max_b = convex_sat.ProjectVertices(vertices_b, axis)
		local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)
		convex_sat.UpdateBestAxis(
			best,
			{
				overlap = overlap,
				normal = convex_sat.OrientAxisNormal(axis, center_delta:Dot(axis)),
				kind = "face",
				reference_body = "a",
				face_index = face_index,
			}
		)
	end

	for face_index, face in ipairs(poly_b.faces or {}) do
		local axis = rotation_b:VecMul(face.normal)
		local min_a, max_a = convex_sat.ProjectVertices(vertices_a, axis)
		local min_b, max_b = convex_sat.ProjectVertices(vertices_b, axis)
		local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)
		convex_sat.UpdateBestAxis(
			best,
			{
				overlap = overlap,
				normal = convex_sat.OrientAxisNormal(axis, center_delta:Dot(axis)),
				kind = "face",
				reference_body = "b",
				face_index = face_index,
			}
		)
	end

	for edge_index_a, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = rotation_a:VecMul(get_edge_direction(poly_a, edge_a))

		for edge_index_b, edge_b in ipairs(poly_b.edges or {}) do
			local axis = dir_a:GetCross(rotation_b:VecMul(get_edge_direction(poly_b, edge_b)))
			local axis_length = axis:GetLength()

			if axis_length > EPSILON then
				local normalized = axis / axis_length
				local min_a, max_a = convex_sat.ProjectVertices(vertices_a, normalized)
				local min_b, max_b = convex_sat.ProjectVertices(vertices_b, normalized)
				local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)
				convex_sat.UpdateBestAxis(
					best,
					{
						overlap = overlap,
						normal = convex_sat.OrientAxisNormal(normalized, center_delta:Dot(normalized)),
						kind = "edge",
						edge_index_a = edge_index_a,
						edge_index_b = edge_index_b,
					}
				)
			end
		end
	end

	local chosen = convex_sat.ChoosePreferredAxis(best, FACE_AXIS_RELATIVE_TOLERANCE, FACE_AXIS_ABSOLUTE_TOLERANCE)
	local best_overlap = chosen and chosen.overlap or math.huge
	local best_normal = chosen and chosen.normal or nil

	if not best_normal or best_overlap == math.huge then return nil end

	local contacts = build_polyhedron_contacts(vertices_a, vertices_b, best_normal)
	local point_a = convex_manifold.AverageWorldPoints(convex_manifold.CollectSupportVertices(vertices_a, best_normal, true))
	local point_b = convex_manifold.AverageWorldPoints(convex_manifold.CollectSupportVertices(vertices_b, best_normal, false))
	return {
		overlap = best_overlap,
		normal = best_normal,
		contacts = contacts,
		point_a = point_a,
		point_b = point_b,
		position_a = position_a,
		position_b = position_b,
		rotation_a = rotation_a,
		rotation_b = rotation_b,
	}
end

local function find_polyhedron_pair_time_of_impact(body_a, poly_a, body_b, poly_b)
	local previous_position_a = body_a:GetPreviousPosition()
	local previous_rotation_a = body_a:GetPreviousRotation()
	local current_position_a = body_a:GetPosition()
	local current_rotation_a = body_a:GetRotation()
	local previous_position_b = body_b:GetPreviousPosition()
	local previous_rotation_b = body_b:GetPreviousRotation()
	local current_position_b = body_b:GetPosition()
	local current_rotation_b = body_b:GetRotation()
	local sample_steps = 10
	local previous_t = 0
	local previous_result = evaluate_polyhedron_pair_at_transforms(
		poly_a,
		previous_position_a,
		previous_rotation_a,
		poly_b,
		previous_position_b,
		previous_rotation_b
	)

	if previous_result then return nil end

	for i = 1, sample_steps do
		local t = i / sample_steps
		local result = evaluate_polyhedron_pair_at_transforms(
			poly_a,
			interpolate_position(previous_position_a, current_position_a, t),
			interpolate_rotation(previous_rotation_a, current_rotation_a, t),
			poly_b,
			interpolate_position(previous_position_b, current_position_b, t),
			interpolate_rotation(previous_rotation_b, current_rotation_b, t)
		)

		if result then
			local low = previous_t
			local high = t
			local best = result

			for _ = 1, 10 do
				local mid = (low + high) * 0.5
				local mid_result = evaluate_polyhedron_pair_at_transforms(
					poly_a,
					interpolate_position(previous_position_a, current_position_a, mid),
					interpolate_rotation(previous_rotation_a, current_rotation_a, mid),
					poly_b,
					interpolate_position(previous_position_b, current_position_b, mid),
					interpolate_rotation(previous_rotation_b, current_rotation_b, mid)
				)

				if mid_result then
					best = mid_result
					high = mid
				else
					low = mid
				end
			end

			best.t = high
			return best
		end

		previous_t = t
	end

	return nil
end

local function solve_temporal_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)
	local result = find_polyhedron_pair_time_of_impact(body_a, poly_a, body_b, poly_b)

	if not result then return false end

	if body_a:HasSolverMass() then
		body_a.Position = result.position_a
		body_a.Rotation = result.rotation_a
	end

	if body_b:HasSolverMass() then
		body_b.Position = result.position_b
		body_b.Rotation = result.rotation_b
	end

	if result.contacts and result.contacts[1] then
		return contact_resolution.ResolvePairPenetration(body_a, body_b, result.normal, result.overlap, dt, nil, nil, result.contacts)
	end

	return contact_resolution.ResolvePairPenetration(body_a, body_b, result.normal, result.overlap, dt, result.point_a, result.point_b)
end

local function solve_relative_swept_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)
	if
		pair_solver_helpers.IsSolverImmovable(body_a) or
		pair_solver_helpers.IsSolverImmovable(body_b)
	then
		return false
	end

	local previous_position_a = body_a:GetPreviousPosition()
	local previous_position_b = body_b:GetPreviousPosition()
	local current_position_a = body_a:GetPosition()
	local current_position_b = body_b:GetPosition()
	local movement_a = current_position_a - previous_position_a
	local movement_b = current_position_b - previous_position_b
	local relative_movement = movement_a - movement_b

	if relative_movement:GetLength() <= EPSILON then return false end

	local previous_rotation_a = body_a:GetPreviousRotation()
	local previous_rotation_b = body_b:GetPreviousRotation()
	local earliest_hit

	for _, local_point in ipairs(body_a:GetCollisionLocalPoints()) do
		local start_world = body_a:GeometryLocalToWorld(local_point, previous_position_a, previous_rotation_a)
		local hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
			body_b,
			poly_b,
			start_world,
			start_world + relative_movement,
			0,
			previous_position_b,
			previous_rotation_b
		)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = {
				t = hit.t,
				normal = hit.normal * -1,
			}
		end
	end

	for _, local_point in ipairs(body_b:GetCollisionLocalPoints()) do
		local start_world = body_b:GeometryLocalToWorld(local_point, previous_position_b, previous_rotation_b)
		local hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
			body_a,
			poly_a,
			start_world,
			start_world - relative_movement,
			0,
			previous_position_a,
			previous_rotation_a
		)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = {
				t = hit.t,
				normal = hit.normal,
			}
		end
	end

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveRelativeSweptPairHit(
		body_a,
		body_b,
		previous_position_a,
		movement_a,
		previous_position_b,
		movement_b,
		earliest_hit,
		dt
	)
end

local function solve_polyhedron_pair_collision(body_a, body_b, dt)
	local poly_a = shape_accessors.GetBodyPolyhedron(body_a)
	local poly_b = shape_accessors.GetBodyPolyhedron(body_b)

	if not (poly_a and poly_b and poly_a.vertices and poly_b.vertices) then
		return false
	end

	if
		shape_accessors.BodyHasSignificantRotation(body_a) or
		shape_accessors.BodyHasSignificantRotation(body_b)
	then
		local temporal = solve_temporal_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)

		if temporal then return true end
	end

	if
		pair_solver_helpers.HasSolverMass(body_a) and
		pair_solver_helpers.HasSolverMass(body_b)
	then
		local previous_bounds_a = body_a:GetBroadphaseAABB(body_a:GetPreviousPosition(), body_a:GetPreviousRotation())
		local previous_bounds_b = body_b:GetBroadphaseAABB(body_b:GetPreviousPosition(), body_b:GetPreviousRotation())

		if not previous_bounds_a:IsBoxIntersecting(previous_bounds_b) then
			local swept = solve_relative_swept_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)

			if swept then return true end
		end
	end

	local axes = {}
	local center_delta = body_b:GetPosition() - body_a:GetPosition()

	for _, face in ipairs(poly_a.faces or {}) do
		convex_sat.AddUniqueAxis(axes, body_a:GetRotation():VecMul(face.normal))
	end

	for _, face in ipairs(poly_b.faces or {}) do
		convex_sat.AddUniqueAxis(axes, body_b:GetRotation():VecMul(face.normal))
	end

	for _, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = body_a:GetRotation():VecMul(get_edge_direction(poly_a, edge_a))

		for _, edge_b in ipairs(poly_b.edges or {}) do
			local dir_b = body_b:GetRotation():VecMul(get_edge_direction(poly_b, edge_b))
			convex_sat.AddUniqueAxis(axes, dir_a:GetCross(dir_b))
		end
	end

	if not axes[1] then return false end

	local vertices_a = polyhedron.GetPolyhedronWorldVertices(body_a, poly_a)
	local vertices_b = polyhedron.GetPolyhedronWorldVertices(body_b, poly_b)
	local best = convex_sat.CreateBestAxisTracker()

	local function try_swept_fallback()
		local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

		if static_body == body_a then
			return solve_swept_polyhedron_polyhedron_collision(dynamic_body, static_body, poly_a, dt)
		end

		if static_body == body_b then
			return solve_swept_polyhedron_polyhedron_collision(dynamic_body, static_body, poly_b, dt)
		end

		return solve_relative_swept_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)
	end

	for _, axis in ipairs(axes) do
		local min_a, max_a = convex_sat.ProjectVertices(vertices_a, axis)
		local min_b, max_b = convex_sat.ProjectVertices(vertices_b, axis)
		local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)

		if overlap <= 0 then return try_swept_fallback() end
	end

	for face_index, face in ipairs(poly_a.faces or {}) do
		local axis = body_a:GetRotation():VecMul(face.normal)
		local min_a, max_a = convex_sat.ProjectVertices(vertices_a, axis)
		local min_b, max_b = convex_sat.ProjectVertices(vertices_b, axis)
		local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)
		convex_sat.UpdateBestAxis(
			best,
			{
				overlap = overlap,
				normal = convex_sat.OrientAxisNormal(axis, center_delta:Dot(axis)),
				kind = "face",
				reference_body = "a",
				face_index = face_index,
			}
		)
	end

	for face_index, face in ipairs(poly_b.faces or {}) do
		local axis = body_b:GetRotation():VecMul(face.normal)
		local min_a, max_a = convex_sat.ProjectVertices(vertices_a, axis)
		local min_b, max_b = convex_sat.ProjectVertices(vertices_b, axis)
		local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)
		convex_sat.UpdateBestAxis(
			best,
			{
				overlap = overlap,
				normal = convex_sat.OrientAxisNormal(axis, center_delta:Dot(axis)),
				kind = "face",
				reference_body = "b",
				face_index = face_index,
			}
		)
	end

	for edge_index_a, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = body_a:GetRotation():VecMul(get_edge_direction(poly_a, edge_a))

		for edge_index_b, edge_b in ipairs(poly_b.edges or {}) do
			local axis = dir_a:GetCross(body_b:GetRotation():VecMul(get_edge_direction(poly_b, edge_b)))
			local axis_length = axis:GetLength()

			if axis_length > EPSILON then
				local normalized = axis / axis_length
				local min_a, max_a = convex_sat.ProjectVertices(vertices_a, normalized)
				local min_b, max_b = convex_sat.ProjectVertices(vertices_b, normalized)
				local overlap = math.min(max_a, max_b) - math.max(min_a, min_b)
				convex_sat.UpdateBestAxis(
					best,
					{
						overlap = overlap,
						normal = convex_sat.OrientAxisNormal(normalized, center_delta:Dot(normalized)),
						kind = "edge",
						edge_index_a = edge_index_a,
						edge_index_b = edge_index_b,
					}
				)
			end
		end
	end

	local chosen = convex_sat.ChoosePreferredAxis(best, FACE_AXIS_RELATIVE_TOLERANCE, FACE_AXIS_ABSOLUTE_TOLERANCE)
	local best_overlap = chosen and chosen.overlap or math.huge
	local best_normal = chosen and chosen.normal or nil

	if not best_normal or best_overlap == math.huge then return false end

	local contacts = chosen.kind == "face" and
		build_face_contacts_from_features(
			poly_a,
			vertices_a,
			body_a:GetRotation(),
			poly_b,
			vertices_b,
			body_b:GetRotation(),
			chosen
		) or
		chosen.kind == "edge" and
		build_edge_contacts_from_features(poly_a, vertices_a, poly_b, vertices_b, chosen)
		or
		build_polyhedron_contacts(vertices_a, vertices_b, best_normal)
	local point_a = convex_manifold.AverageWorldPoints(convex_manifold.CollectSupportVertices(vertices_a, best_normal, true))
	local point_b = convex_manifold.AverageWorldPoints(convex_manifold.CollectSupportVertices(vertices_b, best_normal, false))

	if contacts[1] then
		return contact_resolution.ResolvePairPenetration(body_a, body_b, best_normal, best_overlap, dt, nil, nil, contacts)
	end

	return contact_resolution.ResolvePairPenetration(body_a, body_b, best_normal, best_overlap, dt, point_a, point_b)
end

polyhedron.SolveTemporalPolyhedronPairCollision = solve_temporal_polyhedron_pair_collision
polyhedron.SolvePolyhedronPairCollision = solve_polyhedron_pair_collision

solver:RegisterPairHandler("convex", "box", function(body_a, body_b, _, _, dt)
	return solve_polyhedron_pair_collision(body_a, body_b, dt)
end)

solver:RegisterPairHandler("box", "convex", function(body_a, body_b, _, _, dt)
	return solve_polyhedron_pair_collision(body_a, body_b, dt)
end)

solver:RegisterPairHandler("convex", "convex", function(body_a, body_b, _, _, dt)
	return solve_polyhedron_pair_collision(body_a, body_b, dt)
end)

return polyhedron