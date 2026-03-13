local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics/shared.lua")
local solver = physics.Solver or {}
physics.Solver = solver

local function solve_contact(body, point, hit, dt)
	local normal = physics.GetHitNormal(hit, point)

	if not (hit and normal) then return false end

	local target = hit.position + normal * body.CollisionMargin
	local correction = target - point
	local depth = correction:Dot(normal)

	if depth <= 0 then return false end

	body:ApplyCorrection(0, normal * depth, point, nil, nil, dt)

	if normal.y >= body.MinGroundNormalY then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end

	return true
end

local function solve_motion_contacts(body, dt)
	if not body.CollisionEnabled then return end

	local sweep_margin = body.CollisionMargin + body.CollisionProbeDistance

	for _, local_point in ipairs(body:GetCollisionLocalPoints()) do
		local previous = body:GeometryLocalToWorld(local_point, body:GetPreviousPosition(), body:GetPreviousRotation())
		local current = body:GeometryLocalToWorld(local_point)
		local delta = current - previous
		local distance = delta:GetLength()

		if distance > 0.0001 then
			local hit = physics.Trace(
				previous,
				delta,
				distance + sweep_margin,
				body.Owner,
				body.FilterFunction
			)

			if hit and hit.distance <= distance + sweep_margin then
				solve_contact(body, current, hit, dt)
			end
		end
	end
end

local function solve_support_contacts(body, dt)
	if not body.CollisionEnabled then return end

	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * dt)
	local cast_up = body.CollisionProbeDistance + body.CollisionMargin
	local cast_distance = cast_up + downward + body.CollisionProbeDistance + body.CollisionMargin

	if body.Shape == "sphere" then
		local center = body:GetPosition()
		local hit = physics.TraceDown(
			center + physics.Up * cast_up,
			0,
			body.Owner,
			cast_distance + body.Radius,
			body.FilterFunction
		)
		local normal = physics.GetHitNormal(hit, center)

		if hit and normal then
			local target_center = hit.position + normal * (body.Radius + body.CollisionMargin)
			local correction = target_center - center
			local depth = correction:Dot(normal)

			if depth > 0 then
				body:ApplyCorrection(
					0,
					normal * depth,
					center - normal * body.Radius,
					nil,
					nil,
					dt
				)

				if normal.y >= body.MinGroundNormalY then
					body:SetGrounded(true)
					body:SetGroundNormal(normal)
				end
			end
		end

		return
	end

	for _, local_point in ipairs(body:GetSupportLocalPoints()) do
		local point = body:GeometryLocalToWorld(local_point)
		local hit = physics.TraceDown(
			point + physics.Up * cast_up,
			0,
			body.Owner,
			cast_distance,
			body.FilterFunction
		)

		if hit then solve_contact(body, point, hit, dt) end
	end
end

local function shift_body_position(body, delta)
	body.Position = body.Position + delta
	body.PreviousPosition = body.PreviousPosition + delta
end

local function set_body_velocity_from_current_position(body, velocity, dt)
	body:SetVelocity(velocity)
	body.PreviousPosition = body.Position - velocity * dt
end

local function mark_pair_grounding(body_a, body_b, normal)
	if -normal.y >= body_a.MinGroundNormalY then
		body_a:SetGrounded(true)
		body_a:SetGroundNormal(-normal)
	end

	if normal.y >= body_b.MinGroundNormalY then
		body_b:SetGrounded(true)
		body_b:SetGroundNormal(normal)
	end
end

local function apply_pair_impulse(body_a, body_b, normal, dt)
	local inverse_mass_a = body_a.InverseMass
	local inverse_mass_b = body_b.InverseMass
	local inverse_mass_sum = inverse_mass_a + inverse_mass_b

	if inverse_mass_sum <= 0 then return end

	local velocity_a = body_a:GetVelocity()
	local velocity_b = body_b:GetVelocity()
	local relative_velocity = velocity_b - velocity_a
	local normal_speed = relative_velocity:Dot(normal)

	if normal_speed >= 0 then return end

	local impulse = -normal_speed / inverse_mass_sum

	if inverse_mass_a > 0 then
		velocity_a = velocity_a - normal * (impulse * inverse_mass_a)
		set_body_velocity_from_current_position(body_a, velocity_a, dt)
	end

	if inverse_mass_b > 0 then
		velocity_b = velocity_b + normal * (impulse * inverse_mass_b)
		set_body_velocity_from_current_position(body_b, velocity_b, dt)
	end
end

local function resolve_pair_penetration(body_a, body_b, normal, overlap, dt)
	local inverse_mass_a = body_a.InverseMass
	local inverse_mass_b = body_b.InverseMass
	local inverse_mass_sum = inverse_mass_a + inverse_mass_b

	if inverse_mass_sum <= 0 or overlap <= 0 then return false end

	local correction = normal * overlap

	if inverse_mass_a > 0 then
		shift_body_position(body_a, correction * -(inverse_mass_a / inverse_mass_sum))
	end

	if inverse_mass_b > 0 then
		shift_body_position(body_b, correction * (inverse_mass_b / inverse_mass_sum))
	end

	apply_pair_impulse(body_a, body_b, normal, dt)
	mark_pair_grounding(body_a, body_b, normal)
	return true
end

local function sort(a, b)
	return a.left < b.left
end

