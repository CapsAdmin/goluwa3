local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics = import("goluwa/physics.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local pair_solver_helpers = {}
local axis_data = {
	{"x", Vec3(-1, 0, 0), Vec3(1, 0, 0)},
	{"y", Vec3(0, -1, 0), Vec3(0, 1, 0)},
	{"z", Vec3(0, 0, -1), Vec3(0, 0, 1)},
}
local CCD_MIN_SAMPLE_STEPS = 12
local CCD_MAX_SAMPLE_STEPS = 96
local CCD_REFINE_STEPS = 14
local TEMPORAL_TOI_MIN_SAMPLE_STEPS = 10
local TEMPORAL_TOI_MAX_SAMPLE_STEPS = 48
local TEMPORAL_TOI_REFINE_STEPS = 12

local function normalize_candidate(vec)
	if not vec then return nil, 0 end

	local length = vec:GetLength()

	if length <= physics.EPSILON then return nil, 0 end

	return vec / length, length
end

function pair_solver_helpers.IsSolverImmovable(body)
	return body.IsSolverImmovable and body:IsSolverImmovable() or false
end

function pair_solver_helpers.HasSolverMass(body)
	return body.HasSolverMass and body:HasSolverMass() or false
end

function pair_solver_helpers.IsSimpleBody(collider_list)
	collider_list = collider_list or {}

	if #collider_list ~= 1 then return false end

	local collider = collider_list[1]
	local local_position = collider:GetLocalPosition()
	local local_rotation = collider:GetLocalRotation()
	return local_position:GetLength() <= physics.EPSILON and
		math.abs(local_rotation.x) <= physics.EPSILON and
		math.abs(local_rotation.y) <= physics.EPSILON and
		math.abs(local_rotation.z) <= physics.EPSILON and
		math.abs(local_rotation.w - 1) <= physics.EPSILON
end

function pair_solver_helpers.TryInvokePairHandler(solver, body_a, body_b, entry_a, entry_b, dt)
	local shape_a = body_a:GetShapeType()
	local shape_b = body_b:GetShapeType()
	local handler = solver:GetPairHandler(shape_a, shape_b)

	if handler then return handler(body_a, body_b, entry_a, entry_b, dt), true end

	solver:WarnMissingPairHandler(shape_a, shape_b)
	return false, false
end

function pair_solver_helpers.DispatchColliderPairs(solver, colliders_a, colliders_b, entry_a, entry_b, dt)
	local handled = false

	for _, collider_a in ipairs(colliders_a or {}) do
		for _, collider_b in ipairs(colliders_b or {}) do
			if physics.ShouldBodiesCollide(collider_a, collider_b) then
				local result, found = pair_solver_helpers.TryInvokePairHandler(solver, collider_a, collider_b, entry_a, entry_b, dt)

				if found and result then handled = true end
			end
		end
	end

	return handled
end

function pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)
	if
		pair_solver_helpers.IsSolverImmovable(body_a) and
		pair_solver_helpers.HasSolverMass(body_b)
	then
		return body_a, body_b
	end

	if
		pair_solver_helpers.IsSolverImmovable(body_b) and
		pair_solver_helpers.HasSolverMass(body_a)
	then
		return body_b, body_a
	end

	return nil, nil
end

function pair_solver_helpers.GetCachedPairNormal(body_a, body_b)
	if not (body_a and body_b) then return nil end

	local collision_pairs = physics.collision_pairs

	if not collision_pairs then return nil end

	local pair, swapped = collision_pairs:GetCachedPair(body_a, body_b)

	if not (pair and pair.normal) then return nil end

	local normal = swapped and pair.normal * -1 or pair.normal
	return normalize_candidate(normal)
end

function pair_solver_helpers.GetSafeCollisionNormal(delta, relative_velocity, fallback_delta, fallback_normal)
	local normal, distance = normalize_candidate(delta)

	if normal then return normal, distance end

	normal = select(1, normalize_candidate(fallback_delta))

	if normal then return normal, 0 end

	normal = select(1, normalize_candidate(fallback_normal))

	if normal then return normal, 0 end

	normal = select(1, normalize_candidate(relative_velocity))

	if normal then return normal, 0 end

	return nil, 0
