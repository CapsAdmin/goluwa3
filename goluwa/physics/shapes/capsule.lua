local prototype = import("goluwa/prototype.lua")
local physics = import("goluwa/physics.lua")
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
local CAPSULE_SUPPORT_CONTACT_CONTEXT = {
	best_point = nil,
}
local get_ground_normal
local get_capsule_axis_world

local function build_support_plane_basis(normal)
	normal = normal and normal:GetNormalized() or Vec3(0, 1, 0)
	local reference = math.abs(normal.y) < 0.999 and Vec3(0, 1, 0) or Vec3(1, 0, 0)
	local tangent = reference:GetCross(normal)

	if tangent:GetLength() <= 0.000001 then
		tangent = Vec3(0, 0, 1):GetCross(normal)
	end

	tangent = tangent:GetNormalized()
	local bitangent = normal:GetCross(tangent):GetNormalized()
	return tangent, bitangent
end

local function get_ground_support_tolerance(body, radius)
	return math.max(
		(body:GetCollisionMargin() or 0) * 2,
		(body:GetCollisionProbeDistance() or 0) * 0.5,
		(radius or 0) * 0.2,
		0.05
	)
end

local function collect_capsule_support_contact(context, collider, point, fallback_hit, fallback_dt)
	if not (fallback_hit and fallback_hit.normal and fallback_hit.position and point) then
		return
	end

	local ground_body = fallback_hit.rigid_body
	local ground_shape = ground_body and
		ground_body.GetPhysicsShape and
		ground_body:GetPhysicsShape() or
		nil

	if not (ground_body and ground_shape and ground_shape.Heightmap ~= nil) then
		return
	end

	local margin = collider:GetCollisionMargin() or 0
	local depth = (fallback_hit.position + fallback_hit.normal * margin - point):Dot(fallback_hit.normal)
	local support_tolerance = (collider:GetCollisionProbeDistance() or 0) + margin

	if depth < -support_tolerance then return end

	local best_point = context.best_point

	if
		not best_point or
		depth > best_point.depth or
		(
			math.abs(depth - best_point.depth) <= 0.000001 and
			fallback_hit.normal.y > best_point.hit.normal.y
		)
	then
		context.best_point = {
			body = collider,
			point = point,
			hit = fallback_hit,
			dt = fallback_dt,
			depth = depth,
		}
	end
end

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

function META:GetSupportFootprintMetrics(body, ground_normal)
	ground_normal = ground_normal or body.GroundNormal or Vec3(0, 1, 0)
	local support = body.GetGroundSupportProjectionMetrics and
		body:GetGroundSupportProjectionMetrics() or
		{
			count = 0,
			span_u = 0,
			span_v = 0,
			overhang_length = math.huge,
		}
	local tangent = support.tangent
	local bitangent = support.bitangent

	if not tangent or not bitangent then
		tangent, bitangent = build_support_plane_basis(ground_normal)
	end

	local axis = get_capsule_axis_world(body)
	local radius = self:GetRadius()
	local cylinder_half_height = self:GetCylinderHalfHeight()
	local footprint_half_u = radius + cylinder_half_height * math.abs(axis:Dot(tangent))
	local footprint_half_v = radius + cylinder_half_height * math.abs(axis:Dot(bitangent))
	local footprint_span_u = footprint_half_u * 2
	local footprint_span_v = footprint_half_v * 2
	local major_footprint_span = math.max(footprint_span_u, footprint_span_v)
	local minor_footprint_span = math.min(footprint_span_u, footprint_span_v)
	local support_span_u = support.span_u or 0
	local support_span_v = support.span_v or 0
	local coverage_u = footprint_span_u > 0.0001 and
		math.min(1, support_span_u / footprint_span_u) or
		0
	local coverage_v = footprint_span_v > 0.0001 and
		math.min(1, support_span_v / footprint_span_v) or
		0
	local footprint_area = footprint_span_u * footprint_span_v
	local support_area = support_span_u * support_span_v
	local area_coverage = footprint_area > 0.0001 and math.min(1, support_area / footprint_area) or 0
	local tolerance = get_ground_support_tolerance(body, radius)
	return {
		support = support,
		tangent = tangent,
		bitangent = bitangent,
		axis = axis,
		footprint_span_u = footprint_span_u,
		footprint_span_v = footprint_span_v,
		major_footprint_span = major_footprint_span,
		minor_footprint_span = minor_footprint_span,
		support_span_u = support_span_u,
		support_span_v = support_span_v,
		coverage_u = coverage_u,
		coverage_v = coverage_v,
		min_coverage = math.min(coverage_u, coverage_v),
		area_coverage = area_coverage,
		support_width_coverage = minor_footprint_span > 0.0001 and
			math.min(1, (support.max_span or 0) / minor_footprint_span) or
			0,
		tolerance = tolerance,
		stable = (support.overhang_length or math.huge) <= tolerance,
	}
