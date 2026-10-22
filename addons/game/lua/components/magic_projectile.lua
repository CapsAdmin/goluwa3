local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local system = import("goluwa/system.lua")
local damage = import("lua/damage.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local actors = import("lua/jrpg/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local META = objects.CreateTemplate("magic_projectile")
META.Network = {
	Types = {"string", 1, "reliable"},
	Damage = {"number", 1, "reliable"},
}
META:GetSet("Types", "generic")
META:GetSet("Damage", 30)
META:GetSet("Speed", 11)
META:GetSet("LifeTime", 6)
META:GetSet("Radius", 0.12)
local CASTER_GRACE = 0.35
local STEER_START = 0.15
local STEER_RATE = 7
local TRAIL_POINTS = 14

function META:Initialize()
	self.time = 0
	self.velocity = Vec3()
	self.type_list = {}
	self:AddGlobalEvent("Update")
end

function META:Launch(caster, direction, target, target_point)
	self.caster = caster
	self.target = target
	self.target_point = target_point
	local side = Vec3(math.randomf(-1, 1), math.randomf(0.2, 1), math.randomf(-1, 1))
	self.velocity = (direction + side * 0.45):GetNormalized() * self.Speed
end

function META:GetTypeList()
	if self.parsed_types ~= self.Types then
		self.parsed_types = self.Types
		table.clear(self.type_list)

		for name in self.Types:gmatch("[^,]+") do
			self.type_list[#self.type_list + 1] = name
		end
	end

	return self.type_list
end

function META:GetTargetPoint()
	local target = self.target

	if target and target:IsValid() and not (target.health and target.health:IsDead()) then
		return actors.GetCenter(target)
	end

	return self.target_point
end

function META:Explode(position, normal, victim, part)
	local types = self:GetTypeList()

	if victim and victim.health then
		for _, type_name in ipairs(types) do
			if victim:IsValid() and not victim.health:IsDead() then
				damage.Deal(
					victim,
					{
						Attacker = self.caster,
						Inflictor = self.Owner,
						Damage = self.Damage,
						Type = type_name,
						Position = position,
						Normal = normal,
						Force = self.velocity:GetNormalized() * 4,
						Part = part,
					}
				)
			end
		end
	end

	for _, type_name in ipairs(types) do
		effects.Impact(position, normal, type_name, victim and 1.2 or 0.8)
	end

	self.Owner:Remove()
end

function META:Simulate(dt)
	local transform = self.Owner.transform
	local position = transform:GetPosition()
	local target_point = self:GetTargetPoint()

	if target_point and self.time > STEER_START then
		local to_target = target_point - position
		local distance = to_target:GetLength()

		if distance > 1e-3 then
			local desired = to_target / distance * self.Speed
			local steer = math.min((self.time - STEER_START) * STEER_RATE * dt, 1)
			self.velocity = self.velocity + (desired - self.velocity) * steer
		end
	end

	local movement = self.velocity * dt
	local ignore = self.time < CASTER_GRACE and self.caster or nil
	local hit = damage.Sweep(position, movement, ignore or self.Owner, self.Radius)

	if hit then
		local victim, part

		if hit.entity then
			victim = damage.GetVictim(hit.entity)
			part = hit.entity.ragdoll_part and hit.entity.ragdoll_part.Group
		end

		if victim and not victim.health then victim = nil end

		local body = hit.rigid_body or (hit.entity and hit.entity.rigid_body)

		if body and body:IsDynamic() and not victim then
			body:ApplyImpulse(self.velocity:GetNormalized() * 3, hit.point)
		end

		self:Explode(hit.point, hit.normal, victim, part)
		return
	end

	transform:SetPosition(position + movement)

	if self.time > self.LifeTime then
		self:Explode(position, self.velocity:GetNormalized() * -1)
	end
end

function META:BuildVisuals()
	local types = self:GetTypeList()
	local color = damage_types.MixColor(types)
	local glow = 1

	for _, type_name in ipairs(types) do
		glow = math.max(glow, damage_types.Get(type_name).Glow)
	end

	self.color = color
	self.glow = glow
	self.core = effects.AcquireSprite(Color(1, 1, 1, 1):GetLerped(0.4, color), 8)
	self.halo = effects.AcquireSprite(color, 2)
	self.flare = effects.AcquireSprite(color, 5, effects.GetTexture("flare"))
	self.trail = effects.AcquireTrail(color, 4, TRAIL_POINTS, 0.12 * glow)
	self.emitters = {}

	for i, type_name in ipairs(types) do
		local properties = effects.GetParticleProperties(damage_types.Get(type_name), {Rate = 90, Playing = true, MaxParticles = 384, Spread = 180})
		self.emitters[i] = effects.CreateEmitter("magic_projectile_" .. type_name, properties)
	end

	self.light = Entity.New{
		Name = "magic_projectile_light",
		transform = {},
		light_point = {
			Range = 10,
			OcclusionMap = false,
			Lumen = 10,
			Color = Color(color.r, color.g, color.b, 1),
		},
	}
	self.light:SetTransient(true)
end

function META:UpdateVisuals()
	if not self.core then self:BuildVisuals() end

	local position = self.Owner.transform:GetPosition()
	local now = system.GetElapsedTime()
	local flicker = 1

	for _, type_name in ipairs(self:GetTypeList()) do
		if damage_types.Get(type_name).Flicker > 0 then
			flicker = 0.4 + math.random() * 1.2
		end
	end

	local appear = math.min(self.time * 6, 1)
	local size = 0.16 * self.glow * appear
	self.core:Draw(position, size * 0.7, 1)
	self.halo:Draw(position, size * (2.2 + math.sin(now * 9) * 0.2), 0.6 * flicker)
	self.flare:Draw(position, size * 1.6 * flicker, 0.8)
	self.trail:Push(position)

	for _, emitter in ipairs(self.emitters) do
		emitter.transform:SetPosition(position:Copy())
	end

	self.light.transform:SetPosition(position:Copy())
	self.light.light_point:SetLumen(12 * flicker * appear)
end

function META:OnUpdate(dt)
	self.time = self.time + dt

	if effects.Visual then self:UpdateVisuals() end

	if network.HasAuthority() and self.caster then
		self:Simulate(math.min(dt, 0.05))
	end
end

function META:OnRemove()
	if not self.core then return end

	self.core:Release()
	self.halo:Release()
	self.flare:Release()
	self.trail:Release()
	self.light:Remove()

	for _, emitter in ipairs(self.emitters) do
		emitter.particle_emitter_gpu:SetPlaying(false)
		effects.RemoveDelayed(emitter, 1.5)
	end
end

return META:Register()
