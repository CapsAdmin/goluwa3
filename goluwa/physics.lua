local event = import("goluwa/event.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = library()
import.loaded["goluwa/physics.lua"] = physics
physics.Gravity = physics.Gravity or Vec3(0, -28, 0)
physics.Up = physics.Up or Vec3(0, 1, 0)
physics.DefaultSkin = physics.DefaultSkin or 0.02
physics.RigidBodySubsteps = physics.RigidBodySubsteps or 6
physics.RigidBodyIterations = physics.RigidBodyIterations or 2
physics.DistanceConstraints = physics.DistanceConstraints or {}
local kinematic_body = import("goluwa/ecs/components/3d/kinematic_body.lua")
local raycast = import("goluwa/raycast.lua")

local function get_rigid_body_meta()
	return import("goluwa/ecs/components/3d/rigid_body.lua")
end

local function is_active_rigid_body(body)
	return body and
		body.Enabled and
		body.Owner and
		body.Owner.IsValid and
		body.Owner:IsValid() and
		body.Owner.transform
end

local function build_filter(ignore_entity, filter_fn, options)
	options = options or {}
	local ignore_kinematic = options.IgnoreKinematicBodies ~= false
	local ignore_rigid = options.IgnoreRigidBodies ~= false
	return function(entity)
		if entity == ignore_entity then return false end

		if entity.PhysicsNoCollision or entity.NoPhysicsCollision then return false end

		if ignore_kinematic and entity.kinematic_body then return false end

		if ignore_rigid and entity.rigid_body then return false end

		if filter_fn and not filter_fn(entity) then return false end

		return true
	end
end

function physics.Trace(origin, direction, max_distance, ignore_entity, filter_fn, options)
	local hits = raycast.Cast(
		origin,
		direction,
		max_distance or math.huge,
		build_filter(ignore_entity, filter_fn, options)
	)
	return hits[1]
end

function physics.TraceDown(origin, radius, ignore_entity, max_distance, filter_fn, options)
	options = options or {}
	local allow_rigid = options.IgnoreRigidBodies == false
	local hits = raycast.Cast(
		origin,
		Vec3(0, -1, 0),
		max_distance or math.huge,
		build_filter(
			ignore_entity,
			filter_fn,
			allow_rigid and
				{IgnoreRigidBodies = true, IgnoreKinematicBodies = options.IgnoreKinematicBodies} or
				options
		)
	)
	local best_hit = nil

	for _, hit in ipairs(hits) do
		if hit.normal and hit.normal.y >= 0 then
			best_hit = hit

			break
		end
	end

	if not best_hit then best_hit = hits[1] end

	if allow_rigid then
		local rigid_body = get_rigid_body_meta()

		for _, body in ipairs(rigid_body.Instances or {}) do
			if
				not (
					is_active_rigid_body(body) and
					body.Shape == "sphere" and
					body.Owner ~= ignore_entity
				)
			then
				goto continue
			end

			if body.Owner and (body.Owner.PhysicsNoCollision or body.Owner.NoPhysicsCollision) then
				goto continue
			end

			if filter_fn and not filter_fn(body.Owner) then goto continue end

			local center = body.Owner and
				body.Owner.transform and
				body.Owner.transform:GetPosition() or
				body:GetPosition()
			local offset = origin - center
			local sphere_radius = body.Radius
			local c = offset:Dot(offset) - sphere_radius * sphere_radius

			if c > 0 and offset.y <= 0 then goto continue end

			local discriminant = offset.y * offset.y - c

			if discriminant < 0 then goto continue end

			local distance = offset.y - math.sqrt(discriminant)

			if distance < 0 then distance = offset.y + math.sqrt(discriminant) end

			if distance < 0 or distance > (max_distance or math.huge) then goto continue end

			local position = origin + Vec3(0, -distance, 0)
			local normal = (position - center):GetNormalized()

			if normal.y < 0 then goto continue end

			if not best_hit or distance < best_hit.distance then
				best_hit = {
					entity = body.Owner,
					distance = distance,
					position = position,
					normal = normal,
					rigid_body = body,
				}
			end

			::continue::
		end
	end

	return best_hit
end

function physics.FindGroundPosition(position, radius, ignore_entity, max_distance, filter_fn)
	local cast_up = radius + 1
	local hit = physics.TraceDown(
		position + physics.Up * cast_up,
		radius,
		ignore_entity,
		(max_distance or 4096) + cast_up,
		filter_fn
	)

	if not hit then return nil end

	return hit.position + hit.normal * (radius + physics.DefaultSkin), hit
end

local function approach_vec(current, target, delta)
	local diff = target - current
	local length = diff:GetLength()

	if length == 0 or delta <= 0 then return current end

	if length <= delta then return target end

	return current + diff / length * delta
end

local function update_control_velocity(body, dt)
	local velocity = body:GetVelocity()
	local desired = body:GetDesiredVelocity() or Vec3(0, 0, 0)
	local horizontal = Vec3(velocity.x, 0, velocity.z)
	local accel = body:GetGrounded() and body.Acceleration or body.AirAcceleration
	horizontal = approach_vec(horizontal, desired, accel * dt)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	if body:GetGrounded() and desired:GetLength() < 0.001 then
		local damping = math.exp(-body.LinearDamping * dt)
		velocity.x = velocity.x * damping
		velocity.z = velocity.z * damping
	end

	body:SetVelocity(velocity)
end

function physics.UpdateKinematicBody(body, dt)
	if not body.Enabled then return end

	update_control_velocity(body, dt)
	local velocity = body:GetVelocity()

	if body.MaxFallSpeed and velocity.y < -body.MaxFallSpeed then
		velocity.y = -body.MaxFallSpeed
	end

	if body.GravityScale ~= 0 then
		velocity = velocity + physics.Gravity * (body.GravityScale * dt)
	end

	body:SetVelocity(velocity)
	local transform = body.Owner.transform
	local position = transform:GetPosition():Copy()
	local predicted = position + velocity * dt
	local fall_distance = math.max(0, -velocity.y * dt)
	local cast_up = body.Radius + math.max(1.5, fall_distance + body.GroundSnapDistance)
	local cast_origin = predicted + physics.Up * cast_up
	local cast_distance = cast_up + body.Radius + body.GroundSnapDistance + fall_distance + 0.25
	local hit = physics.TraceDown(
		cast_origin,
		body.Radius,
		body.Owner,
		cast_distance,
		body.FilterFunction,
		{IgnoreRigidBodies = false}
	)
	body:SetGrounded(false)
	body:SetGroundNormal(physics.Up)
	local hit_normal = physics.GetHitNormal(hit, predicted)

	if hit and hit_normal and hit_normal.y >= body.MinGroundNormalY then
		local target = hit.position + hit_normal * (body.Radius + body.Skin)
		local max_snap = body.GroundSnapDistance + fall_distance

		if velocity.y <= 0 and predicted.y <= target.y + max_snap then
			predicted = target
			velocity.y = 0
			body:SetVelocity(velocity)
			body:SetGrounded(true)
			body:SetGroundNormal(hit_normal)
		end
	end

	transform:SetPosition(predicted)
end

physics.UpdateBody = physics.UpdateKinematicBody

function physics.UpdateKinematicBodies(dt)
	if not dt or dt <= 0 then return end

	for i = #(kinematic_body.Instances or {}), 1, -1 do
		physics.UpdateKinematicBody(kinematic_body.Instances[i], dt)
	end
end

local DistanceConstraint = {}
DistanceConstraint.__index = DistanceConstraint

local function remove_distance_constraint(target)
	for i = #physics.DistanceConstraints, 1, -1 do
		if physics.DistanceConstraints[i] == target then
			table.remove(physics.DistanceConstraints, i)
			return
		end
	end
end

local function copy_vec(vec)
	return vec and vec:Copy() or nil
end

function DistanceConstraint:GetWorldPosition0()
	if self.Body0 then return self.Body0:LocalToWorld(self.LocalPosition0) end

	return self.WorldPosition0
end

function DistanceConstraint:GetWorldPosition1()
	if self.Body1 then return self.Body1:LocalToWorld(self.LocalPosition1) end

	return self.WorldPosition1
end

function DistanceConstraint:SetWorldPosition0(vec)
	self.WorldPosition0 = vec:Copy()

	if self.Body0 then self.LocalPosition0 = self.Body0:WorldToLocal(vec) end

	return self
end

function DistanceConstraint:SetWorldPosition1(vec)
	self.WorldPosition1 = vec:Copy()

	if self.Body1 then self.LocalPosition1 = self.Body1:WorldToLocal(vec) end

	return self
end

function DistanceConstraint:Solve(dt)
	if not self.Enabled then return 0 end

	local world_pos0 = self:GetWorldPosition0()
	local world_pos1 = self:GetWorldPosition1()

	if not (world_pos0 and world_pos1 and self.Body0) then return 0 end

	local correction = world_pos1 - world_pos0
	local length = correction:GetLength()

	if length == 0 then return 0 end

	if self.Unilateral and length < self.Distance then return 0 end

	correction = correction / length * (length - self.Distance)
	return self.Body0:ApplyCorrection(self.Compliance or 0, correction, world_pos0, self.Body1, world_pos1, dt)
end

function DistanceConstraint:Destroy()
	remove_distance_constraint(self)
end

function physics.CreateDistanceConstraint(body0, body1, pos0, pos1, distance, compliance, unilateral)
	local constraint = setmetatable(
		{
			Body0 = body0,
			Body1 = body1,
			Distance = distance or ((pos1 - pos0):GetLength()),
			Compliance = compliance or 0,
			Unilateral = unilateral or false,
			Enabled = true,
		},
		DistanceConstraint
	)

	if body0 then
		constraint.LocalPosition0 = body0:WorldToLocal(pos0)
	else
		constraint.WorldPosition0 = copy_vec(pos0)
	end

	if body1 then
		constraint.LocalPosition1 = body1:WorldToLocal(pos1)
	else
		constraint.WorldPosition1 = copy_vec(pos1)
	end

	table.insert(physics.DistanceConstraints, constraint)
	return constraint
end

physics.AddDistanceConstraint = physics.CreateDistanceConstraint

local function get_hit_face_normal(hit)
	if
		not (
			hit and
			hit.primitive and
			hit.primitive.polygon3d and
			hit.triangle_index ~= nil
		)
	then
		return hit and hit.normal or nil
	end

	local poly = hit.primitive.polygon3d
	local vertices = poly.Vertices

	if not vertices or #vertices == 0 then return hit.normal end

	local base = hit.triangle_index * 3
	local indices = poly.indices
	local i0
	local i1
	local i2

	if indices then
		i0 = indices[base + 1] + 1
		i1 = indices[base + 2] + 1
		i2 = indices[base + 3] + 1
	else
		i0 = base + 1
		i1 = base + 2
		i2 = base + 3
	end

	local v0 = vertices[i0] and vertices[i0].pos
	local v1 = vertices[i1] and vertices[i1].pos
	local v2 = vertices[i2] and vertices[i2].pos

	if not (v0 and v1 and v2) then return hit.normal end

	if hit.entity and hit.entity.transform then
		local world = hit.entity.transform:GetWorldMatrix()
		v0 = Vec3(world:TransformVector(v0.x, v0.y, v0.z))
		v1 = Vec3(world:TransformVector(v1.x, v1.y, v1.z))
		v2 = Vec3(world:TransformVector(v2.x, v2.y, v2.z))
	end

	return (v1 - v0):GetCross(v2 - v0):GetNormalized()
end

function physics.GetHitNormal(hit, reference_point)
	local normal = get_hit_face_normal(hit)

	if not normal then return nil end

	if reference_point and hit and hit.position then
		if (reference_point - hit.position):Dot(normal) < 0 then normal = normal * -1 end
	elseif hit and hit.normal and normal:Dot(hit.normal) < 0 then
		normal = normal * -1
	end

	return normal
end

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
			is_active_rigid_body(body) and
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

	local inverse_mass_a = body_a.InverseMass
	local inverse_mass_b = body_b.InverseMass
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

local function solve_rigid_body_pairs(bodies, dt)
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

local function solve_distance_constraints(dt)
	for i = #physics.DistanceConstraints, 1, -1 do
		local constraint = physics.DistanceConstraints[i]

		if constraint and constraint.Enabled ~= false then constraint:Solve(dt) end
	end
end

function physics.UpdateRigidBodies(dt)
	if not dt or dt <= 0 then return end

	local rigid_body = get_rigid_body_meta()
	local bodies = rigid_body.Instances or {}

	if #bodies == 0 then return end

	local substeps = math.max(1, physics.RigidBodySubsteps or 1)
	local iterations = math.max(1, physics.RigidBodyIterations or 1)
	local sub_dt = dt / substeps

	for _, body in ipairs(bodies) do
		if is_active_rigid_body(body) then body:SynchronizeFromTransform() end
	end

	for _ = 1, substeps do
		for _, body in ipairs(bodies) do
			if is_active_rigid_body(body) then
				body:SetGrounded(false)
				body:SetGroundNormal(physics.Up)
				body:Integrate(sub_dt, physics.Gravity)
			end
		end

		for _ = 1, iterations do
			solve_distance_constraints(sub_dt)
			solve_rigid_body_pairs(bodies, sub_dt)

			for _, body in ipairs(bodies) do
				if is_active_rigid_body(body) then
					solve_motion_contacts(body, sub_dt)
					solve_support_contacts(body, sub_dt)
				end
			end
		end

		for _, body in ipairs(bodies) do
			if is_active_rigid_body(body) then body:UpdateVelocities(sub_dt) end
		end
	end

	for _, body in ipairs(bodies) do
		if is_active_rigid_body(body) then body:WriteToTransform() end
	end
end

function physics.Update(dt)
	if not dt or dt <= 0 then return end

	physics.UpdateRigidBodies(dt)
	physics.UpdateKinematicBodies(dt)
end

event.AddListener("Update", "physics", function(dt)
	physics.Update(dt)
end)

return physics