end

get_ground_normal = function(body)
	local normal = body.GroundNormal or Vec3(0, 1, 0)

	if normal:GetLength() <= EPSILON then return Vec3(0, 1, 0) end

	return normal:GetNormalized()
end
get_capsule_axis_world = function(body)
	local axis = body:GetRotation():VecMul(Vec3(0, 1, 0))

	if axis:GetLength() <= EPSILON then return Vec3(0, 1, 0) end

	return axis:GetNormalized()
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
	local ground_body = hit and hit.rigid_body or nil
	local ground_shape = ground_body and
		ground_body.GetPhysicsShape and
		ground_body:GetPhysicsShape() or
		nil

	if ground_shape and ground_shape.Heightmap ~= nil then
		CAPSULE_SUPPORT_CONTACT_CONTEXT.best_point = nil
		support_contacts.ForEachPointSweepContact(body, dt, collect_capsule_support_contact, CAPSULE_SUPPORT_CONTACT_CONTEXT)
		local best_point = CAPSULE_SUPPORT_CONTACT_CONTEXT.best_point
		CAPSULE_SUPPORT_CONTACT_CONTEXT.best_point = nil

		if best_point then
			support_contacts.ApplyPointWorldSupportContact(
				best_point.body,
				best_point.hit.normal,
				best_point.hit.position,
				best_point.point,
				best_point.hit,
				best_point.dt
			)
		end
	end

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

