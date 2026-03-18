local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
local polyhedron_solver = import("goluwa/physics/pair_solvers/polyhedron.lua")
local sphere = {}

local function solve_sphere_pair_collision(body_a, body_b, dt)
	if body_a == body_b then return end

	local pos_a = body_a:GetPosition()
	local pos_b = body_b:GetPosition()
	local delta = pos_b - pos_a
	local radius_a = body_a:GetSphereRadius()
	local radius_b = body_b:GetSphereRadius()
	local min_distance = radius_a + radius_b
	local distance = delta:GetLength()

	if distance >= min_distance then
		local start_a = body_a:GetPreviousPosition()
		local start_b = body_b:GetPreviousPosition()
		local move_a = pos_a - start_a
		local move_b = pos_b - start_b
		local relative_start = start_b - start_a
		local relative_move = move_b - move_a
		local sweep_a = relative_move:Dot(relative_move)

		if sweep_a > physics.EPSILON then
			local sweep_b = 2 * relative_start:Dot(relative_move)
			local sweep_c = relative_start:Dot(relative_start) - min_distance * min_distance
			local discriminant = sweep_b * sweep_b - 4 * sweep_a * sweep_c

			if discriminant >= 0 and sweep_c > physics.EPSILON then
				local sqrt_discriminant = math.sqrt(discriminant)
				local hit_fraction = (-sweep_b - sqrt_discriminant) / (2 * sweep_a)

				if hit_fraction >= 0 and hit_fraction <= 1 then
					local hit_pos_a = start_a + move_a * math.max(0, hit_fraction - physics.EPSILON)
					local hit_pos_b = start_b + move_b * math.max(0, hit_fraction - physics.EPSILON)
					local hit_normal = pair_solver_helpers.GetSafeCollisionNormal(
						hit_pos_b - hit_pos_a,
						body_b:GetVelocity() - body_a:GetVelocity(),
						relative_start,
						pair_solver_helpers.GetCachedPairNormal(body_a, body_b)
					)

					if not hit_normal then return end

					return pair_solver_helpers.ResolveRelativeSweptPairHit(
						body_a,
						body_b,
						start_a,
						move_a,
						start_b,
						move_b,
						{
							t = hit_fraction,
							normal = hit_normal,
						},
						dt,
						true,
						hit_pos_a + hit_normal * radius_a,
						hit_pos_b - hit_normal * radius_b
					)
				end
			end
		end

		return
	end

	local normal
	normal, distance = pair_solver_helpers.GetSafeCollisionNormal(
		delta,
		body_b:GetVelocity() - body_a:GetVelocity(),
		body_b:GetPreviousPosition() - body_a:GetPreviousPosition(),
		pair_solver_helpers.GetCachedPairNormal(body_a, body_b)
	)

	if not normal then return false end

	local overlap = min_distance - distance
	return contact_resolution.ResolvePairPenetration(
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
	if not pair_solver_helpers.IsSolverImmovable(box_body) then return false end

	local sweep = pair_solver_helpers.GetBodySweepMotion(sphere_body)
	local start_world = sweep.previous_position
	local end_world = sweep.current_position
	local movement_world = sweep.movement
	local extents = box_body:GetPhysicsShape():GetExtents()
	local start_local_center = box_body:WorldToLocal(start_world)
	local end_local_center = box_body:WorldToLocal(end_world)
	local center_movement_local = end_local_center - start_local_center
	local descending_from_above = start_local_center.y > extents.y + physics.EPSILON and
		center_movement_local.y < -physics.EPSILON

	if movement_world:GetLength() <= physics.EPSILON then return false end

	local earliest_hit = pair_solver_helpers.FindEarliestBodyPointSweepHit(
		sphere_body,
		sweep.previous_position,
		sweep.previous_rotation,
		sweep.current_position,
		sweep.current_rotation,
		sphere_body:GetSupportLocalPoints() or {},
		function(start_point_world, end_point_world)
			local hit = pair_solver_helpers.SweepPointAgainstBox(box_body, start_point_world, end_point_world)

			if hit and not (descending_from_above and hit.normal_local.y <= physics.EPSILON) then
				return hit
			end

			return nil
		end
	)

	if not earliest_hit then return false end

	return pair_solver_helpers.ResolveSweptHit(box_body, sphere_body, start_world, movement_world, earliest_hit, dt, true)
end

local function solve_sphere_box_collision(sphere_body, box_body, dt)
	local center = sphere_body:GetPosition()
	local local_center = box_body:WorldToLocal(center)
	local previous_local_center = box_body:WorldToLocal(sphere_body:GetPreviousPosition())
	local movement_local = local_center - previous_local_center
	local extents = box_body:GetPhysicsShape():GetExtents()
	local sphere_radius = sphere_body:GetSphereRadius()

	if
		previous_local_center.y > extents.y + physics.EPSILON and
		movement_local.y < -physics.EPSILON
	then
		local top_local = Vec3(
			math.clamp(local_center.x, -extents.x, extents.x),
			extents.y,
			math.clamp(local_center.z, -extents.z, extents.z)
		)
		local top_world = box_body:LocalToWorld(top_local)
		local top_delta = center - top_world
		local top_distance = top_delta:GetLength()
		local top_overlap = sphere_radius - top_distance

		if top_overlap > -physics.EPSILON then
			local top_normal

			if top_distance > physics.EPSILON then
				top_normal = top_delta / top_distance
			else
				top_normal = box_body:GetRotation():VecMul(Vec3(0, 1, 0)):GetNormalized()
			end

			return contact_resolution.ResolvePairPenetration(
				box_body,
				sphere_body,
				top_normal,
				math.max(top_overlap, physics.EPSILON),
				dt,
				top_world,
				center - top_normal * sphere_radius
			)
		end
	end

	local contact = pair_solver_helpers.GetBoxContactForPoint(box_body, center, sphere_radius, movement_local)

	if not contact then
		return solve_swept_sphere_box_collision(sphere_body, box_body, dt)
	end

	return contact_resolution.ResolvePairPenetration(
		box_body,
		sphere_body,
		contact.normal,
		contact.overlap,
		dt,
		contact.point_a,
		contact.point_b
	)
end

local function solve_swept_sphere_convex_collision(sphere_body, convex_body, dt)
	if not pair_solver_helpers.IsSolverImmovable(convex_body) then return false end

	local hull = convex_body:GetResolvedConvexHull()

	if not (hull and hull.vertices and hull.faces and hull.faces[1]) then
		return false
	end

	local sweep = pair_solver_helpers.GetBodySweepMotion(sphere_body)
	local start_world = sweep.previous_position
	local end_world = sweep.current_position
	local movement_world = sweep.movement
	local sphere_radius = sphere_body:GetSphereRadius()
	local hit = pair_solver_helpers.SweepPointAgainstPolyhedron(convex_body, hull, start_world, end_world, sphere_radius)

	if not hit then return false end

	return pair_solver_helpers.ResolveSweptHit(convex_body, sphere_body, start_world, movement_world, hit, dt)
end

local function solve_sphere_convex_collision(sphere_body, convex_body, dt)
	local hull = convex_body:GetResolvedConvexHull()

	if not (hull and hull.vertices and hull.indices and hull.indices[1]) then
		return false
	end

	local center = sphere_body:GetPosition()
	local sphere_radius = sphere_body:GetSphereRadius()
	local vertices = polyhedron_solver.GetPolyhedronWorldVertices(convex_body, hull)
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
		local point = polyhedron_solver.ClosestPointOnTriangle(center, a, b, c)
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
		if best_distance > physics.EPSILON then
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

	return contact_resolution.ResolvePairPenetration(convex_body, sphere_body, normal, overlap, dt, point_a, point_b)
end

physics.solver:RegisterPairHandler("sphere", "sphere", function(body_a, body_b, _, _, dt)
	return solve_sphere_pair_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("sphere", "box", function(body_a, body_b, _, _, dt)
	return solve_sphere_box_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("box", "sphere", function(body_a, body_b, _, _, dt)
	return solve_sphere_box_collision(body_b, body_a, dt)
end)

physics.solver:RegisterPairHandler("sphere", "convex", function(body_a, body_b, _, _, dt)
	return solve_sphere_convex_collision(body_a, body_b, dt)
end)

physics.solver:RegisterPairHandler("convex", "sphere", function(body_a, body_b, _, _, dt)
	return solve_sphere_convex_collision(body_b, body_a, dt)
end)

return sphere
