local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local BaseShape = import("goluwa/physics/shapes/base.lua")
local sample_points = import("goluwa/physics/shapes/sample_points.lua")
local sweep_helpers = import("goluwa/physics/shapes/sweep_helpers.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("physics_shape_box")
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
local BODY_RIGHT = Vec3()
local BODY_UP = Vec3()
local BODY_BACK = Vec3()

-- axes are only ever used through absolute dot products, so the back axis
-- stands in for forward
local function fill_body_axes(body)
	local rotation = body.Rotation
	Quat.SetRightAxis(BODY_RIGHT, rotation)
	Quat.SetUpAxis(BODY_UP, rotation)
	Quat.SetBackAxis(BODY_BACK, rotation)
end

local BOX_SUPPORT_CONTACT_CONTEXT = {
	best_point = nil,
}

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

local MIN_RESTING_COVERAGE = 0.25

local function get_ground_support_tolerance(body)
	return math.max(
		(body:GetCollisionMargin() or 0) * 2,
		(body:GetCollisionProbeDistance() or 0) * 0.5,
		0.1
	)
end

local function collect_box_support_contact(context, collider, point, fallback_hit, fallback_dt, local_point)
	if not (fallback_hit and fallback_hit.normal and fallback_hit.position and point) then
		return
	end

	if not (fallback_hit.rigid_body and fallback_hit.rigid_body.WorldGeometry == true) then
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
			local_point = local_point,
			hit = fallback_hit,
			dt = fallback_dt,
			depth = depth,
		}
	end
end

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

-- the world AABB of a box is exactly the AABB of its 8 corners, which has a
-- closed form in the rotation: the extent along a world axis is the sum of
-- the absolute rotation-column components times the half extents
function META:GetBroadphaseAABB(body, position, rotation, out)
	position = position or body:GetPosition()
	rotation = rotation or body:GetRotation()
	local size = self:GetSize()
	local hx = size.x * 0.5
	local hy = size.y * 0.5
	local hz = size.z * 0.5
	local qx = rotation.x
	local qy = rotation.y
	local qz = rotation.z
	local qw = rotation.w
	local xx = qx * qx
	local yy = qy * qy
	local zz = qz * qz
	local xy = qx * qy
	local xz = qx * qz
	local yz = qy * qz
	local xw = qx * qw
	local yw = qy * qw
	local zw = qz * qw
	local ex = math.abs(1 - 2 * (yy + zz)) * hx + math.abs(2 * (xy - zw)) * hy + math.abs(2 * (xz + yw)) * hz
	local ey = math.abs(2 * (xy + zw)) * hx + math.abs(1 - 2 * (xx + zz)) * hy + math.abs(2 * (yz - xw)) * hz
	local ez = math.abs(2 * (xz - yw)) * hx + math.abs(2 * (yz + xw)) * hy + math.abs(1 - 2 * (xx + yy)) * hz

	if out then
		out.min_x = position.x - ex
		out.min_y = position.y - ey
		out.min_z = position.z - ez
		out.max_x = position.x + ex
		out.max_y = position.y + ey
		out.max_z = position.z + ez
		return out
	end

	return AABB(
		position.x - ex,
		position.y - ey,
		position.z - ez,
		position.x + ex,
		position.y + ey,
		position.z + ez
	)
end

function META:GetAutomaticMass(body)
	local size = self:GetSize()
	return size.x * size.y * size.z * body:GetDensity()
end

function META:BuildInertia(mass)
	local size = self:GetSize()
	return self:BuildBoxInertia(mass, size.x, size.y, size.z)
end

function META:GetLocalVertices()
	return sample_points.BuildBoxCornerPoints(self:GetExtents())
end

function META:BuildSupportLocalPoints()
	return sample_points.BuildBoxSupportGridPoints(self:GetExtents())
end

