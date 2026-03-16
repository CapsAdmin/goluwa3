local module = {}

function module.CreateServices(services)
	local Vec3 = services.Vec3
	local EPSILON = services.EPSILON
	local physics = services.physics
	local clamp = services.clamp
	local get_sign = services.get_sign
	local get_box_extents = services.get_box_extents
	local apply_pair_impulse = services.apply_pair_impulse
	local mark_pair_grounding = services.mark_pair_grounding
	local axis_data = {
		{"x", Vec3(-1, 0, 0), Vec3(1, 0, 0)},
		{"y", Vec3(0, -1, 0), Vec3(0, 1, 0)},
		{"z", Vec3(0, 0, -1), Vec3(0, 0, 1)},
	}

	local function is_solver_immovable(body)
		return body.IsSolverImmovable and body:IsSolverImmovable() or false
	end

	local function has_solver_mass(body)
		return body.HasSolverMass and body:HasSolverMass() or false
	end

	local function get_static_dynamic_pair(body_a, body_b)
		if is_solver_immovable(body_a) and has_solver_mass(body_b) then
			return body_a, body_b
		end

		if is_solver_immovable(body_b) and has_solver_mass(body_a) then
			return body_b, body_a
		end

		return nil, nil
	end

	local function get_safe_collision_normal(delta, relative_velocity)
		local distance = delta:GetLength()

		if distance > EPSILON then return delta / distance, distance end

		if relative_velocity and relative_velocity:GetLength() > EPSILON then
			return relative_velocity:GetNormalized(), 0
		end

		return Vec3(1, 0, 0), 0
	end

	local function sweep_point_against_box(box_body, start_world, end_world)
		local movement_world = end_world - start_world

		if movement_world:GetLength() <= EPSILON then return nil end

		local start_local = box_body:WorldToLocal(start_world)
		local end_local = box_body:WorldToLocal(end_world)
		local movement_local = end_local - start_local
		local extents = get_box_extents(box_body)
		local t_enter = 0
		local t_exit = 1
		local hit_normal_local = nil

		for _, axis in ipairs(axis_data) do
			local name = axis[1]
			local s = start_local[name]
			local d = movement_local[name]
			local min_value = -extents[name]
			local max_value = extents[name]

			if math.abs(d) <= EPSILON then
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

	local function get_box_contact_for_point(box_body, point, radius, movement_local)
		local local_point = box_body:WorldToLocal(point)
		local extents = get_box_extents(box_body)
		local closest_local = Vec3(
			clamp(local_point.x, -extents.x, extents.x),
			clamp(local_point.y, -extents.y, extents.y),
			clamp(local_point.z, -extents.z, extents.z)
		)
		local closest_world = box_body:LocalToWorld(closest_local)
		local delta = point - closest_world
		local distance = delta:GetLength()
		local overlap = radius - distance
		local normal

		if distance > EPSILON then
			normal = delta / distance
		elseif
			math.abs(local_point.x) <= extents.x and
			math.abs(local_point.y) <= extents.y and
			math.abs(local_point.z) <= extents.z
		then
			local candidates = {
				{
					axis = Vec3(1, 0, 0),
					center = local_point.x,
					movement = movement_local and movement_local.x or 0,
					overlap = extents.x - math.abs(local_point.x),
				},
				{
					axis = Vec3(0, 1, 0),
					center = local_point.y,
					movement = movement_local and movement_local.y or 0,
					overlap = extents.y - math.abs(local_point.y),
				},
				{
					axis = Vec3(0, 0, 1),
					center = local_point.z,
					movement = movement_local and movement_local.z or 0,
					overlap = extents.z - math.abs(local_point.z),
				},
			}
			local best

			for _, candidate in ipairs(candidates) do
				local sign = get_sign(candidate.center)

				if sign == 0 then
					if math.abs(candidate.movement) > EPSILON then
						sign = get_sign(-candidate.movement)
					else
						sign = 1
					end
				end

				candidate.axis = candidate.axis * sign
				candidate.motion_weight = math.abs(candidate.movement)

				if
					not best or
					candidate.overlap < best.overlap - EPSILON or
					(
						math.abs(candidate.overlap - best.overlap) <= EPSILON and
						candidate.motion_weight > best.motion_weight + EPSILON
					)
				then
					best = candidate
				end
			end

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

	local function sweep_point_against_polyhedron(static_body, polyhedron, start_world, end_world, extra_radius, position, rotation)
		local movement_world = end_world - start_world

		if movement_world:GetLength() <= EPSILON then return nil end

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

			if math.abs(delta_distance) <= EPSILON then
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

	local function resolve_swept_hit(
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
		dynamic_body.Position = start_world + movement_world * math.max(0, hit_fraction - EPSILON)
		apply_pair_impulse(static_body, dynamic_body, normal, dt)
		mark_pair_grounding(static_body, dynamic_body, normal)

		if physics.RecordCollisionPair then
			physics.RecordCollisionPair(static_body, dynamic_body, normal, 0)
		end

		if allow_remaining_motion then
			local remaining_fraction = 1 - hit_fraction

			if remaining_fraction > EPSILON then
				local post_velocity = dynamic_body:GetVelocity()
				dynamic_body.Position = dynamic_body.Position + post_velocity * (dt * remaining_fraction)
				dynamic_body.PreviousPosition = dynamic_body.Position - post_velocity * dt
			end
		end

		return true, hit_fraction, normal
	end

	local function resolve_relative_swept_pair_hit(
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
		local safe_fraction = math.max(0, hit_fraction - EPSILON)
		local normal = hit.normal
		body_a.Position = start_a + move_a * safe_fraction
		body_b.Position = start_b + move_b * safe_fraction
		apply_pair_impulse(body_a, body_b, normal, dt, point_a, point_b)
		mark_pair_grounding(body_a, body_b, normal)

		if physics.RecordCollisionPair then
			physics.RecordCollisionPair(body_a, body_b, normal, 0)
		end

		if allow_remaining_motion then
			local remaining_fraction = 1 - hit_fraction

			if remaining_fraction > EPSILON then
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

	return {
		GetStaticDynamicPair = get_static_dynamic_pair,
		GetSafeCollisionNormal = get_safe_collision_normal,
		HasSolverMass = has_solver_mass,
		IsSolverImmovable = is_solver_immovable,
		GetBoxContactForPoint = get_box_contact_for_point,
		SweepPointAgainstBox = sweep_point_against_box,
		SweepPointAgainstPolyhedron = sweep_point_against_polyhedron,
		ResolveRelativeSweptPairHit = resolve_relative_swept_pair_hit,
		ResolveSweptHit = resolve_swept_hit,
	}
end

return module