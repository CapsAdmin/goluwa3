local prototype = import("goluwa/prototype.lua")
local physics_constants = import("goluwa/physics/constants.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local capsule_geometry = import("goluwa/physics/capsule_geometry.lua")
local segment_geometry = import("goluwa/physics/segment_geometry.lua")
local sample_points = import("goluwa/physics/shapes/sample_points.lua")
local sweep_helpers = import("goluwa/physics/shapes/sweep_helpers.lua")
local META = prototype.CreateTemplate("physics_shape_capsule")
META.Base = BaseShape
META:GetSet("Radius", 0.5)
META:GetSet("Height", 2)
local EPSILON = physics_constants.EPSILON
local CAPSULE_CAPSULE_SWEEP_CONTEXT = {
	start_a = nil,
	start_b = nil,
	end_a = nil,
	end_b = nil,
	target_collider = nil,
	target_state = nil,
	max_fraction = 0,
	combined_radius = 0,
}

local function evaluate_capsule_capsule_sample(context, t)
	if t == nil then
		t = context
		context = CAPSULE_CAPSULE_SWEEP_CONTEXT
	end

	local query_a = context.start_a + (context.end_a - context.start_a) * t
	local query_b = context.start_b + (context.end_b - context.start_b) * t
	local target_position_t, target_rotation_t = sweep_helpers.GetTargetPose(context.target_state, t, context.max_fraction)
	local target_a, target_b = capsule_geometry.GetSegmentWorld(context.target_collider, target_position_t, target_rotation_t)
	local point_a, point_b = segment_geometry.ClosestPointsBetweenSegments(query_a, query_b, target_a, target_b, EPSILON)
	local delta = point_a - point_b
	local distance = delta:GetLength()

	if distance <= context.combined_radius then
		return {point_a = point_a, point_b = point_b, delta = delta, distance = distance}
	end

	return nil
end

local function select_polyhedron_capsule_body_hit(context, start_sample, end_sample)
	local raw_hit = pair_solver_helpers.SweepPointAgainstPolyhedron(
		context.collider,
		context.polyhedron,
		start_sample,
		end_sample - context.movement * context.max_fraction,
		context.radius,
		context.start_position,
		context.rotation
	)

	if not raw_hit then return nil end

	local normal = raw_hit.normal * -1
	local hit_fraction = raw_hit.t * context.max_fraction
	local center = start_sample + (end_sample - start_sample) * raw_hit.t
	return {
		t = hit_fraction,
		point = raw_hit.position or (center + normal * context.radius),
		position = center + normal * context.radius,
		normal = normal,
	}
end

local function clamp_height(radius, height)
	return math.max(height or radius * 2, radius * 2)
end

function META.New(radius, height)
	local shape = META:CreateObject()
	shape:SetRadius(radius or 0.5)
	shape:SetHeight(clamp_height(radius or 0.5, height or 2))
	return shape
end

function META:GetTypeName()
	return "capsule"
end

function META:OnBodyGeometryChanged(body)
	BaseShape.OnBodyGeometryChanged(self, body)
	self:SetHeight(clamp_height(self:GetRadius(), self:GetHeight()))
end

function META:GetCylinderHeight()
	return capsule_geometry.GetCylinderHeight(self)
end

function META:GetCylinderHalfHeight()
	return capsule_geometry.GetCylinderHalfHeight(self)
end

function META:GetHalfExtents()
	return Vec3(self:GetRadius(), self:GetHeight() * 0.5, self:GetRadius())
end

function META:GetBottomSphereCenterLocal()
	return capsule_geometry.GetBottomSphereCenterLocal(self)
end

function META:GetTopSphereCenterLocal()
	return capsule_geometry.GetTopSphereCenterLocal(self)
end

function META:GetSupportRadiusAlongNormal(body, normal)
	normal = normal and normal:GetNormalized() or Vec3(0, 1, 0)
	local axis = body:GetRotation():VecMul(Vec3(0, 1, 0)):GetNormalized()
	return self:GetRadius() + self:GetCylinderHalfHeight() * math.abs(axis:Dot(normal))
end

function META:GetAutomaticMass(body)
	local radius = self:GetRadius()
	local cylinder_height = self:GetCylinderHeight()
	local cylinder_volume = math.pi * radius * radius * cylinder_height
	local sphere_volume = (4 / 3) * math.pi * radius * radius * radius
	return (cylinder_volume + sphere_volume) * body:GetDensity()
end

function META:BuildInertia(mass)
	local zero_mass, zero_inertia = self:ZeroMassInertia(mass)

	if zero_mass then return zero_mass, zero_inertia end

	local radius = self:GetRadius()
	local cylinder_height = self:GetCylinderHeight()
	local cylinder_volume = math.pi * radius * radius * cylinder_height
	local sphere_volume = (4 / 3) * math.pi * radius * radius * radius
	local total_volume = cylinder_volume + sphere_volume
	local cylinder_mass = total_volume > 0 and mass * (cylinder_volume / total_volume) or 0
	local sphere_mass = mass - cylinder_mass
	local iyy = 0.5 * cylinder_mass * radius * radius + (2 / 5) * sphere_mass * radius * radius
	local ixx = (
			1 / 12
		) * cylinder_mass * (
			3 * radius * radius + cylinder_height * cylinder_height
		) + (
			2 / 5
		) * sphere_mass * radius * radius + sphere_mass * (
			cylinder_height * cylinder_height
		) * 0.25
	local izz = ixx
	return mass, Matrix33():SetDiagonal(ixx, iyy, izz)
end

function META:BuildCollisionLocalPoints()
	return sample_points.BuildCapsuleCollisionPoints(self:GetRadius(), self:GetCylinderHalfHeight())
end

function META:BuildSupportLocalPoints()
	return sample_points.BuildCapsuleSupportPoints(self:GetRadius(), self:GetCylinderHalfHeight())
end

function META:SolveSupportContacts(body, dt, support_contacts)
	local hit = support_contacts.SweepCollider(body, dt)
	local normal = hit and hit.normal or nil
	local contact_position = hit and hit.position or nil

	if not hit then return end

	support_contacts.ApplyWorldSupportContact(
		body,
		normal,
		contact_position,
		self:GetSupportRadiusAlongNormal(body, normal),
		hit,
		dt
	)
end

function META:SweepPointAgainstBody(collider, origin, movement, radius, target_state, max_fraction)
	local capsule_radius = self:GetRadius()
	return sweep_helpers.SweepSampledPointAgainstMovingTarget(
		origin,
		movement,
		radius,
		target_state,
		max_fraction,
		sweep_helpers.GetPointSweepSampleSteps(movement:GetLength(), radius + capsule_radius, max_fraction),
		function(context, point, position, rotation, relative_movement)
			return sweep_helpers.GetCapsuleContactForPointAtPose(
				context.collider,
				point,
				context.radius,
				position,
				rotation,
				relative_movement
			)
		end,
		{
			collider = collider,
			radius = radius,
		}
	)
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
	if query_collider:GetShapeType() == "capsule" then
		local start_a, start_b, radius_a = capsule_geometry.GetSegmentWorld(query_collider, start_position, rotation)
		local end_a, end_b = capsule_geometry.GetSegmentWorld(query_collider, start_position + movement * max_fraction, rotation)
		local _, _, radius_b = capsule_geometry.GetSegmentWorld(target_collider, target_state.previous_position, target_state.previous_rotation)
		local combined_radius = radius_a + radius_b
		CAPSULE_CAPSULE_SWEEP_CONTEXT.start_a = start_a
		CAPSULE_CAPSULE_SWEEP_CONTEXT.start_b = start_b
		CAPSULE_CAPSULE_SWEEP_CONTEXT.end_a = end_a
		CAPSULE_CAPSULE_SWEEP_CONTEXT.end_b = end_b
		CAPSULE_CAPSULE_SWEEP_CONTEXT.target_collider = target_collider
		CAPSULE_CAPSULE_SWEEP_CONTEXT.target_state = target_state
		CAPSULE_CAPSULE_SWEEP_CONTEXT.max_fraction = max_fraction
		CAPSULE_CAPSULE_SWEEP_CONTEXT.combined_radius = combined_radius
		local hit_t, hit_data = sweep_helpers.FindFirstSampledHit(
			max_fraction,
			math.max(
				8,
				math.min(
					32,
					math.ceil((movement:GetLength() * max_fraction) / math.max(combined_radius, 0.2)) * 2
				)
			),
			evaluate_capsule_capsule_sample,
			CAPSULE_CAPSULE_SWEEP_CONTEXT
		)
		CAPSULE_CAPSULE_SWEEP_CONTEXT.start_a = nil
		CAPSULE_CAPSULE_SWEEP_CONTEXT.start_b = nil
		CAPSULE_CAPSULE_SWEEP_CONTEXT.end_a = nil
		CAPSULE_CAPSULE_SWEEP_CONTEXT.end_b = nil
		CAPSULE_CAPSULE_SWEEP_CONTEXT.target_collider = nil
		CAPSULE_CAPSULE_SWEEP_CONTEXT.target_state = nil
		CAPSULE_CAPSULE_SWEEP_CONTEXT.max_fraction = 0
		CAPSULE_CAPSULE_SWEEP_CONTEXT.combined_radius = 0

		if not hit_data then return nil end

		local point_a = hit_data.point_a
		local point_b = hit_data.point_b
		local delta = hit_data.delta
		local distance = hit_data.distance
		local normal = distance > EPSILON and
			(
				delta / distance
			)
			or
			sweep_helpers.EnsureNormalFacesMotion(
				(start_position - target_state.previous_position):GetNormalized(),
				movement - target_state.movement
			)
		return {
			t = hit_t,
			point = point_a - normal * radius_a,
			position = point_b + normal * radius_b,
			normal = normal,
		}
	end

	if query_polyhedron and query_polyhedron.vertices and query_polyhedron.faces then
		local start_samples, end_samples, radius = sweep_helpers.GetCapsuleMotionSamples(
			target_collider,
			target_state.previous_position,
			target_state.previous_rotation,
			target_state.current_position,
			target_state.current_rotation,
			"polyhedron_body_capsule_previous_samples",
			"polyhedron_body_capsule_current_samples"
		)
		local context = {
			collider = query_collider,
			polyhedron = query_polyhedron,
			movement = movement,
			max_fraction = max_fraction,
			radius = radius,
			start_position = start_position,
			rotation = rotation,
		}
		return sweep_helpers.FindBestCapsuleSampleHit(
			start_samples,
			end_samples,
			radius,
			target_state.movement * max_fraction,
			select_polyhedron_capsule_body_hit,
			context
		)
	end

	return nil
end

return META:Register()
