local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local stats = import("goluwa/physics/stats.lua")
local CollisionPairs = objects.CreateTemplate("physics_collision_pairs")
CollisionPairs.ImpactSpeed = 0.5
CollisionPairs.ContactSpeed = 0.2
import.loaded["goluwa/physics/collision_pairs.lua"] = CollisionPairs
-- a builtin LuaJIT cannot record ends the trace so the side traces after it do not inherit the caller locals
local trace_break = coroutine.running

local function get_nested_entry(store, key_a, key_b)
	trace_break()
	local row = store[key_a]

	if not row then return nil end

	return row[key_b]
end

local function set_nested_entry(store, key_a, key_b, entry)
	local row = store[key_a]

	if not row then
		row = table.weak("k")
		store[key_a] = row
	end

	row[key_b] = entry
end

function CollisionPairs.New(config)
	local self = CollisionPairs:CreateObject()
	return self:Initialize(config)
end

function CollisionPairs:Initialize(config)
	config = config or {}
	self.physics = config.physics or self.physics
	self.PreviousCollisionPairs = config.PreviousCollisionPairs or table.weak("k")
	self.CurrentCollisionPairs = config.CurrentCollisionPairs or table.weak("k")
	self.PreviousCollisionEntries = config.PreviousCollisionEntries or {}
	self.CurrentCollisionEntries = config.CurrentCollisionEntries or {}
	self.PreviousWorldCollisionPairs = config.PreviousWorldCollisionPairs or table.weak("k")
	self.CurrentWorldCollisionPairs = config.CurrentWorldCollisionPairs or table.weak("k")
	self.PreviousWorldCollisionEntries = config.PreviousWorldCollisionEntries or {}
	self.CurrentWorldCollisionEntries = config.CurrentWorldCollisionEntries or {}
	return self
end

function CollisionPairs:GetPhysics()
	return self.physics
end

function CollisionPairs:ResetState()
	self.PreviousCollisionPairs = table.weak("k")
	self.CurrentCollisionPairs = table.weak("k")
	self.PreviousCollisionEntries = {}
	self.CurrentCollisionEntries = {}
	self.PreviousWorldCollisionPairs = table.weak("k")
	self.CurrentWorldCollisionPairs = table.weak("k")
	self.PreviousWorldCollisionEntries = {}
	self.CurrentWorldCollisionEntries = {}
end

function CollisionPairs:BeginCollisionFrame()
	self.CurrentCollisionPairs = table.weak("k")
	self.CurrentCollisionEntries = {}
	self.CurrentWorldCollisionPairs = table.weak("k")
	self.CurrentWorldCollisionEntries = {}
end

function CollisionPairs:GetCachedPair(body_a, body_b)
	local pair = get_nested_entry(self.CurrentCollisionPairs, body_a, body_b) or
		get_nested_entry(self.PreviousCollisionPairs, body_a, body_b)
	return pair, pair and pair.body_a ~= body_a or false
end

function CollisionPairs:BodyHasCurrentCollision(body)
	local row = self.CurrentCollisionPairs[body]
	return row ~= nil and next(row) ~= nil
end

