local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local damage = import("lua/damage.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local actors = import("lua/jrpg/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local clips = import("goluwa/render3d/clips.lua")
local META = objects.CreateTemplate("magic_projectile")
META.Network = {
	Types = {"string", 1, "reliable"},
	Damage = {"number", 1, "reliable"},
	Bounced = {"boolean", 1, "reliable"},
}
META:GetSet("Types", "generic")
META:GetSet("Damage", 30)
META:GetSet("Speed", 11)
META:GetSet("LifeTime", 6)
META:GetSet("Radius", 0.12)
META:GetSet("Bounced", false)
local CASTER_GRACE = 0.35
local FADE_TIME = 3
local BOUNCE_GRAVITY = 0.6
local BOUNCE_RESTITUTION = 0.65
local BOUNCE_MIN_SPEED = 1
local STEER_START = 0.15
local STEER_RATE = 7
local TRAIL_POINTS = 20
local LENS_SCALE = 0.5
local TRAIL_RADIUS = 0.012
local PARTICLE_SIZE = 0.01

function META:Initialize()
	self.time = 0
	self.velocity = Vec3()
	self.fade_time = 0
	self.pending_hit = nil
	self.step_velocity = Vec3()
	self.type_list = {}
	self:AddGlobalEvent("Update")
	self:AddGlobalEvent("PhysicsUpdate")
end

function META:Launch(caster, direction, target, target_point)
	self.caster = caster
	self.target = target
	self.target_point = target_point
	local side = Vec3(math.randomf(-1, 1), math.randomf(0.2, 1), math.randomf(-1, 1))
	self.velocity = (direction + side * 0.45):GetNormalized() * self.Speed
	self.Owner.rigid_body:SetVelocity(self.velocity)
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

function META:GetBurstDirection(velocity, normal)
	local incoming = velocity:GetNormalized()
	local facing = normal

	if incoming:GetDot(normal) > 0 then facing = normal * -1 end

	local reflected = incoming - facing * (2 * incoming:GetDot(facing))
	return (normal * 0.35 + reflected * 0.65):GetNormalized()
end

function META:Explode(position, normal, victim, part)
	local types = self:GetTypeList()
	local direction = self:GetBurstDirection(self.velocity, normal)

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
		effects.Impact(position, normal, type_name, victim and 1.2 or 0.8, false, direction)
	end

	self.Owner:Remove()
end

function META:OnPhysicsUpdate()
	self.step_velocity = self.Owner.rigid_body:GetVelocity():Copy()
end

function META:OnCollisionEnter(other, info)
	if not network.HasAuthority() or other == self.caster and self.time < CASTER_GRACE then
		return
	end

	local victim = damage.GetVictim(other)

	if
		not self.Bounced and
		victim.health and
		victim ~= self.caster and
		not victim.health:IsDead()
	then
		if not self.pending_hit then
			self.pending_hit = {entity = other, normal = info.normal, velocity = self.step_velocity}
		end

		return
	end

	local incoming = self.step_velocity
	local normal = info.normal

	if incoming:GetDot(normal) > 0 then normal = normal * -1 end

	local into = incoming:GetDot(normal)
	local outward = math.max(-into * BOUNCE_RESTITUTION, BOUNCE_MIN_SPEED)
	self.Owner.rigid_body:SetVelocity(incoming - normal * into + normal * outward)

	if not self.Bounced and not self.pending_hit then
		self.pending_hit = {
			entity = other,
			body = info.other_body or other.rigid_body,
			normal = normal,
			velocity = incoming,
		}
	end
end

function META:ResolveHit(hit)
	local body = self.Owner.rigid_body
	local position = body:GetPosition()
	local victim, part = damage.GetVictim(hit.entity)
	self.velocity = hit.velocity

	if victim.health and victim ~= self.caster and not victim.health:IsDead() then
		if hit.entity.ragdoll_part then part = hit.entity.ragdoll_part.Group end

		self:Explode(position, hit.normal, victim, part)
		return
	end

	if hit.body and hit.body:IsDynamic() then
		hit.body:ApplyImpulse(hit.velocity:GetNormalized() * 3, position)
	end

	local direction = self:GetBurstDirection(hit.velocity, hit.normal)
	body:SetGravityScale(BOUNCE_GRAVITY)
	self:SetBounced(true)

	for _, type_name in ipairs(self:GetTypeList()) do
		effects.Impact(position, hit.normal, type_name, 0.8, false, direction)
	end
end

function META:Simulate(dt)
	local body = self.Owner.rigid_body

	if self.pending_hit then
		local hit = self.pending_hit
		self.pending_hit = nil
		self:ResolveHit(hit)
		return
	end

	if self.Bounced then
		if self.fade_time >= FADE_TIME then self.Owner:Remove() end

		return
	end

	local position = body:GetPosition()
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

	body:SetVelocity(self.velocity)

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
	self.clip = clips.Play(
		"jrpg_projectile",
		{
			position = Vec3(),
			color = color,
			size = 0,
			fade = 1,
			flicker = 1,
			lens_scale = LENS_SCALE,
			trail_radius = TRAIL_RADIUS * glow,
		},
		true
	)
	self.emitters = {}
	self.emitters_playing = true
	self.debris_emitters = {}

	for i, type_name in ipairs(types) do
		local properties = effects.GetParticleProperties(
			damage_types.Get(type_name),
			{
				Rate = 90,
				Playing = true,
				MaxParticles = 384,
				Spread = 180,
				SizeStart = PARTICLE_SIZE,
				SizeEnd = 0,
				Sparkle = 1,
				GravityScale = 0,
			}
		)
		self.emitters[i] = effects.vfx.CreateEmitter("magic_projectile_" .. type_name, properties)
	end

	for _, type_name in ipairs(types) do
		local debris = damage_types.Get(type_name).Debris

		if debris and debris.Trail then
			self.debris_emitters[#self.debris_emitters + 1] = effects.CreateDebrisEmitter(type_name, debris.Trail)
		end
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

function META:UpdateVisuals(dt)
	if not self.clip then self:BuildVisuals() end

	local position = self.Owner.transform:GetPosition()
	local flicker = 1

	for _, type_name in ipairs(self:GetTypeList()) do
		if damage_types.Get(type_name).Flicker > 0 then
			flicker = 0.4 + math.random() * 1.2
		end
	end

	local fade = 1 - math.min(self.fade_time / FADE_TIME, 1)
	local appear = math.min(self.time * 6, 1) * fade
	local size = 0.16 * self.glow * appear
	local p = self.clip.params
	p.position:Set(position.x, position.y, position.z)
	p.size = size
	p.fade = fade
	p.flicker = flicker
	self.clip:Update(0, dt)

	if self.Bounced and self.emitters_playing then
		self.emitters_playing = false

		for _, emitter in ipairs(self.emitters) do
			emitter.particle_emitter_gpu:SetPlaying(false)
		end

		for _, emitter in ipairs(self.debris_emitters) do
			emitter.particle_emitter_cpu:SetPlaying(false)
		end
	end

	for _, emitter in ipairs(self.emitters) do
		emitter.transform:SetPosition(position:Copy())
	end

	for _, emitter in ipairs(self.debris_emitters) do
		emitter.transform:SetPosition(position:Copy())
	end

	self.light.transform:SetPosition(position:Copy())
	self.light.light_point:SetLumen(12 * flicker * appear)
end

function META:OnUpdate(dt)
	self.time = self.time + dt

	if self.Bounced then self.fade_time = self.fade_time + dt end

	if effects.Visual then self:UpdateVisuals(dt) end

	if network.HasAuthority() and self.caster then
		self:Simulate(math.min(dt, 0.05))
	end
end

function META:OnRemove()
	if not self.clip then return end

	self.clip:Remove()
	self.light:Remove()

	for _, emitter in ipairs(self.emitters) do
		emitter.particle_emitter_gpu:SetPlaying(false)
		effects.vfx.RemoveDelayed(emitter, 1.5)
	end

	for _, emitter in ipairs(self.debris_emitters) do
		emitter.particle_emitter_cpu:SetPlaying(false)
		effects.vfx.RemoveDelayed(emitter, 4)
	end
end

return META:Register()
