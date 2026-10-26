local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local UNIT = import("goluwa/source_engine/units.lua").meters
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local attributes = import("lua/jrpg/attributes.lua")
local actors = import("lua/actors.lua")
local effects = import("lua/jrpg/effects.lua")
local battlecam = import("lua/battlecam.lua")
local Rpg = import("lua/components/rpg.lua")
local jrpg = {}
jrpg.Colors = {
	health = Color.FromHex("#3fd68f"),
	mana = Color.FromHex("#3f8cff"),
	stamina = Color.FromHex("#e8c15a"),
	xp = Color.FromHex("#9b5de5"),
	gold = Color.FromHex("#e8b64c"),
	neon = Color.FromHex("#3fd3e6"),
	danger = Color.FromHex("#e04a33"),
}
jrpg.Loadout = {"weapon_sword", "weapon_shield", "weapon_slash_debug"}

for _, name in ipairs(damage_types.Names) do
	jrpg.Loadout[#jrpg.Loadout + 1] = "weapon_magic_" .. name
end

for _, name in ipairs{"health", "mana", "stamina"} do
	jrpg.Loadout[#jrpg.Loadout + 1] = "weapon_potion_" .. name
end

local ROLL_COST = 30
local BLOCK_SPEED = 0.45
local BLOCK_ANGLE = 0.2
local SHIELD_PHYSICAL = 1
local SHIELD_MAGIC = 0.5
local STUN_TIME = 2
local STUNNED_DAMAGE = 3

function jrpg.IsEnabled(entity)
	return entity.rpg ~= nil
end

function jrpg.IsLocalEnabled()
	return Rpg.IsLocal()
end

function jrpg.GiveLoadout(entity)
	local holder = entity.weapon_holder

	for _, name in ipairs(jrpg.Loadout) do
		if not holder:FindWeapon(name) then holder:Give(name) end
	end

	holder:Equip(holder:FindWeapon("weapon_sword"), "right")
	holder:Equip(holder:FindWeapon("weapon_shield"), "left")
end

function jrpg.RemoveLoadout(entity)
	local holder = entity.weapon_holder

	for _, name in ipairs(jrpg.Loadout) do
		local weapon = holder:FindWeapon(name)

		if weapon then weapon:Remove() end
	end

	if not holder:GetWeapon("right") then holder:EquipFirst() end
end

function jrpg.SetEnabled(entity, enabled, cheat)
	assert(network.HasAuthority(), "rpg mode is changed by the authority")

	if enabled then
		if not entity.rpg then
			entity:AddComponent("rpg")
			jrpg.GiveLoadout(entity)
		end

		entity.rpg:SetCheat(cheat == true)

		if not cheat then entity.rpg:ApplyStats() end
	elseif entity.rpg then
		jrpg.RemoveLoadout(entity)
		status_effects.Clear(entity)
		entity:RemoveComponent("rpg")
	end
end

function jrpg.Toggle(entity, cheat)
	jrpg.SetEnabled(entity, not entity.rpg or cheat ~= nil and entity.rpg:IsCheat() ~= cheat, cheat)
end

local function get_command_entity(client)
	if client and _G.GetPlayerEntity then return _G.GetPlayerEntity(client) end

	return _G.PLAYER_RIG
end

local function run_command(client, what, argument)
	local entity = get_command_entity(client)

	if not entity or not entity:IsValid() then return end

	if what == "rpg" then
		jrpg.Toggle(entity, argument == "cheat" or nil)
	elseif what == "level" then
		assert(entity.rpg, "rpg mode is off, enable it with !rpg")
		assert(entity.rpg:LevelAttribute(argument))
	elseif what == "status" then
		local name, amount = argument:match("^(%S+)%s*(%S*)$")
		status_effects.Set(entity, name, tonumber(amount) or 1, entity)
	end
end

local function command(what, argument)
	if network.HasAuthority() then
		run_command(nil, what, argument)
	else
		message.Send("jrpg_command", what, argument or "")
	end
end

if SERVER then
	message.AddListener("jrpg_command", function(client, what, argument)
		run_command(client, what, argument)
	end)
end

commands.Add("rpg=string|nil", function(mode)
	command("rpg", mode)
end)

commands.Add("level=string|nil", function(name)
	if not name then
		local rpg = _G.PLAYER_RIG and _G.PLAYER_RIG.rpg

		for _, attribute in ipairs(attributes.List) do
			logf(
				"%-16s %8s  %s\n",
				attribute.Name,
				rpg and tostring(math.round(rpg:GetStat(attribute.Name), 2)) or "",
				attribute.Help
			)
		end

		if rpg then logf("%d attribute points left\n", rpg:GetAttributePoints()) end

		return
	end

	command("level", name)
end)

commands.Add("status=string,number[1]", function(name, amount)
	status_effects.GetDefinition(name)
	command("status", name .. " " .. amount)
end)

event.AddListener("RPGEnabled", "jrpg", function(entity)
	if entity == _G.PLAYER_RIG then battlecam.SetEnabled(true) end
end)

event.AddListener("RPGDisabled", "jrpg", function(entity)
	if entity == _G.PLAYER_RIG then battlecam.SetEnabled(false) end
end)

event.AddListener("PlayerRespawn", "jrpg", function(entity)
	if not entity.rpg then return end

	jrpg.GiveLoadout(entity)
	entity.rpg:SetMana(entity.rpg:GetMaxMana())
	entity.rpg:SetStamina(entity.rpg:GetMaxStamina())
	entity.rpg:SetStunned(false)
end)

local function get_shield_point(victim, to_attacker)
	return actors.GetCenter(victim) + to_attacker * 0.45
end

local function flat_direction(from, to)
	local direction = to - from
	direction.y = 0
	local length = direction:GetLength()

	if length < 1e-4 then return Vec3(0, 0, 0) end

	return direction / length
end

event.AddListener("ModifyDamage", "jrpg", function(victim, info)
	local definition = damage_types.Get(info.Type)
	local magic = damage_types.IsMagic(info.Type)
	local attacker = info.Attacker
	local rpg = victim.rpg

	if attacker and attacker:IsValid() and attacker.rpg and not info.Status then
		info.Damage = info.Damage * attacker.rpg:GetStat(magic and "magic_attack" or "physical_attack")
	end

	if definition.Heals then
		info.Damage = -math.abs(info.Damage)
		info.Force = nil
		info.Part = nil
	elseif rpg then
		info.Damage = info.Damage / rpg:GetStat(magic and "magic_defense" or "physical_defense")

		if
			victim.character_movement:IsRolling() and
			not magic and
			attacker ~= victim and
			not info.Status
		then
			info.Cancel = true
			effects.Text(victim, "DODGE", jrpg.Colors.neon)
			return
		end

		if rpg:IsStunned() then info.Damage = info.Damage * STUNNED_DAMAGE end

		local pose = victim.character_pose

		if
			pose:IsBlocking() and
			attacker and
			attacker ~= victim and
			attacker:IsValid() and
			not info.Status
		then
			local to_attacker = flat_direction(actors.GetCenter(victim), actors.GetCenter(attacker))

			if to_attacker:Dot(actors.GetForward(victim)) > BLOCK_ANGLE then
				local blocked = info.Damage * (magic and SHIELD_MAGIC or SHIELD_PHYSICAL)
				rpg:DrainStamina(blocked)
				local broken = rpg:GetStamina() <= 0 and not rpg:IsCheat()

				if broken then
					rpg:Stun(STUN_TIME)
					pose:SetBlocking(false)
				end

				effects.Block(victim, get_shield_point(victim, to_attacker), to_attacker, broken)
				info.Damage = info.Damage - blocked
				info.Part = nil
				info.Force = info.Force and info.Force * 0.2

				if info.Damage <= 0.01 then
					info.Cancel = true
					return
				end
			end
		end
	end

	if definition.OnDamage and not info.Status then
		definition.OnDamage(victim, info)
	end
end)

event.AddListener("HealthDamaged", "jrpg", function(entity, amount, max_health, info)
	if not network.HasAuthority() then return end

	local attacker = info.Attacker

	if
		amount > 0 and
		attacker and
		attacker ~= entity and
		attacker:IsValid() and
		attacker.rpg
	then
		entity.jrpg_attackers = entity.jrpg_attackers or table.weak("k")
		entity.jrpg_attackers[attacker] = (entity.jrpg_attackers[attacker] or 0) + amount
	end

	effects.Damage(entity, info.Type, amount, max_health)
	local definition = damage_types.Get(info.Type)
	local body = entity.rigid_body

	if definition.Knockback and body and amount > 0 and attacker and attacker:IsValid() then
		local push = flat_direction(actors.GetCenter(attacker), actors.GetCenter(entity)) * definition.Knockback
		push.y = definition.Knockback * 0.8
		body:SetVelocity(body:GetVelocity() + push)
	end
end)

event.AddListener("EntityKilled", "jrpg", function(victim)
	if not network.HasAuthority() then return end

	local attackers = victim.jrpg_attackers

	if not attackers then return end

	victim.jrpg_attackers = nil

	for attacker, dealt in pairs(attackers) do
		if attacker:IsValid() and attacker.rpg then
			local xp = math.floor(math.min(dealt, victim.health:GetMaxHealth()) * 2)
			attacker.rpg:GiveXP(xp)
			effects.Text(victim, "XP +" .. xp, jrpg.Colors.xp)
		end
	end
end)

event.AddListener("RPGLevelUp", "jrpg", function(entity, level)
	if network.HasAuthority() then effects.LevelUp(entity, level) end
end)

event.AddListener("CanRoll", "jrpg", function(entity)
	local rpg = entity.rpg

	if not rpg then return end

	return not entity.character_pose:IsBlocking() and
		not rpg:IsStunned()
		and
		status_effects.GetSpeedScale(entity) > 0 and
		rpg:DrainStamina(ROLL_COST)
end)

event.AddListener("PlayerMove", "jrpg", function(entity, move)
	local scale = status_effects.GetSpeedScale(entity)
	local rpg = entity.rpg

	if rpg then
		local movement = entity.character_movement
		local cmd = movement:GetCommand()
		local pose = entity.character_pose

		if not rpg:IsSprintAllowed(cmd) then
			move.wish_speed = math.min(move.wish_speed, movement:GetGroundSpeed())
		end

		if pose:IsBlocking() or rpg:IsStunned() or pose:GetActiveAction() == "drink" then
			scale = scale * BLOCK_SPEED
		end
	end

	local confused = status_effects.Get(entity, "confused")

	if confused > 0 and move.wish_speed > 0 then
		local wobble = status_effects.Registered.confused.Wobble(confused, system.GetElapsedTime())
		local c, s = math.cos(wobble), math.sin(wobble)
		local x, z = move.move.x, move.move.z
		move.move.x = x * c + z * s
		move.move.z = z * c - x * s
	end

	move.wish_speed = move.wish_speed * scale

	if scale <= 0 then move.jump_pressed = false end
end)

return jrpg
