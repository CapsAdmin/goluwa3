local physics_constants = import("goluwa/physics/constants.lua")
local contact_store = import("goluwa/physics/contact_store.lua")
local motion = import("goluwa/physics/motion.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local manifold = {}
local EPSILON = physics_constants.EPSILON
local LOCAL_POINT = Vec3()
local CLAIMED = {}

function manifold.SupportsPersistentTangent(body_a, body_b, manifold_data)
	if manifold_data.n ~= 1 then return false end

	local shape_a = body_a:GetShapeType()
	local shape_b = body_b:GetShapeType()
	return shape_a == "sphere" or
		shape_a == "capsule" or
		shape_b == "sphere" or
		shape_b == "capsule"
end

local function find_by_feature(previous, previous_count, claimed, feature_key)
	if not feature_key then return nil end

	for index = 0, previous_count - 1 do
		if not claimed[index + 1] and previous[index].feature_key == feature_key then
			return index
		end
	end

	return nil
end

local function find_by_distance(previous, previous_count, claimed, c)
	local matched
	local best_distance = 0.25

	for index = 0, previous_count - 1 do
		if not claimed[index + 1] then
			local p = previous[index]
			local distance = math.sqrt((p.lax - c.lax) ^ 2 + (p.lay - c.lay) ^ 2 + (p.laz - c.laz) ^ 2) + math.sqrt((p.lbx - c.lbx) ^ 2 + (p.lby - c.lby) ^ 2 + (p.lbz - c.lbz) ^ 2)

			if distance < best_distance then
				best_distance = distance
				matched = index
			end
		end
	end

	return matched
end

-- Replaces the manifold's contacts with the freshly collided ones. Contacts that match an old
-- one (same feature, else close in both bodies' space) inherit its accumulated impulses.
function manifold.RebuildContacts(body_a, body_b, manifold_data, contacts)
	local count = #contacts
	local rebuilt = contact_store.GetSpare(manifold_data, count)
	local previous = manifold_data.cs
	local previous_count = manifold_data.n or 0
	local claimed = CLAIMED

	for i = 1, previous_count do
		claimed[i] = false
	end

	for contact_index = 1, count do
		local c = rebuilt[contact_index - 1]
		local source = contacts[contact_index]
		body_a:WorldToLocal(source.point_a, nil, nil, LOCAL_POINT)
		c.lax, c.lay, c.laz = LOCAL_POINT.x, LOCAL_POINT.y, LOCAL_POINT.z
		body_b:WorldToLocal(source.point_b, nil, nil, LOCAL_POINT)
		c.lbx, c.lby, c.lbz = LOCAL_POINT.x, LOCAL_POINT.y, LOCAL_POINT.z
		local feature_key = source.feature_key
		local matched = find_by_feature(previous, previous_count, claimed, feature_key)

		if not matched then
			matched = find_by_distance(previous, previous_count, claimed, c)
		end

		if matched then
			local p = previous[matched]
			claimed[matched + 1] = true
			c.jn, c.jt1, c.jt2 = p.jn, p.jt1, p.jt2
			c.v_pre = p.v_pre
			c.rest_stamp, c.rest_speed, c.rest_total, c.rest_impulse = p.rest_stamp, p.rest_speed, p.rest_total, p.rest_impulse
			c.static_active = p.static_active
			c.has_tangent = p.has_tangent
			c.tx, c.ty, c.tz = p.tx, p.ty, p.tz
		else
			c.jn, c.jt1, c.jt2 = 0, 0, 0
			c.v_pre = 0
			c.rest_stamp, c.rest_speed, c.rest_total, c.rest_impulse = -1, 0, 0, 0
			c.static_active = 0
			c.has_tangent = 0
		end

		c.feature_key = feature_key or -1
		local separation = source.separation
		c.has_sep = separation and 1 or 0
		c.sep = separation or 0
		c.has_base = 0
	end

	contact_store.Swap(manifold_data, count)
end

function manifold.ApplyRestitution(body_a, body_b, normal, manifold_data, dt)
	local physics = body_a:GetPhysics()
	local solver = physics.solver
	local restitution = manifold_data.restitution or solver:GetPairRestitution(body_a, body_b)

	if restitution <= EPSILON then return end

	local gravity = physics.Gravity
	local threshold = math.max(
		0.33,
		math.sqrt(gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z) * dt * 2
	)
	local cs = manifold_data.cs

	for contact_index = 0, manifold_data.n - 1 do
		local contact = cs[contact_index]

		if
			contact.rest_stamp == solver.CollideStamp and
			contact.rest_speed < -threshold and
			contact.rest_total > 0 and
			contact.nim > EPSILON
		then
			local normal_speed = (
					body_b.Velocity.x - body_a.Velocity.x
				) * normal.x + (
					body_b.Velocity.y - body_a.Velocity.y
				) * normal.y + (
					body_b.Velocity.z - body_a.Velocity.z
				) * normal.z + body_b.AngularVelocity.x * contact.cbx + body_b.AngularVelocity.y * contact.cby + body_b.AngularVelocity.z * contact.cbz - body_a.AngularVelocity.x * contact.cax - body_a.AngularVelocity.y * contact.cay - body_a.AngularVelocity.z * contact.caz
			local new_impulse = math.max(
				contact.rest_impulse - (
						normal_speed + restitution * contact.rest_speed
					) / contact.nim,
				0
			)
			local impulse_delta = new_impulse - contact.rest_impulse
			contact.rest_impulse = new_impulse

			if manifold_data.prepared_mass_a > 0 then
				local scale = impulse_delta * manifold_data.prepared_mass_a
				body_a.Velocity.x = body_a.Velocity.x - normal.x * scale
				body_a.Velocity.y = body_a.Velocity.y - normal.y * scale
				body_a.Velocity.z = body_a.Velocity.z - normal.z * scale
				body_a.AngularVelocity.x = body_a.AngularVelocity.x - impulse_delta * contact.wax
				body_a.AngularVelocity.y = body_a.AngularVelocity.y - impulse_delta * contact.way
				body_a.AngularVelocity.z = body_a.AngularVelocity.z - impulse_delta * contact.waz
			end

			if manifold_data.prepared_mass_b > 0 then
				local scale = impulse_delta * manifold_data.prepared_mass_b
				body_b.Velocity.x = body_b.Velocity.x + normal.x * scale
				body_b.Velocity.y = body_b.Velocity.y + normal.y * scale
				body_b.Velocity.z = body_b.Velocity.z + normal.z * scale
				body_b.AngularVelocity.x = body_b.AngularVelocity.x + impulse_delta * contact.wbx
				body_b.AngularVelocity.y = body_b.AngularVelocity.y + impulse_delta * contact.wby
				body_b.AngularVelocity.z = body_b.AngularVelocity.z + impulse_delta * contact.wbz
			end
		end
	end

	if body_a.Awake == false then
		motion.SetBodyMotionFromCurrentState(body_a, body_a.Velocity, body_a.AngularVelocity, dt)
	end

	if body_b.Awake == false then
		motion.SetBodyMotionFromCurrentState(body_b, body_b.Velocity, body_b.AngularVelocity, dt)
	end
end

function manifold.PruneOld(manifolds, step_stamp, prune_steps)
	for body_a, row in pairs(manifolds or {}) do
		for body_b, pair_manifold in pairs(row or {}) do
			if
				not pair_manifold.last_seen_step or
				pair_manifold.last_seen_step < step_stamp - prune_steps
			then
				row[body_b] = nil

				if manifolds[body_b] then
					manifolds[body_b][body_a] = nil

					if not next(manifolds[body_b]) then manifolds[body_b] = nil end
				end
			end
		end

		if not next(row) then manifolds[body_a] = nil end
	end
end

return manifold
