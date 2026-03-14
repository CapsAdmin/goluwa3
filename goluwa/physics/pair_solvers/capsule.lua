local module = {}

function module.Register(solver, services)
	local Vec3 = services.Vec3
	local EPSILON = services.EPSILON
	local clamp = services.clamp
	local get_sign = services.get_sign
	local get_box_extents = services.get_box_extents
	local resolve_pair_penetration = services.resolve_pair_penetration

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

		local t = clamp((point - a):Dot(ab) / denom, 0, 1)
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
			t = clamp(f / e, 0, 1)
		else
			local c = d1:Dot(r)

			if e <= EPSILON then
				t = 0
				s = clamp(-c / a, 0, 1)
			else
				local b = d1:Dot(d2)
				local denom = a * e - b * b

				if denom ~= 0 then
					s = clamp((b * f - c * e) / denom, 0, 1)
				else
					s = 0
				end

				t = (b * s + f) / e

				if t < 0 then
					t = 0
					s = clamp(-c / a, 0, 1)
				elseif t > 1 then
					t = 1
					s = clamp((b - c) / a, 0, 1)
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

	local function get_box_contact_for_point(box_body, point, radius)
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
			local distances = {
				{
					axis = Vec3(get_sign(local_point.x), 0, 0),
					overlap = extents.x - math.abs(local_point.x),
				},
				{
					axis = Vec3(0, get_sign(local_point.y), 0),
					overlap = extents.y - math.abs(local_point.y),
				},
				{
					axis = Vec3(0, 0, get_sign(local_point.z)),
					overlap = extents.z - math.abs(local_point.z),
				},
			}

			table.sort(distances, function(lhs, rhs)
				return lhs.overlap < rhs.overlap
			end)

			normal = box_body:GetRotation():VecMul(distances[1].axis):GetNormalized()
			overlap = radius + distances[1].overlap
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

	local function solve_capsule_sphere_collision(capsule_body, sphere_body, dt)
		local a, b, capsule_radius = get_capsule_segment(capsule_body)
		local sphere_center = sphere_body:GetPosition()
		local closest = closest_point_on_segment(a, b, sphere_center)
		local delta = sphere_center - closest
		local sphere_radius = sphere_body:GetPhysicsShape():GetRadius()
		local min_distance = capsule_radius + sphere_radius
		local distance = delta:GetLength()
		local normal

		if distance > EPSILON then
			normal = delta / distance
		else
			local relative_velocity = sphere_body:GetVelocity() - capsule_body:GetVelocity()
			normal = relative_velocity:GetLength() > EPSILON and
				relative_velocity:GetNormalized() or
				Vec3(1, 0, 0)
			distance = 0
		end

		local overlap = min_distance - distance

		if overlap <= 0 then return false end

		return resolve_pair_penetration(
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
		local distance = delta:GetLength()
		local min_distance = radius_a + radius_b
		local normal

		if distance > EPSILON then
			normal = delta / distance
		else
			local relative_velocity = body_b:GetVelocity() - body_a:GetVelocity()
			normal = relative_velocity:GetLength() > EPSILON and
				relative_velocity:GetNormalized() or
				Vec3(1, 0, 0)
			distance = 0
		end

		local overlap = min_distance - distance

		if overlap <= 0 then return false end

		return resolve_pair_penetration(
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
		local best_contact = nil

		for _, sample in ipairs(points) do
			local contact = get_box_contact_for_point(box_body, sample.point, radius)

			if contact and (not best_contact or contact.overlap > best_contact.overlap) then
				best_contact = contact
			end
		end

		if not best_contact then return false end

		return resolve_pair_penetration(
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
end

return module