local toolgun = import("lua/toolgun.lua")
return toolgun.ConstraintTool{
	Name = "no_collide",
	DisplayName = "No collide",
	Kind = "no_collide",
	NoWorld = true,
	Description = "Makes two objects pass through each other.",
	Build = function(context, first, second)
		return {Kind = "no_collide"}, first.position, second.position
	end,
}
