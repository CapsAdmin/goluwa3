local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local STEEL = {Color = Color(0.78, 0.8, 0.84, 1), Roughness = 0.22, Metallic = 1}
local GOLD = {Color = Color(0.85, 0.62, 0.25, 1), Roughness = 0.3, Metallic = 1}
local LEATHER = {Color = Color(0.22, 0.12, 0.07, 1), Roughness = 0.85, Metallic = 0}
local box = nodes.Box

local function marker(name, distance)
	return {
		guid = name,
		parent = "model",
		properties = {Name = name},
		components = {transform = {Position = FORWARD * distance}},
	}
end

return {
	Values = {
		WorldSize = Vec3(0.2, 0.05, 1.1),
		WorldCenter = FORWARD * 0.4,
		Slot = 4.5,
		DisplayName = "Sword",
		Category = "melee",
		FireRate = 0.05,
	},
	Nodes = {
		box("pommel", Vec3(0.045, 0.045, 0.045), FORWARD * -0.11, GOLD),
		box("handle", Vec3(0.032, 0.032, 0.18), FORWARD * -0.01, LEATHER),
		box("guard", Vec3(0.22, 0.035, 0.04), FORWARD * 0.09, GOLD),
		box("blade", Vec3(0.055, 0.012, 0.82), FORWARD * 0.52, STEEL),
		box("tip", Vec3(0.035, 0.01, 0.06), FORWARD * 0.95, STEEL),
		marker("blade_base", 0.14),
		marker("blade_tip", 0.97),
	},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local damage = import("lua/damage.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local actors = import("lua/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local jrpg = import("lua/jrpg/jrpg.lua")
local sounds = import("lua/sounds.lua")
local META = objects.CreateTemplate("weapon_sword")
META:StartStorable()
META:GetSet("Damage", 22)
META:GetSet("Range", 1.7)
META:GetSet("Element", "")
META:EndStorable()
local ATTACKS = {
	light_1 = {action = "slash_r", duration = 0.42, hit = 0.47, damage = 1, stamina = 10, lunge = 2},
	light_2 = {action = "slash_l", duration = 0.42, hit = 0.47, damage = 1, stamina = 10, lunge = 2},
	light_3 = {action = "thrust", duration = 0.5, hit = 0.52, damage = 1.6, stamina = 14, lunge = 5},
	jump = {action = "slash_down", duration = 0.55, hit = 0.55, damage = 2, stamina = 18, lunge = 1},
	heavy = {action = "heavy", duration = 0.85, hit = 0.6, damage = 2.6, stamina = 28, lunge = 3},
}
local COMBO_WINDOW = 0.5
local NO_STAMINA = Color(1, 0.8, 0.3, 1)
local TRAIL_POINTS = 12
local SWING_SOUNDS = {"npc/zombie/claw_miss1.wav", "npc/zombie/claw_miss2.wav"}

function META:Initialize()
	self.combo = 0
	self.idle = 0
	self:AddGlobalEvent("Update")
end

function META:GetHolder()
	return self.Owner:GetParent()
end

function META:StartAttack(name)
	local holder = self:GetHolder()
	local attack = ATTACKS[name]
	local rpg = holder.rpg

	if rpg and not rpg:DrainStamina(attack.stamina) then
		effects.Text(holder, "NO STAMINA", NO_STAMINA)
		return false
	end

	self.attack = attack
	self.attack_time = 0
	self.attack_hit = false
	self.queued = false
	holder.character_pose:PlayAction(attack.action, attack.duration)
	jrpg.Lunge(holder, actors.GetForward(holder), attack.lunge, attack.duration * attack.hit)
	return true
end

function META:OnWeaponPrimary(cmd)
	if self.attack then
		self.queued = true
		return false
	end

	local holder = self:GetHolder()

	if not holder.rigid_body:GetGrounded() then
		self:StartAttack("jump")
		return false
	end

	self.combo = self.idle < COMBO_WINDOW and self.combo % 3 + 1 or 1
	self:StartAttack("light_" .. self.combo)
	return false
end

function META:OnWeaponSecondary(cmd)
	if self.attack then return false end

	self.combo = 0
	self:StartAttack("heavy")
	return false
end

function META:Hit(attack)
	local holder = self:GetHolder()
	local center = actors.GetCenter(holder)
	local forward = actors.GetForward(holder)
	local strike = center + forward * (self.Range * 0.55)
	local amount = self.Damage * attack.damage
	local element = self.Element
	local hit_any = false

	for _, victim in ipairs(actors.Find(strike, self.Range, holder)) do
		local victim_center = actors.GetCenter(victim)
		local to_victim = victim_center - center
		to_victim.y = 0

		if to_victim:GetLength() < 0.7 or to_victim:GetNormalized():Dot(forward) > 0.15 then
			local point, normal, part = victim_center, forward * -1, nil
			local trace = damage.Sweep(center, victim_center - center, holder)

			if trace and trace.entity and damage.GetVictim(trace.entity) == victim then
				point, normal = trace.point, trace.normal
				part = trace.entity.ragdoll_part and trace.entity.ragdoll_part.Group
			end

			damage.Deal(
				victim,
				{
					Attacker = holder,
					Inflictor = self.Owner,
					Damage = amount,
					Type = "generic",
					Position = point,
					Normal = normal,
					Force = forward * 5 * attack.damage,
					Part = part,
				}
			)

			if element ~= "" and victim.health and not victim.health:IsDead() then
				damage.Deal(
					victim,
					{
						Attacker = holder,
						Inflictor = self.Owner,
						Damage = amount * 0.5,
						Type = element,
						Position = point,
						Normal = normal,
					}
				)
			end

			effects.Impact(point, normal, element ~= "" and element or "generic", attack.damage, true)
			hit_any = true
		end
	end

	for _, body in ipairs(RigidBody.Instances) do
		local owner = body.Owner

		if
			body:IsDynamic() and
			not owner.health and
			not owner.ragdoll_part and
			(
				body:GetPosition() - strike
			):GetLength() < self.Range
		then
			body:ApplyImpulse(forward * 4 * attack.damage / body.InverseMass ^ 0.5, body:GetPosition())
			hit_any = true
		end
	end

	return hit_any
end

function META:OnWeaponThink(dt)
	local attack = self.attack

	if not attack then
		self.idle = self.idle + dt
		return
	end

	self.attack_time = self.attack_time + dt
	local f = self.attack_time / attack.duration

	if not self.attack_hit and f >= attack.hit then
		self.attack_hit = true
		self:Hit(attack)
	end

	if f >= 1 then
		self.attack = nil
		self.idle = 0

		if self.queued then
			self.combo = self.combo % 3 + 1
			self:StartAttack("light_" .. self.combo)
		end
	end
end

function META:OnWeaponHolster()
	self.attack = nil
	self.queued = false
end

local function get_world_position(node)
	return Vec3(node.transform:GetWorldMatrix():GetTranslation())
end

function META:OnUpdate(dt)
	if not effects.Visual then return end

	local holder = self:GetHolder()
	local pose = holder:IsValid() and holder.character_pose
	local action = pose and self.Owner.weapon:IsActive() and pose:GetActiveAction()
	local swinging = action and action ~= "cast_l" and action ~= "cast_r" and not action:starts_with("roll")

	if pose and self.seen_actions ~= pose.Actions then
		self.seen_actions = pose.Actions

		if swinging then
			sounds.PlayRandom(SWING_SOUNDS, holder.transform:GetPosition(), 0.7, math.randomf(1, 1.3))
		end
	end

	if not swinging then
		if self.trail then
			self.trail_fade = (self.trail_fade or 1) - dt * 8

			if self.trail_fade <= 0 then
				self.trail:Release()
				self.trail = nil
			else
				self.trail:SetAlpha(self.trail_fade)
			end
		end

		return
	end

	local instance = self.Owner.prefab
	local base = get_world_position(instance:GetNode("blade_base"))
	local tip = get_world_position(instance:GetNode("blade_tip"))

	if not self.trail then
		local color = self.Element ~= "" and damage_types.Get(self.Element).Color or Color(0.85, 0.92, 1, 1)
		self.trail = effects.vfx.AcquireSlashTrail(color, 3, TRAIL_POINTS)
	end

	self.trail_fade = 1
	self.trail:SetAlpha(1)
	self.trail:Push(base, tip)
end

function META:OnRemove()
	if self.trail then self.trail:Release() end
end

return META:Register()
]=====],
}
