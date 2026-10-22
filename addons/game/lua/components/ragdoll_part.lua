local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("ragdoll_part")
META.Network = {
	Group = {"string", 1, "reliable"},
	CharacterId = {"number", 1, "reliable"},
	Limp = {"boolean", 0.1, "reliable"},
}
META:StartStorable()
META:GetSet("Group", "")
META:GetSet("Multiplier", 1)
META:EndStorable()
META:GetSet("CharacterId", -1)
META:IsSet("Limp", false)
return META:Register()
