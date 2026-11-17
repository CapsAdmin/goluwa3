local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local explosions = import("lua/explosions.lua")
local grenade_effects = import("lua/grenade_effects.lua")
local META = objects.CreateTemplate("grenade")
META:GetSet("Damage", 140)
META:GetSet("Radius", 6)
META:GetSet("Fuse", 2.4)
META:GetSet("Impulse", 9)
local BLINK_ON = 1
local BLINK_OFF = 0.15

function META:Initialize()
	self.time = 0
	self:AddGlobalEvent("Update")
end

function META:Launch(caster, velocity)
	self.caster = caster
	local body = self.Owner.rigid_body
	body:SetVelocity(velocity)
	body:SetAngularVelocity(Vec3(math.randomf(-8, 8), math.randomf(-8, 8), math.randomf(-8, 8)))
end

function META:Explode()
	local position, normal = explosions.FindGround(self.Owner.rigid_body:GetPosition():Copy(), self.Owner)
	explosions.Blast{
		Position = position,
		Attacker = self.caster,
		Inflictor = self.Owner,
		Damage = self.Damage,
		Radius = self.Radius,
		Impulse = self.Impulse,
	}
	grenade_effects.Explode(position, normal, self.Radius)
	self.Owner:Remove()
end

function META:UpdateVisuals(dt)
	if not self.clip then self.clip = grenade_effects.StartFuse() end

	local p = self.clip.params
	local position = self.Owner.rigid_body:GetPosition()
	local fraction = math.min(self.time / self.Fuse, 1)
	p.position:Set(position.x, position.y + 0.04, position.z)
	p.blink = (self.time * (3 + fraction * 14)) % 1 < 0.5 and BLINK_ON or BLINK_OFF
	self.clip:Update(0, dt)
end

function META:OnUpdate(dt)
	self.time = self.time + dt

	if grenade_effects.IsVisual() then self:UpdateVisuals(dt) end

	if network.HasAuthority() and self.time >= self.Fuse then self:Explode() end
end

function META:OnRemove()
	if self.clip then self.clip:Remove() end
end

return META:Register()
