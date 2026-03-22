local physics_constants = import("goluwa/physics/constants.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local convex_manifold = import("goluwa/physics/convex_manifold.lua")
local convex_sat = import("goluwa/physics/convex_sat.lua")
local polyhedron_cache = import("goluwa/physics/polyhedron/cache.lua")
local polyhedron_sat = import("goluwa/physics/polyhedron/sat.lua")
local segment_geometry = import("goluwa/physics/segment_geometry.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local helpers = {}
local EPSILON = physics_constants.EPSILON
local POLYHEDRON_SWEEP_MIN_SAMPLE_STEPS = 4
local POLYHEDRON_SWEEP_MAX_SAMPLE_STEPS = 18
local POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT = {
	polyhedron = nil,
	start_position = nil,
	rotation = nil,
	target_polyhedron = nil,
	target_state = nil,
	max_fraction = 0,
	scratch = nil,
	movement = nil,
}
local CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT = {
	radius = 0,
	max_fraction = 0,
	target_state = nil,
	target_collider = nil,
	target_polyhedron = nil,
	start_sample = nil,
	end_sample = nil,
}
local MOVING_TARGET_POINT_SAMPLE_CONTEXT = {
	start_world = nil,
	movement = nil,
	target_state = nil,
	max_fraction = 0,
	evaluate_contact = nil,
	evaluate_contact_context = nil,
	relative_movement = nil,
}

local function clamp01(value)
	return math.max(0, math.min(1, value or 0))
end

function helpers.GetSweepAlpha(t, max_fraction)
	if not max_fraction or math.abs(max_fraction) <= EPSILON then return 0 end

	return clamp01(t / max_fraction)
end

local function interpolate_rotation(previous_rotation, current_rotation, t, max_fraction)
	previous_rotation = previous_rotation or current_rotation
	current_rotation = current_rotation or previous_rotation

	if not previous_rotation then return current_rotation end

	local alpha = helpers.GetSweepAlpha(t, max_fraction)
	local target_rotation = current_rotation

	if previous_rotation:Dot(target_rotation) < 0 then
		target_rotation = target_rotation * -1
	end

	return previous_rotation:GetLerped(alpha, target_rotation):GetNormalized()
end

local function interpolate_position(previous_position, movement, t)
	return previous_position + movement * t
end

function helpers.GetTargetPose(state, t, max_fraction)
	return interpolate_position(state.previous_position, state.movement, t),
	interpolate_rotation(state.previous_rotation, state.current_rotation, t, max_fraction)
end

function helpers.EnsureNormalFacesMotion(normal, movement)
	if not normal then return nil end

	if movement and normal:Dot(movement) > 0 then return normal * -1 end

	return normal
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

local function get_average_contact_positions(contacts)
	if not (contacts and contacts[1]) then return nil, nil end

	local point = Vec3(0, 0, 0)
	local position = Vec3(0, 0, 0)
	local count = 0

	for _, pair in ipairs(contacts) do
		if pair.point_a and pair.point_b then
			point = point + pair.point_a
			position = position + pair.point_b
			count = count + 1
		end
	end

	if count == 0 then return nil, nil end

	return point / count, position / count
end

function helpers.GetPolyhedronPairContactPositions(result, scratch)
	if not result then return nil, nil end

	local point, position = get_average_contact_positions(result.contacts)

	if point and position then return point, position end

	local normal = result.normal
	local vertices_a = scratch and scratch.vertices_a or nil
	local vertices_b = scratch and scratch.vertices_b or nil
	point = point or get_support_point(vertices_a, normal * -1)
	position = position or get_support_point(vertices_b, normal)
	return point, position
end

local function get_polyhedron_extent(polyhedron)
	if not (polyhedron and polyhedron.vertices and polyhedron.vertices[1]) then
		return 1
	end

	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for _, point in ipairs(polyhedron.vertices) do
		min_x = math.min(min_x, point.x)
		min_y = math.min(min_y, point.y)
		min_z = math.min(min_z, point.z)
		max_x = math.max(max_x, point.x)
		max_y = math.max(max_y, point.y)
		max_z = math.max(max_z, point.z)
	end

	return Vec3(max_x - min_x, max_y - min_y, max_z - min_z):GetLength()
end

local function get_polyhedron_sweep_sample_steps(polyhedron, movement_length, max_fraction)
	local extent = math.max(get_polyhedron_extent(polyhedron), 0.25)
	local scaled_length = math.max(0, movement_length * math.max(0, max_fraction or 1))
	return math.max(
		POLYHEDRON_SWEEP_MIN_SAMPLE_STEPS,
		math.min(POLYHEDRON_SWEEP_MAX_SAMPLE_STEPS, math.ceil(scaled_length / (extent * 0.35)))
	)
end

function helpers.EvaluatePolyhedronPairContact(poly_a, position_a, rotation_a, poly_b, position_b, rotation_b, scratch)
	scratch = scratch or {}
	local axes = polyhedron_sat.CollectAxes(poly_a, rotation_a, poly_b, rotation_b, scratch.axes)
	scratch.axes = axes

	if not axes[1] then return nil end

	local vertices_a = polyhedron_cache.FillPolyhedronWorldVertices(poly_a, position_a, rotation_a, scratch.vertices_a)
	local vertices_b = polyhedron_cache.FillPolyhedronWorldVertices(poly_b, position_b, rotation_b, scratch.vertices_b)
	scratch.vertices_a = vertices_a
	scratch.vertices_b = vertices_b

	if polyhedron_sat.HasSeparatingAxis(vertices_a, vertices_b, axes) then
		return nil
	end

	local best = convex_sat.CreateBestAxisTracker()
	local center_delta = position_b - position_a
	polyhedron_sat.UpdateFaceAxisCandidates(best, vertices_a, vertices_b, poly_a, rotation_a, center_delta, "a", EPSILON)
	polyhedron_sat.UpdateFaceAxisCandidates(best, vertices_a, vertices_b, poly_b, rotation_b, center_delta, "b", EPSILON)
	polyhedron_sat.UpdateEdgeAxisCandidates(
		best,
		vertices_a,
		vertices_b,
		poly_a,
		rotation_a,
		poly_b,
		rotation_b,
		center_delta,
		EPSILON
	)
	local chosen = convex_sat.ChoosePreferredAxis(best, 1.05, 0.03)

	if not (chosen and chosen.normal and chosen.overlap and chosen.overlap < math.huge) then
		return nil
	end

	return {
		normal = chosen.normal,
		overlap = chosen.overlap,
		contacts = convex_manifold.BuildAndMergeSupportPairContacts(
			nil,
			vertices_a,
			vertices_b,
			chosen.normal,
			{
				merge_distance = 0.1,
				max_contacts = 4,
			}
		),
	}
end

function helpers.GetPointSweepSampleSteps(movement_length, radius, max_fraction)
	local travel = math.max(0, movement_length * math.max(max_fraction or 0, 0))
	return math.max(8, math.min(40, math.ceil(travel / math.max(radius, 0.125)) * 2))
end

local function find_first_sampled_hit(max_fraction, steps, evaluate_hit, context)
	local start_hit = context ~= nil and evaluate_hit(context, 0) or evaluate_hit(0)

	if start_hit then return 0, start_hit end

	local low = 0
	local high = nil
	local best = nil
	steps = math.max(1, steps or 1)

	for i = 1, steps do
		local t = max_fraction * (i / steps)
		local hit = context ~= nil and evaluate_hit(context, t) or evaluate_hit(t)

		if hit then
			high = t
			best = hit

			break
		end

		low = t
	end

	if not best then return nil end

	for _ = 1, 12 do
		local mid = (low + high) * 0.5
		local mid_hit = context ~= nil and evaluate_hit(context, mid) or evaluate_hit(mid)

		if mid_hit then
			best = mid_hit
			high = mid
		else
			low = mid
		end
	end

	return high, best
end

helpers.FindFirstSampledHit = find_first_sampled_hit

local function sweep_point_against_rotating_target(start_world, movement, max_fraction, steps, evaluate_contact, context)
	local t, hit = find_first_sampled_hit(max_fraction, math.max(6, steps or 12), evaluate_contact, context)

	if not hit then return nil end

	hit.t = t
	return hit
end

local function evaluate_moving_target_point_contact(context, t)
	if t == nil then
		t = context
		context = MOVING_TARGET_POINT_SAMPLE_CONTEXT
	end

	local point = context.start_world + context.movement * t
	local position, rotation = helpers.GetTargetPose(context.target_state, t, context.max_fraction)
	return context.evaluate_contact(
		context.evaluate_contact_context,
		point,
		position,
		rotation,
		context.relative_movement
	)
end

function helpers.SweepSampledPointAgainstMovingTarget(
	start_world,
	movement,
	radius,
	target_state,
	max_fraction,
	steps,
	evaluate_contact,
	evaluate_contact_context
)
	local relative_movement = movement - target_state.movement
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.start_world = start_world
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.movement = movement
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.target_state = target_state
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.max_fraction = max_fraction
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.evaluate_contact = evaluate_contact
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.evaluate_contact_context = evaluate_contact_context
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.relative_movement = relative_movement
	local hit = sweep_point_against_rotating_target(
		start_world,
		movement,
		max_fraction,
		steps,
		evaluate_moving_target_point_contact,
		MOVING_TARGET_POINT_SAMPLE_CONTEXT
	)
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.start_world = nil
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.movement = nil
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.target_state = nil
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.max_fraction = 0
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.evaluate_contact = nil
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.evaluate_contact_context = nil
	MOVING_TARGET_POINT_SAMPLE_CONTEXT.relative_movement = nil
	return hit
end

local function evaluate_polyhedron_body_sweep_sample(context, t)
	if t == nil then
		t = context
		context = POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT
	end

	local target_position_t, target_rotation_t = helpers.GetTargetPose(context.target_state, t, context.max_fraction)
	return helpers.EvaluatePolyhedronPairContact(
		context.polyhedron,
		context.start_position + context.movement * t,
		context.rotation,
		context.target_polyhedron,
		target_position_t,
		target_rotation_t,
		context.scratch
	)
end

function helpers.SweepPolyhedronAgainstTargetPolyhedron(
	query_collider,
	query_polyhedron,
	start_position,
	rotation,
	movement,
	target_collider,
	target_polyhedron,
	target_state,
	max_fraction
)
	local scratch = query_collider.polyhedron_body_sweep_scratch or {}
	query_collider.polyhedron_body_sweep_scratch = scratch
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.polyhedron = query_polyhedron
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.start_position = start_position
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.rotation = rotation
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.target_polyhedron = target_polyhedron
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.target_state = target_state
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.max_fraction = max_fraction
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.scratch = scratch
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.movement = movement
	local hit_t, hit_result = find_first_sampled_hit(
		max_fraction,
		get_polyhedron_sweep_sample_steps(query_polyhedron, movement:GetLength(), max_fraction),
		evaluate_polyhedron_body_sweep_sample,
		POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT
	)
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.polyhedron = nil
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.start_position = nil
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.rotation = nil
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.target_polyhedron = nil
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.target_state = nil
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.max_fraction = 0
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.scratch = nil
	POLYHEDRON_BODY_SWEEP_SAMPLE_CONTEXT.movement = nil

	if not hit_result then return nil end

	local point, position = helpers.GetPolyhedronPairContactPositions(hit_result, scratch)
	return point and
		position and
		{
			t = hit_t,
			point = point,
			position = position,
			normal = hit_result.normal * -1,
		} or
		nil
end

local function collect_capsule_segment_samples(collider, position, rotation, out)
	local a, b, radius = capsule_geometry.GetSegmentWorld(collider, position, rotation)
	local count = math.max(3, math.min(9, math.ceil((b - a):GetLength() / math.max(radius, 0.25)) + 1))
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

function helpers.GetCapsuleMotionSamples(
	collider,
	start_position,
	start_rotation,
	end_position,
	end_rotation,
	previous_cache_key,
	current_cache_key
)
	local previous_samples = collider[previous_cache_key] or {}
	local current_samples = collider[current_cache_key] or {}
	collider[previous_cache_key] = previous_samples
	collider[current_cache_key] = current_samples
	local start_samples, radius = collect_capsule_segment_samples(collider, start_position, start_rotation, previous_samples)
	local end_samples = collect_capsule_segment_samples(collider, end_position, end_rotation, current_samples)
	return start_samples, end_samples, radius
end

local function find_best_capsule_sample_hit(start_samples, end_samples, radius, fallback_delta, select_hit, context)
	local best = nil

	for i, end_sample in ipairs(end_samples) do
		local start_sample = start_samples[i] or (end_sample - fallback_delta)
		local hit = select_hit(context, start_sample, end_sample, radius, i)

		if hit and (not best or hit.t < best.t) then best = hit end
	end

	return best
end

helpers.FindBestCapsuleSampleHit = find_best_capsule_sample_hit

local function evaluate_capsule_polyhedron_target_contact(context, t)
	if t == nil then
		t = context
		context = CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT
	end

	local point = context.start_sample + (
			context.end_sample - context.start_sample
		) * helpers.GetSweepAlpha(t, context.max_fraction)
	local position, rotation_t = helpers.GetTargetPose(context.target_state, t, context.max_fraction)
	return helpers.GetPolyhedronContactForPointAtPose(
		context.target_collider,
		context.target_polyhedron,
		point,
		context.radius,
		position,
		rotation_t,
		context.end_sample - context.start_sample
	)
end

local function select_capsule_polyhedron_body_hit(context, start_sample, end_sample)
	context.start_sample = start_sample
	context.end_sample = end_sample
	local delta = end_sample - start_sample
	local raw_hit = sweep_point_against_rotating_target(
		start_sample,
		delta,
		context.max_fraction,
		helpers.GetPointSweepSampleSteps(delta:GetLength(), context.radius, context.max_fraction),
		evaluate_capsule_polyhedron_target_contact,
		context
	)
	context.start_sample = nil
	context.end_sample = nil

	if not raw_hit then return nil end

	return {
		t = raw_hit.t,
		point = raw_hit.point,
		position = raw_hit.position,
		normal = raw_hit.normal,
	}
end

function helpers.SweepCapsuleAgainstTargetPolyhedron(
	query_collider,
	start_position,
	rotation,
	movement,
	target_collider,
	target_polyhedron,
	target_state,
	max_fraction
)
	local start_points, end_points, radius = helpers.GetCapsuleMotionSamples(
		query_collider,
		start_position,
		rotation,
		start_position + movement * max_fraction,
		rotation,
		"capsule_body_sweep_previous",
		"capsule_body_sweep_current"
	)
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.radius = radius
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.max_fraction = max_fraction
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.target_state = target_state
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.target_collider = target_collider
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.target_polyhedron = target_polyhedron
	local hit = find_best_capsule_sample_hit(
		start_points,
		end_points,
		radius,
		movement * max_fraction,
		select_capsule_polyhedron_body_hit,
		CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT
	)
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.radius = 0
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.max_fraction = 0
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.target_state = nil
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.target_collider = nil
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.target_polyhedron = nil
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.start_sample = nil
	CAPSULE_BODY_POLYHEDRON_SAMPLE_CONTEXT.end_sample = nil
	return hit
end

function helpers.GetPolyhedronContactForPointAtPose(collider, polyhedron, point, radius, position, rotation, movement_world)
	local scratch = collider.point_polyhedron_contact_scratch or {}
	collider.point_polyhedron_contact_scratch = scratch
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
		best_normal = helpers.EnsureNormalFacesMotion((point - position):GetNormalized(), movement_world)
	end

	if not best_normal then return nil end

	return {
		normal = best_normal,
		position = get_support_point(vertices, best_normal),
		point = point - best_normal * radius,
	}
end

function helpers.GetCapsuleContactForPointAtPose(collider, point, radius, position, rotation, movement_world)
	local segment_a, segment_b, capsule_radius = capsule_geometry.GetSegmentWorld(collider, position, rotation)
	local closest = segment_geometry.ClosestPointOnSegment(segment_a, segment_b, point, EPSILON)
	local delta = point - closest
	local distance = delta:GetLength()
	local combined_radius = radius + capsule_radius

	if distance > combined_radius then return nil end

	local normal = distance > EPSILON and
		(
			delta / distance
		)
		or
		helpers.EnsureNormalFacesMotion((point - ((segment_a + segment_b) * 0.5)):GetNormalized(), movement_world)

	if not normal then return nil end

	return {
		normal = normal,
		position = closest + normal * capsule_radius,
		point = point - normal * radius,
	}
end

function helpers.SweepPointAgainstPolyhedronBody(collider, polyhedron, origin, movement, radius, target_state, max_fraction)
	if not (polyhedron and polyhedron.vertices and polyhedron.faces) then
		return nil
	end

	return helpers.SweepSampledPointAgainstMovingTarget(
		origin,
		movement,
		radius,
		target_state,
		max_fraction,
		helpers.GetPointSweepSampleSteps(movement:GetLength(), radius, max_fraction),
		function(context, point, position, rotation, relative_movement)
			return helpers.GetPolyhedronContactForPointAtPose(
				context.collider,
				context.polyhedron,
				point,
				context.radius,
				position,
				rotation,
				relative_movement
			)
		end,
		{
			collider = collider,
			polyhedron = polyhedron,
			radius = radius,
		}
	)
end

return helpers
