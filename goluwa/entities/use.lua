local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local raycast = RENDER_3D and import("goluwa/render3d/raycast.lua")
local use = {}
use.MaxDistance = 3
local trace_options = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

function use.GetMaxDistance(user)
	return use.MaxDistance * (event.Call("UseReachScale", user) or 1)
end

function use.Fire(entity, user, hit)
	local current = entity

	while current:IsValid() do
		if current:CallLocalEvent("OnUse", user, hit) == true then return current end

		current = current:GetParent()
	end
end

function use.Resolve(entity)
	return event.Call("ResolveUseTarget", entity) or entity
end

local function is_not_user(entity, user)
	return entity ~= user and not entity:ContainsParent(user)
end

function use.Trace(user, origin, direction)
	local max_distance = use.GetMaxDistance(user)
	local best = physics.Sweep(origin, direction * max_distance, 0, user, nil, trace_options)
	best = best and best.entity and best or nil

	if raycast then
		local visual = raycast.CastClosestUnskinned(origin, direction, max_distance, is_not_user, user)

		if visual and (not best or visual.distance < best.distance) then
			best = visual
		end
	end

	if not best then return end

	return {
		entity = use.Resolve(best.entity),
		point = best.point or best.position or origin + direction * best.distance,
		distance = best.distance,
	}
end

function use.Find(user, origin, direction)
	local hit = use.Trace(user, origin, direction)
	return event.Call("FindUseFallback", user, origin, direction, hit) or hit
end

function use.Press(user, origin, direction)
	local hit = use.Find(user, origin, direction)

	if not hit then return end

	use.Fire(hit.entity, user, hit)
	event.Call("EntityUsed", hit.entity, user, hit)
	return hit.entity
end

return use
