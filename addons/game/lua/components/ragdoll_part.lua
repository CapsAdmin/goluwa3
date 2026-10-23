local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
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
event.AddListener("ResolveUseTarget", "ragdoll_part", function(entity)
	local part = entity.ragdoll_part

	if part then return part.Character end
end)

return META:Register()