end

function pair_solver_helpers.FindEarliestBodyPointSweepHit(
	body,
	previous_position,
	previous_rotation,
	current_position,
	current_rotation,
	local_points,
	evaluate_hit,
	best_hit,
	evaluate_context
)
	local_points = local_points or body:GetCollisionLocalPoints() or {}
	current_position = current_position or body:GetPosition()
	current_rotation = current_rotation or body:GetRotation()

	for _, local_point in ipairs(local_points) do
		local start_world = body:GeometryLocalToWorld(local_point, previous_position, previous_rotation)
		local end_world = body:GeometryLocalToWorld(local_point, current_position, current_rotation)
		local hit = evaluate_context ~= nil and
			evaluate_hit(evaluate_context, start_world, end_world, local_point) or
			evaluate_hit(start_world, end_world, local_point)

		if hit and (not best_hit or hit.t < best_hit.t) then best_hit = hit end
	end

	return best_hit
end

function pair_solver_helpers.GetBodySweepMotion(body)
	local previous_position = body:GetPreviousPosition()
	local previous_rotation = body:GetPreviousRotation()
	local current_position = body:GetPosition()
	local current_rotation = body:GetRotation()
	return {
		previous_position = previous_position,
		previous_rotation = previous_rotation,
		current_position = current_position,
		current_rotation = current_rotation,
		movement = current_position - previous_position,
	}
end

function pair_solver_helpers.InterpolatePosition(previous, current, t)
	return previous + (current - previous) * t
end

function pair_solver_helpers.InterpolateRotation(previous, current, t)
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

function pair_solver_helpers.GetBodyMotionScale(body)
	local linear = (body:GetPosition() - body:GetPreviousPosition()):GetLength()
	local dot = math.min(1, math.max(-1, math.abs(body:GetPreviousRotation():Dot(body:GetRotation()))))
	local angular = math.acos(dot) * 2
	local bounds = body:GetBroadphaseAABB()
	local extent = Vec3(
			bounds.max_x - bounds.min_x,
			bounds.max_y - bounds.min_y,
			bounds.max_z - bounds.min_z
		):GetLength() * 0.5
	return linear + extent * angular
end

function pair_solver_helpers.GetTemporalTOISampleSteps(body_a, body_b, distance_scale, min_steps, max_steps)
	distance_scale = distance_scale or 0.25
	min_steps = min_steps or TEMPORAL_TOI_MIN_SAMPLE_STEPS
	max_steps = max_steps or TEMPORAL_TOI_MAX_SAMPLE_STEPS
	local motion_scale = math.max(pair_solver_helpers.GetBodyMotionScale(body_a), pair_solver_helpers.GetBodyMotionScale(body_b))
	return math.max(min_steps, math.min(max_steps, math.ceil(motion_scale / distance_scale) * 2))
end

function pair_solver_helpers.FindSampledTemporalHit(evaluate, sample_steps, refine_steps)
	local start_result = evaluate(0)

	if start_result then return nil end

	refine_steps = refine_steps or TEMPORAL_TOI_REFINE_STEPS
	local previous_t = 0

	for i = 1, sample_steps do
		local sample_t = i / sample_steps
		local result = evaluate(sample_t)

		if result then
			local low = previous_t
			local high = sample_t
			local best = result

			for _ = 1, refine_steps do
				local mid = (low + high) * 0.5
				local mid_result = evaluate(mid)

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

		previous_t = sample_t
	end

	return nil
end

function pair_solver_helpers.GetCCDSampleSteps(path_length, distance_scale)
	distance_scale = math.max(distance_scale or 0.25, 0.05)
	return math.max(
		CCD_MIN_SAMPLE_STEPS,
		math.min(CCD_MAX_SAMPLE_STEPS, math.ceil(path_length / distance_scale) * 2)
	)
