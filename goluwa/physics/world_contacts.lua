local world_rigid_mesh_bridge = import("goluwa/physics/world_rigid_mesh_bridge.lua")
local physics = import("goluwa/physics.lua")
local world_contacts = {}

function world_contacts.SolveBodyContacts(body, dt)
	if not (body and body.CollisionEnabled) then return false end

	if physics.collision_pairs and physics.collision_pairs:BodyHasCurrentCollision(body) then
		return false
	end

	local solved = world_rigid_mesh_bridge.ResolveSweptBodyAgainstWorldPrimitives(body, dt)

	return solved
end

return world_contacts
