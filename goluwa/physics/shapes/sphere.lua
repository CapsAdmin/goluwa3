local prototype = import("goluwa/prototype.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local segment_geometry = import("goluwa/physics/segment_geometry.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local sample_points = import("goluwa/physics/shapes/sample_points.lua")
local sweep_helpers = import("goluwa/physics/shapes/sweep_helpers.lua")
local META = prototype.CreateTemplate("physics_shape_sphere")
META.Base = BaseShape
META:GetSet("Radius", 0.5)
local EPSILON = physics_constants.EPSILON

local function evaluate_point_against_capsule_segment(start_world, movement, segment_a, segment_b, t)
	local point = start_world + movement * t
	local closest = segment_geometry.ClosestPointOnSegment(segment_a, segment_b, point, EPSILON)
	local delta = point - closest
	local distance = delta:GetLength()
	return point, closest, delta, distance
end

local function sweep_point_against_capsule_segment(start_world, end_world, segment_a, segment_b, radius)
	local movement = end_world - start_world
	local movement_length = movement:GetLength()

	if movement_length <= EPSILON then return nil end

	local _, _, _, start_distance = evaluate_point_against_capsule_segment(start_world, movement, segment_a, segment_b, 0)

	if start_distance <= radius then return nil end

	local sample_steps = math.max(12, math.min(64, math.ceil(movement_length / math.max(radius, 0.125)) * 2))
	local previous_t = 0

	for i = 1, sample_steps do
		local t = i / sample_steps
		local _, _, _, distance = evaluate_point_against_capsule_segment(start_world, movement, segment_a, segment_b, t)

		if distance <= radius then
			local low = previous_t
			local high = t

			for _ = 1, 14 do
				local mid = (low + high) * 0.5
				local _, _, _, mid_distance = evaluate_point_against_capsule_segment(start_world, movement, segment_a, segment_b, mid)

				if mid_distance <= radius then high = mid else low = mid end
			end

			local point, closest, delta, final_distance = evaluate_point_against_capsule_segment(start_world, movement, segment_a, segment_b, high)
			local normal = final_distance > EPSILON and
				(
					delta / final_distance
				)
				or
				sweep_helpers.EnsureNormalFacesMotion((point - ((segment_a + segment_b) * 0.5)):GetNormalized(), movement)

			if not normal or normal:GetLength() <= EPSILON then return nil end

			return {
				t = high,
				point = point - normal * radius,
				position = closest,
				normal = normal,
			}
		end

		previous_t = t
	end

	return nil
end

function META.New(radius)
	local shape = META:CreateObject()
	shape:SetRadius(radius or 0.5)
	return shape
end

function META:GetTypeName()
	return "sphere"
end

function META:GetHalfExtents()
	local radius = self:GetRadius()
	return Vec3(radius, radius, radius)
end

function META:GetAutomaticMass(body)
	local radius = self:GetRadius()
	return (4 / 3) * math.pi * radius * radius * radius * body:GetDensity()
end

function META:BuildInertia(mass)
	return self:BuildSphereInertia(mass, self:GetRadius())
end

function META:GeometryLocalToWorld(body, local_pos, position, _, out)
	position = position or body:GetPosition()
	out = out or Vec3()
	out.x = position.x + local_pos.x
	out.y = position.y + local_pos.y
	out.z = position.z + local_pos.z
	return out
end

function META:GetBroadphaseAABB(body, position)
	position = position or body:GetPosition()
	local radius = self:GetRadius()
	return AABB(
		position.x - radius,
		position.y - radius,
		position.z - radius,
		position.x + radius,
		position.y + radius,
		position.z + radius
	)
end

function META:BuildCollisionLocalPoints()
	return sample_points.BuildSphereCollisionPoints(self:GetRadius())
end

function META:BuildSupportLocalPoints()
	return sample_points.BuildSphereSupportPoints(self:GetRadius())
end

function META:SolveSupportContacts(body, dt, support_contacts)
	local radius = self:GetRadius()
	local hit = support_contacts.SweepSphere(body, dt, radius)
	local normal = hit and hit.normal or nil
	local contact_position = hit and hit.position or nil

	if not hit then return end

	support_contacts.ApplyWorldSupportContact(body, normal, contact_position, radius, hit, dt)
end

function META:OnGroundedVelocityUpdate(body, dt)
	local radius = self:GetRadius()

	if radius <= 0 then return end

	local normal_velocity = body.GroundNormal * body.Velocity:Dot(body.GroundNormal)
	local tangent_velocity = body.Velocity - normal_velocity
	local tangent_speed = tangent_velocity:GetLength()
	local rolling_friction = math.max(body:GetGroundRollingFriction() or 0, 0)

	if tangent_speed > 0.0001 and rolling_friction > 0 and dt and dt > 0 then
		local damping = math.exp(-rolling_friction * dt)
		tangent_velocity = tangent_velocity * damping
		body.Velocity = normal_velocity + tangent_velocity
		tangent_speed = tangent_velocity:GetLength()
	end

	local rolling_angular = body.GroundNormal:GetCross(tangent_velocity) / radius
	local normal_angular = body.GroundNormal * body.AngularVelocity:Dot(body.GroundNormal)

	if tangent_speed <= 0.0001 then
		body.AngularVelocity = normal_angular
		return
	end

	body.AngularVelocity = rolling_angular + normal_angular
end

function META:TraceAgainstBody(body, origin, direction, max_distance, trace_radius)
	local owner = body:GetOwner()
	local center = owner and
		owner.transform and
		owner.transform:GetPosition() or
		body:GetPosition()
	local ray_direction = direction and direction:GetNormalized() or Vec3(0, 0, 0)

	if ray_direction:GetLength() <= 0.00001 then return nil end

	local sphere_radius = self:GetRadius() + math.max(trace_radius or 0, 0)
	local offset = origin - center
	local b = offset:Dot(ray_direction)
	local c = offset:Dot(offset) - sphere_radius * sphere_radius
	local discriminant = b * b - c

	if discriminant < 0 then return nil end

	local distance = -b - math.sqrt(discriminant)

	if distance < 0 then distance = -b + math.sqrt(discriminant) end

	if distance < 0 or distance > (max_distance or math.huge) then return nil end

	local expanded_position = origin + ray_direction * distance
	local normal = (expanded_position - center):GetNormalized()
	local position = expanded_position - normal * math.max(trace_radius or 0, 0)
	return {
		entity = owner,
		distance = distance,
		position = position,
		normal = normal,
		rigid_body = body.GetBody and body:GetBody() or body,
	}
end

function META:SweepPointAgainstBody(collider, origin, movement, radius, target_state, max_fraction)
	local target_radius = collider:GetSphereRadius()
	local target_position = target_state.previous_position
	local relative_movement = movement - target_state.movement
	local delta = origin - target_position
	local combined_radius = radius + target_radius
	local a = relative_movement:Dot(relative_movement)
	local b = 2 * delta:Dot(relative_movement)
	local c = delta:Dot(delta) - combined_radius * combined_radius

	if a <= 0.000001 or c <= 0.000001 then return nil end

	local discriminant = b * b - 4 * a * c

	if discriminant < 0 then return nil end

	local t = (-b - math.sqrt(discriminant)) / (2 * a)

	if t < 0 or t > max_fraction then return nil end

	local center = origin + relative_movement * t
	local normal = (center - target_position):GetNormalized()
	return {
		t = t,
		position = target_position + normal * target_radius,
		point = center - normal * radius,
		normal = normal,
	}
end

function META:SweepColliderAgainstBody(
	target_collider,
	query_collider,
	query_polyhedron,
	start_position,
	rotation,
	movement,
	target_state,
	max_fraction
)
	local target_radius = self:GetRadius()
	local target_center = target_state.previous_position
	local query_shape_type = query_collider:GetShapeType()

	if query_shape_type == "capsule" then
		local segment_a, segment_b, capsule_radius = capsule_geometry.GetSegmentWorld(query_collider, start_position, rotation)
		local raw_hit = sweep_point_against_capsule_segment(
			target_center,
			target_center - (movement - target_state.movement) * max_fraction,
			segment_a,
			segment_b,
			capsule_radius + target_radius
		)

		if not raw_hit then return nil end

		local normal = raw_hit.normal * -1
		local hit_fraction = raw_hit.t * max_fraction
		return {
			t = hit_fraction,
			point = raw_hit.point,
			position = target_center + target_state.movement * hit_fraction + normal * target_radius,
			normal = normal,
		}
	end

	if query_polyhedron and query_polyhedron.vertices and query_polyhedron.faces then
		local relative_movement = movement - target_state.movement
		local raw_hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
			query_collider,
			query_polyhedron,
			target_center,
			target_center - relative_movement * max_fraction,
			target_radius,
			start_position,
			rotation
		)

		if not raw_hit then return nil end

		local normal = raw_hit.normal * -1
		local hit_fraction = raw_hit.t * max_fraction
		local hit_center = target_center + target_state.movement * hit_fraction
		return {
			t = hit_fraction,
			point = raw_hit.position or (hit_center + normal * target_radius),
			position = hit_center + normal * target_radius,
			normal = normal,
		}
	end

	return nil
end

return META:Register()
