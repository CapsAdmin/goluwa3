local physics = import("goluwa/physics.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_face_clipping = import("goluwa/physics/convex_face_clipping.lua")
local convex_sat = import("goluwa/physics/convex_sat.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron_cache.lua")
local polyhedron_geometry = import("goluwa/physics/polyhedron_geometry.lua")
local triangle_geometry = import("goluwa/physics/triangle_geometry.lua")
local polyhedron = {}
local FACE_CONTACT_SEPARATION_TOLERANCE = 0.08
local FACE_AXIS_RELATIVE_TOLERANCE = 1.05
local FACE_AXIS_ABSOLUTE_TOLERANCE = 0.03
local POLYHEDRON_FACE_CONTACT_SCRATCH = {}
local POLYHEDRON_SUPPORT_CONTACT_SCRATCH = {}
local POLYHEDRON_CONTACT_OUTPUT_SCRATCH = {
	face_contacts = {},
	edge_contacts = {
		{},
	},
}
polyhedron.GetPolyhedronWorldVertices = polyhedron_cache.GetPolyhedronWorldVertices
polyhedron.GetPolyhedronWorldFace = polyhedron_cache.GetPolyhedronWorldFace
polyhedron.ClosestPointOnTriangle = triangle_geometry.ClosestPointOnTriangle

local function get_polyhedron_world_vertices_at(polyhedron, position, rotation, out)
	return polyhedron_cache.FillPolyhedronWorldVertices(polyhedron, position, rotation, out)
end

local function collect_sat_axes(poly_a, rotation_a, poly_b, rotation_b, axes)
	axes = axes or {}

	for i = 1, #axes do
		axes[i] = nil
	end

	for _, face in ipairs(poly_a.faces or {}) do
		convex_sat.AddUniqueAxis(axes, rotation_a:VecMul(face.normal))
	end

	for _, face in ipairs(poly_b.faces or {}) do
		convex_sat.AddUniqueAxis(axes, rotation_b:VecMul(face.normal))
	end

	for _, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = rotation_a:VecMul(polyhedron_geometry.GetEdgeDirection(poly_a, edge_a))

		for _, edge_b in ipairs(poly_b.edges or {}) do
			local dir_b = rotation_b:VecMul(polyhedron_geometry.GetEdgeDirection(poly_b, edge_b))
			convex_sat.AddUniqueAxis(axes, dir_a:GetCross(dir_b))
		end
	end

	return axes
end

local function has_separating_axis(vertices_a, vertices_b, axes)
	for _, axis in ipairs(axes) do
		if convex_sat.GetProjectedOverlap(vertices_a, vertices_b, axis) <= 0 then
			return true
		end
	end

	return false
end

local function update_face_axis_candidates(best, vertices_a, vertices_b, poly_data, rotation, center_delta, reference_body)
	for face_index, face in ipairs(poly_data.faces or {}) do
		local axis = rotation:VecMul(face.normal)
		convex_sat.TryUpdateAxis(
			best,
			vertices_a,
			vertices_b,
			axis,
			center_delta,
			{
				kind = "face",
				reference_body = reference_body,
				face_index = face_index,
			},
			nil,
			false,
			physics.EPSILON
		)
	end

	return best
end

local function update_edge_axis_candidates(
	best,
	vertices_a,
	vertices_b,
	poly_a,
	rotation_a,
	poly_b,
	rotation_b,
	center_delta
)
	for edge_index_a, edge_a in ipairs(poly_a.edges or {}) do
		local dir_a = rotation_a:VecMul(polyhedron_geometry.GetEdgeDirection(poly_a, edge_a))

		for edge_index_b, edge_b in ipairs(poly_b.edges or {}) do
			local axis = dir_a:GetCross(rotation_b:VecMul(polyhedron_geometry.GetEdgeDirection(poly_b, edge_b)))
			convex_sat.TryUpdateAxis(
				best,
				vertices_a,
				vertices_b,
				axis,
				center_delta,
				{
					kind = "edge",
					edge_index_a = edge_index_a,
					edge_index_b = edge_index_b,
				},
				nil,
				true,
				physics.EPSILON
			)
		end
	end

	return best
end
local function get_edge_indices(edge)
	return polyhedron_geometry.GetEdgeIndices(edge)
end

local function build_polyhedron_contacts(vertices_a, vertices_b, normal)
	return convex_manifold.BuildSupportPairContacts(
		vertices_a,
		vertices_b,
		normal,
		{
			scratch = POLYHEDRON_SUPPORT_CONTACT_SCRATCH,
		}
	)
end

local function build_face_contacts_from_features(
	body_a,
	poly_a,
	vertices_a,
	rotation_a,
	body_b,
	poly_b,
	vertices_b,
	rotation_b,
	candidate
)
	local reference_is_a = candidate.reference_body == "a"
	local reference_body = reference_is_a and body_a or body_b
	local reference_poly = reference_is_a and poly_a or poly_b
	local incident_body = reference_is_a and body_b or body_a
	local incident_poly = reference_is_a and poly_b or poly_a
	local incident_rotation = reference_is_a and rotation_b or rotation_a
	local reference_normal = reference_is_a and candidate.normal or -candidate.normal
	local reference_face = polyhedron_cache.GetPolyhedronWorldFace(reference_body, reference_poly, candidate.face_index)

	if not reference_face then return {} end

	local incident_face_index = polyhedron_cache.FindIncidentFaceIndex(incident_poly, incident_rotation, reference_normal)
	local incident_face = polyhedron_cache.GetPolyhedronWorldFace(incident_body, incident_poly, incident_face_index)

	if not incident_face then return {} end

	return convex_face_clipping.BuildFaceContactPairs(
		reference_face.points,
		reference_normal,
		incident_face.points,
		{
			separation_tolerance = FACE_CONTACT_SEPARATION_TOLERANCE,
			max_contacts = 4,
			scratch = POLYHEDRON_FACE_CONTACT_SCRATCH,
			out = POLYHEDRON_CONTACT_OUTPUT_SCRATCH.face_contacts,
			swap = not reference_is_a,
			merge_distance = 0.1,
		}
	)
end

local function build_edge_contacts_from_features(poly_a, vertices_a, poly_b, vertices_b, candidate)
	local edge_a = poly_a.edges and poly_a.edges[candidate.edge_index_a]
	local edge_b = poly_b.edges and poly_b.edges[candidate.edge_index_b]

	if not (edge_a and edge_b) then return {} end

	local a1, a2 = get_edge_indices(edge_a)
	local b1, b2 = get_edge_indices(edge_b)
	local point_a, point_b = convex_manifold.ClosestPointsOnSegments(vertices_a[a1], vertices_a[a2], vertices_b[b1], vertices_b[b2])
	return convex_manifold.BuildSingleContact(POLYHEDRON_CONTACT_OUTPUT_SCRATCH.edge_contacts, point_a, point_b)
end

local function solve_swept_polyhedron_polyhedron_collision(dynamic_body, static_body, static_polyhedron, dt)
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
			return pair_solver_helpers.SweepPointAgainstPolyhedron(static_body, static_polyhedron, start_world, end_world)
		end
	)

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(static_body, dynamic_body, previous_position, movement, earliest_hit, dt)
end

