local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local STEEL = {Color = Color(0.78, 0.8, 0.84, 1), Roughness = 0.22, Metallic = 1}
local GOLD = {Color = Color(0.85, 0.62, 0.25, 1), Roughness = 0.3, Metallic = 1}
local LEATHER = {Color = Color(0.22, 0.12, 0.07, 1), Roughness = 0.85, Metallic = 0}
local Quat = import("goluwa/structs/quat.lua")
local STANCE_TILT = math.rad(65)

local function box(name, size, position, material)
	local node = nodes.Box(name, size, position, material)
	node.parent = "sword"
	return node
end

local function marker(name, distance)
	return {
		guid = name,
		parent = "sword",
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
		Stance = "melee",
		HoldOffset = Vec3(0.1, -0.05, 0),
		FireRate = 0.05,
	},
	Nodes = {
		{
			guid = "sword",
			parent = "model",
			properties = {Name = "sword"},
			components = {transform = {Rotation = Quat():SetAngles(Vec3(STANCE_TILT, 0, 0))}},
		},
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
local slash = import("lua/jrpg/slash.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local actors = import("lua/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local sounds = import("lua/sounds.lua")
local META = objects.CreateTemplate("weapon_sword")
META:StartStorable()
META:GetSet("Damage", 22)
META:GetSet("Range", 1.7)
META:GetSet("Element", "")
META:EndStorable()
local ATTACKS = {
	light_1 = {
		cut = Vec3(-0.94, -0.33, 0),
		action = "sword_light_1",
		duration = 0.5,
		hit = 0.5,
		swing = {0.36, 0.56},
		cancel = 0.8,
		damage = 1,
		stamina = 10,
		lunge = {0.45, 0.25, 0.5},
	},
	light_2 = {
		cut = Vec3(0.93, 0.37, 0),
		action = "sword_light_2",
		duration = 0.5,
		hit = 0.5,
		swing = {0.36, 0.56},
		cancel = 0.8,
		damage = 1,
		stamina = 10,
		lunge = {0.45, 0.25, 0.5},
	},
	light_3 = {
		cut = Vec3(0, 0, 1),
		action = "sword_light_3",
		duration = 0.65,
		hit = 0.57,
		swing = {0.46, 0.62},
		cancel = 0.85,
		damage = 1.6,
		stamina = 14,
		lunge = {1, 0.35, 0.57},
	},
	jump = {
		cut = Vec3(0, -0.95, 0.3),
		action = "sword_jump",
		duration = 0.6,
		hit = 0.45,
		swing = {0.3, 0.5},
		cancel = 0.85,
		damage = 2,
		stamina = 18,
		lunge = {0.4, 0.2, 0.45},
	},
	heavy = {
		cut = Vec3(0, -0.97, 0.25),
		action = "sword_heavy",
		duration = 1,
		hit = 0.66,
		swing = {0.56, 0.72},
		cancel = 0.9,
		damage = 2.6,
		stamina = 28,
		lunge = {0.9, 0.5, 0.66},
	},
}
local BY_ACTION = {}

for _, attack in pairs(ATTACKS) do
	BY_ACTION[attack.action] = attack
end

local LUNGE_STOP_GAP = 1
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
	local forward = actors.GetForward(holder)
	local lunge = attack.lunge
	local distance = self:GetLungeDistance(holder, forward, lunge[1])

	if distance > 0 then
		holder.character_movement:Lunge(
			forward,
			distance,
			attack.duration * lunge[2],
			attack.duration * (lunge[3] - lunge[2])
		)
	end

	return true
end

function META:GetLungeDistance(holder, forward, distance)
	local center = actors.GetCenter(holder)

	for _, victim in ipairs(actors.Find(center, distance + LUNGE_STOP_GAP + 1, holder)) do
		local to_victim = actors.GetCenter(victim) - center
		to_victim.y = 0
		local gap = to_victim:GetLength()

		if gap > 0.01 and to_victim:GetNormalized():Dot(forward) > 0.5 then
			distance = math.min(distance, math.max(gap - LUNGE_STOP_GAP, 0))
		end
	end

	return distance
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
	return slash.Strike(
		self:GetHolder(),
		self.Owner,
		attack.cut,
		self.Damage * attack.damage,
		attack.damage,
		self.Range,
		self.Element
	)
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

	if f >= (self.queued and attack.cancel or 1) then
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
	local name, phase

	if pose and self.Owner.weapon:IsEquipped() then name, phase = pose:GetActiveAction() end

	local attack = BY_ACTION[name]
	local swinging = attack and phase >= attack.swing[1] and phase <= attack.swing[2]

	if swinging and not self.swinging then
		sounds.PlayRandom(SWING_SOUNDS, holder.transform:GetPosition(), 0.7, math.randomf(1, 1.3))
	end

	self.swinging = swinging

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
