local physics_constants = import("goluwa/physics/constants.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local gjk_epa = import("goluwa/physics/gjk_epa.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local polyhedron_face_contacts = import("goluwa/physics/polyhedron/face_contacts.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron/cache.lua")
local polyhedron = {}
local EPSILON = physics_constants.EPSILON
local FACE_CONTACT_SEPARATION_TOLERANCE = 0.08
local FACE_CONTACT_ALIGNMENT_THRESHOLD = 0.5
local POLYHEDRON_FACE_CONTACT_SCRATCH = {}
local POLYHEDRON_SUPPORT_CONTACT_SCRATCH = {}
local POLYHEDRON_CONTACT_OUTPUT_SCRATCH = {
	face_contacts = {},
}
local POLYHEDRON_PAIR_AXIS_CACHE = setmetatable({}, {__mode = "k"})
local find_distance_swept_polyhedron_pair_hit
local solve_distance_swept_polyhedron_pair_collision
polyhedron.GetPolyhedronWorldVertices = polyhedron_cache.GetPolyhedronWorldVertices
polyhedron.GetPolyhedronWorldFace = polyhedron_cache.GetPolyhedronWorldFace

local function get_pair_axis_cache_row(body)
	local row = POLYHEDRON_PAIR_AXIS_CACHE[body]

	if row then return row end

	row = setmetatable({}, {__mode = "k"})
	POLYHEDRON_PAIR_AXIS_CACHE[body] = row
	return row
end

local function get_cached_pair_axis(body_a, body_b)
	local row = POLYHEDRON_PAIR_AXIS_CACHE[body_a]
	local axis = row and row[body_b] or nil

	if axis and axis:GetLength() > EPSILON then return axis end

	return nil
end

local function set_cached_pair_axis(body_a, body_b, axis)
	if not axis or axis:GetLength() <= EPSILON then return end

	local normalized = axis:GetNormalized()
	get_pair_axis_cache_row(body_a)[body_b] = normalized
	get_pair_axis_cache_row(body_b)[body_a] = normalized * -1
end

local function build_polyhedron_contacts(vertices_a, vertices_b, normal)
	return convex_manifold.BuildAndMergeSupportPairContacts(
		nil,
		vertices_a,
		vertices_b,
		normal,
		{
			scratch = POLYHEDRON_SUPPORT_CONTACT_SCRATCH,
		}
	)
end

local function build_face_contacts_from_features(body_a, poly_a, rotation_a, body_b, poly_b, rotation_b, candidate)
	local reference_is_a = candidate.reference_body == "a"
	local reference_body = reference_is_a and body_a or body_b
	local reference_poly = reference_is_a and poly_a or poly_b
	local incident_body = reference_is_a and body_b or body_a
	local incident_poly = reference_is_a and poly_b or poly_a
	local incident_rotation = reference_is_a and rotation_b or rotation_a
	local reference_normal = reference_is_a and candidate.normal or -candidate.normal
	local reference_face = polyhedron_face_contacts.GetWorldFace(reference_body, reference_poly, candidate.face_index)

	if not reference_face then return {} end

	local incident_face = polyhedron_face_contacts.GetIncidentWorldFace(incident_body, incident_poly, incident_rotation, reference_normal)

	if not incident_face then return {} end

	return polyhedron_face_contacts.BuildClippedPairs(
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

local function find_best_face_index_for_normal(polyhedron_data, rotation, normal)
	local best_index = nil
	local best_alignment = -math.huge

	for face_index, face in ipairs(polyhedron_data.faces or {}) do
		local world_normal = rotation:VecMul(face.normal):GetNormalized()
		local alignment = world_normal:Dot(normal)

		if alignment > best_alignment then
			best_alignment = alignment
			best_index = face_index
		end
	end

	return best_index, best_alignment
end

local function build_contacts_from_penetration_result(
	body_a,
	poly_a,
	vertices_a,
	rotation_a,
	body_b,
	poly_b,
	vertices_b,
	rotation_b,
	normal
)
	local face_index_a, alignment_a = find_best_face_index_for_normal(poly_a, rotation_a, normal)
	local face_index_b, alignment_b = find_best_face_index_for_normal(poly_b, rotation_b, normal * -1)
	local candidate = nil

	if
		face_index_a and
		alignment_a >= FACE_CONTACT_ALIGNMENT_THRESHOLD and
		alignment_a >= (
			alignment_b or
			-math.huge
		)
	then
		candidate = {
			kind = "face",
			reference_body = "a",
			face_index = face_index_a,
			normal = normal,
		}
	elseif face_index_b and alignment_b >= FACE_CONTACT_ALIGNMENT_THRESHOLD then
		candidate = {
			kind = "face",
			reference_body = "b",
			face_index = face_index_b,
			normal = normal,
		}
	end

	if candidate then
		local contacts = build_face_contacts_from_features(
			body_a,
			poly_a,
			rotation_a,
			body_b,
			poly_b,
			rotation_b,
			candidate
		)

		if contacts[1] then return contacts end
	end

	return build_polyhedron_contacts(vertices_a, vertices_b, normal)
end

local function solve_swept_polyhedron_polyhedron_collision(dynamic_body, dynamic_polyhedron, static_body, static_polyhedron, dt)
	if not pair_solver_helpers.ShouldUsePairCCD(dynamic_body, static_body) then
		return false
	end

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

	if movement:GetLength() <= EPSILON then return false end

	local distance_hit = find_distance_swept_polyhedron_pair_hit(static_body, dynamic_body, static_polyhedron, dynamic_polyhedron)
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

	if distance_hit and (not earliest_hit or distance_hit.t <= earliest_hit.t) then
		set_cached_pair_axis(static_body, dynamic_body, distance_hit.normal)
		return pair_solver_helpers.ResolveRelativeSweptPairHit(
			static_body,
			dynamic_body,
			static_body:GetPreviousPosition(),
			Vec3(0, 0, 0),
			previous_position,
			movement,
			distance_hit,
			dt,
			false,
			distance_hit.point_a,
			distance_hit.point_b
		)
	end

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(static_body, dynamic_body, previous_position, movement, earliest_hit, dt)
end

local function evaluate_polyhedron_pair_distance_at_transforms(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b, scratch)
	scratch = scratch or {}
	local vertices_a = polyhedron_cache.FillPolyhedronWorldVertices(poly_a, position_a, rotation_a, scratch.vertices_a)
	local vertices_b = polyhedron_cache.FillPolyhedronWorldVertices(poly_b, position_b, rotation_b, scratch.vertices_b)
	scratch.vertices_a = vertices_a
	scratch.vertices_b = vertices_b
	local distance = gjk_epa.Distance(
		vertices_a,
		vertices_b,
		{
			initial_direction = scratch.last_normal or (position_b - position_a),
			simplex = scratch.distance_simplex,
		}
	)
	scratch.distance_simplex = distance and distance.simplex or scratch.distance_simplex

	if distance and distance.normal then
		scratch.last_normal = distance.normal
	elseif distance and distance.delta and distance.delta:GetLength() > EPSILON then
		scratch.last_normal = distance.delta:GetNormalized()
	end

	return distance
end

find_distance_swept_polyhedron_pair_hit = function(body_a, body_b, poly_a, poly_b)
	if not pair_solver_helpers.ShouldUsePairCCD(body_a, body_b) then return false end

	local sweep_a = pair_solver_helpers.GetBodySweepMotion(body_a)
	local sweep_b = pair_solver_helpers.GetBodySweepMotion(body_b)
	local previous_position_a = sweep_a.previous_position
	local previous_position_b = sweep_b.previous_position
	local relative_movement = sweep_a.movement - sweep_b.movement

	if relative_movement:GetLength() <= EPSILON then return false end

	local scratch = {
		vertices_a = {},
		vertices_b = {},
		last_normal = get_cached_pair_axis(body_a, body_b),
	}
	local hit_distance = math.max(
		body_a.GetCollisionMargin and body_a:GetCollisionMargin() or 0,
		body_b.GetCollisionMargin and body_b:GetCollisionMargin() or 0,
		physics_constants.DEFAULT_COLLISION_MARGIN or 0
	)
	local hit = pair_solver_helpers.FindDistanceSweepHit(
		function(t)
			return evaluate_polyhedron_pair_distance_at_transforms(
				poly_a,
				previous_position_a + sweep_a.movement * t,
				sweep_a.previous_rotation,
				poly_b,
				previous_position_b + sweep_b.movement * t,
				sweep_b.previous_rotation,
				scratch
			)
		end,
		hit_distance,
		relative_movement,
		relative_movement:GetLength()
	)

	if not hit or hit.distance > hit_distance + EPSILON then return nil end

	hit.normal = hit.normal or
		select(
			1,
			pair_solver_helpers.GetSafeCollisionNormal(hit.delta, relative_movement, scratch.last_normal)
		)

	if not hit.normal then return nil end

	return hit
end
solve_distance_swept_polyhedron_pair_collision = function(body_a, body_b, poly_a, poly_b, dt)
	local hit = find_distance_swept_polyhedron_pair_hit(body_a, body_b, poly_a, poly_b)

	if not hit then return false end

	local sweep_a = pair_solver_helpers.GetBodySweepMotion(body_a)
	local sweep_b = pair_solver_helpers.GetBodySweepMotion(body_b)
	set_cached_pair_axis(body_a, body_b, hit.normal)
	return pair_solver_helpers.ResolveRelativeSweptPairHit(
		body_a,
		body_b,
		sweep_a.previous_position,
		sweep_a.movement,
		sweep_b.previous_position,
		sweep_b.movement,
		hit,
		dt,
		false,
		hit.point_a,
		hit.point_b
	)
end

local function evaluate_polyhedron_pair_at_transforms(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b, scratch)
	scratch = scratch or {}
	local vertices_a = polyhedron_cache.FillPolyhedronWorldVertices(poly_a, position_a, rotation_a, scratch.vertices_a)
	local vertices_b = polyhedron_cache.FillPolyhedronWorldVertices(poly_b, position_b, rotation_b, scratch.vertices_b)
	scratch.vertices_a = vertices_a
	scratch.vertices_b = vertices_b
	local initial_direction = scratch.last_normal or (position_b - position_a)
	local penetration = gjk_epa.Penetration(
		vertices_a,
		vertices_b,
		{
			initial_direction = initial_direction,
			simplex = scratch.simplex,
		}
	)
	scratch.simplex = penetration and penetration.gjk and penetration.gjk.simplex or scratch.simplex

	if
		penetration and
		penetration.intersect and
		penetration.normal and
		penetration.depth and
		penetration.depth > 0
	then
		scratch.last_normal = penetration.normal
		return {
			overlap = penetration.depth,
			normal = penetration.normal,
			contacts = nil,
			point_a = penetration.point_a or
				convex_manifold.AverageSupportPoint(vertices_a, penetration.normal, true),
			point_b = penetration.point_b or
				convex_manifold.AverageSupportPoint(vertices_b, penetration.normal, false),
			position_a = position_a,
			position_b = position_b,
			rotation_a = rotation_a,
			rotation_b = rotation_b,
		}
	end

	return nil
end

local function intersects_polyhedron_pair_at_transforms(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b, scratch)
	scratch = scratch or {}
	local vertices_a = polyhedron_cache.FillPolyhedronWorldVertices(poly_a, position_a, rotation_a, scratch.vertices_a)
	local vertices_b = polyhedron_cache.FillPolyhedronWorldVertices(poly_b, position_b, rotation_b, scratch.vertices_b)
	scratch.vertices_a = vertices_a
	scratch.vertices_b = vertices_b
	local result = gjk_epa.Intersect(
		vertices_a,
		vertices_b,
		{
			initial_direction = scratch.last_normal or (position_b - position_a),
			simplex = scratch.simplex,
		}
	)
	scratch.simplex = result and result.simplex or scratch.simplex
	return result and result.intersect or false
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
	local sample_steps = pair_solver_helpers.GetTemporalTOISampleSteps(body_a, body_b, 0.125, 14, 64)
	local scratch = {
		vertices_a = {},
		vertices_b = {},
	}
	local hit = pair_solver_helpers.FindSampledTemporalHit(
		function(t)
			local position_a = pair_solver_helpers.InterpolatePosition(previous_position_a, current_position_a, t)
			local rotation_a = pair_solver_helpers.InterpolateRotation(previous_rotation_a, current_rotation_a, t)
			local position_b = pair_solver_helpers.InterpolatePosition(previous_position_b, current_position_b, t)
			local rotation_b = pair_solver_helpers.InterpolateRotation(previous_rotation_b, current_rotation_b, t)

			if
				intersects_polyhedron_pair_at_transforms(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b, scratch)
			then
				return {t = t}
			end

			return nil
		end,
		sample_steps
	)

	if not hit then return nil end

	local hit_t = hit.t or 1
	local result = evaluate_polyhedron_pair_at_transforms(
		poly_a,
		pair_solver_helpers.InterpolatePosition(previous_position_a, current_position_a, hit_t),
		pair_solver_helpers.InterpolateRotation(previous_rotation_a, current_rotation_a, hit_t),
		poly_b,
		pair_solver_helpers.InterpolatePosition(previous_position_b, current_position_b, hit_t),
		pair_solver_helpers.InterpolateRotation(previous_rotation_b, current_rotation_b, hit_t),
		scratch
	)

	if not result then return nil end

	result.t = hit_t
	local vertices_a = polyhedron_cache.FillPolyhedronWorldVertices(poly_a, result.position_a, result.rotation_a, scratch.vertices_a)
	local vertices_b = polyhedron_cache.FillPolyhedronWorldVertices(poly_b, result.position_b, result.rotation_b, scratch.vertices_b)
	result.contacts = build_contacts_from_penetration_result(
		body_a,
		poly_a,
		vertices_a,
		result.rotation_a,
		body_b,
		poly_b,
		vertices_b,
		result.rotation_b,
		result.normal
	)
	return result
end

function polyhedron.SolveTemporalPolyhedronPairCollision(body_a, body_b, poly_a, poly_b, dt)
	if not pair_solver_helpers.ShouldUsePairCCD(body_a, body_b) then return false end

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
	if not pair_solver_helpers.ShouldUsePairCCD(body_a, body_b) then return false end

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

	if relative_movement:GetLength() <= EPSILON then return false end

	local distance_hit = solve_distance_swept_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)

	if distance_hit then return true end

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

local function try_swept_polyhedron_pair_fallback(body_a, body_b, poly_a, poly_b, dt)
	local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

	if static_body == body_a then
		return solve_swept_polyhedron_polyhedron_collision(dynamic_body, poly_b, static_body, poly_a, dt)
	end

	if static_body == body_b then
		return solve_swept_polyhedron_polyhedron_collision(dynamic_body, poly_a, static_body, poly_b, dt)
	end

	return solve_relative_swept_polyhedron_pair_collision(body_a, body_b, poly_a, poly_b, dt)
end

function polyhedron.SolvePolyhedronPairCollision(body_a, body_b, dt)
	local poly_a = body_a:GetBodyPolyhedron()
	local poly_b = body_b:GetBodyPolyhedron()

	if not (poly_a and poly_b and poly_a.vertices and poly_b.vertices) then
		return false
	end

	if body_a:BodyHasSignificantRotation() or body_b:BodyHasSignificantRotation() then
		local temporal = polyhedron.SolveTemporalPolyhedronPairCollision(body_a, body_b, poly_a, poly_b, dt)

		if temporal then return true end
	end

	if pair_solver_helpers.ShouldUsePairCCD(body_a, body_b) then
		local previous_bounds_a = body_a:GetBroadphaseAABB(body_a:GetPreviousPosition(), body_a:GetPreviousRotation())
		local previous_bounds_b = body_b:GetBroadphaseAABB(body_b:GetPreviousPosition(), body_b:GetPreviousRotation())

		if not previous_bounds_a:IsBoxIntersecting(previous_bounds_b) then
			local swept = try_swept_polyhedron_pair_fallback(body_a, body_b, poly_a, poly_b, dt)

			if swept then return true end
		end
	end

	local center_delta = body_b:GetPosition() - body_a:GetPosition()
	local vertices_a = polyhedron.GetPolyhedronWorldVertices(body_a, poly_a)
	local vertices_b = polyhedron.GetPolyhedronWorldVertices(body_b, poly_b)
	local initial_direction = get_cached_pair_axis(body_a, body_b) or center_delta
	local penetration = gjk_epa.Penetration(vertices_a, vertices_b, {
		initial_direction = initial_direction,
	})

	if
		not (
			penetration and
			penetration.intersect and
			penetration.normal and
			penetration.depth and
			penetration.depth > 0
		)
	then
		return try_swept_polyhedron_pair_fallback(body_a, body_b, poly_a, poly_b, dt)
	end

	local best_normal = penetration.normal
	local best_overlap = penetration.depth
	set_cached_pair_axis(body_a, body_b, best_normal)
	local contacts = build_contacts_from_penetration_result(
		body_a,
		poly_a,
		vertices_a,
		body_a:GetRotation(),
		body_b,
		poly_b,
		vertices_b,
		body_b:GetRotation(),
		best_normal
	)
	local point_a = penetration.point_a or
		convex_manifold.AverageSupportPoint(vertices_a, best_normal, true)
	local point_b = penetration.point_b or
		convex_manifold.AverageSupportPoint(vertices_b, best_normal, false)

	if contacts[1] then
		return contact_resolution.ResolvePairPenetration(body_a, body_b, best_normal, best_overlap, dt, nil, nil, contacts)
	end

	return contact_resolution.ResolvePairPenetration(body_a, body_b, best_normal, best_overlap, dt, point_a, point_b)
end

return polyhedron
