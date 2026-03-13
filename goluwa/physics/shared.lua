local Vec3 = import("goluwa/structs/vec3.lua")
local bit = require("bit")
local physics = import.loaded["goluwa/physics/shared.lua"] or
	import.loaded["goluwa/physics/init.lua"] or
	import.loaded["goluwa/physics.lua"]

if not physics then physics = library() end

import.loaded["goluwa/physics/shared.lua"] = physics
import.loaded["goluwa/physics/init.lua"] = physics
import.loaded["goluwa/physics.lua"] = physics
physics.Gravity = physics.Gravity or Vec3(0, -28, 0)
physics.Up = physics.Up or Vec3(0, 1, 0)
physics.DefaultSkin = physics.DefaultSkin or 0.02
physics.RigidBodySubsteps = physics.RigidBodySubsteps or 6
physics.RigidBodyIterations = physics.RigidBodyIterations or 2
physics.DistanceConstraints = physics.DistanceConstraints or {}
physics.PreviousCollisionPairs = physics.PreviousCollisionPairs or {}
physics.CurrentCollisionPairs = physics.CurrentCollisionPairs or {}

function physics.GetRigidBodyMeta()
	return import("goluwa/ecs/components/3d/rigid_body.lua")
end

function physics.IsActiveRigidBody(body)
	return body and
		body.Enabled and
		body.Owner and
		body.Owner.IsValid and
		body.Owner:IsValid() and
		body.Owner.transform
end

local function get_pair_key(body_a, body_b)
	local key_a = tostring(body_a)
	local key_b = tostring(body_b)

	if key_b < key_a then return key_b .. "|" .. key_a, true end

	return key_a .. "|" .. key_b, false
end

function physics.ShouldBodiesCollide(body_a, body_b)
	if not (body_a and body_b) or body_a == body_b then return false end

	if not (physics.IsActiveRigidBody(body_a) and physics.IsActiveRigidBody(body_b)) then
		return false
	end

	local group_a = body_a.CollisionGroup or 1
	local group_b = body_b.CollisionGroup or 1
	local mask_a = body_a.CollisionMask == nil and -1 or body_a.CollisionMask
	local mask_b = body_b.CollisionMask == nil and -1 or body_b.CollisionMask
	return bit.band(mask_a, group_b) ~= 0 and bit.band(mask_b, group_a) ~= 0
end

function physics.BeginCollisionFrame()
	physics.CurrentCollisionPairs = {}
end

function physics.RecordCollisionPair(body_a, body_b, normal, overlap)
	if not physics.ShouldBodiesCollide(body_a, body_b) then return end

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

local function emit_collision_event(what, self_body, other_body, normal, overlap)
	local owner = self_body and self_body.Owner

	if not (owner and owner.CallLocalEvent) then return end

	owner:CallLocalEvent(
		what,
		other_body and other_body.Owner or nil,
		{
			self_body = self_body,
			other_body = other_body,
			normal = normal,
			overlap = overlap or 0,
		}
	)
end

function physics.DispatchCollisionEvents()
	local current = physics.CurrentCollisionPairs or {}
	local previous = physics.PreviousCollisionPairs or {}

	for key, pair in pairs(current) do
		local previous_pair = previous[key]
		local event_name = previous_pair and "OnCollisionStay" or "OnCollisionEnter"
		emit_collision_event(event_name, pair.body_a, pair.body_b, pair.normal, pair.overlap)
		emit_collision_event(event_name, pair.body_b, pair.body_a, pair.normal * -1, pair.overlap)
	end

	for key, pair in pairs(previous) do
		if not current[key] then
			emit_collision_event("OnCollisionExit", pair.body_a, pair.body_b, pair.normal, pair.overlap)
			emit_collision_event("OnCollisionExit", pair.body_b, pair.body_a, pair.normal * -1, pair.overlap)
		end
	end

	physics.PreviousCollisionPairs = current
	physics.CurrentCollisionPairs = {}
end

return physics