local Vec3 = import("goluwa/structs/vec3.lua")
local solver = import("goluwa/physics/solver.lua")
local physics_solver = import("goluwa/physics/solver.lua")
local shape_accessors = import("goluwa/physics/shape_accessors.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local capsule = {}
local EPSILON = physics_solver.EPSILON or 0.00001

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

	if denom <= EPSILON then return a, 0 end

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

	if a <= EPSILON and e <= EPSILON then return p1, p2 end

	if a <= EPSILON then
		s = 0
		t = math.clamp(f / e, 0, 1)
	else
		local c = d1:Dot(r)

		if e <= EPSILON then
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

local function iterate_capsule_points(body, position, rotation)
	local a, b, radius = get_capsule_segment(body, position, rotation)
	local count = get_capsule_sample_count(radius, a, b)
	local points = {}

	for i = 0, count - 1 do
		local t = count == 1 and 0 or i / (count - 1)
		points[#points + 1] = {
			point = a + (b - a) * t,
			t = t,
		}
	end

	return points, radius
end

local function sweep_point_against_capsule_segment(start_world, end_world, segment_a, segment_b, radius, relative_velocity)
	local movement = end_world - start_world

	if movement:GetLength() <= EPSILON then return nil end

	local function evaluate(t)
		local point = start_world + movement * t
		local closest = closest_point_on_segment(segment_a, segment_b, point)
		local delta = point - closest
		local distance = delta:GetLength()
		return point, closest, delta, distance
	end

	local _, _, _, start_distance = evaluate(0)

	if start_distance <= radius then return nil end

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
			local normal = select(
				1,
				pair_solver_helpers.GetSafeCollisionNormal(delta, relative_velocity or movement)
			)
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

	if movement:GetLength() <= EPSILON then return false end

	local earliest_hit

	for _, local_point in ipairs(capsule_body:GetCollisionLocalPoints()) do
		local start_world = capsule_body:GeometryLocalToWorld(local_point, previous_position, capsule_body:GetPreviousRotation())
		local end_world = capsule_body:GeometryLocalToWorld(local_point)
		local hit = pair_solver_helpers.SweepPointAgainstBox(box_body, start_world, end_world)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = hit
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

	if movement:GetLength() <= EPSILON then return false end

	local sphere_center = sphere_body:GetPosition()
	local sphere_radius = sphere_body:GetPhysicsShape():GetRadius()
	local start_a, start_b = get_capsule_segment(capsule_body, previous_position, capsule_body:GetPreviousRotation())
	local end_a, end_b = get_capsule_segment(capsule_body)

	local function evaluate(t)
		local segment_a = start_a + (end_a - start_a) * t
		local segment_b = start_b + (end_b - start_b) * t
		local closest = closest_point_on_segment(segment_a, segment_b, sphere_center)
		local delta = sphere_center - closest
		local distance = delta:GetLength()
		return delta, distance
	end

	local _, start_distance = evaluate(0)

	if start_distance <= sphere_radius then return false end

	local sample_steps = 12
	local previous_t = 0

	for i = 1, sample_steps do
		local t = i / sample_steps
		local _, distance = evaluate(t)

		if distance <= sphere_radius then
			local low = previous_t
			local high = t

			for _ = 1, 12 do
				local mid = (low + high) * 0.5
				local _, mid_distance = evaluate(mid)

				if mid_distance <= sphere_radius then
					high = mid
				else
					low = mid
				end
			end

			local delta = select(1, evaluate(high))
			local normal = select(
				1,
				pair_solver_helpers.GetSafeCollisionNormal(delta * -1, capsule_body:GetVelocity() - sphere_body:GetVelocity())
			)
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

	if movement:GetLength() <= EPSILON then return false end

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

	if movement:GetLength() <= EPSILON then return false end

	local start_a, start_b, dynamic_radius = get_capsule_segment(dynamic_body, previous_position, dynamic_body:GetPreviousRotation())
	local end_a, end_b = get_capsule_segment(dynamic_body)
	local static_a, static_b, static_radius = get_capsule_segment(static_body)
	local combined_radius = dynamic_radius + static_radius

	local function evaluate(t)
		local dynamic_a = start_a + (end_a - start_a) * t
		local dynamic_b = start_b + (end_b - start_b) * t
		local point_dynamic, point_static = closest_points_between_segments(dynamic_a, dynamic_b, static_a, static_b)
		local delta = point_static - point_dynamic
		local distance = delta:GetLength()
		return point_dynamic, point_static, delta, distance
	end

	local _, _, _, start_distance = evaluate(0)

	if start_distance <= combined_radius then return false end

	local sample_steps = 12
	local previous_t = 0

	for i = 1, sample_steps do
		local t = i / sample_steps
		local _, _, _, distance = evaluate(t)

		if distance <= combined_radius then
			local low = previous_t
			local high = t

			for _ = 1, 12 do
				local mid = (low + high) * 0.5
				local _, _, _, mid_distance = evaluate(mid)

				if mid_distance <= combined_radius then
					high = mid
				else
					low = mid
				end
			end

			local _, _, delta = evaluate(high)
			local normal = select(
				1,
				pair_solver_helpers.GetSafeCollisionNormal(delta * -1, dynamic_body:GetVelocity() - static_body:GetVelocity())
			)
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
	local normal, distance = pair_solver_helpers.GetSafeCollisionNormal(delta, sphere_body:GetVelocity() - capsule_body:GetVelocity())
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
	local normal, distance = pair_solver_helpers.GetSafeCollisionNormal(delta, body_b:GetVelocity() - body_a:GetVelocity())
	local overlap = min_distance - distance

	if overlap <= 0 then
		local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

		if static_body then
			return solve_swept_capsule_capsule_collision(dynamic_body, static_body, dt)
		end

		return false
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

local function solve_capsule_box_collision(capsule_body, box_body, dt)
	local points, radius = iterate_capsule_points(capsule_body)
	local previous_points = iterate_capsule_points(
		capsule_body,
		capsule_body:GetPreviousPosition(),
		capsule_body:GetPreviousRotation()
	)
	local best_contact = nil

	for i, sample in ipairs(points) do
		local previous_sample = previous_points[i] or sample
		local movement_local = box_body:WorldToLocal(sample.point) - box_body:WorldToLocal(previous_sample.point)
		local contact = pair_solver_helpers.GetBoxContactForPoint(box_body, sample.point, radius, movement_local)

		if contact and (not best_contact or contact.overlap > best_contact.overlap) then
			best_contact = contact
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

solver:RegisterPairHandler("capsule", "sphere", function(body_a, body_b, _, _, dt)
	return solve_capsule_sphere_collision(body_a, body_b, dt)
end)

solver:RegisterPairHandler("sphere", "capsule", function(body_a, body_b, _, _, dt)
	return solve_capsule_sphere_collision(body_b, body_a, dt)
end)

solver:RegisterPairHandler("capsule", "capsule", function(body_a, body_b, _, _, dt)
	return solve_capsule_capsule_collision(body_a, body_b, dt)
end)

solver:RegisterPairHandler("capsule", "box", function(body_a, body_b, _, _, dt)
	return solve_capsule_box_collision(body_a, body_b, dt)
end)

solver:RegisterPairHandler("box", "capsule", function(body_a, body_b, _, _, dt)
	return solve_capsule_box_collision(body_b, body_a, dt)
end)

return capsule