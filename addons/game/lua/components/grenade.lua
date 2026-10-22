local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local damage = import("lua/damage.lua")
local actors = import("lua/jrpg/actors.lua")
local grenade_effects = import("lua/grenade_effects.lua")
local META = objects.CreateTemplate("grenade")
META:GetSet("Damage", 140)
META:GetSet("Radius", 6)
META:GetSet("Fuse", 2.4)
META:GetSet("Impulse", 9)
local UP = Vec3(0, 1, 0)
local COVER_SCALE = 0.3
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

function META:GetFalloff(distance)
	return math.clamp(1 - distance / self.Radius, 0, 1) ^ 1.5
end

function META:Explode()
	local body = self.Owner.rigid_body
	local position = body:GetPosition():Copy()
	local normal = UP
	local ground = damage.Sweep(position + Vec3(0, 0.3, 0), Vec3(0, -1.5, 0), self.Owner)

	if ground then
		normal = ground.normal
		position = ground.point + normal * 0.05
	end

	local origin = position + Vec3(0, 0.1, 0)

	for _, entity in ipairs(actors.Find(position, self.Radius)) do
		local center = actors.GetCenter(entity)
		local offset = center - origin
		local distance = offset:GetLength()
		local falloff = self:GetFalloff(distance)
		local direction = distance > 1e-3 and offset / distance or UP
		local cover = distance > 1e-3 and damage.Sweep(origin, offset, self.Owner)

		if cover and cover.entity and damage.GetVictim(cover.entity) ~= entity then
			falloff = falloff * COVER_SCALE
		end

		if falloff > 0 then
			damage.Deal(
				entity,
				{
					Attacker = self.caster,
					Inflictor = self.Owner,
					Damage = self.Damage * falloff,
					Type = "fire",
					Position = position,
					Normal = -direction,
					Force = direction * self.Impulse * falloff,
				}
			)
		end
	end

	for _, other in ipairs(RigidBody.Instances) do
		if other ~= body and other:IsDynamic() and not other.Owner.health then
			local offset = other:GetPosition() - origin
			local distance = offset:GetLength()
			local falloff = self:GetFalloff(distance)

			if falloff > 0 and distance > 1e-3 then
				other:ApplyImpulse(offset / distance * self.Impulse * falloff * other:GetMass(), other:GetPosition())
			end
		end
	end

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