local function evaluate_polyhedron_pair_at_transforms(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b, scratch)
	scratch = scratch or {}
	local axes = collect_sat_axes(poly_a, rotation_a, poly_b, rotation_b, scratch.axes)
	scratch.axes = axes

	if not axes[1] then return nil end

	local vertices_a = get_polyhedron_world_vertices_at(poly_a, position_a, rotation_a, scratch.vertices_a)
	local vertices_b = get_polyhedron_world_vertices_at(poly_b, position_b, rotation_b, scratch.vertices_b)
	scratch.vertices_a = vertices_a
	scratch.vertices_b = vertices_b
	local best = convex_sat.CreateBestAxisTracker()
	local center_delta = position_b - position_a

	if has_separating_axis(vertices_a, vertices_b, axes) then return nil end

	update_face_axis_candidates(best, vertices_a, vertices_b, poly_a, rotation_a, center_delta, "a")
	update_face_axis_candidates(best, vertices_a, vertices_b, poly_b, rotation_b, center_delta, "b")
	update_edge_axis_candidates(
		best,
		vertices_a,
		vertices_b,
		poly_a,
		rotation_a,
		poly_b,
		rotation_b,
		center_delta
	)
	local chosen = convex_sat.ChoosePreferredAxis(best, FACE_AXIS_RELATIVE_TOLERANCE, FACE_AXIS_ABSOLUTE_TOLERANCE)
	local best_overlap = chosen and chosen.overlap or math.huge
	local best_normal = chosen and chosen.normal or nil

	if not best_normal or best_overlap == math.huge then return nil end

	local contacts = build_polyhedron_contacts(vertices_a, vertices_b, best_normal)
	local point_a = convex_manifold.AverageSupportPoint(vertices_a, best_normal, true)
	local point_b = convex_manifold.AverageSupportPoint(vertices_b, best_normal, false)
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
	local sample_steps = pair_solver_helpers.GetTemporalTOISampleSteps(body_a, body_b)
	local scratch = {
		vertices_a = {},
		vertices_b = {},
	}
	return pair_solver_helpers.FindSampledTemporalHit(
		function(t)
			return evaluate_polyhedron_pair_at_transforms(
				poly_a,
				pair_solver_helpers.InterpolatePosition(previous_position_a, current_position_a, t),
				pair_solver_helpers.InterpolateRotation(previous_rotation_a, current_rotation_a, t),
				poly_b,
				pair_solver_helpers.InterpolatePosition(previous_position_b, current_position_b, t),
				pair_solver_helpers.InterpolateRotation(previous_rotation_b, current_rotation_b, t),
				scratch
			)
		end,
		sample_steps
	)
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

	local sweep_a = pair_solver_helpers.GetBodySweepMotion(body_a)
	local sweep_b = pair_solver_helpers.GetBodySweepMotion(body_b)
	local previous_position_a = sweep_a.previous_position
	local previous_position_b = sweep_b.previous_position
	local movement_a = sweep_a.movement
	local movement_b = sweep_b.movement
	local relative_movement = movement_a - movement_b

	if relative_movement:GetLength() <= physics.EPSILON then return false end

	local earliest_hit = pair_solver_helpers.FindEarliestBodyPointSweepHit(
		body_a,
		sweep_a.previous_position,
		sweep_a.previous_rotation,
		sweep_a.previous_position + relative_movement,
		sweep_a.previous_rotation,
		body_a:GetCollisionLocalPoints(),
		function(start_world, end_world)
			local hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
				body_b,
				poly_b,
				start_world,
				end_world,
				0,
				sweep_b.previous_position,
				sweep_b.previous_rotation
			)

			if not hit then return nil end

			return {
				t = hit.t,
				normal = hit.normal * -1,
			}
		end
	)
	earliest_hit = pair_solver_helpers.FindEarliestBodyPointSweepHit(
		body_b,
		sweep_b.previous_position,
		sweep_b.previous_rotation,
		sweep_b.previous_position - relative_movement,
		sweep_b.previous_rotation,
		body_b:GetCollisionLocalPoints(),
		function(start_world, end_world)
			local hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
				body_a,
				poly_a,
				start_world,
				end_world,
				0,
				sweep_a.previous_position,
				sweep_a.previous_rotation
			)

			if not hit then return nil end

			return {
				t = hit.t,
				normal = hit.normal,
			}
		end,
		earliest_hit
	)

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
	local poly_a = body_a:GetBodyPolyhedron()
	local poly_b = body_b:GetBodyPolyhedron()

	if not (poly_a and poly_b and poly_a.vertices and poly_b.vertices) then
		return false
	end

	if body_a:BodyHasSignificantRotation() or body_b:BodyHasSignificantRotation() then
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

	local center_delta = body_b:GetPosition() - body_a:GetPosition()
	local axes = collect_sat_axes(poly_a, body_a:GetRotation(), poly_b, body_b:GetRotation())

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

	if has_separating_axis(vertices_a, vertices_b, axes) then
		return try_swept_fallback()
	end

	update_face_axis_candidates(best, vertices_a, vertices_b, poly_a, body_a:GetRotation(), center_delta, "a")
	update_face_axis_candidates(best, vertices_a, vertices_b, poly_b, body_b:GetRotation(), center_delta, "b")
	update_edge_axis_candidates(
		best,
		vertices_a,
		vertices_b,
		poly_a,
		body_a:GetRotation(),
		poly_b,
		body_b:GetRotation(),
		center_delta
	)
	local chosen = convex_sat.ChoosePreferredAxis(best, FACE_AXIS_RELATIVE_TOLERANCE, FACE_AXIS_ABSOLUTE_TOLERANCE)
	local best_overlap = chosen and chosen.overlap or math.huge
	local best_normal = chosen and chosen.normal or nil

	if not best_normal or best_overlap == math.huge then return false end

	local contacts = chosen.kind == "face" and
		build_face_contacts_from_features(
			body_a,
			poly_a,
			vertices_a,
			body_a:GetRotation(),
			body_b,
			poly_b,
			vertices_b,
			body_b:GetRotation(),
			chosen
		) or
		chosen.kind == "edge" and
		build_edge_contacts_from_features(poly_a, vertices_a, poly_b, vertices_b, chosen)
		or
		build_polyhedron_contacts(vertices_a, vertices_b, best_normal)
	local point_a = convex_manifold.AverageSupportPoint(vertices_a, best_normal, true)
	local point_b = convex_manifold.AverageSupportPoint(vertices_b, best_normal, false)

	if contacts[1] then
		return contact_resolution.ResolvePairPenetration(body_a, body_b, best_normal, best_overlap, dt, nil, nil, contacts)
	end

	return contact_resolution.ResolvePairPenetration(body_a, body_b, best_normal, best_overlap, dt, point_a, point_b)
end

polyhedron.SolveTemporalPolyhedronPairCollision = solve_temporal_polyhedron_pair_collision
polyhedron.SolvePolyhedronPairCollision = solve_polyhedron_pair_collision

physics.solver:RegisterPairHandler("convex", "box", function(body_a, body_b, _, _, dt)
	return solve_polyhedron_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("box", "convex", function(body_a, body_b, _, _, dt)
	return solve_polyhedron_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("convex", "convex", function(body_a, body_b, _, _, dt)
	return solve_polyhedron_pair_collision(body_a, body_b, dt)
end)

return polyhedron
