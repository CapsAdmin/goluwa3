local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local raycast = RENDER_3D and import("goluwa/render3d/raycast.lua")
local use = library()
use.MaxDistance = 3
local trace_options = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

-- fires OnUse(user, hit) on the entity and then on its parents until a handler returns true
function use.Fire(entity, user, hit)
	local current = entity

	while current:IsValid() do
		if current:CallLocalEvent("OnUse", user, hit) == true then return current end

		current = current:GetParent()
	end
end

local function is_not_user(entity, user)
	return entity ~= user and not entity:ContainsParent(user)
end

-- the closest thing with a collider and, where there is a renderer, the closest thing that is visible, a dedicated server only has colliders
function use.Trace(user, origin, direction)
	local best = physics.Sweep(origin, direction * use.MaxDistance, 0, user, nil, trace_options)
	best = best and best.entity and best or nil

	if raycast then
		local visual = raycast.CastClosest(origin, direction, use.MaxDistance, is_not_user, user)

		if visual and (not best or visual.distance < best.distance) then best = visual end
	end

	if not best then return end

	return {
		entity = best.entity,
		point = best.point or best.position or origin + direction * best.distance,
		distance = best.distance,
	}
end

-- the authoritative side resolves a press of the use button, use_sync tells the clients about it
function use.Press(user, origin, direction)
	local hit = use.Trace(user, origin, direction)

	if not hit then return end

	use.Fire(hit.entity, user, hit)
	event.Call("EntityUsed", hit.entity, user, hit)
	return hit.entity
end

return use