function META:OnGroundedVelocityUpdate(body, dt)
	if not dt or dt <= 0 then return end

	local ground_body = body.GetGroundBody and body:GetGroundBody() or nil
	local ground_shape = ground_body and
		ground_body.GetPhysicsShape and
		ground_body:GetPhysicsShape() or
		nil
	local pair_friction = 0
	local ground_friction = ground_body and ground_body.GetFriction and ground_body:GetFriction() or 0

	if ground_body and physics and physics.solver and physics.solver.GetPairFriction then
		pair_friction = physics.solver:GetPairFriction(body, ground_body) or 0
	end

	local friction = math.max(
		body:GetGroundRollingFriction() or 0,
		body:GetFriction() or 0,
		pair_friction,
		ground_friction
	)

	if friction <= 0 then return end

	local ground_normal = get_ground_normal(body)
	local is_heightmap_ground = ground_shape and ground_shape.Heightmap ~= nil
	local axis = get_capsule_axis_world(body)
	local upright_alignment = math.abs(axis:Dot(ground_normal))
	local support_metrics = self:GetSupportFootprintMetrics(body, ground_normal)
	local support = support_metrics.support or {count = 0, overhang_length = math.huge}
	local normal_speed = body.Velocity:Dot(ground_normal)
	local normal_velocity = ground_normal * normal_speed
	local tangent_velocity = body.Velocity - normal_velocity
	local tangent_speed = tangent_velocity:GetLength()
	local angular_speed = body.AngularVelocity:GetLength()
	local flat_ground = ground_normal.y >= math.max(body:GetMinGroundNormalY() or 0, 0.75)

	if not is_heightmap_ground then
		local side_alignment = math.sqrt(math.max(0, 1 - upright_alignment * upright_alignment))
		local terrain_like_ground = ground_body and
			(
				ground_body.WorldGeometry == true or
				(
					ground_body.GetShapeType and
					ground_body:GetShapeType() == "mesh"
				)
			)
		local slenderness = self:GetHeight() / math.max(self:GetRadius() * 2, EPSILON)

		if flat_ground and upright_alignment >= 0.88 and math.abs(normal_speed) <= 0.18 then
			normal_velocity = Vec3(0, 0, 0)
		end

		if
			terrain_like_ground and
			flat_ground and
			upright_alignment > 0.45 and
			upright_alignment < 0.995 and
			slenderness >= 2.2 and
			tangent_speed <= 0.75
		then
			local topple_axis = body.AngularVelocity - axis * body.AngularVelocity:Dot(axis)

			if topple_axis:GetLength() <= EPSILON then
				topple_axis = ground_normal:GetCross(axis)
			end

			if topple_axis:GetLength() > EPSILON then
				topple_axis = topple_axis:GetNormalized()
				local instability = math.max(
					side_alignment * math.max(upright_alignment, 0.35),
					math.max(0, (upright_alignment - 0.84) / 0.15)
				)
				local topple_speed = friction * instability * math.max(slenderness - 1, 0) * 1.6
				topple_speed = math.min(
					topple_speed,
					0.45 + side_alignment * 0.4 + (upright_alignment >= 0.9 and 0.1 or 0)
				)
				local topple_component = body.AngularVelocity:Dot(topple_axis)

				if topple_component < topple_speed then
					body.AngularVelocity = body.AngularVelocity + topple_axis * (topple_speed - topple_component)
					angular_speed = body.AngularVelocity:GetLength()
				end
			end
		end

		local allow_full_settling = angular_speed <= 0.35 or (upright_alignment >= 0.9 and tangent_speed <= 0.3)

		if
			terrain_like_ground and
			upright_alignment > 0.35 and
			upright_alignment < 0.98 and
			tangent_speed <= 0.75
		then
			allow_full_settling = false
		end

		if
			tangent_speed > 0.0001 and
			allow_full_settling and
			(
				flat_ground or
				tangent_speed <= 0.25
			)
		then
			local tangent_damping = math.exp(-(friction * (1.5 + upright_alignment * 3.5)) * dt)
			tangent_velocity = tangent_velocity * tangent_damping

			if tangent_velocity:GetLength() < 0.02 then tangent_velocity = Vec3(0, 0, 0) end

			body.Velocity = normal_velocity + tangent_velocity
		end

		local angular_velocity = body.AngularVelocity
		local axis_spin = axis * angular_velocity:Dot(axis)
		local off_axis_angular = angular_velocity - axis_spin
		local nearly_stationary = tangent_speed <= 0.08 and math.abs(normal_speed) <= 0.08

		if off_axis_angular:GetLength() > 0.0001 and allow_full_settling then
			local off_axis_damping = math.exp(-(friction * (1.2 + upright_alignment * 4.8)) * dt)
			off_axis_angular = off_axis_angular * off_axis_damping

			if off_axis_angular:GetLength() < 0.03 then off_axis_angular = Vec3(0, 0, 0) end
		elseif nearly_stationary and off_axis_angular:GetLength() > 0.0001 then
			local off_axis_damping = math.exp(-(friction * (0.7 + side_alignment * 1.8)) * dt)
			off_axis_angular = off_axis_angular * off_axis_damping

			if off_axis_angular:GetLength() < 0.02 then off_axis_angular = Vec3(0, 0, 0) end
		end

		if nearly_stationary then
			local axis_spin_damping = math.exp(-(friction * (3.0 + upright_alignment * 5.5)) * dt)
			axis_spin = axis_spin * axis_spin_damping

			if axis_spin:GetLength() < 0.025 then axis_spin = Vec3(0, 0, 0) end
		elseif tangent_speed <= 0.4 and (upright_alignment >= 0.9 or angular_speed <= 0.2) then
			local axis_spin_damping = math.exp(-(friction * (2.0 + upright_alignment * 4.0)) * dt)
			axis_spin = axis_spin * axis_spin_damping

			if axis_spin:GetLength() < 0.04 then axis_spin = Vec3(0, 0, 0) end
		end

		body.AngularVelocity = off_axis_angular + axis_spin
		return
	end

	local stable_support = support_metrics.stable == true and (support.count or 0) > 0
	local support_coverage = math.max(
		support_metrics.support_width_coverage or 0,
		support_metrics.min_coverage or 0,
		support_metrics.area_coverage or 0
	)
	local toppling_support = (support.count or 0) > 0 and not stable_support

	if stable_support and flat_ground and math.abs(normal_speed) <= 0.18 then
		normal_velocity = Vec3(0, 0, 0)
	end

	if toppling_support and flat_ground and tangent_speed <= 0.9 then
		local overhang = support.overhang
		local overhang_length = support.overhang_length or 0

		if overhang and overhang_length > (support_metrics.tolerance or 0) then
			local topple_axis = ground_normal:GetCross(overhang)

			if topple_axis:GetLength() > EPSILON then
				topple_axis = topple_axis:GetNormalized()
				local lever_arm = math.max((support_metrics.minor_footprint_span or 0) * 0.5, self:GetRadius() * 0.5, EPSILON)
				local instability = math.min(1, overhang_length / lever_arm)
				local gravity_strength = physics.Gravity and physics.Gravity:GetLength() or 28
				local desired_topple = math.min(
					gravity_strength * body:GetGravityScale() * dt * instability * (
							0.45 + support_coverage * 0.75
						),
					0.65
				)
				local topple_component = body.AngularVelocity:Dot(topple_axis)

				if topple_component < desired_topple then
					body.AngularVelocity = body.AngularVelocity + topple_axis * (desired_topple - topple_component)
					angular_speed = body.AngularVelocity:GetLength()
				end
			end
		end
	end

	local allow_full_settling = stable_support and support_coverage >= 0.14 and angular_speed <= 0.45

	if
		tangent_speed > 0.0001 and
		allow_full_settling and
		(
			flat_ground or
			tangent_speed <= 0.25
		)
	then
		local tangent_damping = math.exp(-(friction * (1.35 + support_coverage * 3.65)) * dt)
		tangent_velocity = tangent_velocity * tangent_damping

		if tangent_velocity:GetLength() < 0.02 then tangent_velocity = Vec3(0, 0, 0) end

		body.Velocity = normal_velocity + tangent_velocity
	end

	local angular_velocity = body.AngularVelocity
	local axis_spin = axis * angular_velocity:Dot(axis)
	local off_axis_angular = angular_velocity - axis_spin
	local nearly_stationary = tangent_speed <= 0.08 and math.abs(normal_speed) <= 0.08

	if off_axis_angular:GetLength() > 0.0001 and allow_full_settling then
		local off_axis_damping = math.exp(-(friction * (1.25 + support_coverage * 5.25)) * dt)
		off_axis_angular = off_axis_angular * off_axis_damping

		if off_axis_angular:GetLength() < 0.03 then off_axis_angular = Vec3(0, 0, 0) end
	elseif
		nearly_stationary and
		(
			support.count or
			0
		) > 0 and
		off_axis_angular:GetLength() > 0.0001
	then
		local off_axis_damping = math.exp(-(friction * (1.6 + support_coverage * 4.5)) * dt)
		off_axis_angular = off_axis_angular * off_axis_damping

		if off_axis_angular:GetLength() < 0.015 then off_axis_angular = Vec3(0, 0, 0) end
	end

	if nearly_stationary and (support.count or 0) > 0 then
		local axis_spin_damping = math.exp(-(friction * (2.8 + support_coverage * 5.8)) * dt)
		axis_spin = axis_spin * axis_spin_damping

		if axis_spin:GetLength() < 0.025 then axis_spin = Vec3(0, 0, 0) end
	elseif tangent_speed <= 0.4 and stable_support then
		local axis_spin_damping = math.exp(-(friction * (1.75 + support_coverage * 3.6)) * dt)
		axis_spin = axis_spin * axis_spin_damping

		if axis_spin:GetLength() < 0.04 then axis_spin = Vec3(0, 0, 0) end
	end

	body.AngularVelocity = off_axis_angular + axis_spin
