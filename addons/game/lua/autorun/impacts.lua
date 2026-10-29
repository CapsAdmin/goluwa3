local event = import("goluwa/event.lua")
local impacts = import("lua/impacts.lua")
event.AddListener("PhysicsImpact", "impacts", impacts.FirePhysics)
event.AddListener("PhysicsContact", "impacts", impacts.FireContact)
