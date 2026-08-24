local physics_constants = import("goluwa/physics/constants.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local segment_geometry = import("goluwa/physics/segment_geometry.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron/cache.lua")
local sweep_helpers = import("goluwa/physics/shapes/sweep_helpers.lua")
local gjk_epa = import("goluwa/physics/gjk_epa.lua")
local convex_face_clipping = import("goluwa/physics/convex_face_clipping.lua")
local capsule = {}
local EPSILON = physics_constants.EPSILON
-- positive-separation (speculative) contacts are allowed up to this distance so
-- resting pairs keep a two-point manifold; the solver only holds them while the
-- pair is still closing
local CAPSULE_POLYHEDRON_SPECULATIVE = physics_constants.DEFAULT_COLLISION_MARGIN
-- the GJK normal must be nearly parallel to the reference face normal before
-- clipping produces a two-point manifold (box3d b3CollideHullAndCapsule kTolerance)
local CAPSULE_SHALLOW_FACE_ALIGNMENT = 0.998
-- below this alignment the EPA normal points at an edge; fall back to the
-- witness-point contact instead of clipping
local CAPSULE_DEEP_FACE_ALIGNMENT = 0.5
-- |axisA x axisB| below this means the capsule axes are nearly parallel
local CAPSULE_PARALLEL_CROSS = 0.05
local CAPSULE_MIN_SEGMENT_LENGTH = 0.01
-- feature keys identify which polyhedron face and capsule segment endpoint a
-- contact came from, so the manifold can warm-start impulses by feature pair
-- instead of proximity (box3d b3FeaturePair)
local CAPSULE_FEATURE_WITNESS = 0
local CAPSULE_FEATURE_PARALLEL_BASE = 100
local CAPSULE_SWEEP_POINT_SCRATCH = {
	current = {},
	previous = {},
}
local sweep_point_against_capsule_segment
local solve_swept_capsule_polyhedron_collision
local CAPSULE_BOX_SWEEP_CALLBACK_CONTEXT = {
	box_body = nil,
}
local SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT = {
	segment_a = nil,
	segment_b = nil,
	capsule_radius = 0,
	relative_velocity = nil,
}
local CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT = {
	start_world = nil,
	movement = nil,
	segment_a = nil,
	segment_b = nil,
}
-- per pair scratch: GJK simplex + capsule segment proxy + clip buffers
local CAPSULE_POLYHEDRON_PAIR_SCRATCH = table.weak("k")

local function get_capsule_polyhedron_scratch(capsule_body, polyhedron_body)
	local row = CAPSULE_POLYHEDRON_PAIR_SCRATCH[capsule_body]

	if not row then
		row = table.weak("k")
		CAPSULE_POLYHEDRON_PAIR_SCRATCH[capsule_body] = row
	end

	local scratch = row[polyhedron_body]

	if not scratch then
		local proxy = {Vec3(0, 0, 0), Vec3(0, 0, 0)}
		scratch = {
			proxy = proxy,
			incident = proxy,
			simplex = {},
			clip = {},
			contacts = {},
			last_normal = nil,
		}
		row[polyhedron_body] = scratch
	end

	return scratch
end

local function evaluate_capsule_box_point_sweep(context, start_world, end_world)
	if not (context and context.box_body) then
		end_world = start_world
		start_world = context
		context = CAPSULE_BOX_SWEEP_CALLBACK_CONTEXT
	end

	return pair_solver_helpers.SweepPointAgainstBox(context.box_body, start_world, end_world)
end

local function evaluate_sphere_capsule_point_sweep(context, start_world, end_world)
	if not (context and context.segment_a) then
		end_world = start_world
		start_world = context
		context = SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT
	end

	return sweep_point_against_capsule_segment(
		start_world,
		end_world,
		context.segment_a,
		context.segment_b,
		context.capsule_radius,
		context.relative_velocity
	)
end

local function evaluate_capsule_segment_sweep_distance(context, t)
	local point = context.start_world + context.movement * t
	local closest = segment_geometry.ClosestPointOnSegment(context.segment_a, context.segment_b, point, EPSILON)
	local delta = point - closest
	local distance = delta:GetLength()
	return {
		delta = delta,
		distance = distance,
	}
end

local function evaluate_capsule_segment_point(context, t)
	local point = context.start_world + context.movement * t
	local closest = segment_geometry.ClosestPointOnSegment(context.segment_a, context.segment_b, point, EPSILON)
	local delta = point - closest
	local distance = delta:GetLength()
	return point, closest, delta, distance
end

local function get_capsule_sample_count(radius, a, b)
	local length = (b - a):GetLength()
	return math.max(3, math.min(9, math.ceil(length / math.max(radius, 0.25)) + 1))
end

local function get_oriented_normal(delta, fallback_direction)
	return pair_solver_helpers.GetSafeCollisionNormal(delta, fallback_direction)
end

local function should_prefer_swept_recovery(travel_distance, feature_radius)
	feature_radius = math.max(feature_radius or 0, 0.05)
	return travel_distance > math.max(feature_radius * 0.5, 0.25)
end

local function iterate_capsule_points(body, position, rotation, out)
	local a, b, radius = capsule_geometry.GetSegmentWorld(body, position, rotation)
	local count = get_capsule_sample_count(radius, a, b)
	out = out or {}

	for i = 0, count - 1 do
		local t = count == 1 and 0 or i / (count - 1)
		out[i + 1] = a + (b - a) * t
	end

	for i = count + 1, #out do
		out[i] = nil
	end

	return out, radius
end

function sweep_point_against_capsule_segment(start_world, end_world, segment_a, segment_b, radius, relative_velocity)
	local movement = end_world - start_world

	if movement:GetLength() <= EPSILON then return nil end

	CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.start_world = start_world
	CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.movement = movement
	CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.segment_a = segment_a
	CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.segment_b = segment_b
	local _, _, _, start_distance = evaluate_capsule_segment_point(CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT, 0)

	if start_distance <= radius then
		CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.start_world = nil
		CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.movement = nil
		CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.segment_a = nil
		CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.segment_b = nil
		return nil
	end

	local hit = pair_solver_helpers.FindDistanceSweepHit(
		evaluate_capsule_segment_sweep_distance,
		radius,
		relative_velocity or movement,
		movement:GetLength(),
		nil,
		CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT
	)
	CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.start_world = nil
	CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.movement = nil
	CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.segment_a = nil
	CAPSULE_SEGMENT_SWEEP_EVALUATION_CONTEXT.segment_b = nil

	if hit then
		hit.normal = get_oriented_normal(hit.delta, (relative_velocity or movement) * -1)
		return hit
	end

	return nil
end

local function solve_swept_capsule_box_collision(capsule_body, box_body, dt)
	if not pair_solver_helpers.ShouldUsePairCCD(capsule_body, box_body) then
		return false
	end

	if not pair_solver_helpers.IsSolverImmovable(box_body) then return false end

	local sweep = pair_solver_helpers.GetBodySweepMotion(capsule_body)
	local previous_position = sweep.previous_position
	local current_position = sweep.current_position
	local movement = sweep.movement

	if movement:GetLength() <= EPSILON then return false end

	local current_points, radius = iterate_capsule_points(capsule_body, nil, nil, CAPSULE_SWEEP_POINT_SCRATCH.current)
	local previous_points = iterate_capsule_points(
		capsule_body,
		previous_position,
		capsule_body:GetPreviousRotation(),
		CAPSULE_SWEEP_POINT_SCRATCH.previous
	)
	local earliest_hit

	for i, sample in ipairs(current_points) do
		local previous_sample = previous_points[i] or sample
		local hit = pair_solver_helpers.SweepPointAgainstBox(box_body, previous_sample, sample, radius)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = hit
		end
	end

	if not earliest_hit then
		CAPSULE_BOX_SWEEP_CALLBACK_CONTEXT.box_body = box_body
		earliest_hit = pair_solver_helpers.FindEarliestBodyPointSweepHit(
			capsule_body,
			previous_position,
			sweep.previous_rotation,
			current_position,
			sweep.current_rotation,
			capsule_body:GetCollisionLocalPoints(),
			evaluate_capsule_box_point_sweep,
			earliest_hit,
			CAPSULE_BOX_SWEEP_CALLBACK_CONTEXT
		)
		CAPSULE_BOX_SWEEP_CALLBACK_CONTEXT.box_body = nil
	end

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(box_body, capsule_body, previous_position, movement, earliest_hit, dt)
end

local function solve_swept_capsule_sphere_collision(capsule_body, sphere_body, dt)
	if not pair_solver_helpers.ShouldUsePairCCD(capsule_body, sphere_body) then
		return false
	end

	if
		not pair_solver_helpers.IsSolverImmovable(sphere_body) or
		not pair_solver_helpers.HasSolverMass(capsule_body)
	then
		return false
	end

	local sweep = pair_solver_helpers.GetBodySweepMotion(capsule_body)
	local previous_position = sweep.previous_position
	local current_position = sweep.current_position
	local movement = sweep.movement

	if movement:GetLength() <= EPSILON then return false end

	local sphere_center = sphere_body:GetPosition()
	local sphere_radius = sphere_body:GetPhysicsShape():GetRadius()
	local capsule_radius = capsule_geometry.GetCapsuleShape(capsule_body):GetRadius()
	local combined_radius = capsule_radius + sphere_radius
	local relative_velocity = sphere_body:GetVelocity() - capsule_body:GetVelocity()

	if not capsule_body:BodyHasSignificantRotation() then
		local static_a, static_b = capsule_geometry.GetSegmentWorld(capsule_body, previous_position, sweep.previous_rotation)
		local hit = sweep_point_against_capsule_segment(
			sphere_center,
			sphere_center - movement,
			static_a,
			static_b,
			combined_radius,
			relative_velocity
		)

		if hit then
			return pair_solver_helpers.ResolveSweptHit(
				sphere_body,
				capsule_body,
				previous_position,
				movement,
				{
					t = hit.t,
					normal = hit.normal * -1,
				},
				dt
			)
		end
	end

	local start_a, start_b = capsule_geometry.GetSegmentWorld(capsule_body, previous_position, sweep.previous_rotation)
	local end_a, end_b = capsule_geometry.GetSegmentWorld(capsule_body)

	local function evaluate(t)
		local segment_a = start_a + (end_a - start_a) * t
		local segment_b = start_b + (end_b - start_b) * t
		local closest = segment_geometry.ClosestPointOnSegment(segment_a, segment_b, sphere_center, EPSILON)
		local delta = sphere_center - closest
		local distance = delta:GetLength()
		return {
			delta = delta,
			distance = distance,
		}
	end

	local start_distance = evaluate(0).distance

	if start_distance <= combined_radius then return false end

	local hit = pair_solver_helpers.FindDistanceSweepHit(evaluate, combined_radius, relative_velocity, movement:GetLength())

	if hit then
		local normal = get_oriented_normal(hit.delta * -1, sphere_body:GetVelocity() - capsule_body:GetVelocity())
		return pair_solver_helpers.ResolveSweptHit(
			sphere_body,
			capsule_body,
			previous_position,
			movement,
			{
				t = hit.t,
				normal = normal,
			},
			dt
		)
	end

	return false
end

local function solve_swept_sphere_capsule_collision(sphere_body, capsule_body, dt)
	if not pair_solver_helpers.ShouldUsePairCCD(sphere_body, capsule_body) then
		return false
	end

	if
		not pair_solver_helpers.IsSolverImmovable(capsule_body) or
		not pair_solver_helpers.HasSolverMass(sphere_body)
	then
		return false
	end

	local sweep = pair_solver_helpers.GetBodySweepMotion(sphere_body)
	local previous_position = sweep.previous_position
	local current_position = sweep.current_position
	local movement = sweep.movement

	if movement:GetLength() <= EPSILON then return false end

	local segment_a, segment_b, capsule_radius = capsule_geometry.GetSegmentWorld(capsule_body)
	SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT.segment_a = segment_a
	SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT.segment_b = segment_b
	SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT.capsule_radius = capsule_radius
	SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT.relative_velocity = sphere_body:GetVelocity() - capsule_body:GetVelocity()
	local earliest_hit = pair_solver_helpers.FindEarliestBodyPointSweepHit(
		sphere_body,
		previous_position,
		sweep.previous_rotation,
		current_position,
		sweep.current_rotation,
		sphere_body:GetCollisionLocalPoints(),
		evaluate_sphere_capsule_point_sweep,
		nil,
		SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT
	)
	SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT.segment_a = nil
	SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT.segment_b = nil
	SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT.capsule_radius = 0
	SPHERE_CAPSULE_SWEEP_CALLBACK_CONTEXT.relative_velocity = nil

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(capsule_body, sphere_body, previous_position, movement, earliest_hit, dt)
end

local function solve_swept_capsule_capsule_collision(dynamic_body, static_body, dt)
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

	local start_a, start_b, dynamic_radius = capsule_geometry.GetSegmentWorld(dynamic_body, previous_position, sweep.previous_rotation)
	local end_a, end_b = capsule_geometry.GetSegmentWorld(dynamic_body)
	local static_a, static_b, static_radius = capsule_geometry.GetSegmentWorld(static_body)
	local combined_radius = dynamic_radius + static_radius
	local relative_velocity = static_body:GetVelocity() - dynamic_body:GetVelocity()

	local function evaluate(t)
		local dynamic_a = start_a + (end_a - start_a) * t
		local dynamic_b = start_b + (end_b - start_b) * t
		local point_dynamic, point_static = segment_geometry.ClosestPointsBetweenSegments(dynamic_a, dynamic_b, static_a, static_b, EPSILON)
		local delta = point_static - point_dynamic
		local distance = delta:GetLength()
		return {
			point_dynamic = point_dynamic,
			point_static = point_static,
			delta = delta,
			distance = distance,
		}
	end

	local start_distance = evaluate(0).distance

	if start_distance <= combined_radius then return false end

	local hit = pair_solver_helpers.FindDistanceSweepHit(evaluate, combined_radius, relative_velocity, movement:GetLength())

	if hit then
		local normal = get_oriented_normal(hit.delta * -1, static_body:GetVelocity() - dynamic_body:GetVelocity())
		return pair_solver_helpers.ResolveSweptHit(
			static_body,
			dynamic_body,
			previous_position,
			movement,
			{
				t = hit.t,
				normal = normal,
			},
			dt
		)
	end

	return false
end

local function solve_capsule_sphere_collision(capsule_body, sphere_body, dt)
	local a, b, capsule_radius = capsule_geometry.GetSegmentWorld(capsule_body)
	local sphere_center = sphere_body:GetPosition()
	local closest = segment_geometry.ClosestPointOnSegment(a, b, sphere_center, EPSILON)
	local delta = sphere_center - closest
	local previous_sphere_center = sphere_body:GetPreviousPosition()
	local previous_a, previous_b = capsule_geometry.GetSegmentWorld(
		capsule_body,
		capsule_body:GetPreviousPosition(),
		capsule_body:GetPreviousRotation()
	)
	local previous_closest = segment_geometry.ClosestPointOnSegment(previous_a, previous_b, previous_sphere_center, EPSILON)
	local sphere_radius = sphere_body:GetPhysicsShape():GetRadius()
	local min_distance = capsule_radius + sphere_radius
	local normal, distance = pair_solver_helpers.GetSafeCollisionNormal(
		delta,
		capsule_body:GetVelocity() - sphere_body:GetVelocity(),
		previous_sphere_center - previous_closest,
		pair_solver_helpers.GetCachedPairNormal(capsule_body, sphere_body)
	)

	if not normal then return false end

	local overlap = min_distance - distance

	if overlap <= 0 then
		if pair_solver_helpers.IsSolverImmovable(sphere_body) then
			return solve_swept_capsule_sphere_collision(capsule_body, sphere_body, dt)
		end

		if pair_solver_helpers.IsSolverImmovable(capsule_body) then
			return solve_swept_sphere_capsule_collision(sphere_body, capsule_body, dt)
		end

		return false
	end

	return contact_resolution.ResolvePairPenetration(
		capsule_body,
		sphere_body,
		normal,
		overlap,
		dt,
		closest + normal * capsule_radius,
		sphere_center - normal * sphere_radius
	)
end

-- Clips the capsule segment against the reference face of the polyhedron and
-- emits one contact per surviving vertex (up to two). The segment is the
-- incident polygon, so the clipped result is at most the two segment
-- endpoints, possibly with interpolated points on the face boundary.
local function build_capsule_face_contacts(polyhedron_body, polyhedron, face_index, face_normal, radius, scratch)
	local face = polyhedron_cache.GetPolyhedronWorldFace(polyhedron_body, polyhedron, face_index)

	if not (face and face.points and face.points[1]) then return nil end

	local reference_face = convex_face_clipping.BuildReferenceFace(face.points, face_normal, nil, nil, scratch.clip)

	if not reference_face then return nil end

	local clipped = convex_face_clipping.ClipIncidentPolygonToReferenceFace(reference_face, scratch.incident, scratch.clip)
	local contacts = scratch.contacts
	local count = 0

	for _, local_point in ipairs(clipped or {}) do
		-- the clipped point sits on the capsule segment; the surface point that
		-- touches the face is a full radius below it (box3d: distance - radius)
		local separation = local_point.z - radius
		count = count + 1
		local contact = contacts[count] or {}
		contact.point_a = reference_face.center + reference_face.tangent_u * local_point.x + reference_face.tangent_v * local_point.y
		contact.point_b = contact.point_a + face_normal * separation
		contact.separation = separation
		contact.feature_key = face_index * 2 + count
		contacts[count] = contact
	end

	return list.clear_from_index(contacts, count + 1)
end

local function get_capsule_face_depths(contacts, speculative)
	local best_depth

	for _, contact in ipairs(contacts or {}) do
		local depth = -contact.separation

		if depth > -speculative and (not best_depth or depth > best_depth) then
			best_depth = depth
		end
	end

	return best_depth
end

local function find_best_face_index(polyhedron, rotation, normal)
	local best_index
	local best_alignment

	for face_index, face in ipairs(polyhedron.faces) do
		local alignment = rotation:VecMul(face.normal):Dot(normal)

		if not best_alignment or alignment > best_alignment then
			best_alignment = alignment
			best_index = face_index
		end
	end

	return best_index, best_alignment
end

local function build_single_contact(scratch, point_a, point_b, separation, feature_key)
	local contacts = scratch.contacts
	local contact = contacts[1] or {}
	contact.point_a = point_a
	contact.point_b = point_b
	contact.separation = separation
	contact.feature_key = feature_key or CAPSULE_FEATURE_WITNESS
	contacts[1] = contact
	return list.clear_from_index(contacts, 2)
end

-- The capsule is treated as an analytic segment with a radius, the same way
-- box3d collides hull-and-capsule: GJK/EPA on the two segment endpoints plus
-- reference-face clipping. No point sampling of the capsule surface.
local function solve_capsule_polyhedron_core(capsule_body, polyhedron_body, polyhedron, dt)
	local scratch = get_capsule_polyhedron_scratch(capsule_body, polyhedron_body)
	local vertices = polyhedron_cache.GetPolyhedronWorldVertices(polyhedron_body, polyhedron)
	local segment_a, segment_b, radius = capsule_geometry.GetSegmentWorld(capsule_body)
	local proxy = scratch.proxy
	proxy[1]:CopyFrom(segment_a)
	proxy[2]:CopyFrom(segment_b)
	local initial_direction = scratch.last_normal or
		(
			capsule_body:GetPosition() - polyhedron_body:GetPosition()
		)
	local distance = gjk_epa.Distance(vertices, proxy, initial_direction, scratch.simplex)
	scratch.simplex = distance and distance.simplex or scratch.simplex

	if not distance then return false end

	local max_distance = radius + CAPSULE_POLYHEDRON_SPECULATIVE

	if not distance.intersect and (distance.distance or 0) > max_distance then
		return solve_swept_capsule_polyhedron_collision(capsule_body, polyhedron_body, polyhedron, dt)
	end

	local normal
	local overlap
	local contacts
	local rotation = polyhedron_body:GetRotation()

	if not distance.intersect and (distance.distance or 0) > EPSILON * 100 then
		-- Shallow penetration: the GJK witness points are exact
		normal = distance.normal
		overlap = radius - distance.distance

		if not normal or overlap <= 0 then
			return solve_swept_capsule_polyhedron_collision(capsule_body, polyhedron_body, polyhedron, dt)
		end

		local face_index, alignment = find_best_face_index(polyhedron, rotation, normal)

		if face_index and alignment >= CAPSULE_SHALLOW_FACE_ALIGNMENT then
			local face = polyhedron_cache.GetPolyhedronWorldFace(polyhedron_body, polyhedron, face_index)
			local face_normal = face.normal:GetNormalized()
			local face_contacts = build_capsule_face_contacts(polyhedron_body, polyhedron, face_index, face_normal, radius, scratch)
			local best_depth = get_capsule_face_depths(face_contacts, CAPSULE_POLYHEDRON_SPECULATIVE)

			if best_depth and best_depth > 0 then
				contacts = face_contacts
				normal = face_normal
				overlap = math.max(overlap, best_depth)
			end
		end

		if not contacts then
			contacts = build_single_contact(scratch, distance.point_a, distance.point_b - normal * radius, -overlap)
		end
	else
		-- Deep penetration: EPA gives the minimum translation axis
		local penetration = gjk_epa.Penetration(vertices, proxy, initial_direction, scratch.simplex)
		scratch.simplex = penetration and penetration.gjk and penetration.gjk.simplex or scratch.simplex

		if
			penetration and
			penetration.intersect and
			penetration.normal and
			penetration.depth and
			penetration.depth > 0
		then
			normal = penetration.normal
			overlap = penetration.depth
			local face_index, alignment = find_best_face_index(polyhedron, rotation, normal)

			if face_index and alignment >= CAPSULE_DEEP_FACE_ALIGNMENT then
				local face = polyhedron_cache.GetPolyhedronWorldFace(polyhedron_body, polyhedron, face_index)
				local face_normal = face.normal:GetNormalized()
				local face_contacts = build_capsule_face_contacts(polyhedron_body, polyhedron, face_index, face_normal, radius, scratch)
				local best_depth = get_capsule_face_depths(face_contacts, CAPSULE_POLYHEDRON_SPECULATIVE)

				if best_depth and best_depth > 0 then
					contacts = face_contacts
					normal = face_normal
					overlap = math.max(overlap, best_depth)
				end
			end

			if not contacts then
				contacts = build_single_contact(scratch, penetration.point_a, penetration.point_b - normal * radius, -overlap)
			end
		else
			normal = distance.normal
			overlap = radius - (distance.distance or 0)

			if not normal or overlap <= 0 then
				return solve_swept_capsule_polyhedron_collision(capsule_body, polyhedron_body, polyhedron, dt)
			end

			contacts = build_single_contact(scratch, distance.point_a, distance.point_b - normal * radius, -overlap)
		end
	end

	scratch.last_normal = normal
	return contact_resolution.ResolvePairPenetration(polyhedron_body, capsule_body, normal, overlap, dt, nil, nil, contacts)
end

solve_swept_capsule_polyhedron_collision = function(dynamic_body, static_body, static_polyhedron, dt)
	if not pair_solver_helpers.ShouldUsePairCCD(dynamic_body, static_body) then
		return false
	end

	if
		not pair_solver_helpers.IsSolverImmovable(static_body) or
		not pair_solver_helpers.HasSolverMass(dynamic_body)
	then
		return false
	end

	local dynamic_collider = dynamic_body:GetColliders()[1]
	local static_collider = static_body:GetColliders()[1]

	if not (dynamic_collider and static_collider) then return false end

	local dynamic_sweep = pair_solver_helpers.GetBodySweepMotion(dynamic_body)
	local static_sweep = pair_solver_helpers.GetBodySweepMotion(static_body)

	if
		dynamic_sweep.movement:GetLength() <= EPSILON and
		static_sweep.movement:GetLength() <= EPSILON
	then
		return false
	end

	local hit = sweep_helpers.SweepCapsuleAgainstTargetPolyhedron(
		dynamic_collider,
		dynamic_sweep.previous_position,
		dynamic_sweep.previous_rotation,
		dynamic_sweep.movement,
		static_collider,
		static_polyhedron,
		{
			previous_position = static_sweep.previous_position,
			current_position = static_sweep.current_position,
			movement = static_sweep.movement,
			previous_rotation = static_sweep.previous_rotation,
			current_rotation = static_sweep.current_rotation,
		},
		1
	)

	if not hit then return false end

	return pair_solver_helpers.ResolveRelativeSweptPairHit(
		static_body,
		dynamic_body,
		static_sweep.previous_position,
		static_sweep.movement,
		dynamic_sweep.previous_position,
		dynamic_sweep.movement,
		hit,
		dt,
		false,
		hit.position,
		hit.point
	)
end

local function get_capsule_polyhedron(body)
	local shape = body:GetPhysicsShape()
	local polyhedron = shape and shape.GetPolyhedron and shape:GetPolyhedron(body) or nil

	if not (polyhedron and polyhedron.vertices and polyhedron.faces) then
		return nil
	end

	return polyhedron
end

local function solve_capsule_box_collision(capsule_body, box_body, dt)
	local polyhedron = get_capsule_polyhedron(box_body)

	if not polyhedron then return false end

	return solve_capsule_polyhedron_core(capsule_body, box_body, polyhedron, dt)
end

local function solve_capsule_polyhedron_collision(capsule_body, polyhedron_body, dt)
	local polyhedron = get_capsule_polyhedron(polyhedron_body)

	if not polyhedron then return false end

	return solve_capsule_polyhedron_core(capsule_body, polyhedron_body, polyhedron, dt)
end

-- Nearly parallel capsules: clip segment B against the side planes of
-- segment A so the manifold gets two stable contact points instead of one
-- that flips side to side (box3d b3CollideCapsules parallel branch)
local function build_capsule_capsule_parallel_contacts(a0, a1, b0, b1, radius_a, radius_b)
	local axis_a = a1 - a0
	local length_a = axis_a:GetLength()
	local axis_b = b1 - b0
	local length_b = axis_b:GetLength()
	local min_segment = CAPSULE_MIN_SEGMENT_LENGTH * CAPSULE_MIN_SEGMENT_LENGTH

	if length_a * length_a <= min_segment or length_b * length_b <= min_segment then
		return nil
	end

	local cross = axis_a:GetCross(axis_b)

	if cross:Dot(cross) >= CAPSULE_PARALLEL_CROSS * CAPSULE_PARALLEL_CROSS then
		return nil
	end

	local u = axis_a / length_a
	local w = axis_b
	local s0 = (b0 - a0):Dot(u)
	local sw = w:Dot(u)
	local t_enter = 0
	local t_exit = 1

	if sw > 0 then
		t_enter = math.max(t_enter, (0 - s0) / sw)
		t_exit = math.min(t_exit, (length_a - s0) / sw)
	else
		t_enter = math.max(t_enter, (length_a - s0) / sw)
		t_exit = math.min(t_exit, (0 - s0) / sw)
	end

	if t_enter >= t_exit then return nil end

	local min_distance = radius_a + radius_b
	local point_b_1 = b0 + w * t_enter
	local point_b_2 = b0 + w * t_exit
	local closest_1 = segment_geometry.ClosestPointOnSegment(a0, a1, point_b_1, EPSILON)
	local closest_2 = segment_geometry.ClosestPointOnSegment(a0, a1, point_b_2, EPSILON)
	local delta_1 = point_b_1 - closest_1
	local distance_1 = delta_1:GetLength()
	local delta_2 = point_b_2 - closest_2
	local distance_2 = delta_2:GetLength()

	if
		distance_1 > min_distance or
		distance_2 > min_distance or
		distance_1 <= EPSILON or
		distance_2 <= EPSILON
	then
		return nil
	end

	local normal = (delta_1 / distance_1 + delta_2 / distance_2):GetNormalized()
	local overlap = min_distance - math.min(distance_1, distance_2)

	if overlap <= 0 then return nil end

	local contacts = {}
	local contact_1 = {}
	contact_1.point_a = closest_1 + normal * radius_a
	contact_1.point_b = point_b_1 - normal * radius_b
	contact_1.separation = distance_1 - min_distance
	contact_1.feature_key = CAPSULE_FEATURE_PARALLEL_BASE + 1
	contacts[1] = contact_1
	local contact_2 = {}
	contact_2.point_a = closest_2 + normal * radius_a
	contact_2.point_b = point_b_2 - normal * radius_b
	contact_2.separation = distance_2 - min_distance
	contact_2.feature_key = CAPSULE_FEATURE_PARALLEL_BASE + 2
	contacts[2] = contact_2
	return contacts, normal, overlap
end

local function solve_capsule_capsule_collision(body_a, body_b, dt)
	local a0, a1, radius_a = capsule_geometry.GetSegmentWorld(body_a)
	local b0, b1, radius_b = capsule_geometry.GetSegmentWorld(body_b)
	local point_a, point_b = segment_geometry.ClosestPointsBetweenSegments(a0, a1, b0, b1, EPSILON)
	local delta = point_b - point_a
	local previous_a0, previous_a1 = capsule_geometry.GetSegmentWorld(body_a, body_a:GetPreviousPosition(), body_a:GetPreviousRotation())
	local previous_b0, previous_b1 = capsule_geometry.GetSegmentWorld(body_b, body_b:GetPreviousPosition(), body_b:GetPreviousRotation())
	local previous_point_a, previous_point_b = segment_geometry.ClosestPointsBetweenSegments(previous_a0, previous_a1, previous_b0, previous_b1, EPSILON)
	local min_distance = radius_a + radius_b
	local normal, distance = pair_solver_helpers.GetSafeCollisionNormal(
		delta,
		body_a:GetVelocity() - body_b:GetVelocity(),
		previous_point_b - previous_point_a,
		pair_solver_helpers.GetCachedPairNormal(body_a, body_b)
	)

	if not normal then return false end

	local overlap = min_distance - distance
	local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)
	local movement = dynamic_body and
		(
			dynamic_body:GetPosition() - dynamic_body:GetPreviousPosition()
		)
		or
		nil

	if overlap <= 0 then
		if static_body then
			return solve_swept_capsule_capsule_collision(dynamic_body, static_body, dt)
		end

		return false
	end

	local parallel_contacts, parallel_normal, parallel_overlap = build_capsule_capsule_parallel_contacts(a0, a1, b0, b1, radius_a, radius_b)

	if parallel_contacts then
		return contact_resolution.ResolvePairPenetration(
			body_a,
			body_b,
			parallel_normal,
			parallel_overlap,
			dt,
			nil,
			nil,
			parallel_contacts
		)
	end

	if
		static_body and
		movement and
		should_prefer_swept_recovery(movement:GetLength(), math.min(radius_a, radius_b))
	then
		local previous_distance = (previous_point_b - previous_point_a):GetLength()

		if previous_distance > min_distance + EPSILON then
			local swept = solve_swept_capsule_capsule_collision(dynamic_body, static_body, dt)

			if swept then return swept end
		end
	end

	return contact_resolution.ResolvePairPenetration(
		body_a,
		body_b,
		normal,
		overlap,
		dt,
		point_a + normal * radius_a,
		point_b - normal * radius_b
	)
end

function capsule.SolveCapsuleSpherePair(body_a, body_b, _, _, dt)
	return solve_capsule_sphere_collision(body_a, body_b, dt)
end

function capsule.SolveSphereCapsulePair(body_a, body_b, _, _, dt)
	return solve_capsule_sphere_collision(body_b, body_a, dt)
end

function capsule.SolveCapsuleCapsulePair(body_a, body_b, _, _, dt)
	return solve_capsule_capsule_collision(body_a, body_b, dt)
end

function capsule.SolveCapsuleBoxPair(body_a, body_b, _, _, dt)
	return solve_capsule_box_collision(body_a, body_b, dt)
end

function capsule.SolveBoxCapsulePair(body_a, body_b, _, _, dt)
	return solve_capsule_box_collision(body_b, body_a, dt)
end

function capsule.SolveCapsuleConvexPair(body_a, body_b, _, _, dt)
	return solve_capsule_polyhedron_collision(body_a, body_b, dt)
end

function capsule.SolveConvexCapsulePair(body_a, body_b, _, _, dt)
	return solve_capsule_polyhedron_collision(body_b, body_a, dt)
end

return capsule