function CollisionPairs:RecordCollisionPair(body_a, body_b, normal, overlap, speed, position)
	if not (body_a and body_a:ShouldCollide(body_b)) then return end

	local existing = get_nested_entry(self.CurrentCollisionPairs, body_a, body_b)
	local stored_overlap = overlap or 0

	if existing then
		if stored_overlap > (existing.overlap or 0) then
			existing.normal = existing.body_a == body_a and normal or normal * -1
			existing.overlap = stored_overlap
		end

		if speed and speed > existing.speed then
			existing.speed = speed
			existing.position = position
			existing.impact_normal = existing.body_a == body_a and normal or normal * -1
		end

		return existing
	end

	existing = {
		body_a = body_a,
		body_b = body_b,
		normal = normal,
		overlap = stored_overlap,
		speed = speed or 0,
		position = position,
		impact_normal = normal,
		contact_x = 0,
		contact_y = 0,
		contact_z = 0,
		contact_count = 0,
	}
	set_nested_entry(self.CurrentCollisionPairs, body_a, body_b, existing)
	set_nested_entry(self.CurrentCollisionPairs, body_b, body_a, existing)
	self.CurrentCollisionEntries[#self.CurrentCollisionEntries + 1] = existing
	return existing
end

function CollisionPairs:RecordGroundImpact(body, ground_body, normal, speed)
	if speed < self.ImpactSpeed then return end

	local world = get_nested_entry(self.CurrentWorldCollisionPairs, body, ground_body.Owner)

	if world then
		if speed > world.speed then world.speed = speed end

		return
	end

	self:RecordCollisionPair(ground_body, body, normal:Copy(), 0, speed)
end

function CollisionPairs:AddContactPoint(entry, x, y, z, weight)
	entry.contact_x = entry.contact_x + x
	entry.contact_y = entry.contact_y + y
	entry.contact_z = entry.contact_z + z
	entry.contact_count = entry.contact_count + weight
end

function CollisionPairs:RecordWorldCollision(body, hit, normal, overlap, speed, position)
	if not (hit and hit.entity) then return end

	if hit.entity == body.Owner then return end

	local stored_overlap = overlap or 0
	local existing = get_nested_entry(self.CurrentWorldCollisionPairs, body, hit.entity)

	if existing then
		if stored_overlap > (existing.overlap or 0) then
			existing.normal = normal
			existing.overlap = stored_overlap
			existing.hit = hit
			existing.other_body = hit.rigid_body
		end

		if speed and speed > existing.speed then
			existing.speed = speed
			existing.position = position
			existing.impact_hit = hit
			existing.impact_normal = normal
		end

		existing.contact = position
		return
	end

	existing = {
		body = body,
		entity = hit.entity,
		other_body = hit.rigid_body,
		normal = normal,
		overlap = stored_overlap,
		hit = hit,
		speed = speed or 0,
		position = position,
		impact_hit = hit,
		impact_normal = normal,
		contact = position,
	}
	set_nested_entry(self.CurrentWorldCollisionPairs, body, hit.entity, existing)
	self.CurrentWorldCollisionEntries[#self.CurrentWorldCollisionEntries + 1] = existing
end

do
	local function get_point_velocity(body, px, py, pz)
		if not body then return 0, 0, 0 end

		local v, w, o = body.Velocity, body.AngularVelocity, body.Position
		local rx, ry, rz = px - o.x, py - o.y, pz - o.z
		return v.x + w.y * rz - w.z * ry,
		v.y + w.z * rx - w.x * rz,
		v.z + w.x * ry - w.y * rx
	end

	local function get_tangent(x, y, z, n)
		local d = x * n.x + y * n.y + z * n.z
		return x - n.x * d, y - n.y * d, z - n.z * d
	end

	-- the part of a body's motion along the surface that its spin carries, so the contact point does not slide
	local function get_roll_speed(body, ox, oy, oz, px, py, pz, n)
		if not body then return 0 end

		local v, w, o = body.Velocity, body.AngularVelocity, body.Position
		local rx, ry, rz = px - o.x, py - o.y, pz - o.z
		local tx, ty, tz = get_tangent(v.x - ox, v.y - oy, v.z - oz, n)
		local travel = math.sqrt(tx * tx + ty * ty + tz * tz)

		if travel < 1e-6 then return 0 end

		local sx, sy, sz = get_tangent(w.y * rz - w.z * ry, w.z * rx - w.x * rz, w.x * ry - w.y * rx, n)
		return math.clamp(-(sx * tx + sy * ty + sz * tz) / travel, 0, travel)
	end

	function CollisionPairs:DispatchContact(entity_a, entity_b, body_a, body_b, normal, px, py, pz, hit_a)
		local ax, ay, az = get_point_velocity(body_a, px, py, pz)
		local bx, by, bz = get_point_velocity(body_b, px, py, pz)
		local sx, sy, sz = get_tangent(bx - ax, by - ay, bz - az, normal)
		local slip = math.sqrt(sx * sx + sy * sy + sz * sz)
		local roll_a = get_roll_speed(body_a, bx, by, bz, px, py, pz, normal)
		local roll_b = get_roll_speed(body_b, ax, ay, az, px, py, pz, normal)
		local roll = math.max(roll_a, roll_b)

		if slip < self.ContactSpeed and roll < self.ContactSpeed then return end

		event.Call(
			"PhysicsContact",
			{
				entity_a = entity_a,
				entity_b = entity_b,
				body_a = body_a,
				body_b = body_b,
				normal = normal,
				position = Vec3(px, py, pz),
				slip = slip,
				roll = roll,
				roller = roll > 0 and (roll_b >= roll_a and body_b or body_a) or nil,
				hit_a = hit_a,
			}
		)
	end
end

local function emit_collision_event(what, self_owner, self_body, other_entity, other_body, normal, overlap, hit)
	stats:Count(what)
	local owner = self_owner or (self_body and self_body.Owner)

	if not (owner and owner.CallLocalEvent) then return end

	owner:CallLocalEvent(
		what,
		other_entity,
		{
			self_body = self_body,
			other_body = other_body,
			other_entity = other_entity,
			normal = normal,
			overlap = overlap or 0,
			hit = hit,
		}
	)
end

local queue_impact, fire_impacts

do
	local pending = {}
	local pending_count = 0
	local by_owner = {}

	function queue_impact(impact)
		local a, b = impact.entity_a or impact.body_a, impact.entity_b or impact.body_b
		local index = by_owner[a] and by_owner[a][b] or by_owner[b] and by_owner[b][a]

		if index then
			if impact.speed > pending[index].speed then pending[index] = impact end

			return
		end

		pending_count = pending_count + 1
		pending[pending_count] = impact
		local row = by_owner[a]

		if not row then
			row = {}
			by_owner[a] = row
		end

		row[b] = pending_count
	end

	function fire_impacts()
		for i = 1, pending_count do
			local impact = pending[i]
			pending[i] = nil
			by_owner[impact.entity_a or impact.body_a] = nil
			by_owner[impact.entity_b or impact.body_b] = nil
			event.Call("PhysicsImpact", impact)
		end

		pending_count = 0
	end
end

function CollisionPairs:DispatchCollisionEvents()
	local current = self.CurrentCollisionPairs or {}
	local previous = self.PreviousCollisionPairs or {}
	local impact_speed = self.ImpactSpeed

	for _, pair in ipairs(self.CurrentWorldCollisionEntries) do
		local hit = pair.impact_hit
		local body_pair = get_nested_entry(current, pair.body, hit.rigid_body)
		local speed = pair.speed

		if body_pair then
			speed = math.max(speed, body_pair.speed)
			body_pair.speed = 0
			body_pair.contact_count = 0
		end

		if speed >= impact_speed then
			queue_impact{
				entity_a = pair.entity,
				entity_b = pair.body.Owner,
				body_a = hit.rigid_body,
				body_b = pair.body,
				normal = pair.impact_normal,
				position = pair.position or hit.position,
				speed = speed,
				hit_a = hit,
			}
		end

		local contact = pair.contact

		if contact then
			self:DispatchContact(
				pair.entity,
				pair.body.Owner,
				pair.hit.rigid_body,
				pair.body,
				pair.normal,
				contact.x,
				contact.y,
				contact.z,
				pair.hit
			)
		end
	end

	for _, pair in ipairs(self.CurrentCollisionEntries) do
		if pair.speed >= impact_speed then
			queue_impact{
				entity_a = pair.body_a.Owner,
				entity_b = pair.body_b.Owner,
				body_a = pair.body_a,
				body_b = pair.body_b,
				normal = pair.impact_normal,
				position = pair.position or
					(
						pair.body_b:IsDynamic() and
						pair.body_b or
						pair.body_a
					):GetPosition():Copy(),
				speed = pair.speed,
			}
		end

		local count = pair.contact_count

		if count > 0 then
			self:DispatchContact(
				pair.body_a.Owner,
				pair.body_b.Owner,
				pair.body_a,
				pair.body_b,
				pair.normal,
				pair.contact_x / count,
				pair.contact_y / count,
				pair.contact_z / count
			)
		end
	end

	fire_impacts()

	for _, pair in ipairs(self.CurrentCollisionEntries or {}) do
		local previous_pair = get_nested_entry(previous, pair.body_a, pair.body_b)
		local event_name = previous_pair and "OnCollisionStay" or "OnCollisionEnter"
		emit_collision_event(
			event_name,
			pair.body_a and pair.body_a.Owner or nil,
			pair.body_a,
			pair.body_b and pair.body_b.Owner or nil,
			pair.body_b,
			pair.normal,
			pair.overlap
		)
		emit_collision_event(
			event_name,
			pair.body_b and pair.body_b.Owner or nil,
			pair.body_b,
			pair.body_a and pair.body_a.Owner or nil,
			pair.body_a,
			pair.normal * -1,
			pair.overlap
		)
	end

	for _, pair in ipairs(self.PreviousCollisionEntries or {}) do
		if not get_nested_entry(current, pair.body_a, pair.body_b) then
			emit_collision_event(
				"OnCollisionExit",
				pair.body_a and pair.body_a.Owner or nil,
				pair.body_a,
				pair.body_b and pair.body_b.Owner or nil,
				pair.body_b,
				pair.normal,
				pair.overlap
			)
			emit_collision_event(
				"OnCollisionExit",
				pair.body_b and pair.body_b.Owner or nil,
				pair.body_b,
				pair.body_a and pair.body_a.Owner or nil,
				pair.body_a,
				pair.normal * -1,
				pair.overlap
			)
		end
	end

	local current_world = self.CurrentWorldCollisionPairs or {}
	local previous_world = self.PreviousWorldCollisionPairs or {}

	for _, pair in ipairs(self.CurrentWorldCollisionEntries or {}) do
		local previous_pair = get_nested_entry(previous_world, pair.body, pair.entity)
		local event_name = previous_pair and "OnCollisionStay" or "OnCollisionEnter"
		local other_body = pair.other_body or pair.hit and pair.hit.rigid_body or nil
		emit_collision_event(
			event_name,
			pair.body and pair.body.Owner or nil,
			pair.body,
			pair.entity,
			other_body,
			pair.normal,
			pair.overlap,
			pair.hit
		)
		emit_collision_event(
			event_name,
			pair.entity,
			nil,
			pair.body and pair.body.Owner or nil,
			pair.body,
			pair.normal * -1,
			pair.overlap,
			pair.hit
		)
	end

	for _, pair in ipairs(self.PreviousWorldCollisionEntries or {}) do
		if not get_nested_entry(current_world, pair.body, pair.entity) then
			local other_body = pair.other_body or pair.hit and pair.hit.rigid_body or nil
			emit_collision_event(
				"OnCollisionExit",
				pair.body and pair.body.Owner or nil,
				pair.body,
				pair.entity,
				other_body,
				pair.normal,
				pair.overlap,
				pair.hit
			)
			emit_collision_event(
				"OnCollisionExit",
				pair.entity,
				nil,
				pair.body and pair.body.Owner or nil,
				pair.body,
				pair.normal * -1,
				pair.overlap,
				pair.hit
			)
		end
	end

	self.PreviousCollisionPairs = current
	self.PreviousCollisionEntries = self.CurrentCollisionEntries
	self.CurrentCollisionPairs = table.weak("k")
	self.CurrentCollisionEntries = {}
	self.PreviousWorldCollisionPairs = current_world
	self.PreviousWorldCollisionEntries = self.CurrentWorldCollisionEntries
	self.CurrentWorldCollisionPairs = table.weak("k")
	self.CurrentWorldCollisionEntries = {}
end

CollisionPairs:Register()
return CollisionPairs
