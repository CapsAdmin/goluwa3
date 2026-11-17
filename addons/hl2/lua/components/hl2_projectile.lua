local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local physics = import("goluwa/physics.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local hl2 = import("lua/hl2.lua")
local META = objects.CreateTemplate("hl2_projectile")
META.Network = {
	Kind = {"string", 0.5, "reliable"},
	Stuck = {"boolean", 0.1, "reliable"},
}
META:GetSet("Kind", "bolt")
META:GetSet("Damage", 100)
META:GetSet("Radius", 4)
META:GetSet("Speed", 60)
META:GetSet("Life", 10)
META:IsSet("Stuck", false)
local SWEEP_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}
local KINDS = {}
local sprites, vfx, sounds

local function init_visuals()
	if sprites then return end

	sprites = import("goluwa/render3d/sprites.lua")
	vfx = import("goluwa/render3d/vfx.lua")
	sounds = import("lua/sounds.lua")
end

local function visual_enabled()
	return RENDER_3D and import("goluwa/render/render.lua").IsInitialized()
end

function META:Initialize()
	self.time = 0
	self.hit_victims = {}
	self:AddGlobalEvent("PhysicsUpdate")
	self:AddGlobalEvent("Update")
end

function META:OnEntityConstructed()
	local kind = KINDS[self.Kind]

	if network.HasAuthority() and kind.Body and not self.Stuck then
		self.Owner:AddComponent("rigid_body", kind.Body(self))
	end

	self.model = hl2.AttachModel(self.Owner, kind.Model, kind.Fallback)
end

function META:Launch(caster, weapon, velocity)
	self.caster = caster
	self.weapon = weapon
	self.velocity = velocity:Copy()
	self.filter = function(entity)
		if entity == caster then return false end

		local part = entity.ragdoll_part

		if part then return part.Character ~= caster end

		return not entity.ragdoll
	end

	if self.Owner.rigid_body then self.Owner.rigid_body:SetVelocity(velocity) end
end

function META:GetVelocity()
	local body = self.Owner.rigid_body
	return body and body:GetVelocity() or self.velocity
end

function META:GetPosition()
	local body = self.Owner.rigid_body
	return body and body:GetPosition() or self.Owner.transform:GetPosition()
end

function META:Stick(hit, direction, depth)
	self.Owner:RemoveComponent("rigid_body")
	self.Stuck = true
	self.Owner.transform:SetPosition(hit.point + direction * depth)
	self.Owner.transform:SetRotation(Quat():SetLookDirection(direction))
	self.time = 0
	self.Life = 20
end

function META:DealDamage(hit, amount, kind, force)
	if self.hit_victims[hit.entity] then return end

	local victim = hl2.DealHit(
		hit,
		{
			Attacker = self.caster,
			Inflictor = self.Owner,
			Damage = amount,
			Type = kind or "generic",
			Force = force,
		}
	)

	if victim then
		self.hit_victims[hit.entity] = true
		self.hit_victims[victim] = true
	end

	return victim
end

function META:Explode(position, normal)
	if self.exploded then return end

	self.exploded = true
	hl2.Explode{
		Position = position,
		Normal = normal,
		Attacker = self.caster,
		Inflictor = self.Owner,
		Damage = self.Damage,
		Radius = self.Radius,
	}
	self.Owner:Remove()
end

function META:OnPhysicsUpdate(dt)
	if not network.HasAuthority() or self.Stuck or not self.velocity then return end

	self.time = self.time + dt
	local kind = KINDS[self.Kind]

	if self.time >= self.Life then
		if kind.Expire then kind.Expire(self) else self.Owner:Remove() end

		return
	end

	if kind.Think then kind.Think(self, dt) end

	if not self.Owner:IsValid() or self.spent then return end

	local velocity = self:GetVelocity()
	local position = self:GetPosition()
	local hit = physics.Sweep(
		position,
		velocity * dt,
		kind.SweepRadius or 0,
		self.Owner,
		self.filter,
		SWEEP_OPTIONS
	)

	if hit and not self.hit_victims[hit.entity] then
		kind.Hit(self, hit, velocity)
	end

	if self.Owner:IsValid() and not self.Owner.rigid_body and not self.Stuck then
		self.Owner.transform:SetPosition(position + self.velocity * dt)
	end
end

function META:OnUpdate(dt)
	if not visual_enabled() then return end

	local kind = KINDS[self.Kind]

	if kind.Draw then
		init_visuals()
		kind.Draw(self, dt)
	end
end

function META:OnRemove()
	if self.loop then self.loop:Stop() end

	if self.trail then self.trail:Release() end
end

