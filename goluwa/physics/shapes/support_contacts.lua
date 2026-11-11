local physics_constants = import("goluwa/physics/constants.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local sweep_candidates = import("goluwa/physics/sweep_candidates.lua")
local stats = import("goluwa/physics/stats.lua")
local support_contacts = {}
local cast_origin_offset = Vec3(0, 0, 0)
local cast_delta = Vec3(0, 0, 0)
local sweep_origin = Vec3(0, 0, 0)
local MIN_SUPPORT_NORMAL_Y = 0.1

local function fill_cast_vectors(cast_up, cast_distance)
	local up = physics_constants.UP
	cast_origin_offset.x = up.x * cast_up
	cast_origin_offset.y = up.y * cast_up
	cast_origin_offset.z = up.z * cast_up
	cast_delta.x = up.x * -cast_distance
	cast_delta.y = up.y * -cast_distance
	cast_delta.z = up.z * -cast_distance
end

local function apply_support_grounding_metadata(body, hit, normal)
	if not (body and hit and normal and normal.y >= body:GetMinGroundNormalY()) then
		return
	end

	local ground_body = hit.rigid_body
	local physics = body:GetPhysics()
	local rolling_friction = 0

	if
		ground_body and
		physics and
		physics.solver and
		physics.solver.GetPairRollingFriction
	then
		rolling_friction = physics.solver:GetPairRollingFriction(body, ground_body) or 0
	end

	body:SetGrounded(true)
	body:SetGroundNormal(normal)
	body:SetGroundRollingFriction(rolling_friction)
	body:SetGroundBody(ground_body)
	body:SetGroundEntity(ground_body and ground_body:GetOwner() or nil)
end

local function record_support_contact(body, hit, contact)
	local hit_body = hit and hit.rigid_body

	if hit_body and hit_body:HasSolverMass() then
		body._WorldSupportContacts = nil
		return
	end

	local cache = body._WorldSupportContacts

	if not cache then return end

	cache.contacts[#cache.contacts + 1] = contact
end

local function record_support_point(body, normal, x, y, z)
	local cache = body._WorldSupportContacts

	if not cache then return end

	local points = cache.support_points
	points[#points + 1] = {normal = normal, x = x, y = y, z = z}
end

function support_contacts.GetCastDistances(body)
	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * body:GetPhysics().solver.StepDt)
	local cast_up = body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	local cast_distance = cast_up + downward + body:GetCollisionProbeDistance() + body:GetCollisionMargin()
	return cast_up, cast_distance
end

function support_contacts.AccumulatePointSweepSupport(body, point, hit)
	if not (body and point and hit and hit.normal and hit.position) then
		return false
	end

	local margin = body:GetCollisionMargin() or 0
	local support_tolerance = (body:GetCollisionProbeDistance() or 0) + margin
	local depth = (hit.position + hit.normal * margin - point):Dot(hit.normal)

	if depth < -support_tolerance then return false end

	if hit.normal.y >= body:GetMinGroundNormalY() then
		body:AccumulateGroundSupportContact(hit.normal, hit.position.x, hit.position.y, hit.position.z)
		record_support_point(body, hit.normal, hit.position.x, hit.position.y, hit.position.z)
		return true
	end

	return false
end

local SWEEP_BOUNDS = AABB(0, 0, 0, 0, 0, 0)
local SWEEP_POINT = Vec3()
local SWEEP_CANDIDATES = {}

local function is_any_sweep_candidate(physics, body, support_points, owner, filter_function)
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for i = 1, #support_points do
		local point = body:GeometryLocalToWorld(support_points[i], nil, nil, SWEEP_POINT)
		min_x = math.min(min_x, point.x)
		min_y = math.min(min_y, point.y)
		min_z = math.min(min_z, point.z)
		max_x = math.max(max_x, point.x)
		max_y = math.max(max_y, point.y)
		max_z = math.max(max_z, point.z)
	end

	local bounds = SWEEP_BOUNDS
	bounds.min_x = min_x + cast_origin_offset.x + math.min(cast_delta.x, 0)
	bounds.min_y = min_y + cast_origin_offset.y + math.min(cast_delta.y, 0)
	bounds.min_z = min_z + cast_origin_offset.z + math.min(cast_delta.z, 0)
	bounds.max_x = max_x + cast_origin_offset.x + math.max(cast_delta.x, 0)
	bounds.max_y = max_y + cast_origin_offset.y + math.max(cast_delta.y, 0)
	bounds.max_z = max_z + cast_origin_offset.z + math.max(cast_delta.z, 0)
	local candidates = SWEEP_CANDIDATES
	table.clear(candidates)
	sweep_candidates.CollectRigidBodyCandidates(physics, bounds, owner, filter_function, nil, candidates)
	return candidates[1] ~= nil, min_y
end

-- a collider of a compound body that sits well above the body's lowest point rests on the body's own lower colliders, so it is not probed
local COMPOUND_SUPPORT_HEIGHT = 0.25
local FLOOR_POINT = Vec3()

local function get_compound_floor_y(rigid_body, stamp)
	local cache = rigid_body._SupportFloor

	if cache and cache.stamp == stamp then return cache.y end

	if not cache then
		cache = {}
		rigid_body._SupportFloor = cache
	end

	local floor_y = math.huge
	local colliders = rigid_body:GetColliders()

	for i = 1, #colliders do
		local collider = colliders[i]
		local points = collider:GetSupportLocalPoints()

		for j = 1, #points do
			floor_y = math.min(floor_y, collider:GeometryLocalToWorld(points[j], nil, nil, FLOOR_POINT).y)
		end
	end

	cache.stamp = stamp
	cache.y = floor_y
	return floor_y
end

function support_contacts.ForEachPointSweepContact(body, dt, solve_contact, solve_contact_context, support_points)
	local physics = body:GetPhysics()
	local cast_up, cast_distance = support_contacts.GetCastDistances(body)
	local owner = body:GetOwner()
	local filter_function = body:GetFilterFunction()
	fill_cast_vectors(cast_up, cast_distance)
	local has_candidate, min_y = is_any_sweep_candidate(physics, body, support_points, owner, filter_function)

	if not has_candidate then return end

	local rigid_body = body.Body

	if
		rigid_body and
		#rigid_body:GetColliders() > 1 and
		min_y > get_compound_floor_y(rigid_body, physics.solver.CollideStamp) + COMPOUND_SUPPORT_HEIGHT
	then
		return
	end

	if stats:IsEnabled() then stats:PushTime("support_point_sweeps") end

	for i = 1, #support_points do
		local local_point = support_points[i]
		local point = body:GeometryLocalToWorld(local_point)
		sweep_origin.x = point.x + cast_origin_offset.x
		sweep_origin.y = point.y + cast_origin_offset.y
		sweep_origin.z = point.z + cast_origin_offset.z
		local hit = physics.Sweep(sweep_origin, cast_delta, 0, owner, filter_function)
		stats:Count("sweeps_support_points")

		if hit then
			support_contacts.AccumulatePointSweepSupport(body, point, hit)

			if solve_contact_context ~= nil then
				solve_contact(solve_contact_context, body, point, hit, dt, local_point)
			else
				solve_contact(body, point, hit, dt, local_point)
			end
		end
	end

	if stats:IsEnabled() then stats:PopTime() end
end

-- primitive pair solvers only count overlap as touching, so a push out to the margin would take away their friction; they get no support
local function is_support_surface(hit)
	local shape_type = (hit.collider or hit.rigid_body):GetShapeType()
	return shape_type == "mesh" or shape_type == "heightmap"
end

local SUPPORT_CORRECTION = Vec3()
local SUPPORT_POINT = Vec3()
local SUPPORT_IMPULSE = Vec3()

local function apply_world_support(body, normal, contact_position, support_radius, hit, dt)
	local margin = body:GetCollisionMargin() or 0
	local center = body:GetPosition()
	local offset = support_radius + margin
	local depth = (
			contact_position.x + normal.x * offset - center.x
		) * normal.x + (
			contact_position.y + normal.y * offset - center.y
		) * normal.y + (
			contact_position.z + normal.z * offset - center.z
		) * normal.z

	if depth > 0 then
		SUPPORT_CORRECTION.x, SUPPORT_CORRECTION.y, SUPPORT_CORRECTION.z = normal.x * depth, normal.y * depth, normal.z * depth
		SUPPORT_POINT.x = center.x - normal.x * support_radius
		SUPPORT_POINT.y = center.y - normal.y * support_radius
		SUPPORT_POINT.z = center.z - normal.z * support_radius
		body:ApplyCorrection(0, SUPPORT_CORRECTION, SUPPORT_POINT, nil, nil, dt)
		local velocity = body.Velocity
		local normal_speed = velocity.x * normal.x + velocity.y * normal.y + velocity.z * normal.z

		if normal_speed < 0 then
			velocity:AddScaled(normal, -normal_speed)
			body:SyncSolverVelocity()
		end

		if normal.y >= body:GetMinGroundNormalY() then
			apply_support_grounding_metadata(body, hit, normal)
			body:AccumulateGroundSupportContact(normal, contact_position.x, contact_position.y, contact_position.z)
		end

		body:GetPhysics().collision_pairs:RecordWorldCollision(body, hit, normal, depth, -normal_speed, contact_position)
		return true
	end

	return depth >= -((body:GetCollisionProbeDistance() or 0) + margin)
end

local function apply_point_world_support(body, normal, contact_position, support_point, hit, dt)
	local margin = body:GetCollisionMargin() or 0
	local depth = (
			contact_position.x + normal.x * margin - support_point.x
		) * normal.x + (
			contact_position.y + normal.y * margin - support_point.y
		) * normal.y + (
			contact_position.z + normal.z * margin - support_point.z
		) * normal.z
	local normal_speed = 0

	if depth > 0 then
		SUPPORT_CORRECTION.x, SUPPORT_CORRECTION.y, SUPPORT_CORRECTION.z = normal.x * depth, normal.y * depth, normal.z * depth
		body:ApplyCorrection(0, SUPPORT_CORRECTION, support_point, nil, nil, dt)
		local velocity = body.Velocity
		local angular = body.AngularVelocity
		local position = body.Position
		local rx, ry, rz = support_point.x - position.x, support_point.y - position.y, support_point.z - position.z
		local vx = velocity.x + angular.y * rz - angular.z * ry
		local vy = velocity.y + angular.z * rx - angular.x * rz
		local vz = velocity.z + angular.x * ry - angular.y * rx
		normal_speed = vx * normal.x + vy * normal.y + vz * normal.z

		if normal_speed < 0 then
			local scale = -normal_speed / body:GetInverseMassAlong(normal, support_point)
			SUPPORT_IMPULSE.x, SUPPORT_IMPULSE.y, SUPPORT_IMPULSE.z = normal.x * scale, normal.y * scale, normal.z * scale
			body:ApplyImpulse(SUPPORT_IMPULSE, support_point)
			body:SyncSolverVelocity()
		end
	end

	if depth < -((body:GetCollisionProbeDistance() or 0) + margin) then
		return false
	end

	if normal.y >= body:GetMinGroundNormalY() then
		apply_support_grounding_metadata(body, hit, normal)
		body:AccumulateGroundSupportContact(normal, support_point.x, support_point.y, support_point.z)
	end

	body:GetPhysics().collision_pairs:RecordWorldCollision(body, hit, normal, depth, -normal_speed, contact_position)
	return true
end

function support_contacts.ApplyWorldSupportContact(body, normal, contact_position, support_radius, hit, dt)
	if not (normal and contact_position) then return false end

	if not is_support_surface(hit) then return false end

	if normal.y < MIN_SUPPORT_NORMAL_Y then return false end

	if hit.distance <= 0 then return false end

	if not apply_world_support(body, normal, contact_position, support_radius, hit, dt) then
		return false
	end

	record_support_contact(
		body,
		hit,
		{
			normal = normal,
			position = contact_position,
			radius = support_radius,
			hit = hit,
		}
	)
	return true
end

function support_contacts.ApplyPointWorldSupportContact(body, normal, contact_position, support_point, local_point, hit, dt)
	if not (normal and contact_position and support_point) then return false end

	if not is_support_surface(hit) then return false end

	if
		not apply_point_world_support(body, normal, contact_position, support_point, hit, dt)
	then
		return false
	end

	record_support_contact(
		body,
		hit,
		{
			normal = normal,
			position = contact_position,
			local_point = local_point,
			hit = hit,
		}
	)
	return true
end

function support_contacts.SweepCollider(body, dt)
	local physics = body:GetPhysics()
	local cast_up, cast_distance = support_contacts.GetCastDistances(body)
	local center = body:GetPosition()
	local hit = physics.SweepCollider(
		body,
		center + physics_constants.UP * cast_up,
		physics_constants.UP * -cast_distance,
		body:GetOwner(),
		body:GetFilterFunction(),
		{Rotation = body:GetRotation()}
	)
	stats:Count("sweeps_support_body")
	return hit
end

-- the sweep is narrower than the sphere so a wall or curb the sphere leans on does not start it overlapped and hide the floor
local SUPPORT_SWEEP_SHARE = 0.5

function support_contacts.SweepSphere(body, dt, radius)
	local physics = body:GetPhysics()
	local cast_up, cast_distance = support_contacts.GetCastDistances(body)
	local center = body:GetPosition()
	fill_cast_vectors(cast_up, cast_distance + radius)
	sweep_origin.x = center.x + cast_origin_offset.x
	sweep_origin.y = center.y + cast_origin_offset.y
	sweep_origin.z = center.z + cast_origin_offset.z
	local hit = physics.Sweep(
		sweep_origin,
		cast_delta,
		radius * SUPPORT_SWEEP_SHARE,
		body:GetOwner(),
		body:GetFilterFunction()
	)
	stats:Count("sweeps_support_sphere")
	return hit
end

function support_contacts.SolveShapeSupportContacts(body, shape, dt)
	if not (shape and dt and shape.SolveSupportContacts) then return end

	return shape:SolveSupportContacts(body, dt, support_contacts)
end

function support_contacts.BeginSupportDetection(body)
	local stamp = body:GetPhysics().solver.CollideStamp
	local cache = body._WorldSupportContacts

	if cache and cache.stamp == stamp then return false end

	if not cache then
		cache = {contacts = {}, support_points = {}}
		body._WorldSupportContacts = cache
	end

	cache.stamp = stamp
	table.clear(cache.contacts)
	table.clear(cache.support_points)
	return true
end

local CACHED_POINT = Vec3()

function support_contacts.ResolveCachedSupportContacts(body, dt)
	local cache = body._WorldSupportContacts

	if not cache then return end

	if stats:IsEnabled() then stats:PushTime("support_resolve") end

	local points = cache.support_points

	for i = 1, #points do
		local point = points[i]
		body:AccumulateGroundSupportContact(point.normal, point.x, point.y, point.z)
	end

	local contacts = cache.contacts

	for i = 1, #contacts do
		local contact = contacts[i]

		if contact.local_point then
			apply_point_world_support(
				body,
				contact.normal,
				contact.position,
				body:GeometryLocalToWorld(contact.local_point, nil, nil, CACHED_POINT),
				contact.hit,
				dt
			)
		else
			apply_world_support(body, contact.normal, contact.position, contact.radius, contact.hit, dt)
		end
	end

	if stats:IsEnabled() then stats:PopTime() end
end

return support_contacts
