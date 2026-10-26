local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("weapon_switch")
META.NetworkOwnerExcluded = true
META.Network = {
	On = {"boolean", 0.05, "reliable"},
}
META:StartStorable()
META:IsSet("On", false)
META:EndStorable()
return META:Register()
