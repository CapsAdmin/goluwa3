local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local model_replacements = import("lua/model_replacements.lua")
local STEEL = {Color = Color(0.78, 0.8, 0.84, 1), Roughness = 0.22, Metallic = 1}
local Quat = import("goluwa/structs/quat.lua")
local STANCE_TILT = math.rad(65)
local pole = nodes.Cylinder("replacement", 0.025, 1.08, FORWARD * 0.43, STEEL, true)
pole.parent = "grip_shift"

local function marker(name, distance)
	return {
		guid = name,
		parent = "grip_shift",
		properties = {Name = name},
		components = {transform = {Position = FORWARD * distance}},
	}
end

model_replacements.Register(
	"sword",
	{
		Game = "gmod",
		Path = "models/weapons/w_crowbar.mdl",
		Position = FORWARD * 0.383,
		Rotation = Quat():SetAngles(Vec3(0, math.pi, 0)),
		Scale = Vec3(1.66, 1.66, 1.66),
	}
)
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
		Replacement = "sword",
		Rollable = true,
	},
	Nodes = {
		{
			guid = "sword",
			parent = "model",
			properties = {Name = "sword"},
			components = {transform = {Rotation = Quat():SetAngles(Vec3(STANCE_TILT, 0, 0))}},
		},
		{
			guid = "grip_shift",
			parent = "sword",
			properties = {Name = "grip_shift"},
			components = {transform = {Position = FORWARD * -0.08}},
		},
		pole,
		marker("blade_base", 0.14),
		marker("blade_tip", 0.97),
	},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local slash = import("lua/jrpg/slash.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local SLASH = {"slash"}
local actors = import("lua/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local sounds = import("lua/sounds.lua")
local flow_ribbons = import("goluwa/render3d/flow_ribbons.lua")
local effect_exposure = import("lua/jrpg/effect_exposure.lua")
local META = objects.CreateTemplate("weapon_sword")
META:StartStorable()
META:GetSet("Damage", 22)
META:GetSet("Range", 1.7)
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
local TRAIL_POINTS = 18
local TRAIL_FADE_RATE = 1
local TRAIL_STRENGTH = 0.1
local TRAIL_OVERLAY_CONFIG = {FadeIn = 0.05, FadeOut = 0.05, Scale = 1.5, UVScale = {0.8, 1}, UVStretch = 40}
local SPARK_LINGER = 0.15
local LINE_STRENGTH = 6
local LINE_RADIUS = 0.03
local LINE_POINTS = 48
local LINE_SUBDIVISIONS = 4
local LINE_END_TAPER = 0.8
local SPARK_DENSITY = 20
local WHITE = Color(1, 1, 1, 1)
local SWING_SOUNDS = {"npc/zombie/claw_miss1.wav", "npc/zombie/claw_miss2.wav"}

function META:Initialize()
	self.combo = 0
	self.idle = 0
	self.fading_trails = {}
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
	local types = self.Owner.weapon:GetDamageTypes(SLASH)
	local holder = self:GetHolder()
	local hit_any, cut, hits, normal = slash.Strike(
		holder,
		self.Owner,
		actors.GetForward(holder),
		attack.cut,
		self.Damage * attack.damage * self.Owner.weapon:GetDamageScale(),
		attack.damage,
		self.Range,
		types
	)

	for _, hit in ipairs(hits) do
		for _, type_name in ipairs(types) do
			effects.HitOverlay(hit.victim, type_name)
		end
	end

	return hit_any, cut, hits, normal
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
	local fading = self.fading_trails

	for i = #fading, 1, -1 do
		local entry = fading[i]
		entry.fade = entry.fade - dt * TRAIL_FADE_RATE

		if entry.fade <= 0 then
			entry.trail:Release()
			table.remove(fading, i)
		else
			entry.trail:SetAlpha(entry.fade)
		end
	end

	local instance = self.Owner.prefab

	if not swinging then
		if self.trail then
			fading[#fading + 1] = {trail = self.trail, fade = 1}
			fading[#fading + 1] = {trail = self.line, fade = 1}
			self.trail = nil
			self.line = nil
			self.linger = SPARK_LINGER
		end

		if self.sparks then
			self.linger = self.linger - dt

			if self.linger > 0 then
				local tip = get_world_position(instance:GetNode("blade_tip"))
				self.sparks:Move(tip.x, tip.y, tip.z)
			else
				self.sparks:Release()
				self.sparks = nil
			end
		end

		return
	end

	local base = get_world_position(instance:GetNode("blade_base"))
	local tip = get_world_position(instance:GetNode("blade_tip"))

	if not self.trail then
		if self.sparks then
			self.sparks:Release()
			self.sparks = nil
		end

		local attributes = self.Owner.weapon.Attributes
		self.color = #attributes > 0 and damage_types.MixColor(attributes) or Color(0.85, 0.92, 1, 1)
		local overlay = damage_types.Get(attributes[1] or "slash")
		local overlay_config = TRAIL_OVERLAY_CONFIG

		if #attributes > 0 then
			overlay_config = table.shallow_copy(TRAIL_OVERLAY_CONFIG)
			overlay_config.ColorA = self.color
		end

		self.trail = effects.vfx.AcquireSlashTrail(self.color, TRAIL_STRENGTH, TRAIL_POINTS, overlay.Overlay, overlay_config)
		self.line = effects.vfx.AcquireTrail(self.color, LINE_STRENGTH, LINE_POINTS, LINE_RADIUS, nil, LINE_SUBDIVISIONS, LINE_END_TAPER)
	end

	if not self.sparks then
		self.sparks = flow_ribbons.AcquireEmitter{
			color = self.color,
			core = WHITE,
			density = SPARK_DENSITY,
			exposure_compensation = effect_exposure.particles,
		}
	end

	self.sparks:Move(tip.x, tip.y, tip.z)

	self.trail:Push(base, tip)
	self.line:Push(tip)
end

function META:OnRemove()
	if self.trail then self.trail:Release() end

	if self.line then self.line:Release() end

	for _, entry in ipairs(self.fading_trails) do
		entry.trail:Release()
	end

	if self.sparks then self.sparks:Release() end
end

return META:Register()
]=====],
}