end

function META:ShouldForceGroundedSleep(body)
	local ground_body = body.GetGroundBody and body:GetGroundBody() or nil
	local ground_shape = ground_body and
		ground_body.GetPhysicsShape and
		ground_body:GetPhysicsShape() or
		nil

	if not (ground_shape and ground_shape.Heightmap ~= nil) then
		local ground_normal = get_ground_normal(body)

		if ground_normal.y < math.max(body:GetMinGroundNormalY() or 0, 0.8) then
			return false
		end

		local axis = get_capsule_axis_world(body)
		return math.abs(axis:Dot(ground_normal)) >= 0.96
	end

	local metrics = self:GetSupportFootprintMetrics(body)

	if not metrics.stable then return false end

	if metrics.support_width_coverage >= 0.72 then return true end

	return (
			metrics.support.count or
			0
		) >= 2 and
		metrics.min_coverage >= 0.16 and
		metrics.area_coverage >= 0.04
end

function META:ShouldUseGroundedVelocityConstraints(body, stable)
	if stable then return true end

	if not (body and body.GetGrounded and body:GetGrounded()) then return false end

	local ground_body = body.GetGroundBody and body:GetGroundBody() or nil
	local ground_shape = ground_body and
		ground_body.GetPhysicsShape and
		ground_body:GetPhysicsShape() or
		nil

	if not ground_body then return false end

	local is_world_geometry = ground_body.WorldGeometry == true or
		(
			ground_body.GetShapeType and
			ground_body:GetShapeType() == "mesh"
		)

	if not is_world_geometry then return false end

	local ground_normal = get_ground_normal(body)

	if ground_normal.y < math.max(body:GetMinGroundNormalY() or 0, 0.45) then
		return false
	end

	if not (ground_shape and ground_shape.Heightmap ~= nil) then
		local axis = get_capsule_axis_world(body)
		local upright_alignment = math.abs(axis:Dot(ground_normal))
		local normal_speed = math.abs(body:GetVelocity():Dot(ground_normal))
		local tangent_velocity = body:GetVelocity() - ground_normal * body:GetVelocity():Dot(ground_normal)
		local tangent_speed = tangent_velocity:GetLength()
		local angular_speed = body:GetAngularVelocity():GetLength()

		if upright_alignment < 0.86 and angular_speed > 0.35 then return false end

		return tangent_speed <= 3.5 and normal_speed <= 2.5
	end

	local metrics = self:GetSupportFootprintMetrics(body, ground_normal)
	local support = metrics.support or {count = 0, overhang_length = math.huge}
	local normal_speed = math.abs(body:GetVelocity():Dot(ground_normal))
	local tangent_velocity = body:GetVelocity() - ground_normal * body:GetVelocity():Dot(ground_normal)
	local tangent_speed = tangent_velocity:GetLength()

	if (support.count or 0) <= 0 then return false end

	if is_world_geometry then
		local max_overhang = (metrics.tolerance or 0.1) * 4

		if (support.overhang_length or math.huge) <= max_overhang then
			return tangent_speed <= 3.5 and normal_speed <= 6.0
		end

		return tangent_speed <= 1.25 and normal_speed <= 4.0
	end

	return normal_speed <= 0.8 and tangent_speed <= 3.5
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