KINDS.bolt = {
	Model = "hl2_crossbow_bolt",
	Fallback = {
		ModelPath = "models/cylinder.lua",
		ModelOptions = {radius = 0.006, height = 0.4},
		MaterialConfig = {Color = Color(0.5, 0.45, 0.4, 1), Roughness = 0.4, Metallic = 0.9},
	},
	Body = function(self)
		return {
			Shape = BoxShape.New(Vec3(0.02, 0.02, 0.4)),
			Mass = 0.3,
			AutomaticMass = false,
			GravityScale = 0.08,
			CCD = true,
			CanSleep = false,
			Friction = 0.4,
			Restitution = 0.2,
			CollisionGroup = usercmd.HELD_COLLISION_GROUP,
		}
	end,
	Think = function(self)
		local velocity = self:GetVelocity()

		if not self.loose and velocity:GetLength() > 1 then
			self.Owner.rigid_body:SetRotation(Quat():SetLookDirection(velocity:GetNormalized()))
			self.Owner.rigid_body:SetAngularVelocity(Vec3())
		end
	end,
	Hit = function(self, hit, velocity)
		if self.loose then return end

		local direction = velocity:GetNormalized()
		local force = direction * 12
		local victim = self:DealDamage(hit, self.Damage, "generic", force)

		if victim then
			hl2.RandomSound(self.Owner, {"weapons/crossbow/hitbod1.wav", "weapons/crossbow/hitbod2.wav"}, 85)
			self.Owner:Remove()
			return
		end

		hl2.SoundAt(hit.point, "weapons/crossbow/hit1.wav", 90, math.randomf(0.95, 1.05), nil)
		weapon_effects.Hit(self.weapon, hit.point, hit.normal, force)
		local body = hl2.GetDynamicBody(hit)

		if body then
			body:ApplyImpulse(force, hit.point)
			self.loose = true
			self.Owner.rigid_body:SetGravityScale(1)
			self.Owner.rigid_body:SetVelocity(velocity * 0.2)
			self.Life = self.time + 8
			return
		end

		if direction:Dot(hit.normal) > -0.25 then
			self.loose = true
			self.Owner.rigid_body:SetGravityScale(1)
			self.Life = self.time + 8
			return
		end

		self:Stick(hit, direction, 0.12)
	end,
}
KINDS.grenade = {
	Model = "hl2_smg_grenade",
	Fallback = {
		ModelPath = "models/sphere.lua",
		ModelOptions = {radius = 0.03, segments = 12, rings = 8},
		MaterialConfig = {Color = Color(0.25, 0.3, 0.2, 1), Roughness = 0.5, Metallic = 0.5},
	},
	SweepRadius = 0.03,
	Body = function(self)
		return {
			Shape = SphereShape.New(0.03),
			Mass = 0.3,
			AutomaticMass = false,
			CCD = true,
			CanSleep = false,
			CollisionGroup = usercmd.HELD_COLLISION_GROUP,
		}
	end,
	Think = function(self)
		local velocity = self:GetVelocity()

		if velocity:GetLength() > 1 then
			self.Owner.rigid_body:SetRotation(Quat():SetLookDirection(velocity:GetNormalized()))
		end
	end,
	Hit = function(self, hit)
		self:Explode(hit.point + hit.normal * 0.05, hit.normal)
	end,
	Expire = function(self)
		self:Explode(self:GetPosition():Copy())
	end,
}
KINDS.bugbait = {
	Model = "hl2_bugbait",
	Fallback = {
		ModelPath = "models/sphere.lua",
		ModelOptions = {radius = 0.06, segments = 12, rings = 8},
		MaterialConfig = {Color = Color(0.6, 0.35, 0.3, 1), Roughness = 0.6, Metallic = 0},
	},
	SweepRadius = 0.06,
	Body = function(self)
		return {
			Shape = SphereShape.New(0.06),
			Mass = 0.3,
			AutomaticMass = false,
			CCD = true,
			CanSleep = false,
			CollisionGroup = usercmd.HELD_COLLISION_GROUP,
		}
	end,
	Hit = function(self, hit, velocity)
		hl2.RandomSound(
			self.Owner,
			{"weapons/bugbait/bugbait_impact1.wav", "weapons/bugbait/bugbait_impact3.wav"},
			80
		)
		weapon_effects.Hit(self.weapon, hit.point, hit.normal, velocity * 0.1)
		self.Owner:Remove()
	end,
}
KINDS.rocket = {
	Model = "hl2_rocket",
	Fallback = {
		ModelPath = "models/cylinder.lua",
		ModelOptions = {radius = 0.04, height = 0.35},
		MaterialConfig = {Color = Color(0.3, 0.3, 0.32, 1), Roughness = 0.5, Metallic = 0.8},
	},
	SweepRadius = 0.05,
	Think = function(self, dt)
		local target = self.target

		if target and self.time > 0.25 then
			local wanted = (target - self:GetPosition()):GetNormalized()
			local current = self.velocity:GetNormalized()
			local blend = math.min(dt * 6, 1)
			self.velocity = (current + (wanted - current) * blend):GetNormalized() * self.Speed
		end

		self.Owner.transform:SetRotation(Quat():SetLookDirection(self.velocity:GetNormalized()))
	end,
	Hit = function(self, hit)
		self:Explode(hit.point + hit.normal * 0.1, hit.normal)
	end,
	Expire = function(self)
		self:Explode(self:GetPosition():Copy())
	end,
	Draw = function(self, dt)
		local position = self.Owner.transform:GetWorldPosition()
		local back = self.Owner.transform:GetWorldRotation():GetForward() * -0.25
		local x, y, z = position.x + back.x, position.y + back.y, position.z + back.z
		local flicker = math.randomf(0.8, 1.2)
		sprites.GetBatch(vfx.GetTexture("flare")):Add(x, y, z, 0.35 * flicker, 40, 22, 8, 1)
		sprites.GetBatch():Add(x, y, z, 0.12, 60, 40, 20, 1)

		if not self.trail then
			self.trail = vfx.AcquireGpuTrail{
				Color = Color(0.55, 0.53, 0.5, 1),
				Strength = 1,
				Points = 64,
				Radius = 0.09,
				Texture = vfx.GetTexture("trail"),
				Drift = 0.6,
			}
			self.loop = sounds.CreateSource("weapons/rpg/rocket1.wav")

			if self.loop then
				self.loop:SetLooping(true)
				self.loop:SetGain(sounds.SPLToVolume(95))
				self.loop:Play()
			end
		end

		self.trail:ShiftXYZ(x, y, z)

		if self.loop then self.loop:SetPosition(position:Copy()) end
	end,
}
KINDS.ball = {
	Model = "hl2_combine_ball",
	Fallback = {
		ModelPath = "models/sphere.lua",
		ModelOptions = {radius = 0.15, segments = 16, rings = 10},
		MaterialConfig = {Color = Color(1, 1, 1, 1), Roughness = 0.1, Metallic = 0},
	},
	SweepRadius = 0.15,
	Body = function(self)
		return {
			Shape = SphereShape.New(0.15),
			Mass = 2,
			AutomaticMass = false,
			GravityScale = 0,
			Restitution = 1,
			Friction = 0,
			LinearDamping = 0,
			AngularDamping = 0,
			CCD = true,
			CanSleep = false,
			CollisionGroup = usercmd.HELD_COLLISION_GROUP,
		}
	end,
	Think = function(self)
		local body = self.Owner.rigid_body
		local velocity = body:GetVelocity()
		local speed = velocity:GetLength()

		if speed > 0.1 then body:SetVelocity(velocity * (self.Speed / speed)) end

		if
			self.bounce_check and
			(
				velocity:GetNormalized() - self.bounce_check
			):GetLength() > 0.3
		then
			hl2.RandomSound(
				self.Owner,
				{
					"weapons/physcannon/energy_bounce1.wav",
					"weapons/physcannon/energy_bounce2.wav",
				},
				85
			)
		end

		self.bounce_check = speed > 0.1 and velocity:GetNormalized() or nil
	end,
	Hit = function(self, hit, velocity)
		local victim = self:DealDamage(hit, self.Damage, "magic", velocity:GetNormalized() * 30)

		if victim then
			hl2.RandomSound(
				self.Owner,
				{
					"weapons/physcannon/energy_disintegrate4.wav",
					"weapons/physcannon/energy_disintegrate5.wav",
				},
				95
			)
			return
		end

		local body = hl2.GetDynamicBody(hit)

		if body then body:ApplyImpulse(velocity:GetNormalized() * 40, hit.point) end
	end,
	Expire = function(self)
		local position = self:GetPosition():Copy()
		hl2.SoundAt(position, "weapons/physcannon/energy_sing_explosion2.wav", 110, 1, nil)
		hl2.BallExplode(position)
		self.Owner:Remove()
	end,
	Draw = function(self, dt)
		local position = self.Owner.transform:GetWorldPosition()
		local pulse = math.randomf(0.8, 1.1)
		sprites.GetBatch(vfx.GetTexture("glow")):Add(position.x, position.y, position.z, 0.5 * pulse, 8, 14, 30, 1)
		sprites.GetBatch(vfx.GetTexture("flare")):Add(position.x, position.y, position.z, 0.3, 20, 30, 50, pulse)
		sprites.GetBatch():Add(position.x, position.y, position.z, 0.12, 80, 90, 100, 1)

		if not self.loop then
			self.loop = sounds.CreateSource("weapons/physcannon/energy_sing_loop4.wav")

			if self.loop then
				self.loop:SetLooping(true)
				self.loop:SetGain(sounds.SPLToVolume(85))
				self.loop:Play()
			end
		end

		if self.loop then self.loop:SetPosition(position:Copy()) end
	end,
}
META.Kinds = KINDS
return META:Register()