do
	-- shared by every caller in this file, which only read it right away
	local metrics = {min_coverage = 0, area_coverage = 0, support_width_coverage = 0, stable = false}

	function META:GetSupportFootprintMetrics(body, ground_normal)
		local support = body:GetGroundSupportProjectionMetrics()
		local tangent = support.tangent
		local bitangent = support.bitangent

		if not tangent or not bitangent then
			tangent, bitangent = build_support_plane_basis(ground_normal or body.GroundNormal or Vec3(0, 1, 0))
		end

		local extents = self:GetExtents()
		fill_body_axes(body)
		local span_u = 2 * (extents.x * math.abs(tangent:Dot(BODY_RIGHT)) + extents.y * math.abs(tangent:Dot(BODY_UP)) + extents.z * math.abs(tangent:Dot(BODY_BACK)))
		local span_v = 2 * (extents.x * math.abs(bitangent:Dot(BODY_RIGHT)) + extents.y * math.abs(bitangent:Dot(BODY_UP)) + extents.z * math.abs(bitangent:Dot(BODY_BACK)))
		local support_span_u = support.span_u or 0
		local support_span_v = support.span_v or 0
		local coverage_u = span_u > 0.0001 and math.min(1, support_span_u / span_u) or 0
		local coverage_v = span_v > 0.0001 and math.min(1, support_span_v / span_v) or 0
		local minor_span = math.min(span_u, span_v)
		metrics.min_coverage = math.min(coverage_u, coverage_v)
		metrics.area_coverage = span_u * span_v > 0.0001 and
			math.min(1, support_span_u * support_span_v / (span_u * span_v)) or
			0
		metrics.support_width_coverage = minor_span > 0.0001 and
			math.min(1, (support.max_span or 0) / minor_span) or
			0
		metrics.stable = (support.overhang_length or math.huge) <= get_ground_support_tolerance(body)
		return metrics
	end
end

function META:ShouldUseBroadSupportContact(body, ground_normal)
	local metrics = self:GetSupportFootprintMetrics(body, ground_normal)
	return metrics.stable and metrics.min_coverage >= 0.7 and metrics.area_coverage >= 0.5
end

function META:SolveSupportContacts(body, dt, support_contacts)
	if not support_contacts.BeginSupportDetection(body) then
		support_contacts.ResolveCachedSupportContacts(body, dt)
		return
	end

	BOX_SUPPORT_CONTACT_CONTEXT.best_point = nil
	support_contacts.ForEachPointSweepContact(body, dt, collect_box_support_contact, BOX_SUPPORT_CONTACT_CONTEXT)
	local best_point = BOX_SUPPORT_CONTACT_CONTEXT.best_point
	BOX_SUPPORT_CONTACT_CONTEXT.best_point = nil

	if
		best_point and
		self:ShouldUseBroadSupportContact(best_point.body, best_point.hit.normal)
	then
		support_contacts.ApplyPointWorldSupportContact(
			best_point.body,
			best_point.hit.normal,
			best_point.hit.position,
			best_point.point,
			best_point.local_point,
			best_point.hit,
			best_point.dt
		)
		return
	end

	local hit = support_contacts.SweepCollider(body, dt)
	local normal = hit and hit.normal or nil
	local contact_position = hit and hit.position or nil

	if
		hit and
		normal and
		contact_position and
		self:ShouldUseBroadSupportContact(body, normal)
	then
		support_contacts.ApplyWorldSupportContact(
			body,
			normal,
			contact_position,
			self:GetSupportRadiusAlongNormal(body, normal),
			hit,
			dt
		)
	end
end

function META:GetSupportRadiusAlongNormal(body, normal)
	normal = normal and normal:GetNormalized() or Vec3(0, 1, 0)
	local extents = self:GetExtents()
	fill_body_axes(body)
	return extents.x * math.abs(normal:Dot(BODY_RIGHT)) + extents.y * math.abs(normal:Dot(BODY_UP)) + extents.z * math.abs(normal:Dot(BODY_BACK))
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

