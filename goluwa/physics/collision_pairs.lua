local physics = import("goluwa/physics.lua")
local bit = require("bit")

local function get_pair_key(body_a, body_b)
	local key_a = physics.GetObjectCacheKey(body_a)
	local key_b = physics.GetObjectCacheKey(body_b)

	if key_b < key_a then return key_b .. "|" .. key_a, true end

	return key_a .. "|" .. key_b, false
end

function physics.ShouldBodiesCollide(body_a, body_b)
	if not (body_a and body_b) or body_a == body_b then return false end

	if not (physics.IsActiveRigidBody(body_a) and physics.IsActiveRigidBody(body_b)) then
		return false
	end

	local group_a = body_a.GetCollisionGroup and
		body_a:GetCollisionGroup() or
		body_a.CollisionGroup or
		1
	local group_b = body_b.GetCollisionGroup and
		body_b:GetCollisionGroup() or
		body_b.CollisionGroup or
		1
	local mask_a = body_a.GetCollisionMask and body_a:GetCollisionMask() or body_a.CollisionMask
	local mask_b = body_b.GetCollisionMask and body_b:GetCollisionMask() or body_b.CollisionMask
	mask_a = mask_a == nil and -1 or mask_a
	mask_b = mask_b == nil and -1 or mask_b
	return bit.band(mask_a, group_b) ~= 0 and bit.band(mask_b, group_a) ~= 0
end

function physics.BeginCollisionFrame()
	table.clear(physics.CurrentCollisionPairs)
	table.clear(physics.CurrentWorldCollisionPairs)
end

function physics.RecordCollisionPair(body_a, body_b, normal, overlap)
	if not physics.ShouldBodiesCollide(body_a, body_b) then return end

	body_a = body_a.GetBody and body_a:GetBody() or body_a
	body_b = body_b.GetBody and body_b:GetBody() or body_b
	local key, swapped = get_pair_key(body_a, body_b)
	local stored_normal = swapped and normal * -1 or normal
	local stored_overlap = overlap or 0
	local existing = physics.CurrentCollisionPairs[key]

	if not existing or stored_overlap > (existing.overlap or 0) then
		physics.CurrentCollisionPairs[key] = {
			body_a = swapped and body_b or body_a,
			body_b = swapped and body_a or body_b,
			normal = stored_normal,
			overlap = stored_overlap,
		}
	end
end

local function get_world_pair_key(body, entity)
	if not (physics.IsActiveRigidBody(body) and entity) then return nil end

	return physics.GetObjectCacheKey(body) .. "|world|" .. physics.GetObjectCacheKey(entity)
end

function physics.RecordWorldCollision(body, hit, normal, overlap)
	if not physics.IsActiveRigidBody(body) then return end

	if not (hit and hit.entity) then return end

	if hit.entity == body.Owner then return end

	local key = get_world_pair_key(body, hit.entity)

	if not key then return end

	local stored_overlap = overlap or 0
	local existing = physics.CurrentWorldCollisionPairs[key]

	if not existing or stored_overlap > (existing.overlap or 0) then
		physics.CurrentWorldCollisionPairs[key] = {
			body = body,
			entity = hit.entity,
			normal = normal,
			overlap = stored_overlap,
			hit = hit,
		}
	end
end

local function emit_collision_event(what, self_owner, self_body, other_entity, other_body, normal, overlap, hit)
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

function physics.DispatchCollisionEvents()
	local current = physics.CurrentCollisionPairs or {}
	local previous = physics.PreviousCollisionPairs or {}

	for key, pair in pairs(current) do
		local previous_pair = previous[key]
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

	for key, pair in pairs(previous) do
		if not current[key] then
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

	local current_world = physics.CurrentWorldCollisionPairs or {}
	local previous_world = physics.PreviousWorldCollisionPairs or {}

	for key, pair in pairs(current_world) do
		local previous_pair = previous_world[key]
		local event_name = previous_pair and "OnCollisionStay" or "OnCollisionEnter"
		emit_collision_event(
			event_name,
			pair.body and pair.body.Owner or nil,
			pair.body,
			pair.entity,
			nil,
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

	for key, pair in pairs(previous_world) do
		if not current_world[key] then
			emit_collision_event(
				"OnCollisionExit",
				pair.body and pair.body.Owner or nil,
				pair.body,
				pair.entity,
				nil,
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

	physics.PreviousCollisionPairs = current
	physics.CurrentCollisionPairs = {}
	physics.PreviousWorldCollisionPairs = current_world
	physics.CurrentWorldCollisionPairs = {}
end

return physics