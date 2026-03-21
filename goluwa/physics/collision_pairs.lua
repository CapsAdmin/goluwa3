local prototype = import("goluwa/prototype.lua")
local physics = import("goluwa/physics.lua")
local bit = require("bit")
local CollisionPairs = prototype.CreateTemplate("physics_collision_pairs")
import.loaded["goluwa/physics/collision_pairs.lua"] = CollisionPairs

local function new_weak_key_table()
	return setmetatable({}, {__mode = "k"})
end

local function get_nested_entry(store, key_a, key_b)
	local row = store[key_a]
	return row and row[key_b] or nil
end

local function set_nested_entry(store, key_a, key_b, entry)
	local row = store[key_a]

	if not row then
		row = new_weak_key_table()
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
	self.physics = config.physics or self.physics or physics
	self.PreviousCollisionPairs = config.PreviousCollisionPairs or new_weak_key_table()
	self.CurrentCollisionPairs = config.CurrentCollisionPairs or new_weak_key_table()
	self.PreviousCollisionEntries = config.PreviousCollisionEntries or {}
	self.CurrentCollisionEntries = config.CurrentCollisionEntries or {}
	self.PreviousWorldCollisionPairs = config.PreviousWorldCollisionPairs or new_weak_key_table()
	self.CurrentWorldCollisionPairs = config.CurrentWorldCollisionPairs or new_weak_key_table()
	self.PreviousWorldCollisionEntries = config.PreviousWorldCollisionEntries or {}
	self.CurrentWorldCollisionEntries = config.CurrentWorldCollisionEntries or {}
	return self
end

function CollisionPairs:GetPhysics()
	return self.physics or physics
end

function CollisionPairs:ResetState()
	self.PreviousCollisionPairs = new_weak_key_table()
	self.CurrentCollisionPairs = new_weak_key_table()
	self.PreviousCollisionEntries = {}
	self.CurrentCollisionEntries = {}
	self.PreviousWorldCollisionPairs = new_weak_key_table()
	self.CurrentWorldCollisionPairs = new_weak_key_table()
	self.PreviousWorldCollisionEntries = {}
	self.CurrentWorldCollisionEntries = {}
end

function physics.ShouldBodiesCollide(body_a, body_b)
	if body_a == body_b then return false end

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

function CollisionPairs:BeginCollisionFrame()
	self.CurrentCollisionPairs = new_weak_key_table()
	self.CurrentCollisionEntries = {}
	self.CurrentWorldCollisionPairs = new_weak_key_table()
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

function CollisionPairs:RecordCollisionPair(body_a, body_b, normal, overlap)
	local physics = self:GetPhysics()

	if not physics.ShouldBodiesCollide(body_a, body_b) then return end

	local existing = get_nested_entry(self.CurrentCollisionPairs, body_a, body_b)
	local stored_overlap = overlap or 0

	if existing then
		if stored_overlap > (existing.overlap or 0) then
			existing.normal = existing.body_a == body_a and normal or normal * -1
			existing.overlap = stored_overlap
		end

		return
	end

	existing = {
		body_a = body_a,
		body_b = body_b,
		normal = normal,
		overlap = stored_overlap,
	}
	set_nested_entry(self.CurrentCollisionPairs, body_a, body_b, existing)
	set_nested_entry(self.CurrentCollisionPairs, body_b, body_a, existing)
	self.CurrentCollisionEntries[#self.CurrentCollisionEntries + 1] = existing
end

function CollisionPairs:RecordWorldCollision(body, hit, normal, overlap)
	if not (hit and hit.entity) then return end

	if hit.entity == body.Owner then return end

	local stored_overlap = overlap or 0
	local existing = get_nested_entry(self.CurrentWorldCollisionPairs, body, hit.entity)

	if existing then
		if stored_overlap > (existing.overlap or 0) then
			existing.normal = normal
			existing.overlap = stored_overlap
			existing.hit = hit
		end

		return
	end

	existing = {
		body = body,
		entity = hit.entity,
		normal = normal,
		overlap = stored_overlap,
		hit = hit,
	}
	set_nested_entry(self.CurrentWorldCollisionPairs, body, hit.entity, existing)
	self.CurrentWorldCollisionEntries[#self.CurrentWorldCollisionEntries + 1] = existing
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

function CollisionPairs:DispatchCollisionEvents()
	local current = self.CurrentCollisionPairs or {}
	local previous = self.PreviousCollisionPairs or {}

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

	for _, pair in ipairs(self.PreviousWorldCollisionEntries or {}) do
		if not get_nested_entry(current_world, pair.body, pair.entity) then
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

	self.PreviousCollisionPairs = current
	self.PreviousCollisionEntries = self.CurrentCollisionEntries
	self.CurrentCollisionPairs = new_weak_key_table()
	self.CurrentCollisionEntries = {}
	self.PreviousWorldCollisionPairs = current_world
	self.PreviousWorldCollisionEntries = self.CurrentWorldCollisionEntries
	self.CurrentWorldCollisionPairs = new_weak_key_table()
	self.CurrentWorldCollisionEntries = {}
end

CollisionPairs:Register()
return CollisionPairs