end

function pair_solver_helpers.RefineDistanceSweepHit(evaluate, hit_distance, low, high, evaluate_context)

	local best_t = high
	local best_result = evaluate_context ~= nil and evaluate(evaluate_context, high) or evaluate(high)

	for _ = 1, CCD_REFINE_STEPS do
		local mid = (low + high) * 0.5
		local result = evaluate_context ~= nil and evaluate(evaluate_context, mid) or evaluate(mid)

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

function pair_solver_helpers.FindDistanceTimeOfImpact(evaluate, hit_distance, relative_velocity, path_length, evaluate_context)
	local start_result = evaluate_context ~= nil and evaluate(evaluate_context, 0) or evaluate(0)

	if start_result.distance <= hit_distance then return nil end

	local sample_steps = pair_solver_helpers.GetCCDSampleSteps(path_length, hit_distance)
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

		local next_result = evaluate_context ~= nil and evaluate(evaluate_context, next_t) or evaluate(next_t)

		if next_result.distance <= hit_distance then
			return pair_solver_helpers.RefineDistanceSweepHit(evaluate, hit_distance, t, next_t, evaluate_context)
		end

		local midpoint_t = (t + next_t) * 0.5
		local midpoint_result = evaluate_context ~= nil and evaluate(evaluate_context, midpoint_t) or evaluate(midpoint_t)

		if midpoint_result.distance <= hit_distance then
			return pair_solver_helpers.RefineDistanceSweepHit(evaluate, hit_distance, t, midpoint_t, evaluate_context)
		end

		t = next_t
		current = next_result

		if t >= 1 - physics.EPSILON then break end
	end

	local previous_t = 0

	for i = 1, sample_steps do
		local sample_t = i / sample_steps
		local result = evaluate_context ~= nil and evaluate(evaluate_context, sample_t) or evaluate(sample_t)

		if result.distance <= hit_distance then
			return pair_solver_helpers.RefineDistanceSweepHit(evaluate, hit_distance, previous_t, sample_t, evaluate_context)
		end

		previous_t = sample_t
	end

	return nil
end

function pair_solver_helpers.FindSampledDistanceThresholdHit(evaluate, hit_distance, sample_steps, evaluate_context)
	sample_steps = sample_steps or 12
	local previous_t = 0

	for i = 1, sample_steps do
		local sample_t = i / sample_steps
		local result = evaluate_context ~= nil and evaluate(evaluate_context, sample_t) or evaluate(sample_t)

		if result.distance <= hit_distance then
			return pair_solver_helpers.RefineDistanceSweepHit(evaluate, hit_distance, previous_t, sample_t, evaluate_context)
		end

		previous_t = sample_t
	end

	return nil
end

function pair_solver_helpers.FindDistanceSweepHit(evaluate, hit_distance, relative_velocity, path_length, sample_steps, evaluate_context)
	local hit = pair_solver_helpers.FindDistanceTimeOfImpact(evaluate, hit_distance, relative_velocity, path_length, evaluate_context)

	if hit then return hit end

	return pair_solver_helpers.FindSampledDistanceThresholdHit(evaluate, hit_distance, sample_steps, evaluate_context)
end

