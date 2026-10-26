local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("tool_beam")
META.NetworkOwnerExcluded = true
META.Network = {
	Active = {"boolean", 0.05, "reliable"},
	Target = {"string", 0.05, "reliable"},
	TargetPoint = {"vec3", 0.05, "reliable"},
}
META:StartStorable()
META:IsSet("Active", false)
META:GetSet("Target", "")
META:GetSet("TargetPoint", Vec3())
META:EndStorable()
return META:Register()