-- a box touching along one edge or a corner is balanced, not resting: it only
-- looks still for the moment it takes to start falling over
function META:CanRestOnSupport(body)
	return self:GetSupportFootprintMetrics(body).min_coverage >= MIN_RESTING_COVERAGE
end

function META:ShouldForceGroundedSleep(body)
	local metrics = self:GetSupportFootprintMetrics(body)
	local ground_normal = body.GroundNormal or Vec3(0, 1, 0)
	fill_body_axes(body)
	local face_alignment = math.max(
		math.abs(ground_normal:Dot(BODY_RIGHT)),
		math.abs(ground_normal:Dot(BODY_UP)),
		math.abs(ground_normal:Dot(BODY_BACK))
	)
	if not metrics.stable then return false end

	if face_alignment >= 0.983 then
		return metrics.support_width_coverage >= 0.96 or
			(
				metrics.support_width_coverage >= 0.82 and
				metrics.min_coverage >= 0.08
			)
	end

	return face_alignment < 0.97 and
		metrics.support_width_coverage >= 0.7 and
		metrics.min_coverage >= 0.35
end

local axis_data = {
	{"x", Vec3(-1, 0, 0), Vec3(1, 0, 0)},
	{"y", Vec3(0, -1, 0), Vec3(0, 1, 0)},
	{"z", Vec3(0, 0, -1), Vec3(0, 0, 1)},
}

do
	local function slab_sweep(start_local, movement_local, extents, expansion)
		local t_enter = 0
		local t_exit = 1
		local hit_normal_local = nil

		for _, axis in ipairs(axis_data) do
			local name = axis[1]
			local s = start_local[name]
			local d = movement_local[name]
			local min_value = -extents[name] + expansion
			local max_value = extents[name] + expansion

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

		return t_enter, hit_normal_local
	end

	function META:TraceAgainstBody(body, origin, direction, max_distance, trace_radius)
		local distance_limit = max_distance or math.huge
		local movement_world = direction and direction:GetNormalized() * distance_limit or Vec3(0, 0, 0)

		if movement_world:GetLength() <= 0.00001 then return nil end

		local start_local = body:WorldToLocal(origin)
		local end_local = body:WorldToLocal(origin + movement_world)
		local movement_local = end_local - start_local
		local expansion = math.max(trace_radius or 0, 0)
		local extents = self:GetExtents()
		local t_enter, hit_normal_local = slab_sweep(start_local, movement_local, extents, expansion)

		if not t_enter then return nil end

		local expanded_position = origin + movement_world * t_enter
		local normal = body:GetRotation():VecMul(hit_normal_local):GetNormalized()
		local position = expanded_position - normal * expansion
		return {
			entity = body:GetOwner(),
			distance = distance_limit * t_enter,
			position = position,
			normal = normal,
			rigid_body = body,
		}
	end
end

function META:SweepPointAgainstBody(collider, origin, movement, radius, target_state, max_fraction)
	return sweep_helpers.SweepPointAgainstPolyhedronBody(
		collider,
		self:GetPolyhedron(collider),
		origin,
		movement,
		radius,
		target_state,
		max_fraction
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
	local target_polyhedron = self:GetPolyhedron(target_collider)

	if query_collider:GetShapeType() == "capsule" then
		return sweep_helpers.SweepCapsuleAgainstTargetPolyhedron(
			query_collider,
			start_position,
			rotation,
			movement,
			target_collider,
			target_polyhedron,
			target_state,
			max_fraction
		)
	end

	if query_polyhedron and query_polyhedron.vertices and query_polyhedron.faces then
		return sweep_helpers.SweepPolyhedronAgainstTargetPolyhedron(
			query_collider,
			query_polyhedron,
			start_position,
			rotation,
			movement,
			target_collider,
			target_polyhedron,
			target_state,
			max_fraction
		)
	end

	return nil
end

return META:Register()
