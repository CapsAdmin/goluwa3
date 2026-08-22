local physics_constants = import("goluwa/physics/constants.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local stats = import("goluwa/physics/stats.lua")
local support_contacts = {}
-- reusable cast vectors for the per-frame support sweep path
local cast_origin_offset = Vec3(0, 0, 0)
local cast_delta = Vec3(0, 0, 0)
local sweep_origin = Vec3(0, 0, 0)

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

	-- a moving ground body invalidates the cached hit pose, so drop the cache
	-- and fall back to re-detecting on every solver iteration
	if hit_body and hit_body:HasSolverMass() then
		body._WorldSupportContacts = nil
		return
	end

	local cache = body._WorldSupportContacts

	if not cache then return end

	cache.contacts[#cache.contacts + 1] = contact
end

function support_contacts.GetCastDistances(body, dt)
	local velocity = body:GetVelocity()
	local downward = math.max(0, -velocity.y * dt)
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
		body:AccumulateGroundSupportContact(hit.normal, hit.position)
		return true
	end

	return false
end

function support_contacts.ForEachPointSweepContact(body, dt, solve_contact, solve_contact_context)
	local physics = body:GetPhysics()
	local cast_up, cast_distance = support_contacts.GetCastDistances(body, dt)
	local support_points = body:GetSupportLocalPoints()
	local owner = body:GetOwner()
	local filter_function = body:GetFilterFunction()
	fill_cast_vectors(cast_up, cast_distance)

	if stats:IsEnabled() then stats:PushTime("support_point_sweeps") end
	for i = 1, #support_points do
		local local_point = support_points[i]
		local point = body:GeometryLocalToWorld(local_point)
		sweep_origin.x = point.x + cast_origin_offset.x
		sweep_origin.y = point.y + cast_origin_offset.y
		sweep_origin.z = point.z + cast_origin_offset.z
		local hit = physics.Sweep(sweep_origin, cast_delta, 0, owner, filter_function)
		stats:Count("support_sweeps")

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

function support_contacts.ApplyWorldSupportContact(body, normal, contact_position, support_radius, hit, dt)
	if not (normal and contact_position) then return false end

	local physics = body:GetPhysics()
	local margin = body:GetCollisionMargin() or 0
	local center = body:GetPosition()
	local target_center = contact_position + normal * (support_radius + margin)
	local correction = target_center - center
	local depth = correction:Dot(normal)
	local support_tolerance = (body:GetCollisionProbeDistance() or 0) + margin

	if depth > 0 then
		body:ApplyCorrection(0, normal * depth, center - normal * support_radius, nil, nil, dt)

		if normal.y >= body:GetMinGroundNormalY() then
			apply_support_grounding_metadata(body, hit, normal)
			body:AccumulateGroundSupportContact(normal, contact_position)
		end

		physics.collision_pairs:RecordWorldCollision(body, hit, normal, depth)
		return true
	end

	if depth < -support_tolerance then return false end

	-- within probe tolerance above the surface: no correction or grounding, but
	-- the contact still anchors the body if it gets pushed back down mid-substep
	record_support_contact(
		body,
		hit,
		{normal = normal, position = contact_position, radius = support_radius}
	)
	return true
end

function support_contacts.ApplyPointWorldSupportContact(body, normal, contact_position, support_point, local_point, hit, dt)
	if not (normal and contact_position and support_point) then return false end

	local physics = body:GetPhysics()
	local margin = body:GetCollisionMargin() or 0
	local target_point = contact_position + normal * margin
	local correction = target_point - support_point
	local depth = correction:Dot(normal)
	local support_tolerance = (body:GetCollisionProbeDistance() or 0) + margin

	if depth > 0 then
		body:ApplyCorrection(0, normal * depth, support_point, nil, nil, dt)
	end

	if depth < -support_tolerance then return false end

	if normal.y >= body:GetMinGroundNormalY() then
		apply_support_grounding_metadata(body, hit, normal)
		body:AccumulateGroundSupportContact(normal, support_point)
	end

	physics.collision_pairs:RecordWorldCollision(body, hit, normal, depth)
	record_support_contact(
		body,
		hit,
		{normal = normal, position = contact_position, local_point = local_point}
	)
	return true
end

function support_contacts.SweepCollider(body, dt)
	local physics = body:GetPhysics()
	local cast_up, cast_distance = support_contacts.GetCastDistances(body, dt)
	local center = body:GetPosition()
	local hit = physics.SweepCollider(
		body,
		center + physics_constants.UP * cast_up,
		physics_constants.UP * -cast_distance,
		body:GetOwner(),
		body:GetFilterFunction(),
		{Rotation = body:GetRotation()}
	)
	stats:Count("support_sweeps")
	return hit
end

function support_contacts.SweepSphere(body, dt, radius)
	local physics = body:GetPhysics()
	local cast_up, cast_distance = support_contacts.GetCastDistances(body, dt)
	local center = body:GetPosition()
	fill_cast_vectors(cast_up, cast_distance + radius)
	sweep_origin.x = center.x + cast_origin_offset.x
	sweep_origin.y = center.y + cast_origin_offset.y
	sweep_origin.z = center.z + cast_origin_offset.z
	local hit = physics.Sweep(sweep_origin, cast_delta, radius, body:GetOwner(), body:GetFilterFunction())
	stats:Count("support_sweeps")
	return hit
end

function support_contacts.SolveShapeSupportContacts(body, shape, dt)
	if not (shape and dt and shape.SolveSupportContacts) then return end

	return shape:SolveSupportContacts(body, dt, support_contacts)
end

-- World support contact detection (sweeps) is expensive, so each shape caches
-- its resolved contacts on the body for the rest of the substep. The cache is
-- keyed on the body pose it was validated at: any correction applied in a
-- detection or resolve pass moves the body, which invalidates the cache and
-- forces a fresh re-sweep on the next solver iteration. This keeps the
-- iterative surface-fit (re-probing after every correction) while skipping
-- the re-sweeps that would have found the body already seated.
function support_contacts.GetSubstepId(body)
	local physics = body:GetPhysics()
	local solver = physics and physics.solver

	if not solver then return 0 end

	return solver.StepStamp or 0
end

local function get_support_pose(body)
	local pose_body = body.Body or body
	return pose_body.Position, pose_body.Rotation
end

function support_contacts.BeginSupportDetection(body)
	local substep = support_contacts.GetSubstepId(body)
	local cache = body._WorldSupportContacts
	local position, rotation = get_support_pose(body)

	if
		cache and
		cache.substep == substep and
		cache.px == position.x and
		cache.py == position.y and
		cache.pz == position.z and
		cache.rx == rotation.x and
		cache.ry == rotation.y and
		cache.rz == rotation.z and
		cache.rw == rotation.w
	then
		return false
	end

	body._WorldSupportContacts = {
		substep = substep,
		contacts = {},
		px = position.x,
		py = position.y,
		pz = position.z,
		rx = rotation.x,
		ry = rotation.y,
		rz = rotation.z,
		rw = rotation.w,
	}
	return true
end

function support_contacts.ResolveCachedSupportContacts(body, dt)
	local cache = body._WorldSupportContacts

	if not cache then return end

	if stats:IsEnabled() then stats:PushTime("support_resolve") end
	local contacts = cache.contacts
	local margin = body:GetCollisionMargin() or 0

	for i = 1, #contacts do
		local contact = contacts[i]
		local normal = contact.normal

		if contact.local_point then
			local support_point = body:GeometryLocalToWorld(contact.local_point)
			local depth = (contact.position + normal * margin - support_point):Dot(normal)

			if depth > 0 then
				body:ApplyCorrection(0, normal * depth, support_point, nil, nil, dt)
			end
		else
			local center = body:GetPosition()
			local depth = (contact.position + normal * (contact.radius + margin) - center):Dot(normal)

			if depth > 0 then
				body:ApplyCorrection(0, normal * depth, center - normal * contact.radius, nil, nil, dt)
			end
		end
	end
	if stats:IsEnabled() then stats:PopTime() end
end

return support_contacts
