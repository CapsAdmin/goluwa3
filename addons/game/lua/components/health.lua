local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local timer = import("goluwa/timer.lua")
local META = objects.CreateTemplate("health")
META.Network = {
	Health = {"number", 0.1, "reliable", to_owner = true},
	MaxHealth = {"number", 0.5, "reliable", to_owner = true},
}
META:StartStorable()
META:GetSet("Health", 100)
META:GetSet("MaxHealth", 100)
META:IsSet("RemoveOnDeath", false)
META:GetSet("RefillDelay", 0)
META:EndStorable()

local function revive(self)
	self:Revive()
end

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

	local before = self.Health
	self:SetHealth(math.clamp(self.Health - info.Damage, 0, self.MaxHealth))
	event.Call("HealthDamaged", self.Owner, before - self.Health, self.MaxHealth, info)
	self.Owner:CallLocalEvent("OnTakeDamage", info)

	if self.Health > 0 then return end

	self.Owner:CallLocalEvent("OnDeath", info)
	event.Call("EntityKilled", self.Owner, info)

	if self.RefillDelay > 0 then
		timer.Delay(self.RefillDelay, revive, nil, self, self)
		return
	end

	if self.RemoveOnDeath then self.Owner:Remove() end
end

return META:Register()
