local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
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
local CHAIN_SPEED = 2.5
local CHAIN_SHARE = 0.8

function META:OnCollisionStay(other)
	local character = self.Character

	if not network.HasAuthority() or other == character then return end

	local other_part = other.ragdoll_part

	if other_part and other_part.Character == character then return end

	character.ragdoll.part_by_name[self.Group].touched = true
end

function META:OnCollisionEnter(other, info)
	if not network.HasAuthority() then return end

	self:OnCollisionStay(other)

	if not self.Character.ragdoll.thrown then return end

	local velocity = info.self_body.Velocity

	if velocity:GetLength() < CHAIN_SPEED then return end

	local victim = other.ragdoll_part and other.ragdoll_part.Character or other
	local ragdoll = victim.ragdoll

	if
		not ragdoll or
		victim == self.Character or
		ragdoll.Limp or
		victim.health:IsDead()
	then
		return
	end

	ragdoll:Knockdown(velocity * CHAIN_SHARE)
end

event.AddListener("ResolveUseTarget", "ragdoll_part", function(entity)
	local part = entity.ragdoll_part

	if part then return part.Character end
end)

return META:Register()