function pair_solver_helpers.SweepPointAgainstBox(box_body, start_world, end_world, extra_radius)
	local movement_world = end_world - start_world

	if movement_world:GetLength() <= physics.EPSILON then return nil end

	local start_local = box_body:WorldToLocal(start_world)
	local end_local = box_body:WorldToLocal(end_world)
	local movement_local = end_local - start_local
	local extents = box_body:GetPhysicsShape():GetExtents()
	extra_radius = math.max(extra_radius or 0, 0)
	local t_enter = 0
	local t_exit = 1
	local hit_normal_local = nil

	for _, axis in ipairs(axis_data) do
		local name = axis[1]
		local s = start_local[name]
		local d = movement_local[name]
		local min_value = -extents[name] - extra_radius
		local max_value = extents[name] + extra_radius

		if math.abs(d) <= physics.EPSILON then
			if s < min_value or s > max_value then return nil end
		else
			local enter_t
			local exit_t
			local enter_normal

			if d > 0 then
				enter_t = (min_value - s) / d
				exit_t = (max_value - s) / d
				enter_normal = axis[2]
			else
				enter_t = (max_value - s) / d
				exit_t = (min_value - s) / d
				enter_normal = axis[3]
			end

			if enter_t > t_enter then
				t_enter = enter_t
				hit_normal_local = enter_normal
			end

			if exit_t < t_exit then t_exit = exit_t end

			if t_enter > t_exit then return nil end
		end
	end

	if not hit_normal_local or t_enter < 0 or t_enter > 1 then return nil end

	return {
		t = t_enter,
		normal_local = hit_normal_local,
		normal = box_body:GetRotation():VecMul(hit_normal_local):GetNormalized(),
	}
end

function pair_solver_helpers.GetBoxContactForPoint(box_body, point, radius, movement_local)
	local local_point = box_body:WorldToLocal(point)
	local extents = box_body:GetPhysicsShape():GetExtents()
	local closest_local = Vec3(
		math.clamp(local_point.x, -extents.x, extents.x),
		math.clamp(local_point.y, -extents.y, extents.y),
		math.clamp(local_point.z, -extents.z, extents.z)
	)
	local closest_world = box_body:LocalToWorld(closest_local)
	local delta = point - closest_world
	local distance = delta:GetLength()
	local overlap = radius - distance
	local normal

	if distance > physics.EPSILON then
		normal = delta / distance
	elseif
		math.abs(local_point.x) <= extents.x and
		math.abs(local_point.y) <= extents.y and
		math.abs(local_point.z) <= extents.z
	then
		local candidates = {
			{
				name = "x",
				axis = Vec3(1, 0, 0),
				center = local_point.x,
				movement = movement_local and movement_local.x or 0,
				overlap = extents.x - math.abs(local_point.x),
			},
			{
				name = "y",
				axis = Vec3(0, 1, 0),
				center = local_point.y,
				movement = movement_local and movement_local.y or 0,
				overlap = extents.y - math.abs(local_point.y),
			},
			{
				name = "z",
				axis = Vec3(0, 0, 1),
				center = local_point.z,
				movement = movement_local and movement_local.z or 0,
				overlap = extents.z - math.abs(local_point.z),
			},
		}
		local best

		for _, candidate in ipairs(candidates) do
			local sign = math.sign(candidate.center)

			if sign == 0 then
				if math.abs(candidate.movement) > physics.EPSILON then
					sign = math.sign(-candidate.movement)
				else
					sign = 1
				end
			end

			candidate.axis = candidate.axis * sign
			candidate.motion_weight = math.abs(candidate.movement)

			if
				not best or
				candidate.overlap < best.overlap - physics.EPSILON or
				(
					math.abs(candidate.overlap - best.overlap) <= physics.EPSILON and
					candidate.motion_weight > best.motion_weight + physics.EPSILON
				)
			then
				best = candidate
			end
		end

		if best.name == "x" then
			closest_local = Vec3(best.axis.x * extents.x, local_point.y, local_point.z)
		elseif best.name == "y" then
			closest_local = Vec3(local_point.x, best.axis.y * extents.y, local_point.z)
		else
			closest_local = Vec3(local_point.x, local_point.y, best.axis.z * extents.z)
		end

		closest_world = box_body:LocalToWorld(closest_local)
		normal = box_body:GetRotation():VecMul(best.axis):GetNormalized()
		overlap = radius + best.overlap
	else
		return nil
	end

	if overlap <= 0 then return nil end

	return {
		normal = normal,
		overlap = overlap,
		point_a = closest_world,
		point_b = point - normal * radius,
	}
end

