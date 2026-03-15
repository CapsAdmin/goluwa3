local module = {}

function module.Register(solver, services)
	local Vec3 = services.Vec3
	local EPSILON = services.EPSILON
	local get_sign = services.get_sign
	local clamp = services.clamp
	local get_sphere_radius = services.get_sphere_radius
	local get_box_extents = services.get_box_extents
	local resolve_pair_penetration = services.resolve_pair_penetration
	local apply_pair_impulse = services.apply_pair_impulse
	local mark_pair_grounding = services.mark_pair_grounding
	local closest_point_on_triangle = services.closest_point_on_triangle
	local get_polyhedron_world_vertices = services.get_polyhedron_world_vertices
	local sweep_point_against_polyhedron = services.sweep_point_against_polyhedron

	local function solve_sphere_pair_collision(body_a, body_b, dt)
		if body_a == body_b then return end

		local pos_a = body_a:GetPosition()
		local pos_b = body_b:GetPosition()
		local delta = pos_b - pos_a
		local radius_a = get_sphere_radius(body_a)
		local radius_b = get_sphere_radius(body_b)
		local min_distance = radius_a + radius_b
		local distance = delta:GetLength()

		if distance >= min_distance then return end

		local normal

		if distance > EPSILON then
			normal = delta / distance
		else
			local relative_velocity = body_b:GetVelocity() - body_a:GetVelocity()

			if relative_velocity:GetLength() > EPSILON then
				normal = relative_velocity:GetNormalized()
			else
				normal = Vec3(1, 0, 0)
			end

			distance = 0
		end

		local overlap = min_distance - distance
		return resolve_pair_penetration(
			body_a,
			body_b,
			normal,
			overlap,
			dt,
			pos_a + normal * radius_a,
			pos_b - normal * radius_b
		)
	end

	local function solve_swept_sphere_box_collision(sphere_body, box_body, dt)
		if not (box_body.IsSolverImmovable and box_body:IsSolverImmovable()) then
			return false
		end

		local start_world = sphere_body:GetPreviousPosition()
		local end_world = sphere_body:GetPosition()
		local movement_world = end_world - start_world
		local extents = get_box_extents(box_body)
		local start_local_center = box_body:WorldToLocal(start_world)
		local end_local_center = box_body:WorldToLocal(end_world)
		local center_movement_local = end_local_center - start_local_center
		local descending_from_above =
			start_local_center.y > extents.y + EPSILON and center_movement_local.y < -EPSILON

		if movement_world:GetLength() <= EPSILON then return false end

		local function sweep_point_against_box(start_point_world, end_point_world)
			local start_local = box_body:WorldToLocal(start_point_world)
			local end_local = box_body:WorldToLocal(end_point_world)
			local movement_local = end_local - start_local
			local extents = get_box_extents(box_body)
			local t_enter = 0
			local t_exit = 1
			local hit_normal_local = nil
			local axis_data = {
				{"x", Vec3(-1, 0, 0), Vec3(1, 0, 0)},
				{"y", Vec3(0, -1, 0), Vec3(0, 1, 0)},
				{"z", Vec3(0, 0, -1), Vec3(0, 0, 1)},
			}

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

			return {t = t_enter, normal_local = hit_normal_local}
		end

		local earliest_hit = nil
		for _, local_point in ipairs(sphere_body:GetSupportLocalPoints() or {}) do
			local start_point_world = sphere_body:GeometryLocalToWorld(
				local_point,
				sphere_body:GetPreviousPosition(),
				sphere_body:GetPreviousRotation()
			)
			local end_point_world = sphere_body:GeometryLocalToWorld(local_point)
			local hit = sweep_point_against_box(start_point_world, end_point_world)

			if hit and not (descending_from_above and hit.normal_local.y <= EPSILON) then
				if not earliest_hit or hit.t < earliest_hit.t then
					earliest_hit = hit
				end
			end
		end

		if not earliest_hit then return false end

		local hit_fraction = math.max(0, math.min(1, earliest_hit.t))
		sphere_body.Position = start_world + movement_world * math.max(0, hit_fraction - EPSILON)
		local hit_normal = box_body:GetRotation():VecMul(earliest_hit.normal_local):GetNormalized()
		apply_pair_impulse(box_body, sphere_body, hit_normal, dt)
		mark_pair_grounding(box_body, sphere_body, hit_normal)
		local remaining_fraction = 1 - hit_fraction

		if remaining_fraction > EPSILON then
			local post_velocity = sphere_body:GetVelocity()
			sphere_body.Position = sphere_body.Position + post_velocity * (dt * remaining_fraction)
			sphere_body.PreviousPosition = sphere_body.Position - post_velocity * dt
		end

		return true
	end

	local function solve_sphere_box_collision(sphere_body, box_body, dt)
		local center = sphere_body:GetPosition()
		local local_center = box_body:WorldToLocal(center)
		local previous_local_center = box_body:WorldToLocal(sphere_body:GetPreviousPosition())
		local movement_local = local_center - previous_local_center
		local extents = get_box_extents(box_body)
		local sphere_radius = get_sphere_radius(sphere_body)

		if previous_local_center.y > extents.y + EPSILON and movement_local.y < -EPSILON then
			local top_local = Vec3(
				clamp(local_center.x, -extents.x, extents.x),
				extents.y,
				clamp(local_center.z, -extents.z, extents.z)
			)
			local top_world = box_body:LocalToWorld(top_local)
			local top_delta = center - top_world
			local top_distance = top_delta:GetLength()
			local top_overlap = sphere_radius - top_distance

			if top_overlap > -EPSILON then
				local top_normal

				if top_distance > EPSILON then
					top_normal = top_delta / top_distance
				else
					top_normal = box_body:GetRotation():VecMul(Vec3(0, 1, 0)):GetNormalized()
				end

				return resolve_pair_penetration(
					box_body,
					sphere_body,
					top_normal,
					math.max(top_overlap, EPSILON),
					dt,
					top_world,
					center - top_normal * sphere_radius
				)
			end
		end

		local closest_local = Vec3(
			clamp(local_center.x, -extents.x, extents.x),
			clamp(local_center.y, -extents.y, extents.y),
			clamp(local_center.z, -extents.z, extents.z)
		)
		local closest_world = box_body:LocalToWorld(closest_local)
		local delta = center - closest_world
		local distance = delta:GetLength()
		local overlap = sphere_radius - distance
		local normal

		if distance > EPSILON then
			normal = delta / distance
		elseif
			math.abs(local_center.x) <= extents.x and
			math.abs(local_center.y) <= extents.y and
			math.abs(local_center.z) <= extents.z
		then
			local candidates = {
				{
					axis = Vec3(1, 0, 0),
					center = local_center.x,
					movement = movement_local.x,
					overlap = extents.x - math.abs(local_center.x),
				},
				{
					axis = Vec3(0, 1, 0),
					center = local_center.y,
					movement = movement_local.y,
					overlap = extents.y - math.abs(local_center.y),
				},
				{
					axis = Vec3(0, 0, 1),
					center = local_center.z,
					movement = movement_local.z,
					overlap = extents.z - math.abs(local_center.z),
				},
			}
			local best = nil

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
			overlap = sphere_radius + best.overlap
		else
			return
		end

		if overlap <= 0 then
			return solve_swept_sphere_box_collision(sphere_body, box_body, dt)
		end

		return resolve_pair_penetration(
			box_body,
			sphere_body,
			normal,
			overlap,
			dt,
			closest_world,
			center - normal * sphere_radius
		)
	end

	local function solve_swept_sphere_convex_collision(sphere_body, convex_body, dt)
		if not (convex_body.IsSolverImmovable and convex_body:IsSolverImmovable()) then
			return false
		end

		local hull = convex_body:GetResolvedConvexHull()

		if not (hull and hull.vertices and hull.faces and hull.faces[1]) then
			return false
		end

		local start_world = sphere_body:GetPreviousPosition()
		local end_world = sphere_body:GetPosition()
		local movement_world = end_world - start_world
		local sphere_radius = get_sphere_radius(sphere_body)
		local hit = sweep_point_against_polyhedron(convex_body, hull, start_world, end_world, sphere_radius)

		if not hit then return false end

		sphere_body.Position = start_world + movement_world * math.max(0, hit.t - EPSILON)
		apply_pair_impulse(convex_body, sphere_body, hit.normal, dt)
		mark_pair_grounding(convex_body, sphere_body, hit.normal)

		if services.physics.RecordCollisionPair then
			services.physics.RecordCollisionPair(convex_body, sphere_body, hit.normal, 0)
		end

		return true
	end

	local function solve_sphere_convex_collision(sphere_body, convex_body, dt)
		local hull = convex_body:GetResolvedConvexHull()

		if not (hull and hull.vertices and hull.indices and hull.indices[1]) then
			return false
		end

		local center = sphere_body:GetPosition()
		local sphere_radius = get_sphere_radius(sphere_body)
		local vertices = get_polyhedron_world_vertices(convex_body, hull)
		local inside = true
		local nearest_face_distance = -math.huge
		local nearest_face_normal = nil
		local best_point = nil
		local best_distance = math.huge

		for _, face in ipairs(hull.faces or {}) do
			local plane_point = vertices[face.indices[1]]
			local normal = convex_body:GetRotation():VecMul(face.normal):GetNormalized()
			local distance = (center - plane_point):Dot(normal)

			if distance > 0 then inside = false end

			if distance > nearest_face_distance then
				nearest_face_distance = distance
				nearest_face_normal = normal
			end
		end

		for i = 1, #hull.indices, 3 do
			local a = vertices[hull.indices[i]]
			local b = vertices[hull.indices[i + 1]]
			local c = vertices[hull.indices[i + 2]]
			local point = closest_point_on_triangle(center, a, b, c)
			local distance = (center - point):GetLength()

			if distance < best_distance then
				best_distance = distance
				best_point = point
			end
		end

		local normal
		local overlap
		local point_a
		local point_b

		if inside then
			normal = nearest_face_normal
			overlap = sphere_radius - nearest_face_distance
			point_a = center - normal * nearest_face_distance
			point_b = center - normal * sphere_radius
		elseif best_point and best_distance < sphere_radius then
			if best_distance > EPSILON then
				normal = (center - best_point) / best_distance
			else
				normal = nearest_face_normal or Vec3(0, 1, 0)
			end

			overlap = sphere_radius - best_distance
			point_a = best_point
			point_b = center - normal * sphere_radius
		else
			return solve_swept_sphere_convex_collision(sphere_body, convex_body, dt)
		end

		if not normal or overlap <= 0 then return false end

		return resolve_pair_penetration(convex_body, sphere_body, normal, overlap, dt, point_a, point_b)
	end

	solver:RegisterPairHandler("sphere", "sphere", function(body_a, body_b, _, _, dt)
		return solve_sphere_pair_collision(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("sphere", "box", function(body_a, body_b, _, _, dt)
		return solve_sphere_box_collision(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("box", "sphere", function(body_a, body_b, _, _, dt)
		return solve_sphere_box_collision(body_b, body_a, dt)
	end)

	solver:RegisterPairHandler("sphere", "convex", function(body_a, body_b, _, _, dt)
		return solve_sphere_convex_collision(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("convex", "sphere", function(body_a, body_b, _, _, dt)
		return solve_sphere_convex_collision(body_b, body_a, dt)
	end)
end

return module