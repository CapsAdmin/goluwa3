local event = import("goluwa/event.lua")
local physics = import("goluwa/physics/shared.lua")
import("goluwa/physics/trace.lua")
import("goluwa/physics/constraint.lua")
import("goluwa/physics/solver.lua")
import("goluwa/physics/rigid_body.lua")

function physics.Update(dt)
	if not dt or dt <= 0 then return end

	physics.UpdateRigidBodies(dt)
end

if not physics.UpdateListenerRegistered then
	event.AddListener("Update", "physics", function(dt)
		physics.Update(dt)
	end)

	physics.UpdateListenerRegistered = true
end

return physics