function pair_solver_helpers.SweepPointAgainstPolyhedron(static_body, polyhedron, start_world, end_world, extra_radius, position, rotation)
	local movement_world = end_world - start_world

	if movement_world:GetLength() <= physics.EPSILON then return nil end

	position = position or static_body:GetPosition()
	rotation = rotation or static_body:GetRotation()
	local start_local = static_body:WorldToLocal(start_world, position, rotation)
	local end_local = static_body:WorldToLocal(end_world, position, rotation)
	local movement_local = end_local - start_local
	local t_enter = 0
	local t_exit = 1
	local hit_normal_local = nil
	extra_radius = extra_radius or 0

	for _, face in ipairs(polyhedron.faces or {}) do
		local plane_point = polyhedron.vertices[face.indices[1]]
		local plane_distance = face.normal:Dot(plane_point) + extra_radius
		local start_distance = face.normal:Dot(start_local) - plane_distance
		local delta_distance = face.normal:Dot(movement_local)

		if math.abs(delta_distance) <= physics.EPSILON then
			if start_distance > 0 then return nil end
		else
			local hit_t = -start_distance / delta_distance

			if delta_distance < 0 then
				if hit_t > t_enter then
					t_enter = hit_t
					hit_normal_local = face.normal
				end
			else
				if hit_t < t_exit then t_exit = hit_t end
			end

			if t_enter > t_exit then return nil end
		end
	end

	if not hit_normal_local or t_enter < 0 or t_enter > 1 then return nil end

	return {
		t = t_enter,
		normal = rotation:VecMul(hit_normal_local):GetNormalized(),
	}
end

function pair_solver_helpers.ResolveSweptHit(
	static_body,
	dynamic_body,
	start_world,
	movement_world,
	hit,
	dt,
	allow_remaining_motion
)
	local hit_fraction = math.max(0, math.min(1, hit.t))
	local normal = hit.normal
	dynamic_body.Position = start_world + movement_world * math.max(0, hit_fraction - physics.EPSILON)
	contact_resolution.ApplyPairImpulse(static_body, dynamic_body, normal, dt)
	contact_resolution.MarkPairGrounding(static_body, dynamic_body, normal)
	physics.collision_pairs:RecordCollisionPair(static_body, dynamic_body, normal, 0)

	if allow_remaining_motion then
		local remaining_fraction = 1 - hit_fraction

		if remaining_fraction > physics.EPSILON then
			local post_velocity = dynamic_body:GetVelocity()
			dynamic_body.Position = dynamic_body.Position + post_velocity * (dt * remaining_fraction)
			dynamic_body.PreviousPosition = dynamic_body.Position - post_velocity * dt
		end
	end

	return true, hit_fraction, normal
end

function pair_solver_helpers.ResolveRelativeSweptPairHit(
	body_a,
	body_b,
	start_a,
	move_a,
	start_b,
	move_b,
	hit,
	dt,
	allow_remaining_motion,
	point_a,
	point_b
)
	local hit_fraction = math.max(0, math.min(1, hit.t))
	local safe_fraction = math.max(0, hit_fraction - physics.EPSILON)
	local normal = hit.normal
	body_a.Position = start_a + move_a * safe_fraction
	body_b.Position = start_b + move_b * safe_fraction
	contact_resolution.ApplyPairImpulse(body_a, body_b, normal, dt, point_a, point_b)
	contact_resolution.MarkPairGrounding(body_a, body_b, normal)
	physics.collision_pairs:RecordCollisionPair(body_a, body_b, normal, 0)

	if allow_remaining_motion then
		local remaining_fraction = 1 - hit_fraction

		if remaining_fraction > physics.EPSILON then
			local velocity_a = body_a:GetVelocity()
			local velocity_b = body_b:GetVelocity()
			body_a.Position = body_a.Position + velocity_a * (dt * remaining_fraction)
			body_a.PreviousPosition = body_a.Position - velocity_a * dt
			body_b.Position = body_b.Position + velocity_b * (dt * remaining_fraction)
			body_b.PreviousPosition = body_b.Position - velocity_b * dt
		end
	end

	return true, hit_fraction, normal
end

return pair_solver_helpers
