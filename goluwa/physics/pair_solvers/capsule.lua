local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local solver = import("goluwa/physics/solver.lua")
local shape_accessors = import("goluwa/physics/shape_accessors.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local capsule = {}

local CCD_MIN_SAMPLE_STEPS = 12
local CCD_MAX_SAMPLE_STEPS = 96
local CCD_REFINE_STEPS = 14
local CAPSULE_SWEEP_POINT_SCRATCH = {
	current = {},
	previous = {},
}
local CAPSULE_BOX_POINT_SCRATCH = {
	current = {},
	previous = {},
}

local function get_capsule_shape(body)
	local shape = body:GetPhysicsShape()
	return shape and shape.GetTypeName and shape:GetTypeName() == "capsule" and shape or nil
end

local function get_capsule_segment(body, position, rotation)
	local shape = get_capsule_shape(body)

	if not shape then return nil, nil, 0 end

	return body:LocalToWorld(shape:GetBottomSphereCenterLocal(), position, rotation),
	body:LocalToWorld(shape:GetTopSphereCenterLocal(), position, rotation),
	shape:GetRadius()
end

local function closest_point_on_segment(a, b, point)
	local ab = b - a
	local denom = ab:Dot(ab)

	if denom <= physics.EPSILON then return a, 0 end

	local t = math.clamp((point - a):Dot(ab) / denom, 0, 1)
	return a + ab * t, t
end

local function closest_points_between_segments(p1, q1, p2, q2)
	local d1 = q1 - p1
	local d2 = q2 - p2
	local r = p1 - p2
	local a = d1:Dot(d1)
	local e = d2:Dot(d2)
	local f = d2:Dot(r)
	local s
	local t

	if a <= physics.EPSILON and e <= physics.EPSILON then return p1, p2 end

	if a <= physics.EPSILON then
		s = 0
		t = math.clamp(f / e, 0, 1)
	else
		local c = d1:Dot(r)

		if e <= physics.EPSILON then
			t = 0
			s = math.clamp(-c / a, 0, 1)
		else
			local b = d1:Dot(d2)
			local denom = a * e - b * b

			if denom ~= 0 then
				s = math.clamp((b * f - c * e) / denom, 0, 1)
			else
				s = 0
			end

			t = (b * s + f) / e

			if t < 0 then
				t = 0
				s = math.clamp(-c / a, 0, 1)
			elseif t > 1 then
				t = 1
				s = math.clamp((b - c) / a, 0, 1)
			end
		end
	end

	return p1 + d1 * s, p2 + d2 * t
end

local function get_capsule_sample_count(radius, a, b)
	local length = (b - a):GetLength()
	return math.max(3, math.min(9, math.ceil(length / math.max(radius, 0.25)) + 1))
end

local function get_ccd_sample_steps(path_length, distance_scale)
	distance_scale = math.max(distance_scale or 0.25, 0.05)
	return math.max(
		CCD_MIN_SAMPLE_STEPS,
		math.min(CCD_MAX_SAMPLE_STEPS, math.ceil(path_length / distance_scale) * 2)
	)
end

local function get_oriented_normal(delta, fallback_direction)
	return select(1, pair_solver_helpers.GetSafeCollisionNormal(delta, fallback_direction))
end

local function should_prefer_swept_recovery(travel_distance, feature_radius)
	feature_radius = math.max(feature_radius or 0, 0.05)
	return travel_distance > math.max(feature_radius * 0.5, 0.25)
end

local function iterate_capsule_points(body, position, rotation, out)
	local a, b, radius = get_capsule_segment(body, position, rotation)
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

local function refine_sweep_hit(evaluate, hit_distance, low, high)
	local best_t = high
	local best_result = evaluate(high)

	for _ = 1, CCD_REFINE_STEPS do
		local mid = (low + high) * 0.5
		local result = evaluate(mid)

		if result.distance <= hit_distance then
			best_t = mid
			best_result = result
			high = mid
		else
			low = mid
		end
	end

	best_result.t = best_t
	return best_result
end

local function find_distance_time_of_impact(evaluate, hit_distance, relative_velocity, path_length)
	local start_result = evaluate(0)

	if start_result.distance <= hit_distance then return nil end

	local sample_steps = get_ccd_sample_steps(path_length, hit_distance)
	local t = 0
	local current = start_result

	for _ = 1, sample_steps do
		local normal = select(1, pair_solver_helpers.GetSafeCollisionNormal(current.delta, relative_velocity))
		local approach_speed = math.max(0, -(relative_velocity or Vec3(0, 0, 0)):Dot(normal))
		local next_t

		if approach_speed > physics.EPSILON then
			next_t = math.min(
				1,
				t + math.max((current.distance - hit_distance) / approach_speed, 1 / sample_steps)
			)
		else
			next_t = math.min(1, t + (1 / sample_steps))
		end

		if next_t <= t + physics.EPSILON then break end

		local next_result = evaluate(next_t)

		if next_result.distance <= hit_distance then
			return refine_sweep_hit(evaluate, hit_distance, t, next_t)
		end

		local midpoint_t = (t + next_t) * 0.5
		local midpoint_result = evaluate(midpoint_t)

		if midpoint_result.distance <= hit_distance then
			return refine_sweep_hit(evaluate, hit_distance, t, midpoint_t)
		end

		t = next_t
		current = next_result

		if t >= 1 - physics.EPSILON then break end
	end

	local previous_t = 0

	for i = 1, sample_steps do
		local sample_t = i / sample_steps
		local result = evaluate(sample_t)

		if result.distance <= hit_distance then
			return refine_sweep_hit(evaluate, hit_distance, previous_t, sample_t)
		end

		previous_t = sample_t
	end

	return nil
end

local function sweep_point_against_capsule_segment(start_world, end_world, segment_a, segment_b, radius, relative_velocity)
	local movement = end_world - start_world

	if movement:GetLength() <= physics.EPSILON then return nil end

	local function evaluate(t)
		local point = start_world + movement * t
		local closest = closest_point_on_segment(segment_a, segment_b, point)
		local delta = point - closest
		local distance = delta:GetLength()
		return point, closest, delta, distance
	end

	local _, _, _, start_distance = evaluate(0)

	if start_distance <= radius then return nil end

	local hit = find_distance_time_of_impact(
		function(t)
			local _, _, delta, distance = evaluate(t)
			return {
				delta = delta,
				distance = distance,
			}
		end,
		radius,
		relative_velocity or movement,
		movement:GetLength()
	)

	if hit then
		hit.normal = get_oriented_normal(hit.delta, (relative_velocity or movement) * -1)
		return hit
	end

	local sample_steps = 12
	local previous_t = 0

	for i = 1, sample_steps do
		local t = i / sample_steps
		local _, _, _, distance = evaluate(t)

		if distance <= radius then
			local low = previous_t
			local high = t

			for _ = 1, 12 do
				local mid = (low + high) * 0.5
				local _, _, _, mid_distance = evaluate(mid)

				if mid_distance <= radius then high = mid else low = mid end
			end

			local _, _, delta, final_distance = evaluate(high)
			local normal = get_oriented_normal(delta, (relative_velocity or movement) * -1)
			return {
				t = high,
				normal = normal,
				distance = final_distance,
			}
		end

		previous_t = t
	end

	return nil
end

local function solve_swept_capsule_box_collision(capsule_body, box_body, dt)
	if not pair_solver_helpers.IsSolverImmovable(box_body) then return false end

	local previous_position = capsule_body:GetPreviousPosition()
	local current_position = capsule_body:GetPosition()
	local movement = current_position - previous_position

	if movement:GetLength() <= physics.EPSILON then return false end

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
		for _, local_point in ipairs(capsule_body:GetCollisionLocalPoints()) do
			local start_world = capsule_body:GeometryLocalToWorld(local_point, previous_position, capsule_body:GetPreviousRotation())
			local end_world = capsule_body:GeometryLocalToWorld(local_point)
			local hit = pair_solver_helpers.SweepPointAgainstBox(box_body, start_world, end_world)

			if hit and (not earliest_hit or hit.t < earliest_hit.t) then
				earliest_hit = hit
			end
		end
	end

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(box_body, capsule_body, previous_position, movement, earliest_hit, dt)
end

local function solve_swept_capsule_sphere_collision(capsule_body, sphere_body, dt)
	if
		not pair_solver_helpers.IsSolverImmovable(sphere_body) or
		not pair_solver_helpers.HasSolverMass(capsule_body)
	then
		return false
	end

	local previous_position = capsule_body:GetPreviousPosition()
	local current_position = capsule_body:GetPosition()
	local movement = current_position - previous_position

	if movement:GetLength() <= physics.EPSILON then return false end

	local sphere_center = sphere_body:GetPosition()
	local sphere_radius = sphere_body:GetPhysicsShape():GetRadius()
	local capsule_radius = get_capsule_shape(capsule_body):GetRadius()
	local combined_radius = capsule_radius + sphere_radius
	local relative_velocity = sphere_body:GetVelocity() - capsule_body:GetVelocity()

	if not shape_accessors.BodyHasSignificantRotation(capsule_body) then
		local static_a, static_b = get_capsule_segment(capsule_body, previous_position, capsule_body:GetPreviousRotation())
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

	local start_a, start_b = get_capsule_segment(capsule_body, previous_position, capsule_body:GetPreviousRotation())
	local end_a, end_b = get_capsule_segment(capsule_body)

	local function evaluate(t)
		local segment_a = start_a + (end_a - start_a) * t
		local segment_b = start_b + (end_b - start_b) * t
		local closest = closest_point_on_segment(segment_a, segment_b, sphere_center)
		local delta = sphere_center - closest
		local distance = delta:GetLength()
		return {
			delta = delta,
			distance = distance,
		}
	end

	local start_distance = evaluate(0).distance

	if start_distance <= combined_radius then return false end

	local hit = find_distance_time_of_impact(evaluate, combined_radius, relative_velocity, movement:GetLength())

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

	local sample_steps = 12
	local previous_t = 0

	for i = 1, sample_steps do
		local t = i / sample_steps
		local distance = evaluate(t).distance

		if distance <= combined_radius then
			local low = previous_t
			local high = t

			for _ = 1, 12 do
				local mid = (low + high) * 0.5
				local mid_distance = evaluate(mid).distance

				if mid_distance <= combined_radius then
					high = mid
				else
					low = mid
				end
			end

			local delta = evaluate(high).delta
			local normal = get_oriented_normal(delta * -1, sphere_body:GetVelocity() - capsule_body:GetVelocity())
			return pair_solver_helpers.ResolveSweptHit(
				sphere_body,
				capsule_body,
				previous_position,
				movement,
				{
					t = high,
					normal = normal,
				},
				dt
			)
		end

		previous_t = t
	end

	return false
end

local function solve_swept_sphere_capsule_collision(sphere_body, capsule_body, dt)
	if
		not pair_solver_helpers.IsSolverImmovable(capsule_body) or
		not pair_solver_helpers.HasSolverMass(sphere_body)
	then
		return false
	end

	local previous_position = sphere_body:GetPreviousPosition()
	local current_position = sphere_body:GetPosition()
	local movement = current_position - previous_position

	if movement:GetLength() <= physics.EPSILON then return false end

	local segment_a, segment_b, capsule_radius = get_capsule_segment(capsule_body)
	local earliest_hit

	for _, local_point in ipairs(sphere_body:GetCollisionLocalPoints()) do
		local start_world = sphere_body:GeometryLocalToWorld(local_point, previous_position, sphere_body:GetPreviousRotation())
		local end_world = sphere_body:GeometryLocalToWorld(local_point)
		local hit = sweep_point_against_capsule_segment(
			start_world,
			end_world,
			segment_a,
			segment_b,
			capsule_radius,
			sphere_body:GetVelocity() - capsule_body:GetVelocity()
		)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = hit
		end
	end

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(capsule_body, sphere_body, previous_position, movement, earliest_hit, dt)
end

local function solve_swept_capsule_capsule_collision(dynamic_body, static_body, dt)
	if
		not pair_solver_helpers.IsSolverImmovable(static_body) or
		not pair_solver_helpers.HasSolverMass(dynamic_body)
	then
		return false
	end

	local previous_position = dynamic_body:GetPreviousPosition()
	local current_position = dynamic_body:GetPosition()
	local movement = current_position - previous_position

	if movement:GetLength() <= physics.EPSILON then return false end

	local start_a, start_b, dynamic_radius = get_capsule_segment(dynamic_body, previous_position, dynamic_body:GetPreviousRotation())
	local end_a, end_b = get_capsule_segment(dynamic_body)
	local static_a, static_b, static_radius = get_capsule_segment(static_body)
	local combined_radius = dynamic_radius + static_radius
	local relative_velocity = static_body:GetVelocity() - dynamic_body:GetVelocity()

	local function evaluate(t)
		local dynamic_a = start_a + (end_a - start_a) * t
		local dynamic_b = start_b + (end_b - start_b) * t
		local point_dynamic, point_static = closest_points_between_segments(dynamic_a, dynamic_b, static_a, static_b)
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

	local hit = find_distance_time_of_impact(evaluate, combined_radius, relative_velocity, movement:GetLength())

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

	local sample_steps = 12
	local previous_t = 0

	for i = 1, sample_steps do
		local t = i / sample_steps
		local distance = evaluate(t).distance

		if distance <= combined_radius then
			local low = previous_t
			local high = t

			for _ = 1, 12 do
				local mid = (low + high) * 0.5
				local mid_distance = evaluate(mid).distance

				if mid_distance <= combined_radius then
					high = mid
				else
					low = mid
				end
			end

			local delta = evaluate(high).delta
			local normal = get_oriented_normal(delta * -1, static_body:GetVelocity() - dynamic_body:GetVelocity())
			return pair_solver_helpers.ResolveSweptHit(
				static_body,
				dynamic_body,
				previous_position,
				movement,
				{
					t = high,
					normal = normal,
				},
				dt
			)
		end

		previous_t = t
	end

	return false
end

local function solve_capsule_sphere_collision(capsule_body, sphere_body, dt)
	local a, b, capsule_radius = get_capsule_segment(capsule_body)
	local sphere_center = sphere_body:GetPosition()
	local closest = closest_point_on_segment(a, b, sphere_center)
	local delta = sphere_center - closest
	local sphere_radius = sphere_body:GetPhysicsShape():GetRadius()
	local min_distance = capsule_radius + sphere_radius
	local normal, distance = pair_solver_helpers.GetSafeCollisionNormal(delta, capsule_body:GetVelocity() - sphere_body:GetVelocity())
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
	local a0, a1, radius_a = get_capsule_segment(body_a)
	local b0, b1, radius_b = get_capsule_segment(body_b)
	local point_a, point_b = closest_points_between_segments(a0, a1, b0, b1)
	local delta = point_b - point_a
	local min_distance = radius_a + radius_b
	local normal, distance = pair_solver_helpers.GetSafeCollisionNormal(delta, body_a:GetVelocity() - body_b:GetVelocity())
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
		local previous_a0, previous_a1 = get_capsule_segment(body_a, body_a:GetPreviousPosition(), body_a:GetPreviousRotation())
		local previous_b0, previous_b1 = get_capsule_segment(body_b, body_b:GetPreviousPosition(), body_b:GetPreviousRotation())
		local previous_point_a, previous_point_b = closest_points_between_segments(previous_a0, previous_a1, previous_b0, previous_b1)
		local previous_distance = (previous_point_b - previous_point_a):GetLength()

		if previous_distance > min_distance + physics.EPSILON then
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

local function solve_capsule_sphere_pair_handler(body_a, body_b, _, _, dt)
	return solve_capsule_sphere_collision(body_a, body_b, dt)
end

local function solve_sphere_capsule_pair_handler(body_a, body_b, _, _, dt)
	return solve_capsule_sphere_collision(body_b, body_a, dt)
end

local function solve_capsule_capsule_pair_handler(body_a, body_b, _, _, dt)
	return solve_capsule_capsule_collision(body_a, body_b, dt)
end

local function solve_capsule_box_pair_handler(body_a, body_b, _, _, dt)
	return solve_capsule_box_collision(body_a, body_b, dt)
end

local function solve_box_capsule_pair_handler(body_a, body_b, _, _, dt)
	return solve_capsule_box_collision(body_b, body_a, dt)
end

solver:RegisterPairHandler("capsule", "sphere", solve_capsule_sphere_pair_handler)
solver:RegisterPairHandler("sphere", "capsule", solve_sphere_capsule_pair_handler)
solver:RegisterPairHandler("capsule", "capsule", solve_capsule_capsule_pair_handler)
solver:RegisterPairHandler("capsule", "box", solve_capsule_box_pair_handler)
solver:RegisterPairHandler("box", "capsule", solve_box_capsule_pair_handler)
return capsule