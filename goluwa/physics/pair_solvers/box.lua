local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics/shared.lua")
local solver = import("goluwa/physics/solver.lua")
local physics_solver = import("goluwa/physics/solver.lua")
local shape_accessors = import("goluwa/physics/shape_accessors.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local polyhedron_solver = import("goluwa/physics/pair_solvers/polyhedron.lua")
local box = {}
local EPSILON = physics_solver.EPSILON or 0.00001

local function should_use_box_contact_patch(body)
	local axes = body:GetPhysicsShape():GetAxes(body)
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

local function is_rod_like_box(body)
	local extents = body:GetPhysicsShape():GetExtents()
	local lengths = {extents.x * 2, extents.y * 2, extents.z * 2}
	table.sort(lengths)
	return lengths[3] >= lengths[2] * 2 and lengths[2] <= lengths[1] * 1.2
end

local function is_compact_box(body)
	local extents = body:GetPhysicsShape():GetExtents()
	local lengths = {extents.x * 2, extents.y * 2, extents.z * 2}
	table.sort(lengths)
	return lengths[3] <= lengths[1] * 1.35
end

local function should_use_face_biased_settling(body)
	return is_rod_like_box(body) or is_compact_box(body)
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
	local extents = body:GetPhysicsShape():GetExtents()
	local axes = body:GetPhysicsShape():GetAxes(body)
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
	local extents = body:GetPhysicsShape():GetExtents()
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

local function get_body_world_vertices(body)
	local polyhedron = shape_accessors.GetBodyPolyhedron(body)
	local vertices = {}

	for i, point in ipairs((polyhedron and polyhedron.vertices) or {}) do
		vertices[i] = body:LocalToWorld(point)
	end

	return vertices
end

local function collect_support_vertices(vertices, axis, want_max)
	local support = {}
	local best = want_max and -math.huge or math.huge
	local tolerance = 0.06

	for _, point in ipairs(vertices) do
		local projection = point:Dot(axis)

		if want_max then
			if projection > best + tolerance then
				best = projection
				support = {point}
			elseif math.abs(projection - best) <= tolerance then
				support[#support + 1] = point
			end
		else
			if projection < best - tolerance then
				best = projection
				support = {point}
			elseif math.abs(projection - best) <= tolerance then
				support[#support + 1] = point
			end
		end
	end

	return support
end

local function build_support_pair_contacts(body_a, body_b, normal)
	local contacts = {}
	local vertices_a = get_body_world_vertices(body_a)
	local vertices_b = get_body_world_vertices(body_b)
	local support_a = collect_support_vertices(vertices_a, normal, true)
	local support_b = collect_support_vertices(vertices_b, normal, false)

	if not support_a[1] or not support_b[1] then return contacts end

	local primary = #support_a <= #support_b and support_a or support_b
	local secondary = primary == support_a and support_b or support_a
	local primary_is_a = primary == support_a

	for _, point in ipairs(primary) do
		local closest_other = nil
		local closest_distance = math.huge

		for _, other in ipairs(secondary) do
			local tangent_delta = other - point
			tangent_delta = tangent_delta - normal * tangent_delta:Dot(normal)
			local tangent_distance = tangent_delta:GetLength()

			if tangent_distance < closest_distance then
				closest_distance = tangent_distance
				closest_other = other
			end
		end

		if closest_other then
			if primary_is_a then
				add_box_contact_point(contacts, point, closest_other)
			else
				add_box_contact_point(contacts, closest_other, point)
			end
		end

		if #contacts >= 4 then break end
	end

	return contacts
end

local function build_projected_box_contacts(body_a, body_b, normal)
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

local function update_best_axis(best, overlap, normal, kind, reference_body)
	local candidate = {
		overlap = overlap,
		normal = normal,
		kind = kind,
		reference_body = reference_body,
	}

	if overlap < best.any.overlap then best.any = candidate end

	if kind == "face" and (not best.face or overlap < best.face.overlap) then
		best.face = candidate
	end
end

local function test_obb_axis(axis, delta, extents_a, axes_a, extents_b, axes_b, best, kind, reference_body)
	local axis_length = axis:GetLength()

	if axis_length <= EPSILON then return true end

	local normal = axis / axis_length
	local distance = delta:Dot(normal)
	local abs_distance = math.abs(distance)
	local radius_a = project_box_radius(extents_a, axes_a, normal)
	local radius_b = project_box_radius(extents_b, axes_b, normal)
	local overlap = radius_a + radius_b - abs_distance

	if overlap <= 0 then return false end

	update_best_axis(best, overlap, normal * math.sign(distance), kind, reference_body)
	return true
end

local function choose_best_axis(best, face_preference_slop)
	local chosen = best.any
	face_preference_slop = face_preference_slop or 0.12

	if
		chosen.kind == "edge" and
		best.face and
		best.face.overlap <= chosen.overlap + face_preference_slop
	then
		chosen = best.face
	end

	return chosen
end

local function solve_swept_box_box_collision(dynamic_body, static_body, dt)
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

	local earliest_hit

	for _, local_point in ipairs(dynamic_body:GetCollisionLocalPoints()) do
		local start_world = dynamic_body:GeometryLocalToWorld(local_point, previous_position, dynamic_body:GetPreviousRotation())
		local end_world = dynamic_body:GeometryLocalToWorld(local_point)
		local hit = pair_solver_helpers.SweepPointAgainstBox(static_body, start_world, end_world)

		if hit and (not earliest_hit or hit.t < earliest_hit.t) then
			earliest_hit = hit
		end
	end

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(static_body, dynamic_body, previous_position, movement, earliest_hit, dt)
end

local function solve_box_pair_collision(body_a, body_b, dt)
	if
		shape_accessors.BodyHasSignificantRotation(body_a) or
		shape_accessors.BodyHasSignificantRotation(body_b)
	then
		local temporal = polyhedron_solver.SolveTemporalPolyhedronPairCollision(
			body_a,
			body_b,
			shape_accessors.GetBodyPolyhedron(body_a),
			shape_accessors.GetBodyPolyhedron(body_b),
			dt
		)

		if temporal then return true end
	end

	local center_a = body_a:GetPosition()
	local center_b = body_b:GetPosition()
	local delta = center_b - center_a
	local extents_a = body_a:GetPhysicsShape():GetExtents()
	local extents_b = body_b:GetPhysicsShape():GetExtents()
	local axes_a = body_a:GetPhysicsShape():GetAxes(body_a)
	local axes_b = body_b:GetPhysicsShape():GetAxes(body_b)
	local best = {any = {overlap = math.huge, normal = nil, kind = nil}, face = nil}

	for i = 1, 3 do
		if
			not test_obb_axis(axes_a[i], delta, extents_a, axes_a, extents_b, axes_b, best, "face", "a")
		then
			local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

			if static_body then
				return solve_swept_box_box_collision(dynamic_body, static_body, dt)
			end

			return
		end

		if
			not test_obb_axis(axes_b[i], delta, extents_a, axes_a, extents_b, axes_b, best, "face", "b")
		then
			local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

			if static_body then
				return solve_swept_box_box_collision(dynamic_body, static_body, dt)
			end

			return
		end
	end

	for i = 1, 3 do
		for j = 1, 3 do
			if
				not test_obb_axis(
					axes_a[i]:GetCross(axes_b[j]),
					delta,
					extents_a,
					axes_a,
					extents_b,
					axes_b,
					best,
					"edge",
					nil
				)
			then
				local static_body, dynamic_body = pair_solver_helpers.GetStaticDynamicPair(body_a, body_b)

				if static_body then
					return solve_swept_box_box_collision(dynamic_body, static_body, dt)
				end

				return
			end
		end
	end

	local raw_best = best.any
	local use_face_biased_settling = should_use_face_biased_settling(body_a) or
		should_use_face_biased_settling(body_b)
	best = choose_best_axis(best, use_face_biased_settling and 0.4 or 0.12)

	if not best.normal or best.overlap == math.huge then return end

	if should_use_box_contact_patch(body_a) or should_use_box_contact_patch(body_b) then
		if use_face_biased_settling then
			local contacts = build_support_pair_contacts(body_a, body_b, best.normal)

			if contacts and contacts[1] then
				return contact_resolution.ResolvePairPenetration(
					body_a,
					body_b,
					best.normal,
					best.overlap,
					dt,
					nil,
					nil,
					contacts
				)
			end
		end

		return contact_resolution.ResolvePairPenetration(
			body_a,
			body_b,
			raw_best.normal,
			raw_best.overlap,
			dt,
			nil,
			nil,
			build_projected_box_contacts(body_a, body_b, raw_best.normal)
		)
	end

	return contact_resolution.ResolvePairPenetration(body_a, body_b, best.normal, best.overlap, dt)
end

solver:RegisterPairHandler("box", "box", function(body_a, body_b, _, _, dt)
	return solve_box_pair_collision(body_a, body_b, dt)
end)

return box