local function build_broadphase_entries(bodies)
	local entries = {}

	for _, body in ipairs(bodies) do
		if
			physics.IsActiveRigidBody(body) and
			body.CollisionEnabled and
			not (
				body.Owner and
				(
					body.Owner.PhysicsNoCollision or
					body.Owner.NoPhysicsCollision
				)
			)
		then
			local bounds = body:GetBroadphaseAABB()
			entries[#entries + 1] = {
				body = body,
				bounds = bounds,
				center = body:GetPosition(),
				left = bounds.min_x,
				right = bounds.max_x,
			}
		end
	end

	table.sort(entries, sort)
	return entries
end

local function solve_sphere_pair_collision(body_a, body_b, dt)
	if body_a == body_b then return end

	local pos_a = body_a:GetPosition()
	local pos_b = body_b:GetPosition()
	local delta = pos_b - pos_a
	local min_distance = body_a.Radius + body_b.Radius
	local distance = delta:GetLength()

	if distance >= min_distance then return end

	local normal

	if distance > 0.00001 then
		normal = delta / distance
	else
		local relative_velocity = body_b:GetVelocity() - body_a:GetVelocity()

		if relative_velocity:GetLength() > 0.00001 then
			normal = relative_velocity:GetNormalized()
		else
			normal = Vec3(1, 0, 0)
		end

		distance = 0
	end

	local overlap = min_distance - distance
	resolve_pair_penetration(body_a, body_b, normal, overlap, dt)
end

local function clamp(value, min_value, max_value)
	return math.max(min_value, math.min(max_value, value))
end

local function solve_sphere_box_collision(sphere_body, box_body, dt)
	local center = sphere_body:GetPosition()
	local bounds = box_body:GetBroadphaseAABB()
	local closest = Vec3(
		clamp(center.x, bounds.min_x, bounds.max_x),
		clamp(center.y, bounds.min_y, bounds.max_y),
		clamp(center.z, bounds.min_z, bounds.max_z)
	)
	local delta = center - closest
	local distance = delta:GetLength()
	local overlap = sphere_body.Radius - distance
	local normal

	if distance > 0.00001 then
		normal = delta / distance
	elseif bounds:IsPointInside(center) then
		local distances = {
			{axis = Vec3(-1, 0, 0), overlap = center.x - bounds.min_x},
			{axis = Vec3(1, 0, 0), overlap = bounds.max_x - center.x},
			{axis = Vec3(0, -1, 0), overlap = center.y - bounds.min_y},
			{axis = Vec3(0, 1, 0), overlap = bounds.max_y - center.y},
			{axis = Vec3(0, 0, -1), overlap = center.z - bounds.min_z},
			{axis = Vec3(0, 0, 1), overlap = bounds.max_z - center.z},
		}

		table.sort(distances, function(a, b)
			return a.overlap < b.overlap
		end)

		normal = distances[1].axis
		overlap = sphere_body.Radius + distances[1].overlap
	else
		return
	end

	if overlap <= 0 then return end

	resolve_pair_penetration(box_body, sphere_body, normal, overlap, dt)
end

local function solve_aabb_pair_collision(body_a, body_b, bounds_a, bounds_b, dt)
	local overlap_x = math.min(bounds_a.max_x, bounds_b.max_x) - math.max(bounds_a.min_x, bounds_b.min_x)
	local overlap_y = math.min(bounds_a.max_y, bounds_b.max_y) - math.max(bounds_a.min_y, bounds_b.min_y)
	local overlap_z = math.min(bounds_a.max_z, bounds_b.max_z) - math.max(bounds_a.min_z, bounds_b.min_z)

	if overlap_x <= 0 or overlap_y <= 0 or overlap_z <= 0 then return end

	local center_delta = body_b:GetPosition() - body_a:GetPosition()
	local normal
	local overlap = overlap_x

	if overlap_y < overlap then
		overlap = overlap_y
		normal = Vec3(0, center_delta.y >= 0 and 1 or -1, 0)
	end

	if overlap_z < overlap then
		overlap = overlap_z
		normal = Vec3(0, 0, center_delta.z >= 0 and 1 or -1)
	end

	if not normal then normal = Vec3(center_delta.x >= 0 and 1 or -1, 0, 0) end

	resolve_pair_penetration(body_a, body_b, normal, overlap, dt)
end

local function solve_rigid_body_pair(body_a, body_b, entry_a, entry_b, dt)
	local shape_a = body_a.Shape
	local shape_b = body_b.Shape

	if shape_a == "sphere" and shape_b == "sphere" then
		return solve_sphere_pair_collision(body_a, body_b, dt)
	end

	if shape_a == "sphere" and shape_b == "box" then
		return solve_sphere_box_collision(body_a, body_b, dt)
	end

	if shape_a == "box" and shape_b == "sphere" then
		return solve_sphere_box_collision(body_b, body_a, dt)
	end

	return solve_aabb_pair_collision(body_a, body_b, entry_a.bounds, entry_b.bounds, dt)
end

function solver.SolveDistanceConstraints(dt)
	for i = #physics.DistanceConstraints, 1, -1 do
		local constraint = physics.DistanceConstraints[i]

		if constraint and constraint.Enabled ~= false then constraint:Solve(dt) end
	end
end

function solver.SolveRigidBodyPairs(bodies, dt)
	local entries = build_broadphase_entries(bodies)

	for i = 1, #entries do
		local a = entries[i]
		local max_right = a.right

		for j = i + 1, #entries do
			local b = entries[j]

			if b.left > max_right then break end

			if a.bounds:IsBoxIntersecting(b.bounds) then
				solve_rigid_body_pair(a.body, b.body, a, b, dt)
			end
		end
	end
end

function solver.SolveBodyContacts(body, dt)
	solve_motion_contacts(body, dt)
	solve_support_contacts(body, dt)
end

return solver