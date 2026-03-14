local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics/shared.lua")
local RigidBodyComponent = import("goluwa/ecs/components/3d/rigid_body.lua")
local module = {}

local function approach_vec(current, target, delta)
	local diff = target - current
	local length = diff:GetLength()

	if length == 0 or delta <= 0 then return current end

	if length <= delta then return target end

	return current + diff / length * delta
end

local function get_trace_radius(body)
	local shape = body:GetPhysicsShape()

	if shape and shape.GetRadius then return shape:GetRadius() end

	local half_extents = body:GetHalfExtents()
	return math.max(0, math.min(half_extents.x, half_extents.z))
end

local function get_ground_probe(body)
	local shape = body:GetPhysicsShape()
	local radius = get_trace_radius(body)
	local support_local = Vec3(0, 0, 0)

	if shape and shape.GetBottomSphereCenterLocal then
		support_local = shape:GetBottomSphereCenterLocal()
	else
		local half_extents = body:GetHalfExtents()

		if half_extents.y > radius then
			support_local = Vec3(0, -(half_extents.y - radius), 0)
		end
	end

	return radius, support_local
end

local function get_forward_probe_heights(body, radius)
	radius = radius or get_trace_radius(body)
	local shape = body:GetPhysicsShape()
	local heights = {
		math.max(0.02, body.CollisionMargin),
		radius,
	}

	if shape and shape.GetBottomSphereCenterLocal and shape.GetTopSphereCenterLocal then
		local bottom = shape:GetBottomSphereCenterLocal().y
		local top = shape:GetTopSphereCenterLocal().y
		local segment_height = math.max(0, top - bottom)
		local total_height = segment_height + radius * 2
		heights[#heights + 1] = radius + segment_height * 0.35
		heights[#heights + 1] = radius + segment_height * 0.7
		heights[#heights + 1] = math.max(radius, total_height - math.max(0.04, body.CollisionMargin))
	else
		local half_extents = body:GetHalfExtents()
		local total_height = half_extents.y * 2
		heights[#heights + 1] = total_height * 0.5
		heights[#heights + 1] = math.max(radius, total_height - math.max(0.04, body.CollisionMargin))
	end

	return heights
end

local function get_capsule_segment_points(body, position, rotation, radius)
	local shape = body:GetPhysicsShape()
	local points = {}

	if
		shape and
		shape.GetTypeName and
		shape:GetTypeName() == "capsule" and
		shape.GetBottomSphereCenterLocal and
		shape.GetTopSphereCenterLocal
	then
		local bottom = body:LocalToWorld(shape:GetBottomSphereCenterLocal(), position, rotation)
		local top = body:LocalToWorld(shape:GetTopSphereCenterLocal(), position, rotation)
		local segment = top - bottom
		local sample_count = 5

		for i = 0, sample_count - 1 do
			local t = sample_count == 1 and 0 or i / (sample_count - 1)
			points[#points + 1] = bottom + segment * t
		end
	else
		points[#points + 1] = position
	end

	return points, radius
end

local function get_box_contact_for_point(box_body, point, radius)
	local local_point = box_body:WorldToLocal(point)
	local extents = box_body:GetPhysicsShape():GetExtents()
	local top_normal = box_body:GetRotation():VecMul(Vec3(0, 1, 0)):GetNormalized()

	if
		local_point.y >= extents.y and
		math.abs(local_point.x) <= extents.x + radius and
		math.abs(local_point.z) <= extents.z + radius
	then
		local top_local = Vec3(
			math.clamp(local_point.x, -extents.x, extents.x),
			extents.y,
			math.clamp(local_point.z, -extents.z, extents.z)
		)
		local top_world = box_body:LocalToWorld(top_local)
		local separation = (point - top_world):Dot(top_normal)
		local overlap = radius - separation

		if overlap > 0 then
			return {
				normal = top_normal,
				overlap = overlap,
				point = top_world,
				rigid_body = box_body,
				entity = box_body.Owner,
			}
		end
	end

	local closest_local = Vec3(
		math.clamp(local_point.x, -extents.x, extents.x),
		math.clamp(local_point.y, -extents.y, extents.y),
		math.clamp(local_point.z, -extents.z, extents.z)
	)
	local closest_world = box_body:LocalToWorld(closest_local)
	local delta = point - closest_world
	local distance = delta:GetLength()
	local overlap = radius - distance
	local normal

	if distance > 0.00001 then
		normal = delta / distance
	elseif
		math.abs(local_point.x) <= extents.x and
		math.abs(local_point.y) <= extents.y and
		math.abs(local_point.z) <= extents.z
	then
		local distances = {
			{
				axis = Vec3(local_point.x >= 0 and 1 or -1, 0, 0),
				overlap = extents.x - math.abs(local_point.x),
			},
			{
				axis = Vec3(0, local_point.y >= 0 and 1 or -1, 0),
				overlap = extents.y - math.abs(local_point.y),
			},
			{
				axis = Vec3(0, 0, local_point.z >= 0 and 1 or -1),
				overlap = extents.z - math.abs(local_point.z),
			},
		}

		table.sort(distances, function(a, b)
			return a.overlap < b.overlap
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
		point = closest_world,
		rigid_body = box_body,
		entity = box_body.Owner,
	}
end

local is_beyond_box_top_edge

local function resolve_kinematic_box_overlaps(body, predicted, rotation, velocity, radius, ignored_body)
	local points = get_capsule_segment_points(body, predicted, rotation, radius)
	local adjusted = predicted:Copy()
	local adjusted_velocity = velocity:Copy()
	local support_local = select(2, get_ground_probe(body))
	local current_ground_body = body.GetGroundBody and body:GetGroundBody() or nil
	local best_ground = nil

	for _ = 1, 2 do
		local best_contact = nil

		for _, other in ipairs(RigidBodyComponent.Instances or {}) do
			if
				other == body or
				other == ignored_body or
				not (
					physics.IsActiveRigidBody and
					physics.IsActiveRigidBody(other)
				)
			then
				goto continue
			end

			if other.Owner == body.Owner then goto continue end

			local shape = other.GetPhysicsShape and other:GetPhysicsShape()

			if
				not (
					shape and
					shape.GetTypeName and
					shape:GetTypeName() == "box" and
					shape.GetExtents
				)
			then
				goto continue
			end

			for _, point in ipairs(points) do
				local contact = get_box_contact_for_point(other, point, radius)

				if
					contact and
					current_ground_body == other and
					contact.normal.y < body.MinGroundNormalY and
					is_beyond_box_top_edge(other, adjusted + rotation:VecMul(support_local))
				then
					contact = nil
				end

				if contact and (not best_contact or contact.overlap > best_contact.overlap) then
					best_contact = contact
				end
			end

			::continue::
		end

		if not best_contact then break end

		adjusted = adjusted + best_contact.normal * best_contact.overlap
		points = get_capsule_segment_points(body, adjusted, rotation, radius)
		local into = adjusted_velocity:Dot(best_contact.normal)

		if into < 0 then
			adjusted_velocity = adjusted_velocity - best_contact.normal * into
		end

		if best_contact.normal.y >= body.MinGroundNormalY then
			best_ground = best_contact
		end
	end

	return adjusted, adjusted_velocity, best_ground
end

is_beyond_box_top_edge = function(box_body, support_center)
	if not (box_body and box_body.GetPhysicsShape) then return false end

	local shape = box_body:GetPhysicsShape()

	if
		not (
			shape and
			shape.GetTypeName and
			shape:GetTypeName() == "box" and
			shape.GetExtents
		)
	then
		return false
	end

	local extents = shape:GetExtents()
	local local_point = box_body:WorldToLocal(support_center)
	return math.abs(local_point.x) > extents.x or math.abs(local_point.z) > extents.z
end

local function try_land_on_box_top(
	body,
	controller,
	predicted_support_center,
	current_support_center,
	support_offset,
	radius,
	grounded,
	fall_distance,
	ignored_body
)
	local best_landing = nil
	local horizontal_padding = grounded and 0 or radius
	local max_rise = grounded and
		(
			math.max(controller.StepHeight or 0, 0) + body.CollisionMargin + controller.GroundSnapDistance
		)
		or
		math.max(0.12, radius * 0.5)
	local max_drop = math.max(controller.GroundSnapDistance + fall_distance + 0.25, radius + 0.1)

	for _, other in ipairs(RigidBodyComponent.Instances or {}) do
		if
			other == body or
			other == ignored_body or
			not (
				physics.IsActiveRigidBody and
				physics.IsActiveRigidBody(other)
			)
		then
			goto continue
		end

		if other.Owner == body.Owner then goto continue end

		if
			grounded and
			body.GetGroundBody and
			body:GetGroundBody() == other and
			is_beyond_box_top_edge(other, predicted_support_center)
		then
			goto continue
		end

		local shape = other.GetPhysicsShape and other:GetPhysicsShape()

		if
			not (
				shape and
				shape.GetTypeName and
				shape:GetTypeName() == "box" and
				shape.GetExtents
			)
		then
			goto continue
		end

		local extents = shape:GetExtents()
		local local_point = other:WorldToLocal(predicted_support_center)

		if
			math.abs(local_point.x) > extents.x + horizontal_padding or
			math.abs(local_point.z) > extents.z + horizontal_padding
		then
			goto continue
		end

		local top_local = Vec3(
			math.clamp(local_point.x, -extents.x, extents.x),
			extents.y,
			math.clamp(local_point.z, -extents.z, extents.z)
		)
		local top_normal = other:GetRotation():VecMul(Vec3(0, 1, 0)):GetNormalized()

		if top_normal.y < body.MinGroundNormalY then goto continue end

		local top_world = other:LocalToWorld(top_local)
		local target_support_center = top_world + top_normal * (radius + body.CollisionMargin)
		local delta_y = target_support_center.y - predicted_support_center.y
		local rise_from_current = target_support_center.y - current_support_center.y

		if delta_y < -max_drop or delta_y > max_rise then goto continue end

		if grounded and rise_from_current > max_rise then goto continue end

		local score = math.abs(delta_y)

		if not best_landing or score < best_landing.score then
			best_landing = {
				score = score,
				position = target_support_center - support_offset,
				support_center = target_support_center,
				hit = {
					entity = other.Owner,
					rigid_body = other,
					position = top_world,
					normal = top_normal,
				},
				normal = top_normal,
			}
		end

		::continue::
	end

	return best_landing
end

local function get_ground_motion_delta(body, dt)
	if not (body and body.GetGroundBody and body:GetGrounded()) then
		return Vec3(0, 0, 0)
	end

	local ground_body = body:GetGroundBody()

	if
		not (
			ground_body and
			physics.IsActiveRigidBody and
			physics.IsActiveRigidBody(ground_body)
		)
	then
		return Vec3(0, 0, 0)
	end

	local current = ground_body.GetPosition and ground_body:GetPosition()
	local previous = ground_body.GetPreviousPosition and ground_body:GetPreviousPosition() or current

	if current and previous then
		local delta = current - previous

		if delta:GetLength() > 0.00001 then return delta end
	end

	if ground_body.GetVelocity and dt and dt > 0 then
		return ground_body:GetVelocity() * dt
	end

	return Vec3(0, 0, 0)
end

local function trace_options(body, trace_radius)
	return {
		IgnoreRigidBodies = false,
		IgnoreKinematicBodies = true,
		TraceRadius = trace_radius or 0,
	}
end

local function find_forward_obstacle(body, controller, support_center, move, radius, trace_radius)
	local length = move:GetLength()

	if length <= 0.00001 then return nil end

	radius = radius or get_trace_radius(body)
	trace_radius = math.max(trace_radius or 0, 0)
	local direction = move / length
	local probe_base = support_center - physics.Up * math.max(radius - body.CollisionMargin, 0)
	local probe_heights = get_forward_probe_heights(body, radius)
	local max_distance = length + radius + body.CollisionMargin + 0.02

	for _, probe_height in ipairs(probe_heights) do
		local trace_origin = probe_base + physics.Up * probe_height
		local hit = physics.Trace(
			trace_origin,
			direction,
			max_distance,
			body.Owner,
			body.FilterFunction,
			trace_options(body, trace_radius)
		)
		local normal = physics.GetHitNormal(hit, trace_origin)

		if hit and normal and normal.y < body.MinGroundNormalY then
			return hit, normal
		end
	end

	return nil
end

local function try_step_up_against_obstacle(body, controller, support_center, support_offset, move, radius, obstacle_hit)
	local step_height = math.max(controller.StepHeight or 0, 0)

	if step_height <= 0 then return nil end

	radius = radius or get_trace_radius(body)
	local obstacle_normal

	if obstacle_hit then
		obstacle_normal = physics.GetHitNormal(obstacle_hit, support_center)
	else
		obstacle_hit, obstacle_normal = find_forward_obstacle(body, controller, support_center, move, radius, 0)
	end

	if not obstacle_hit then return nil end

	local move_length = move:GetLength()

	if move_length <= 0.00001 then return nil end

	local direction = move / move_length
	local raised_origin = support_center + physics.Up * (
			step_height + radius + body.CollisionMargin + 0.05
		)
	local raised_hit = physics.Trace(
		raised_origin,
		direction,
		move_length + radius + body.CollisionMargin + 0.04,
		body.Owner,
		body.FilterFunction,
		trace_options(body, radius)
	)
	local raised_normal = physics.GetHitNormal(raised_hit, raised_origin)

	if raised_hit and raised_normal and raised_normal.y < body.MinGroundNormalY then
		return nil
	end

	local raised_support_center = raised_origin + move
	local hit = physics.TraceDown(
		raised_support_center,
		radius,
		body.Owner,
		step_height + radius * 2 + body.CollisionMargin + controller.GroundSnapDistance + 0.2,
		body.FilterFunction,
		trace_options(body)
	)
	local hit_normal = physics.GetHitNormal(hit, raised_support_center)

	if not (hit and hit_normal and hit_normal.y >= body.MinGroundNormalY) then
		return nil
	end

	local target_support_center = hit.position + hit_normal * (radius + body.CollisionMargin)
	local rise = target_support_center.y - support_center.y

	if rise <= 0 then return nil end

	if rise > step_height + body.CollisionMargin + controller.GroundSnapDistance then
		return nil
	end

	return {
		position = target_support_center - support_offset,
		support_center = target_support_center,
		hit = hit,
		normal = hit_normal,
		obstacle_hit = obstacle_hit,
		obstacle_normal = obstacle_normal,
	}
end

local function probe_step_landing(body, controller, support_center, support_offset, move, radius)
	local step_height = math.max(controller.StepHeight or 0, 0)
	local move_length = move:GetLength()

	if step_height <= 0 or move_length <= 0.00001 then return nil end

	radius = radius or get_trace_radius(body)
	local direction = move / move_length
	local probe_origin = support_center + move + direction * (
			radius + body.CollisionMargin + 0.05
		) + physics.Up * (
			step_height + radius + body.CollisionMargin + 0.05
		)
	local hit = physics.TraceDown(
		probe_origin,
		radius,
		body.Owner,
		step_height + radius * 2 + body.CollisionMargin + controller.GroundSnapDistance + 0.25,
		body.FilterFunction,
		trace_options(body)
	)
	local hit_normal = physics.GetHitNormal(hit, probe_origin)

	if not (hit and hit_normal and hit_normal.y >= body.MinGroundNormalY) then
		return nil
	end

	local target_support_center = hit.position + hit_normal * (radius + body.CollisionMargin)
	local rise = target_support_center.y - support_center.y
	return {
		rise = rise,
		position = target_support_center - support_offset,
		support_center = target_support_center,
		hit = hit,
		normal = hit_normal,
	}
end

local function try_step_up_on_box_body(body, controller, support_center, support_offset, move, radius)
	local step_height = math.max(controller.StepHeight or 0, 0)
	local move_length = move:GetLength()

	if step_height <= 0 or move_length <= 0.00001 then return nil end

	radius = radius or get_trace_radius(body)
	local predicted_support_center = support_center + move
	local best_step = nil
	local step_limit = step_height + body.CollisionMargin + controller.GroundSnapDistance

	for _, other in ipairs(RigidBodyComponent.Instances or {}) do
		if
			other == body or
			not (
				physics.IsActiveRigidBody and
				physics.IsActiveRigidBody(other)
			)
		then
			goto continue
		end

		if other.Owner == body.Owner then goto continue end

		if
			other.Owner and
			(
				other.Owner.PhysicsNoCollision or
				other.Owner.NoPhysicsCollision
			)
		then
			goto continue
		end

		if controller.FilterFunction and not controller.FilterFunction(other.Owner) then
			goto continue
		end

		local shape = other.GetPhysicsShape and other:GetPhysicsShape()

		if
			not (
				shape and
				shape.GetTypeName and
				shape:GetTypeName() == "box" and
				shape.GetExtents
			)
		then
			goto continue
		end

		local extents = shape:GetExtents()
		local local_point = other:WorldToLocal(predicted_support_center)
		local horizontal_overlap = math.abs(local_point.x) <= extents.x + radius and
			math.abs(local_point.z) <= extents.z + radius

		if not horizontal_overlap then goto continue end

		local top_local = Vec3(
			math.clamp(local_point.x, -extents.x, extents.x),
			extents.y,
			math.clamp(local_point.z, -extents.z, extents.z)
		)
		local top_normal = other:GetRotation():VecMul(Vec3(0, 1, 0)):GetNormalized()

		if top_normal.y < body.MinGroundNormalY then goto continue end

		local top_world = other:LocalToWorld(top_local)
		local target_support_center = top_world + top_normal * (radius + body.CollisionMargin)
		local rise = target_support_center.y - support_center.y

		if rise > 0 and rise <= step_limit then
			if not best_step or rise < best_step.rise then
				best_step = {
					rise = rise,
					position = target_support_center - support_offset,
					support_center = target_support_center,
					hit = {
						entity = other.Owner,
						rigid_body = other,
						position = top_world,
						normal = top_normal,
					},
					normal = top_normal,
				}
			end
		elseif rise > step_limit then
			return false
		end

		::continue::
	end

	return best_step
end

local function should_ignore_box_side_hit(hit, origin, trace_radius)
	local other = hit and hit.rigid_body

	if not (other and other.GetPhysicsShape) then return false end

	local shape = other:GetPhysicsShape()

	if
		not (
			shape and
			shape.GetTypeName and
			shape:GetTypeName() == "box" and
			shape.GetExtents
		)
	then
		return false
	end

	local extents = shape:GetExtents()
	local local_point = other:WorldToLocal(origin)
	local top_local = Vec3(
		math.clamp(local_point.x, -extents.x, extents.x),
		extents.y,
		math.clamp(local_point.z, -extents.z, extents.z)
	)
	local top_world = other:LocalToWorld(top_local)
	return origin.y >= top_world.y - math.max(trace_radius or 0, 0) - 0.08
end

local function clip_horizontal_move_against_world(body, controller, origin, move, trace_radius)
	local length = move:GetLength()

	if length <= 0.00001 then return move end

	local hit, normal = find_forward_obstacle(body, controller, origin, move, get_trace_radius(body), trace_radius)

	if not normal or normal.y >= body.MinGroundNormalY then return move end

	if
		trace_radius and
		trace_radius > 0 and
		should_ignore_box_side_hit(hit, origin, trace_radius)
	then
		return move
	end

	local into = move:Dot(normal)

	if into >= 0 then return move end

	return move - normal * into
end

local function project_move_on_ground(move, normal)
	if not normal then return move end

	local tangent = move - normal * move:Dot(normal)
	local tangent_length = tangent:GetLength()
	local move_length = move:GetLength()

	if tangent_length <= 0.00001 or move_length <= 0.00001 then
		return Vec3(0, 0, 0)
	end

	return tangent / tangent_length * move_length
end

function module.UpdateBody(body, dt, gravity)
	if not body then return end

	local owner = body.Owner
	local controller = body.GetKinematicController and body:GetKinematicController() or nil

	if not (owner and controller and controller.Enabled) then return end

	local controlled_body = controller.GetRigidBody and controller:GetRigidBody() or nil

	if controlled_body ~= body then return end

	if controller.EnsureKinematicBody then controller:EnsureKinematicBody() end

	if not (body.IsKinematic and body:IsKinematic()) then return end

	local velocity = controller.GetVelocity and
		controller:GetVelocity():Copy() or
		body:GetVelocity():Copy()
	local grounded = body:GetGrounded()
	local ground_normal = body.GetGroundNormal and body:GetGroundNormal() or physics.Up
	local desired = controller:GetDesiredVelocity() or Vec3(0, 0, 0)
	local horizontal
	local ground_lift_velocity = 0

	if grounded then
		horizontal = desired:Copy()

		if ground_normal and ground_normal.y >= body.MinGroundNormalY then
			horizontal = project_move_on_ground(horizontal, ground_normal)
			ground_lift_velocity = math.max(horizontal.y or 0, 0)
		end
	else
		horizontal = Vec3(velocity.x, 0, velocity.z)
		local accel = controller.AirAcceleration or controller.Acceleration
		horizontal = approach_vec(horizontal, desired, accel * dt)
	end

	velocity.x = horizontal.x
	velocity.z = horizontal.z

	if grounded and desired:GetLength() < 0.001 then
		local damping = math.exp(-body.LinearDamping * dt)
		velocity.x = velocity.x * damping
		velocity.z = velocity.z * damping
	end

	if controller.MaxFallSpeed and velocity.y < -controller.MaxFallSpeed then
		velocity.y = -controller.MaxFallSpeed
	end

	if grounded then
		if velocity.y < ground_lift_velocity then velocity.y = ground_lift_velocity end
	elseif body.GravityScale ~= 0 then
		velocity = velocity + gravity * (body.GravityScale * dt)
	end

	if controller.SetVelocity then controller:SetVelocity(velocity) end

	body.Velocity = velocity
	local ground_motion = get_ground_motion_delta(body, dt)
	local previous_ground_body = grounded and body.GetGroundBody and body:GetGroundBody() or nil
	body:SetGrounded(false)
	body:SetGroundNormal(physics.Up)
	local radius, support_local = get_ground_probe(body)
	local support_offset = body:GetRotation():VecMul(support_local)
	local current_position = body:GetPosition()
	local current_support_center = current_position + support_offset
	local horizontal_move = Vec3(ground_motion.x + velocity.x * dt, 0, ground_motion.z + velocity.z * dt)
	local leaving_ground_box = previous_ground_body and
		is_beyond_box_top_edge(previous_ground_body, current_support_center + horizontal_move) or
		false

	if grounded and leaving_ground_box then grounded = false end

	local predicted = current_position + Vec3(horizontal_move.x, ground_motion.y + velocity.y * dt, horizontal_move.z)
	local predicted_support_center = predicted + support_offset
	local fall_distance = math.max(0, -velocity.y * dt)
	local step_override = nil
	local obstacle_hit, obstacle_normal = nil, nil
	local landing_probe = nil

	if grounded and horizontal_move:GetLength() > 0.0001 then
		if not leaving_ground_box then
			local box_step = try_step_up_on_box_body(
				body,
				controller,
				current_support_center,
				support_offset,
				horizontal_move,
				radius
			)

			if box_step == false then
				horizontal_move = Vec3(ground_motion.x, 0, ground_motion.z)
			elseif box_step then
				step_override = box_step
			end
		end

		landing_probe = probe_step_landing(body, controller, current_support_center, support_offset, horizontal_move, radius)
		local ignored_box_edge_hit = false

		if not step_override and landing_probe then
			local step_limit = math.max(controller.StepHeight or 0, 0) + body.CollisionMargin + controller.GroundSnapDistance
			local step_down_limit = math.max(
					math.max(controller.StepHeight or 0, 0),
					math.max(controller.GroundSnapDistance or 0, 0)
				) + body.CollisionMargin + controller.GroundSnapDistance

			if landing_probe.rise > 0 and landing_probe.rise <= step_limit then
				step_override = landing_probe
			elseif landing_probe.rise < 0 and -landing_probe.rise <= step_down_limit then
				step_override = landing_probe
			elseif landing_probe.rise > step_limit then
				horizontal_move = Vec3(ground_motion.x, 0, ground_motion.z)
			end
		end

		if not leaving_ground_box then
			obstacle_hit, obstacle_normal = find_forward_obstacle(body, controller, current_support_center, horizontal_move, radius, 0)
		end

		if
			obstacle_hit and
			should_ignore_box_side_hit(obstacle_hit, current_support_center, radius)
		then
			obstacle_hit = nil
			obstacle_normal = nil
			ignored_box_edge_hit = true
		end

		if not step_override and not ignored_box_edge_hit then
			step_override = try_step_up_against_obstacle(
				body,
				controller,
				current_support_center,
				support_offset,
				horizontal_move,
				radius,
				obstacle_hit
			)
		end

		if step_override then
			predicted = step_override.position
			predicted_support_center = step_override.support_center
			velocity.y = 0
		else
			if obstacle_hit and obstacle_normal then
				local into = horizontal_move:Dot(obstacle_normal)

				if into < 0 then horizontal_move = horizontal_move - obstacle_normal * into end
			end

			predicted = current_position + Vec3(horizontal_move.x, ground_motion.y + velocity.y * dt, horizontal_move.z)
			predicted_support_center = predicted + support_offset
		end
	else
		if not leaving_ground_box then
			horizontal_move = clip_horizontal_move_against_world(body, controller, current_support_center, horizontal_move, radius)
		end

		predicted = current_position + Vec3(horizontal_move.x, ground_motion.y + velocity.y * dt, horizontal_move.z)
		predicted_support_center = predicted + support_offset
	end

	local overlap_ground = nil
	predicted, velocity, overlap_ground = resolve_kinematic_box_overlaps(
		body,
		predicted,
		body:GetRotation(),
		velocity,
		radius,
		leaving_ground_box and previous_ground_body or nil
	)
	predicted_support_center = predicted + support_offset
	local cast_up = radius + math.max(1.5, fall_distance + controller.GroundSnapDistance)
	local hit, hit_normal = nil, nil
	local box_top_landing = nil

	if grounded or velocity.y <= 0 then
		box_top_landing = try_land_on_box_top(
			body,
			controller,
			predicted_support_center,
			current_support_center,
			support_offset,
			radius,
			grounded,
			fall_distance,
			leaving_ground_box and previous_ground_body or nil
		)
	end

	if box_top_landing then
		predicted = box_top_landing.position
		predicted_support_center = box_top_landing.support_center
		hit = box_top_landing.hit
		hit_normal = box_top_landing.normal
	end

	local cast_origin = predicted_support_center + physics.Up * cast_up
	local cast_distance = cast_up + radius + controller.GroundSnapDistance + fall_distance + 0.25
	hit = hit or
		physics.TraceDown(
			cast_origin,
			radius,
			owner,
			cast_distance,
			body.FilterFunction,
			trace_options(body)
		)

	if
		grounded and
		hit and
		hit.rigid_body and
		body.GetGroundBody and
		hit.rigid_body == body:GetGroundBody()
		and
		is_beyond_box_top_edge(hit.rigid_body, predicted_support_center)
	then
		local previous_ground_owner = hit.rigid_body.Owner
		local previous_filter = body.FilterFunction
		hit = physics.TraceDown(
			cast_origin,
			radius,
			owner,
			cast_distance,
			function(entity)
				if entity == previous_ground_owner then return false end

				return not previous_filter or previous_filter(entity)
			end,
			trace_options(body)
		)
		hit_normal = nil
	end

	hit_normal = hit_normal or physics.GetHitNormal(hit, predicted_support_center)

	if hit and hit_normal and hit_normal.y >= body.MinGroundNormalY then
		local target_support_center = hit.position + hit_normal * (radius + body.CollisionMargin)
		local max_snap = controller.GroundSnapDistance + fall_distance
		local step_up = math.max(controller.StepHeight or 0, 0)
		local support_rise = target_support_center.y - current_support_center.y
		local allow_step_up = grounded and
			step_up > 0 and
			horizontal_move:GetLength() > 0.0001 and
			support_rise > 0 and
			support_rise <= step_up + body.CollisionMargin + controller.GroundSnapDistance

		if
			velocity.y <= 0 and
			(
				predicted_support_center.y <= target_support_center.y + max_snap or
				allow_step_up
			)
		then
			if step_override then
				predicted = step_override.position
			else
				predicted = predicted:Copy()
				predicted.y = predicted.y + (target_support_center.y - predicted_support_center.y)
			end

			velocity.y = 0

			if controller.SetVelocity then controller:SetVelocity(velocity) end

			body.Velocity = velocity
			body:SetGrounded(true)
			body:SetGroundNormal(hit_normal)
			body:SetGroundEntity(hit.entity)
			body:SetGroundBody(hit.rigid_body)
		end
	end

	if not body:GetGrounded() and overlap_ground then
		body:SetGrounded(true)
		body:SetGroundNormal(overlap_ground.normal)
		body:SetGroundEntity(overlap_ground.entity)
		body:SetGroundBody(overlap_ground.rigid_body)
	end

	body.Position = predicted
end

return module