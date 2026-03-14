local module = {}

function module.Register(solver, services)
	local Vec3 = services.Vec3
	local EPSILON = services.EPSILON
	local get_sign = services.get_sign
	local get_box_extents = services.get_box_extents
	local get_box_axes = services.get_box_axes
	local get_body_polyhedron = services.get_body_polyhedron
	local resolve_pair_penetration = services.resolve_pair_penetration
	local apply_pair_impulse = services.apply_pair_impulse
	local mark_pair_grounding = services.mark_pair_grounding
	local solve_temporal_polyhedron_pair_collision = services.solve_temporal_polyhedron_pair_collision
	local solve_polyhedron_pair_collision = services.solve_polyhedron_pair_collision
	local physics = services.physics

	local function should_use_box_contact_patch(body)
		local axes = get_box_axes(body)
		local world_axes = {
			Vec3(1, 0, 0),
			Vec3(0, 1, 0),
			Vec3(0, 0, 1),
		}

		for _, axis in ipairs(axes) do
			local best_alignment = 0

			for _, world_axis in ipairs(world_axes) do
				best_alignment = math.max(best_alignment, math.abs(axis:Dot(world_axis)))
			end

			if best_alignment < 0.97 then return true end
		end

		return false
	end

	local function add_box_contact_point(contacts, point_a, point_b)
		local midpoint = (point_a + point_b) * 0.5

		for _, existing in ipairs(contacts) do
			local existing_midpoint = (existing.point_a + existing.point_b) * 0.5

			if (existing_midpoint - midpoint):GetLength() <= 0.12 then return end
		end

		contacts[#contacts + 1] = {
			point_a = point_a,
			point_b = point_b,
		}
	end

	local function get_box_face(body, desired_normal)
		local extents = get_box_extents(body)
		local axes = get_box_axes(body)
		local axis_index = 1
		local alignment = -math.huge

		for i = 1, 3 do
			local dot = axes[i]:Dot(desired_normal)
			local abs_dot = math.abs(dot)

			if abs_dot > alignment then
				alignment = abs_dot
				axis_index = i
			end
		end

		local axis = axes[axis_index]
		local sign = axis:Dot(desired_normal) >= 0 and 1 or -1
		local ex, ey, ez = extents.x, extents.y, extents.z
		local local_points

		if axis_index == 1 then
			local_points = {
				Vec3(sign * ex, -ey, -ez),
				Vec3(sign * ex, ey, -ez),
				Vec3(sign * ex, ey, ez),
				Vec3(sign * ex, -ey, ez),
			}
		elseif axis_index == 2 then
			local_points = {
				Vec3(-ex, sign * ey, -ez),
				Vec3(ex, sign * ey, -ez),
				Vec3(ex, sign * ey, ez),
				Vec3(-ex, sign * ey, ez),
			}
		else
			local_points = {
				Vec3(-ex, -ey, sign * ez),
				Vec3(ex, -ey, sign * ez),
				Vec3(ex, ey, sign * ez),
				Vec3(-ex, ey, sign * ez),
			}
		end

		local world_points = {}

		for i, local_point in ipairs(local_points) do
			world_points[i] = body:LocalToWorld(local_point)
		end

		return {
			axis_index = axis_index,
			sign = sign,
			alignment = alignment,
			center = body:LocalToWorld((local_points[1] + local_points[3]) * 0.5),
			points = world_points,
		}
	end

	local function point_inside_box_face(body, face, point)
		local extents = get_box_extents(body)
		local local_point = body:WorldToLocal(point)
		local tolerance = 0.08

		if face.axis_index == 1 then
			return math.abs(local_point.x - face.sign * extents.x) <= tolerance and
				math.abs(local_point.y) <= extents.y + tolerance and
				math.abs(local_point.z) <= extents.z + tolerance
		end

		if face.axis_index == 2 then
			return math.abs(local_point.y - face.sign * extents.y) <= tolerance and
				math.abs(local_point.x) <= extents.x + tolerance and
				math.abs(local_point.z) <= extents.z + tolerance
		end

		return math.abs(local_point.z - face.sign * extents.z) <= tolerance and
			math.abs(local_point.x) <= extents.x + tolerance and
			math.abs(local_point.y) <= extents.y + tolerance
	end

	local function project_to_plane(point, plane_point, plane_normal)
		return point - plane_normal * (point - plane_point):Dot(plane_normal)
	end

	local function build_box_box_contacts(body_a, body_b, normal)
		local face_a = get_box_face(body_a, normal)
		local face_b = get_box_face(body_b, -normal)
		local contacts = {}

		if face_a.alignment < 0.55 or face_b.alignment < 0.55 then return contacts end

		for _, point_a in ipairs(face_a.points) do
			local projected = project_to_plane(point_a, face_b.center, normal)

			if point_inside_box_face(body_b, face_b, projected) then
				add_box_contact_point(contacts, point_a, projected)
			end
		end

		for _, point_b in ipairs(face_b.points) do
			local projected = project_to_plane(point_b, face_a.center, normal)

			if point_inside_box_face(body_a, face_a, projected) then
				add_box_contact_point(contacts, projected, point_b)
			end
		end

		return contacts
	end

	local function project_box_radius(extents, axes, normal)
		return extents.x * math.abs(normal:Dot(axes[1])) + extents.y * math.abs(normal:Dot(axes[2])) + extents.z * math.abs(normal:Dot(axes[3]))
	end

	local function test_obb_axis(axis, delta, extents_a, axes_a, extents_b, axes_b, best)
		local axis_length = axis:GetLength()

		if axis_length <= EPSILON then return true end

		local normal = axis / axis_length
		local distance = delta:Dot(normal)
		local abs_distance = math.abs(distance)
		local radius_a = project_box_radius(extents_a, axes_a, normal)
		local radius_b = project_box_radius(extents_b, axes_b, normal)
		local overlap = radius_a + radius_b - abs_distance

		if overlap <= 0 then return false end

		if overlap < best.overlap then
			best.overlap = overlap
			best.normal = normal * get_sign(distance)
		end

		return true
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

		return {
			t = t_enter,
			normal = box_body:GetRotation():VecMul(hit_normal_local):GetNormalized(),
		}
	end

	local function solve_swept_box_box_collision(dynamic_body, static_body, dt)
		if
			not (
				static_body.IsSolverImmovable and
				static_body:IsSolverImmovable()
			) or
			not (
				dynamic_body.HasSolverMass and
				dynamic_body:HasSolverMass()
			)
		then
			return false
		end

		local previous_position = dynamic_body:GetPreviousPosition()
		local current_position = dynamic_body:GetPosition()
		local movement = current_position - previous_position

		if movement:GetLength() <= EPSILON then return false end

		local earliest_hit

		for _, local_point in ipairs(dynamic_body:GetCollisionLocalPoints()) do
			local start_world = dynamic_body:GeometryLocalToWorld(local_point, previous_position, dynamic_body:GetPreviousRotation())
			local end_world = dynamic_body:GeometryLocalToWorld(local_point)
			local hit = sweep_point_against_box(static_body, start_world, end_world)

			if hit and (not earliest_hit or hit.t < earliest_hit.t) then
				earliest_hit = hit
			end
		end

		if not earliest_hit then return false end

		dynamic_body.Position = previous_position + movement * math.max(0, earliest_hit.t - EPSILON)
		apply_pair_impulse(static_body, dynamic_body, earliest_hit.normal, dt)
		mark_pair_grounding(static_body, dynamic_body, earliest_hit.normal)

		if physics.RecordCollisionPair then
			physics.RecordCollisionPair(static_body, dynamic_body, earliest_hit.normal, 0)
		end

		return true
	end

	local function solve_box_pair_collision(body_a, body_b, dt)
		if
			services.body_has_significant_rotation(body_a) or
			services.body_has_significant_rotation(body_b)
		then
			local temporal = solve_temporal_polyhedron_pair_collision(
				body_a,
				body_b,
				get_body_polyhedron(body_a),
				get_body_polyhedron(body_b),
				dt
			)

			if temporal then return true end
		end

		local center_a = body_a:GetPosition()
		local center_b = body_b:GetPosition()
		local delta = center_b - center_a
		local extents_a = get_box_extents(body_a)
		local extents_b = get_box_extents(body_b)
		local axes_a = get_box_axes(body_a)
		local axes_b = get_box_axes(body_b)
		local best = {overlap = math.huge, normal = nil}

		for i = 1, 3 do
			if not test_obb_axis(axes_a[i], delta, extents_a, axes_a, extents_b, axes_b, best) then
				if body_a:IsSolverImmovable() and body_b:HasSolverMass() then
					return solve_swept_box_box_collision(body_b, body_a, dt)
				end

				if body_b:IsSolverImmovable() and body_a:HasSolverMass() then
					return solve_swept_box_box_collision(body_a, body_b, dt)
				end

				return
			end

			if not test_obb_axis(axes_b[i], delta, extents_a, axes_a, extents_b, axes_b, best) then
				if body_a:IsSolverImmovable() and body_b:HasSolverMass() then
					return solve_swept_box_box_collision(body_b, body_a, dt)
				end

				if body_b:IsSolverImmovable() and body_a:HasSolverMass() then
					return solve_swept_box_box_collision(body_a, body_b, dt)
				end

				return
			end
		end

		for i = 1, 3 do
			for j = 1, 3 do
				if
					not test_obb_axis(axes_a[i]:GetCross(axes_b[j]), delta, extents_a, axes_a, extents_b, axes_b, best)
				then
					if body_a:IsSolverImmovable() and body_b:HasSolverMass() then
						return solve_swept_box_box_collision(body_b, body_a, dt)
					end

					if body_b:IsSolverImmovable() and body_a:HasSolverMass() then
						return solve_swept_box_box_collision(body_a, body_b, dt)
					end

					return
				end
			end
		end

		if not best.normal or best.overlap == math.huge then return end

		if should_use_box_contact_patch(body_a) or should_use_box_contact_patch(body_b) then
			return resolve_pair_penetration(
				body_a,
				body_b,
				best.normal,
				best.overlap,
				dt,
				nil,
				nil,
				build_box_box_contacts(body_a, body_b, best.normal)
			)
		end

		return resolve_pair_penetration(body_a, body_b, best.normal, best.overlap, dt)
	end

	solver:RegisterPairHandler("box", "box", function(body_a, body_b, _, _, dt)
		return solve_box_pair_collision(body_a, body_b, dt)
	end)
end

return module