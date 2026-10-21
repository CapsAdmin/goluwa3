local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local META = objects.CreateTemplate("health")
META.Network = {
	Health = {"number", 0.1, "reliable"},
	MaxHealth = {"number", 0.5, "reliable"},
}
META:StartStorable()
META:GetSet("Health", 100)
META:GetSet("MaxHealth", 100)
META:IsSet("RemoveOnDeath", false)
META:EndStorable()

function META:IsDead()
	return self.Health <= 0
end

function META:GetFraction()
	return self.Health / self.MaxHealth
end

function META:Heal(amount)
	self:SetHealth(math.min(self.Health + amount, self.MaxHealth))
end

function META:Revive()
	self:SetHealth(self.MaxHealth)
end

function META:TakeDamage(info)
	if self.Health <= 0 then return end

	self:SetHealth(math.clamp(self.Health - info.Damage, 0, self.MaxHealth))
	self.Owner:CallLocalEvent("OnTakeDamage", info)

	if self.Health > 0 then return end

	self.Owner:CallLocalEvent("OnDeath", info)
	event.Call("EntityKilled", self.Owner, info)

	if self.RemoveOnDeath then self.Owner:Remove() end
end

return META:Register()
