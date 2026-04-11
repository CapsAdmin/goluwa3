local physics_constants = import("goluwa/physics/constants.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local segment_geometry = import("goluwa/physics/segment_geometry.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron/cache.lua")
local sweep_helpers = import("goluwa/physics/shapes/sweep_helpers.lua")
local capsule = {}
local EPSILON = physics_constants.EPSILON
local CAPSULE_SWEEP_POINT_SCRATCH = {
	current = {},
	previous = {},
}
local sweep_point_against_capsule_segment
local CAPSULE_BOX_POINT_SCRATCH = {
	current = {},
	previous = {},
}
local CAPSULE_POLYHEDRON_CONTACT_SCRATCH = {
	current = {},
	previous = {},
}
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

local function get_support_point(vertices, direction)
	if not (vertices and vertices[1] and direction) then return nil end

	local best_point = vertices[1]
	local best_dot = best_point:Dot(direction)

	for i = 2, #vertices do
		local point = vertices[i]
		local dot = point:Dot(direction)

		if dot > best_dot then
			best_dot = dot
			best_point = point
		end
	end

	return best_point
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

local function get_capsule_box_best_contact(box_body, samples, previous_samples, radius)
	local best_contact = nil

	for i, sample in ipairs(samples) do
		local previous_sample = previous_samples and previous_samples[i] or sample
		local movement_local

		if previous_sample then
			movement_local = box_body:WorldToLocal(sample) - box_body:WorldToLocal(previous_sample)
		end

		local contact = pair_solver_helpers.GetBoxContactForPoint(box_body, sample, radius, movement_local)

		if contact and (not best_contact or contact.overlap > best_contact.overlap) then
			best_contact = contact
		end
	end

	return best_contact
end

local function get_capsule_polyhedron_contact(polyhedron_body, polyhedron, point, radius, position, rotation, movement_world)
	if not (polyhedron and polyhedron.vertices and polyhedron.faces) then
		return nil
	end

	local scratch = polyhedron_body._PhysicsCapsulePolyhedronContactScratch or {}
	polyhedron_body._PhysicsCapsulePolyhedronContactScratch = scratch
	local vertices = polyhedron_cache.FillPolyhedronWorldVertices(polyhedron, position, rotation, scratch.vertices)
	scratch.vertices = vertices
	local best_distance = -math.huge
	local best_normal = nil

	for _, face in ipairs(polyhedron.faces or {}) do
		local plane_point = vertices[face.indices[1]]
		local normal = rotation:VecMul(face.normal):GetNormalized()
		local distance = normal:Dot(point - plane_point)

		if distance > radius + EPSILON then return nil end

		if distance > best_distance then
			best_distance = distance
			best_normal = normal
		end
	end

	if not best_normal then return nil end

	if best_normal:GetLength() <= EPSILON then
		best_normal = select(
			1,
			pair_solver_helpers.GetSafeCollisionNormal(point - position, movement_world, scratch.last_normal)
		)
	end

	if not best_normal then return nil end

	scratch.last_normal = best_normal
	local overlap = radius - best_distance

	if overlap <= 0 then return nil end

	return {
		normal = best_normal,
		overlap = overlap,
		point_a = get_support_point(vertices, best_normal),
		point_b = point - best_normal * radius,
	}
end

local function get_capsule_polyhedron_best_contact(
	polyhedron_body,
	polyhedron,
	samples,
	previous_samples,
	radius,
	position,
	rotation
)
	local best_contact = nil

	for i, sample in ipairs(samples) do
		local previous_sample = previous_samples and previous_samples[i] or sample
		local movement_world = previous_sample and (sample - previous_sample) or nil
		local contact = get_capsule_polyhedron_contact(
			polyhedron_body,
			polyhedron,
			sample,
			radius,
			position,
			rotation,
			movement_world
		)

		if contact and (not best_contact or contact.overlap > best_contact.overlap) then
			best_contact = contact
		end
	end

	return best_contact
end

local function solve_swept_capsule_polyhedron_collision(dynamic_body, static_body, static_polyhedron, dt)
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

local function solve_capsule_box_collision(capsule_body, box_body, dt)
	local points, radius = iterate_capsule_points(capsule_body, nil, nil, CAPSULE_BOX_POINT_SCRATCH.current)
	local previous_points = iterate_capsule_points(
		capsule_body,
		capsule_body:GetPreviousPosition(),
		capsule_body:GetPreviousRotation(),
		CAPSULE_BOX_POINT_SCRATCH.previous
	)
	local movement = capsule_body:GetPosition() - capsule_body:GetPreviousPosition()
	local previous_contact = nil
	local best_contact = get_capsule_box_best_contact(box_body, points, previous_points, radius)

	if should_prefer_swept_recovery(movement:GetLength(), radius) then
		previous_contact = get_capsule_box_best_contact(box_body, previous_points, nil, radius)

		if not previous_contact then
			local swept = solve_swept_capsule_box_collision(capsule_body, box_body, dt)

			if swept then return swept end
		end
	end

	if not best_contact then
		return solve_swept_capsule_box_collision(capsule_body, box_body, dt)
	end

	return contact_resolution.ResolvePairPenetration(
		box_body,
		capsule_body,
		best_contact.normal,
		best_contact.overlap,
		dt,
		best_contact.point_a,
		best_contact.point_b
	)
end

local function solve_capsule_polyhedron_collision(capsule_body, polyhedron_body, dt)
	local polyhedron_shape = polyhedron_body:GetPhysicsShape()
	local polyhedron = polyhedron_shape and
		polyhedron_shape.GetPolyhedron and
		polyhedron_shape:GetPolyhedron(polyhedron_body) or
		nil

	if not (polyhedron and polyhedron.vertices and polyhedron.faces) then
		return false
	end

	local points, radius = iterate_capsule_points(capsule_body, nil, nil, CAPSULE_POLYHEDRON_CONTACT_SCRATCH.current)
	local previous_points = iterate_capsule_points(
		capsule_body,
		capsule_body:GetPreviousPosition(),
		capsule_body:GetPreviousRotation(),
		CAPSULE_POLYHEDRON_CONTACT_SCRATCH.previous
	)
	local movement = capsule_body:GetPosition() - capsule_body:GetPreviousPosition()
	local best_contact = get_capsule_polyhedron_best_contact(
		polyhedron_body,
		polyhedron,
		points,
		previous_points,
		radius,
		polyhedron_body:GetPosition(),
		polyhedron_body:GetRotation()
	)

	if should_prefer_swept_recovery(movement:GetLength(), radius) then
		local previous_contact = get_capsule_polyhedron_best_contact(
			polyhedron_body,
			polyhedron,
			previous_points,
			nil,
			radius,
			polyhedron_body:GetPreviousPosition(),
			polyhedron_body:GetPreviousRotation()
		)

		if not previous_contact then
			local swept = solve_swept_capsule_polyhedron_collision(capsule_body, polyhedron_body, dt)

			if swept then return swept end
		end
	end

	if not best_contact then
		return solve_swept_capsule_polyhedron_collision(capsule_body, polyhedron_body, dt)
	end

	return contact_resolution.ResolvePairPenetration(
		polyhedron_body,
		capsule_body,
		best_contact.normal,
		best_contact.overlap,
		dt,
		best_contact.point_a,
		best_contact.point_b
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
