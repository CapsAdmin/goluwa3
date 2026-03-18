local prototype = import("goluwa/prototype.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Matrix33 = import("goluwa/structs/matrix33.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics = import("goluwa/physics.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local META = prototype.CreateTemplate("physics_shape_box")
META.Base = BaseShape
META:GetSet("Size", Vec3(1, 1, 1))
local BOX_FACE_NORMALS = {
	Vec3(1, 0, 0),
	Vec3(-1, 0, 0),
	Vec3(0, 1, 0),
	Vec3(0, -1, 0),
	Vec3(0, 0, 1),
	Vec3(0, 0, -1),
}
local BOX_FACE_INDICES = {
	{2, 3, 7, 6},
	{1, 5, 8, 4},
	{4, 8, 7, 3},
	{1, 2, 6, 5},
	{5, 6, 7, 8},
	{1, 4, 3, 2},
}
local BOX_EDGE_PAIRS = {
	{1, 2},
	{2, 3},
	{3, 4},
	{4, 1},
	{5, 6},
	{6, 7},
	{7, 8},
	{8, 5},
	{1, 5},
	{2, 6},
	{3, 7},
	{4, 8},
}

function META.New(size)
	local shape = META:CreateObject()
	shape:SetSize(size or Vec3(1, 1, 1))
	return shape
end

function META:GetTypeName()
	return "box"
end

function META:OnBodyGeometryChanged(body)
	BaseShape.OnBodyGeometryChanged(self, body)
	self.Polyhedron = nil
end

function META:GetExtents()
	return self:GetSize() * 0.5
end

function META:GetHalfExtents()
	return self:GetExtents()
end

function META:GetMassProperties(body)
	local size = self:GetSize()
	local mass = body:GetMass()

	if body.IsDynamic and not body:IsDynamic() then
		mass = 0
	elseif body:GetAutomaticMass() then
		mass = size.x * size.y * size.z * body:GetDensity()
	end

	if mass <= 0 then return 0, Matrix33():SetZero() end

	local sx, sy, sz = size.x, size.y, size.z
	local ix = (1 / 12) * mass * (sy * sy + sz * sz)
	local iy = (1 / 12) * mass * (sx * sx + sz * sz)
	local iz = (1 / 12) * mass * (sx * sx + sy * sy)
	return mass, Matrix33():SetDiagonal(ix, iy, iz)
end

function META:GetAxes(body)
	local rotation = body:GetRotation()
	return {
		rotation:VecMul(Vec3(1, 0, 0)):GetNormalized(),
		rotation:VecMul(Vec3(0, 1, 0)):GetNormalized(),
		rotation:VecMul(Vec3(0, 0, 1)):GetNormalized(),
	}
end

function META:GetLocalVertices()
	local extents = self:GetExtents()
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	return {
		Vec3(-ex, -ey, -ez),
		Vec3(ex, -ey, -ez),
		Vec3(ex, ey, -ez),
		Vec3(-ex, ey, -ez),
		Vec3(-ex, -ey, ez),
		Vec3(ex, -ey, ez),
		Vec3(ex, ey, ez),
		Vec3(-ex, ey, ez),
	}
end

function META:GetBroadphaseAABB(body, position, rotation)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	local bounds = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for _, corner in ipairs(self:GetLocalVertices()) do
		bounds:ExpandVec3(position + rotation:VecMul(corner))
	end

	return bounds
end

function META:BuildCollisionLocalPoints()
	local extents = self:GetExtents()
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	return {
		Vec3(-ex, -ey, -ez),
		Vec3(ex, -ey, -ez),
		Vec3(ex, ey, -ez),
		Vec3(-ex, ey, -ez),
		Vec3(-ex, -ey, ez),
		Vec3(ex, -ey, ez),
		Vec3(ex, ey, ez),
		Vec3(-ex, ey, ez),
		Vec3(0, -ey, 0),
		Vec3(0, ey, 0),
		Vec3(ex, 0, 0),
		Vec3(-ex, 0, 0),
		Vec3(0, 0, ez),
		Vec3(0, 0, -ez),
	}
end

function META:BuildSupportLocalPoints()
	local extents = self:GetExtents()
	local ex = extents.x
	local ey = extents.y
	local ez = extents.z
	local points = {}
	local samples_x = {-1, -0.75, -0.5, 0, 0.5, 0.75, 1}
	local samples_z = {-1, 0, 1}

	for _, sx in ipairs(samples_x) do
		for _, sz in ipairs(samples_z) do
			points[#points + 1] = Vec3(ex * sx, -ey, ez * sz)
		end
	end

	return points
end

function META:GetSupportRadiusAlongNormal(body, normal)
	normal = normal and normal:GetNormalized() or Vec3(0, 1, 0)
	local extents = self:GetExtents()
	local axes = self:GetAxes(body)
	return extents.x * math.abs(normal:Dot(axes[1])) + extents.y * math.abs(normal:Dot(axes[2])) + extents.z * math.abs(normal:Dot(axes[3]))
end

local function solve_box_support_contact(self, body, normal, contact_position, hit, dt)
	local support_radius = self:GetSupportRadiusAlongNormal(body, normal)
	local center = body:GetPosition()
	local target_center = contact_position + normal * (support_radius + body:GetCollisionMargin())
	local correction = target_center - center
	local depth = correction:Dot(normal)

	if depth <= 0 then return end

	body:ApplyCorrection(0, normal * depth, center - normal * support_radius, nil, nil, dt)

	if normal.y >= body:GetMinGroundNormalY() then
		body:SetGrounded(true)
		body:SetGroundNormal(normal)
	end

	if physics.RecordWorldCollision then
		physics.RecordWorldCollision(body, hit, normal, depth)
	end
end

function META:SolveSupportContacts(body, dt)
	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * dt)
	local cast_up = body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local cast_distance = cast_up + downward + body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local center = body:GetPosition()
	local hit = physics.SweepCollider(
		body,
		center + physics.Up * cast_up,
		physics.Up * -cast_distance,
		body:GetOwner(),
		body:GetFilterFunction(),
		{
			Rotation = body:GetRotation(),
		}
	)
	local normal = hit and hit.normal or nil
	local contact_position = hit and hit.position or nil

	if hit and normal and contact_position then
		solve_box_support_contact(self, body, normal, contact_position, hit, dt)
		return
	end

	BaseShape.SolveSupportContacts(
		self,
		body,
		dt,
		function(collider, _, fallback_hit, fallback_dt)
			local fallback_normal = fallback_hit and
				fallback_hit.normal or
				fallback_hit and
				fallback_hit.face_normal or
				nil
			local fallback_position = fallback_hit and fallback_hit.position or nil

			if fallback_normal and fallback_position then
				solve_box_support_contact(self, collider, fallback_normal, fallback_position, fallback_hit, fallback_dt)
			end
		end
	)
end

function META:GetPolyhedron()
	if self.Polyhedron then return self.Polyhedron end

	local faces = {}

	for i, indices in ipairs(BOX_FACE_INDICES) do
		faces[i] = {
			indices = indices,
			normal = BOX_FACE_NORMALS[i],
		}
	end

	self.Polyhedron = {
		vertices = self:GetLocalVertices(),
		faces = faces,
		edges = BOX_EDGE_PAIRS,
	}
	return self.Polyhedron
end

function META:GetGroundedSupportMetrics(body, ground_normal)
	ground_normal = ground_normal or body.GroundNormal or Vec3(0, 1, 0)
	local axes = self:GetAxes(body)
	local best_alignment = -1
	local support_axis = 1

	for i = 1, 3 do
		local alignment = math.abs(axes[i]:Dot(ground_normal))

		if alignment > best_alignment then
			best_alignment = alignment
			support_axis = i
		end
	end

	local size = self:GetSize()
	local face_areas = {
		size.y * size.z,
		size.x * size.z,
		size.x * size.y,
	}
	local support_area = face_areas[support_axis]
	local max_face_area = math.max(face_areas[1], face_areas[2], face_areas[3])
	return best_alignment, support_area, max_face_area, support_axis
end

function META:OnGroundedVelocityUpdate(body, dt)
	if not dt or dt <= 0 then return end

	local ground_normal = body.GroundNormal or Vec3(0, 1, 0)
	local best_alignment, support_area, max_face_area = self:GetGroundedSupportMetrics(body, ground_normal)

	if best_alignment < 0.94 or support_area < max_face_area * 0.85 then return end

	local friction = math.max(body:GetGroundRollingFriction() or 0, body:GetFriction() or 0)

	if friction <= 0 then return end

	local normal_velocity = ground_normal * body.Velocity:Dot(ground_normal)
	local tangent_velocity = body.Velocity - normal_velocity
	local tangent_speed = tangent_velocity:GetLength()
	local tangent_angular = body.AngularVelocity - ground_normal * body.AngularVelocity:Dot(ground_normal)
	local tangent_angular_speed = tangent_angular:GetLength()

	if tangent_speed > 0.08 or tangent_angular_speed > 0.22 then return end

	local damping_strength = friction * (2.5 + best_alignment * 2.0)

	if tangent_speed > 0.0001 then
		local tangent_damping = math.exp(-damping_strength * dt)
		tangent_velocity = tangent_velocity * tangent_damping

		if tangent_velocity:GetLength() < 0.015 then tangent_velocity = Vec3(0, 0, 0) end

		body.Velocity = normal_velocity + tangent_velocity
	end

	if tangent_angular_speed > 0.0001 then
		local angular_damping = math.exp(-(damping_strength * 1.35) * dt)
		tangent_angular = tangent_angular * angular_damping

		if tangent_angular:GetLength() < 0.035 then tangent_angular = Vec3(0, 0, 0) end

		body.AngularVelocity = tangent_angular + ground_normal * body.AngularVelocity:Dot(ground_normal)
	end
end

function META:ShouldForceGroundedSleep(body)
	local best_alignment, support_area, max_face_area = self:GetGroundedSupportMetrics(body)
	return (
			best_alignment >= 0.992 and
			support_area >= max_face_area * 0.85
		)
		or
		best_alignment >= 0.997
end

local function snap_angle_to_step(angle, step)
	local scaled = angle / step

	if scaled >= 0 then return math.floor(scaled + 0.5) * step end

	return math.ceil(scaled - 0.5) * step
end

function META:SnapGroundedSleepPose(body)
	local ground_normal = body.GroundNormal or Vec3(0, 1, 0)

	if math.abs(ground_normal.y) < 0.98 then return false end

	local linear_speed = body:GetVelocity():GetLength()
	local angular_speed = body:GetAngularVelocity():GetLength()
	local max_linear_snap_speed = math.max(0.025, (body:GetSleepLinearThreshold() or 0) * 0.2)
	local max_angular_snap_speed = math.max(0.045, (body:GetSleepAngularThreshold() or 0) * 0.25)

	if linear_speed > max_linear_snap_speed or angular_speed > max_angular_snap_speed then
		return false
	end

	local best_alignment, support_area, max_face_area, support_axis = self:GetGroundedSupportMetrics(body, ground_normal)

	if best_alignment < 0.985 or support_area < max_face_area * 0.85 then
		return false
	end

	local size = self:GetSize()
	local face_dims = support_axis == 1 and
		{size.y, size.z} or
		support_axis == 2 and
		{size.x, size.z} or
		{size.x, size.y}
	local major = math.max(face_dims[1], face_dims[2])
	local minor = math.min(face_dims[1], face_dims[2])

	if minor <= 0 or major / minor < 1.3 then return false end

	local angles = body:GetRotation():GetAngles()
	local step = math.pi * 0.5
	local snapped_pitch = snap_angle_to_step(angles.x, step)
	local snapped_roll = snap_angle_to_step(angles.z, step)
	local max_snap_angle_delta = 0.08

	if
		math.abs(snapped_pitch - angles.x) > max_snap_angle_delta or
		math.abs(snapped_roll - angles.z) > max_snap_angle_delta
	then
		return false
	end

	local rotation = Quat():SetAngles(Ang3(snapped_pitch, angles.y, snapped_roll))
	local extents = self:GetExtents()
	local axes = self:GetAxes(body)
	local current_support_radius = extents.x * math.abs(ground_normal:Dot(axes[1])) + extents.y * math.abs(ground_normal:Dot(axes[2])) + extents.z * math.abs(ground_normal:Dot(axes[3]))
	local snapped_axes = {
		rotation:VecMul(Vec3(1, 0, 0)):GetNormalized(),
		rotation:VecMul(Vec3(0, 1, 0)):GetNormalized(),
		rotation:VecMul(Vec3(0, 0, 1)):GetNormalized(),
	}
	local desired_support_radius = extents.x * math.abs(ground_normal:Dot(snapped_axes[1])) + extents.y * math.abs(ground_normal:Dot(snapped_axes[2])) + extents.z * math.abs(ground_normal:Dot(snapped_axes[3]))
	body.Position = body.Position + ground_normal * (desired_support_radius - current_support_radius)
	body.Rotation = rotation
	body.PreviousPosition = body.Position:Copy()
	body.PreviousRotation = rotation:Copy()
	return true
end

function META:TraceAgainstBody(body, origin, direction, max_distance, trace_radius)
	local distance_limit = max_distance or math.huge
	local movement_world = direction and direction:GetNormalized() * distance_limit or Vec3(0, 0, 0)

	if movement_world:GetLength() <= 0.00001 then return nil end

	local start_local = body:WorldToLocal(origin)
	local end_local = body:WorldToLocal(origin + movement_world)
	local movement_local = end_local - start_local
	local expansion = math.max(trace_radius or 0, 0)
	local extents = self:GetExtents() + Vec3(expansion, expansion, expansion)
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

		if math.abs(d) <= 0.00001 then
			if s < min_value or s > max_value then return nil end
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

			if t_enter > t_exit then return nil end
		end
	end

	if not hit_normal_local or t_enter < 0 or t_enter > 1 then return nil end

	local expanded_position = origin + movement_world * t_enter
	local normal = body:GetRotation():VecMul(hit_normal_local):GetNormalized()
	local position = expanded_position - normal * expansion
	return {
		entity = body:GetOwner(),
		distance = distance_limit * t_enter,
		position = position,
		normal = normal,
		rigid_body = body.GetBody and body:GetBody() or body,
	}
end

return META:Register()