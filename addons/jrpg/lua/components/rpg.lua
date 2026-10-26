local objects = import("goluwa/objects/objects.lua")
local network = import("goluwa/network/network.lua")
local event = import("goluwa/event.lua")
local codec = import("goluwa/codec.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local attributes = import("lua/jrpg/attributes.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local META = objects.CreateTemplate("rpg")
META.Network = {
	Mana = {"number", 0.1, "reliable", to_owner = true},
	MaxMana = {"number", 0.5, "reliable", to_owner = true},
	Stamina = {"number", 0.1, "reliable", to_owner = true},
	MaxStamina = {"number", 0.5, "reliable", to_owner = true},
	XP = {"number", 0.25, "reliable", to_owner = true},
	Level = {"number", 0.25, "reliable", to_owner = true},
	AttributePoints = {"number", 0.25, "reliable", to_owner = true},
	Cheat = {"boolean", 0.5, "reliable", to_owner = true},
	Stunned = {"boolean", 0.1, "reliable", to_owner = true},
}
META:GetSet("Mana", 125)
META:GetSet("MaxMana", 125)
META:GetSet("Stamina", 100)
META:GetSet("MaxStamina", 100)
META:GetSet("XP", 0)
META:GetSet("Level", 0)
META:GetSet("AttributePoints", 0)
META:IsSet("Cheat", false)
META:IsSet("Stunned", false)
local GROUND_SPEED = 110 * UNIT
local JUMP_MULTIPLIER = 1.4
local CHEAT_AMOUNT = 9999
local STAMINA_IDLE_REGEN = 60
local STAMINA_WALK_REGEN = 20
local STAMINA_BLOCK_REGEN = 10
local STAMINA_SPRINT_DRAIN = 20
local STAMINA_REGEN_DELAY = 1
local MANA_REGEN = 3
local MANA_IDLE_REGEN = 8
local SAVE_PATH = "data/jrpg/%s.txt"

function META.IsLocal()
	local rig = _G.PLAYER_RIG
	return rig ~= nil and rig:IsValid() and rig.rpg ~= nil
end

function META:Initialize()
	self.stats = attributes.GetDefaults()
	self.regen_delay = 0
	self:AddGlobalEvent("Update")
end

function META:OnAdd()
	local owner = self.Owner

	if network.HasAuthority() then
		local movement = owner.character_movement
		self.restore = {
			max_health = owner.health:GetMaxHealth(),
			jump_speed = movement:GetJumpSpeed(),
			ground_speed = movement:GetGroundSpeed(),
		}
		self:Load()
		self:ApplyStats()
		owner.health:SetHealth(owner.health:GetMaxHealth())
		self:SetMana(self.MaxMana)
		self:SetStamina(self.MaxStamina)
	end

	event.Call("RPGEnabled", owner, self)
end

function META:OnRemove()
	local owner = self.Owner

	if network.HasAuthority() and self.restore and owner:IsValid() then
		local health = owner.health
		local movement = owner.character_movement
		health:SetMaxHealth(self.restore.max_health)
		health:SetHealth(math.min(health:GetHealth(), health:GetMaxHealth()))
		movement:SetJumpSpeed(self.restore.jump_speed)
		movement:SetGroundSpeed(self.restore.ground_speed)
		self:Save()
	end

	event.Call("RPGDisabled", owner, self)
end

function META:GetStat(name)
	return self.stats[name]
end

function META:GetStats()
	return self.stats
end

function META:ApplyStats()
	local owner = self.Owner
	local stats = self.stats
	local movement = owner.character_movement
	owner.health:SetMaxHealth(attributes.ByName.health.Base + stats.health)
	self:SetMaxMana(attributes.ByName.mana.Base + stats.mana)
	self:SetMaxStamina(attributes.ByName.stamina.Base + stats.stamina)
	self:SetMana(math.min(self.Mana, self.MaxMana))
	self:SetStamina(math.min(self.Stamina, self.MaxStamina))
	movement:SetJumpSpeed(self.restore.jump_speed * (stats.jump * JUMP_MULTIPLIER) ^ 0.5)
	movement:SetGroundSpeed(GROUND_SPEED + stats.speed)
end

function META:GetSavePath()
	if not self.Owner.player_controller then return end

	local network_component = self.Owner.network
	local key = network_component and
		not network_component.linked and
		network_component:GetNetworkOwner() or
		""
	return SAVE_PATH:format(key == "" and "local" or key)
end

function META:Load()
	local path = self:GetSavePath()

	if not path then return end

	local data = codec.ReadFile("luadata", path)

	if not data then return end

	self:SetXP(data.xp or 0)
	self:SetLevel(data.level or 0)
	self:SetAttributePoints(data.attribute_points or 0)

	for _, attribute in ipairs(attributes.List) do
		self.stats[attribute.Name] = math.max(data.stats and data.stats[attribute.Name] or attribute.Init, attribute.Init)
	end
end

function META:Save()
	local path = self:GetSavePath()

	if not path then return end

	codec.WriteFile(
		"luadata",
		path,
		{
			xp = self.XP,
			level = self.Level,
			attribute_points = self.AttributePoints,
			stats = self.stats,
		}
	)
end

function META:GetNextLevelXP()
	return attributes.GetNextLevelXP(self.Level)
end

function META:GiveXP(xp)
	local next_level = self:GetNextLevelXP()

	while self.XP + xp >= next_level do
		xp = xp - (next_level - self.XP)
		self:SetXP(0)
		self:SetLevel(self.Level + 1)
		self:SetAttributePoints(self.AttributePoints + 1)
		event.Call("RPGLevelUp", self.Owner, self.Level)
		next_level = self:GetNextLevelXP()
	end

	self:SetXP(self.XP + xp)
	self:Save()
end

function META:LevelAttribute(name)
	local attribute = attributes.ByName[name]

	if not attribute then return false, "no such attribute" end

	if self.AttributePoints < 1 then return false, "not enough attribute points" end

	self.stats[name] = self.stats[name] + attribute.Step
	self:SetAttributePoints(self.AttributePoints - 1)
	self:ApplyStats()
	self:Save()
	return true
end

function META:DrainStamina(amount)
	if self.Cheat then return true end

	if self.Stamina <= 0 then return false end

	self:SetStamina(math.max(self.Stamina - amount, 0))

	if self.Stamina <= 0 then self.regen_delay = STAMINA_REGEN_DELAY end

	return true
end

function META:DrainMana(amount)
	if self.Cheat then return true end

	if self.Mana < amount then return false end

	self:SetMana(self.Mana - amount)
	return true
end

function META:Stun(duration)
	self.stun_time = duration
	self:SetStunned(true)
end

function META:OnCanAttack()
	if self.Stunned or self.Owner.character_movement:IsRolling() then
		return false
	end

	local pose = self.Owner.character_pose

	if pose and pose:IsBlocking() then return false end
end

function META:OnUpdate(dt)
	if not network.HasAuthority() then return end

	local owner = self.Owner

	if owner.health:IsDead() then return end

	if self.Cheat then
		self:SetMana(CHEAT_AMOUNT)
		self:SetMaxMana(CHEAT_AMOUNT)
		self:SetStamina(CHEAT_AMOUNT)
		self:SetMaxStamina(CHEAT_AMOUNT)
		return
	end

	local body = owner.rigid_body
	local velocity = body:GetVelocity()
	local speed = math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
	local movement = owner.character_movement
	local blocking = owner.character_pose:IsBlocking()
	local idle = speed < 0.2
	self.regen_delay = math.max(self.regen_delay - dt, 0)

	if self.stun_time then
		self.stun_time = self.stun_time - dt

		if self.stun_time <= 0 then
			self.stun_time = nil
			self:SetStunned(false)
		end
	end

	local stamina = self.Stamina

	if not self.Stunned and body:GetGrounded() then
		if idle then
			if self.regen_delay <= 0 then
				stamina = stamina + (blocking and STAMINA_BLOCK_REGEN or STAMINA_IDLE_REGEN) * dt
			end
		elseif speed > movement:GetGroundSpeed() * 1.15 then
			stamina = stamina - STAMINA_SPRINT_DRAIN * dt

			if stamina <= 0 then self.regen_delay = STAMINA_REGEN_DELAY end
		elseif self.regen_delay <= 0 and not blocking then
			stamina = stamina + STAMINA_WALK_REGEN * dt
		end
	end

	self:SetStamina(math.clamp(stamina, 0, self.MaxStamina))
	self:SetMana(math.min(self.Mana + (idle and MANA_IDLE_REGEN or MANA_REGEN) * dt, self.MaxMana))
end

function META:IsSprintAllowed(cmd)
	return self.Stamina > 0 or
		self.Cheat or
		not usercmd.HasButton(cmd, usercmd.BUTTON.SPRINT)
end

return META:Register()
