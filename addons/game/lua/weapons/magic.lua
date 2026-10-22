local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local magic = {}
magic.Values = {
	WorldSize = Vec3(0.16, 0.16, 0.16),
	WorldCenter = Vec3(),
	Slot = 5,
	Category = "magic",
	FireRate = 0.5,
	Automatic = true,
}

function magic.CreateNodes(color)
	return {
		{
			guid = "orb",
			parent = "model",
			properties = {Name = "orb"},
			components = {transform = {Position = Vec3(0, 0.02, -0.04)}},
		},
		{
			guid = "glow",
			parent = "orb",
			properties = {Name = "glow"},
			components = {
				transform = {},
				light_point = {
					Range = 4,
					OcclusionMap = false,
					Lumen = 2,
					Color = Color(color.r, color.g, color.b, 1),
				},
			},
		},
		{
			guid = "motes",
			parent = "orb",
			properties = {Name = "motes"},
			components = {
				transform = {},
				particle_emitter_gpu = {
					MaxParticles = 96,
					Rate = 24,
					Spread = 180,
					SpeedMin = 0.05,
					SpeedMax = 0.25,
					LifetimeMin = 0.3,
					LifetimeMax = 0.8,
					SizeStart = 0.005,
					SizeEnd = 0,
					Drag = 2,
					GravityScale = -0.15,
					Lit = false,
					Sparkle = 1,
					SaturationJitter = 0.35,
					Emissive = 2e5,
					ColorStart = Color(color.r, color.g, color.b, 1),
					ColorEnd = Color(color.r, color.g, color.b, 0),
				},
			},
		},
	}
end

magic.Source = [=====[
local bit = require("bit")
local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local damage = import("lua/damage.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local effects = import("lua/jrpg/effects.lua")
local sounds = import("lua/sounds.lua")
local META = objects.CreateTemplate("weapon_magic")
META:StartStorable()
META:GetSet("Element", "generic")
META:GetSet("ManaCost", 15)
META:GetSet("Damage", 30)
META:GetSet("CastTime", 0.45)
META:GetSet("Range", 60)
META:EndStorable()
local NO_MANA = Color(0.5, 0.6, 1, 1)
local HAND_OFFSET = 0.3
local HAND_DROP = 0.35
local ORB_SIZE = 0.05
local PROJECTILE_GROUP = 0x4000

function META:Initialize()
	self.left = false
	self.was_active = false
	self.seen_actions = nil
	self:AddGlobalEvent("Update")
end

function META:GetCaster()
	return self.Owner:GetParent()
end

function META:Cast(cmd, self_target)
	local caster = self:GetCaster()
	local rpg = caster.rpg

	if rpg and not rpg:DrainMana(self.ManaCost) then
		effects.Text(caster, "NO MANA", NO_MANA)
		return false
	end

	self.left = not self.left
	caster.character_pose:PlayAction(self.left and "cast_l" or "cast_r", self.CastTime)
	local view = cmd.view
	local forward = view:GetForward()
	local eye = caster.transform:GetPosition() + caster.character_movement:GetViewOffset()
	local origin = eye + forward * 0.4 + view:GetRight() * (self.left and -HAND_OFFSET or HAND_OFFSET) - Vec3(0, HAND_DROP, 0)
	local target, target_point

	if self_target then
		target = caster
	else
		local hit = damage.Sweep(eye, forward * self.Range, caster)

		if hit then
			target_point = hit.point:Copy()

			if hit.entity then
				local victim = damage.GetVictim(hit.entity)

				if victim and victim.health and victim ~= caster then target = victim end
			end
		else
			target_point = eye + forward * self.Range
		end
	end

	local projectile = Entity.New{
		Name = "magic_projectile",
		transform = {Position = origin},
		rigid_body = {
			Shape = SphereShape.New(0.12),
			Mass = 0.05,
			AutomaticMass = false,
			GravityScale = 0,
			Restitution = 1,
			RestitutionCombineMode = "max",
			Friction = 0.6,
			RollingFriction = 0.3,
			AngularDamping = 2,
			LinearDamping = 0.2,
			CCD = true,
			CanSleep = false,
			CollisionGroup = PROJECTILE_GROUP,
			CollisionMask = bit.bnot(PROJECTILE_GROUP),
		},
		magic_projectile = {Types = self.Element, Damage = self.Damage},
		network = SERVER and {} or nil,
	}
	projectile.magic_projectile:Launch(caster, forward, target, target_point)
end

function META:OnWeaponPrimary(cmd)
	return self:Cast(cmd, false)
end

function META:OnWeaponSecondary(cmd)
	return self:Cast(cmd, true)
end

local function get_world_position(node)
	return Vec3(node.transform:GetWorldMatrix():GetTranslation())
end

function META:OnUpdate()
	if not effects.Visual then return end

	local orb = self.Owner.prefab:GetNode("orb")

	if not self.orb then
		self.orb = effects.AcquireOrb(damage_types.Get(self.Element).Color, 1)
	end

	self.orb:Draw(get_world_position(orb), ORB_SIZE, orb.visibility_hidden and 0 or 1, 1)

	local caster = self:GetCaster()

	if not caster:IsValid() or not caster.character_pose then
		self.was_active = false
		return
	end

	local active = self.Owner.weapon:IsActive()
	local definition = damage_types.Get(self.Element)
	local pose = caster.character_pose

	if active and not self.was_active then
		effects.ShowMagicCircle(caster, definition.Color, 0.85, 2, 1.2, true)
		sounds.Play("ambient/water/distant_drip2.wav", caster.transform:GetPosition(), 0.8, 0.75)
	end

	self.was_active = active

	if active and self.seen_actions ~= pose.Actions then
		self.seen_actions = pose.Actions
		local action = pose:GetActiveAction()

		if action == "cast_l" or action == "cast_r" then
			effects.ShowMagicCircle(caster, definition.Color, 0.55, 1, 1, false)
			sounds.Play("ambient/levels/citadel/portal_beam_shoot5.wav", caster.transform:GetPosition(), 0.5, 1.6)
		end
	end
end

function META:OnRemove()
	if self.orb then self.orb:Release() end
end

return META:Register()
]=====]
return magic
