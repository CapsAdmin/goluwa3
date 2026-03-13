local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics/shared.lua")
local solver = physics.Solver or {}
physics.Solver = solver
local EPSILON = 0.00001

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
	if body.InverseMass ~= 0 and delta:GetLength() > 0.01 and body.Wake then
		body:Wake()
	end

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

local function get_pair_restitution(body_a, body_b)
	return math.max(body_a.Restitution or 0, body_b.Restitution or 0)
end

local function get_pair_friction(body_a, body_b)
	return math.sqrt(math.max(body_a.Friction or 0, 0) * math.max(body_b.Friction or 0, 0))
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

	local restitution = get_pair_restitution(body_a, body_b)
	local normal_impulse = -(1 + restitution) * normal_speed / inverse_mass_sum

	if inverse_mass_a > 0 then
		velocity_a = velocity_a - normal * (normal_impulse * inverse_mass_a)
	end

	if inverse_mass_b > 0 then
		velocity_b = velocity_b + normal * (normal_impulse * inverse_mass_b)
	end

	relative_velocity = velocity_b - velocity_a
	local tangent_velocity = relative_velocity - normal * relative_velocity:Dot(normal)
	local tangent_speed = tangent_velocity:GetLength()

	if tangent_speed > EPSILON then
		local tangent = tangent_velocity / tangent_speed
		local friction = get_pair_friction(body_a, body_b)
		local tangent_impulse = -relative_velocity:Dot(tangent) / inverse_mass_sum
		local max_friction_impulse = normal_impulse * friction
		tangent_impulse = math.max(-max_friction_impulse, math.min(max_friction_impulse, tangent_impulse))

		if inverse_mass_a > 0 then
			velocity_a = velocity_a - tangent * (tangent_impulse * inverse_mass_a)
		end

		if inverse_mass_b > 0 then
			velocity_b = velocity_b + tangent * (tangent_impulse * inverse_mass_b)
		end
	end

	if inverse_mass_a > 0 then
		set_body_velocity_from_current_position(body_a, velocity_a, dt)
	end

	if inverse_mass_b > 0 then
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

	if physics.RecordCollisionPair then
		physics.RecordCollisionPair(body_a, body_b, normal, overlap)
	end

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
			local previous_bounds = body:GetBroadphaseAABB(body:GetPreviousPosition(), body:GetPreviousRotation())
			bounds.min_x = math.min(bounds.min_x, previous_bounds.min_x)
			bounds.min_y = math.min(bounds.min_y, previous_bounds.min_y)
			bounds.min_z = math.min(bounds.min_z, previous_bounds.min_z)
			bounds.max_x = math.max(bounds.max_x, previous_bounds.max_x)
			bounds.max_y = math.max(bounds.max_y, previous_bounds.max_y)
			bounds.max_z = math.max(bounds.max_z, previous_bounds.max_z)
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

local function get_sign(value)
	return value < 0 and -1 or 1
end

local function get_box_extents(body)
	return body.Size * 0.5
end

local function get_box_axes(body)
	local rotation = body:GetRotation()
	return {
		rotation:VecMul(Vec3(1, 0, 0)):GetNormalized(),
		rotation:VecMul(Vec3(0, 1, 0)):GetNormalized(),
		rotation:VecMul(Vec3(0, 0, 1)):GetNormalized(),
	}
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

local function solve_swept_sphere_box_collision(sphere_body, box_body, dt)
	if box_body.InverseMass ~= 0 then return false end

	local start_world = sphere_body:GetPreviousPosition()
	local end_world = sphere_body:GetPosition()
	local movement_world = end_world - start_world

	if movement_world:GetLength() <= EPSILON then return false end

	local start_local = box_body:WorldToLocal(start_world)
	local end_local = box_body:WorldToLocal(end_world)
	local movement_local = end_local - start_local
	local extents = get_box_extents(box_body) + Vec3(sphere_body.Radius, sphere_body.Radius, sphere_body.Radius)
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
			if s < min_value or s > max_value then return false end
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

			if t_enter > t_exit then return false end
		end
	end

	if not hit_normal_local or t_enter < 0 or t_enter > 1 then return false end

	sphere_body.Position = start_world + movement_world * math.max(0, t_enter - EPSILON)
	local hit_normal = box_body:GetRotation():VecMul(hit_normal_local):GetNormalized()
	apply_pair_impulse(box_body, sphere_body, hit_normal, dt)
	mark_pair_grounding(box_body, sphere_body, hit_normal)
	return true
end

local function solve_sphere_box_collision(sphere_body, box_body, dt)
	local center = sphere_body:GetPosition()
	local local_center = box_body:WorldToLocal(center)
	local extents = get_box_extents(box_body)
	local closest_local = Vec3(
		clamp(local_center.x, -extents.x, extents.x),
		clamp(local_center.y, -extents.y, extents.y),
		clamp(local_center.z, -extents.z, extents.z)
	)
	local closest_world = box_body:LocalToWorld(closest_local)
	local delta = center - closest_world
	local distance = delta:GetLength()
	local overlap = sphere_body.Radius - distance
	local normal

	if distance > EPSILON then
		normal = delta / distance
	elseif
		math.abs(local_center.x) <= extents.x and
		math.abs(local_center.y) <= extents.y and
		math.abs(local_center.z) <= extents.z
	then
		local distances = {
			{
				axis = Vec3(get_sign(local_center.x), 0, 0),
				overlap = extents.x - math.abs(local_center.x),
			},
			{
				axis = Vec3(0, get_sign(local_center.y), 0),
				overlap = extents.y - math.abs(local_center.y),
			},
			{
				axis = Vec3(0, 0, get_sign(local_center.z)),
				overlap = extents.z - math.abs(local_center.z),
			},
		}

		table.sort(distances, function(a, b)
			return a.overlap < b.overlap
		end)

		normal = box_body:GetRotation():VecMul(distances[1].axis):GetNormalized()
		overlap = sphere_body.Radius + distances[1].overlap
	else
		return
	end

	if overlap <= 0 then
		return solve_swept_sphere_box_collision(sphere_body, box_body, dt)
	end

	resolve_pair_penetration(box_body, sphere_body, normal, overlap, dt)
	return true
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

local function solve_box_pair_collision(body_a, body_b, dt)
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
			return
		end

		if not test_obb_axis(axes_b[i], delta, extents_a, axes_a, extents_b, axes_b, best) then
			return
		end
	end

	for i = 1, 3 do
		for j = 1, 3 do
			if
				not test_obb_axis(axes_a[i]:GetCross(axes_b[j]), delta, extents_a, axes_a, extents_b, axes_b, best)
			then
				return
			end
		end
	end

	if not best.normal or best.overlap == math.huge then return end

	resolve_pair_penetration(body_a, body_b, best.normal, best.overlap, dt)
end

local function solve_rigid_body_pair(body_a, body_b, entry_a, entry_b, dt)
	local shape_a = body_a.Shape
	local shape_b = body_b.Shape

	if not physics.ShouldBodiesCollide(body_a, body_b) then return end

	if shape_a == "sphere" and shape_b == "sphere" then
		return solve_sphere_pair_collision(body_a, body_b, dt)
	end

	if shape_a == "sphere" and shape_b == "box" then
		return solve_sphere_box_collision(body_a, body_b, dt)
	end

	if shape_a == "box" and shape_b == "sphere" then
		return solve_sphere_box_collision(body_b, body_a, dt)
	end

	if shape_a == "box" and shape_b == "box" then
		return solve_box_pair_collision(body_a, body_b, dt)
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