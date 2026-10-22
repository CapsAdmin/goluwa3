local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/weapons.lua")
import("addons/game/lua/autorun/characters.lua")
import("addons/game/lua/autorun/jrpg.lua")
local damage = import("lua/damage.lua")
local jrpg = import("lua/jrpg/jrpg.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local damage_types = import("lua/jrpg/damage_types.lua")

local function create_dummy(health)
	return Entity.New{
		ComponentSet = {"transform", "health"},
		transform = {Position = Vec3(0, 0, 0)},
		health = {Health = health or 100, MaxHealth = health or 100},
	}
end

local function create_character(position)
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local entity = Entity.New{
		ComponentSet = {"transform", "ai_controller", "character_pose", "weapon_holder", "health"},
		transform = {Position = position:Copy()},
		ai_controller = {Wander = false},
	}
	entity.ai_controller:Teleport(position, 0)
	return entity
end

local function tick(component, seconds)
	for _ = 1, seconds * 20 do
		component:OnUpdate(1 / 20)
	end
end

T.Test("every damage type and status effect is registered", function()
	for _, name in ipairs(damage_types.Names) do
		T(damage_types.Get(name).Name)["=="](name)
	end

	for _, name in ipairs(status_effects.Names) do
		T(status_effects.GetDefinition(name).Name)["=="](name)
	end
end)

T.Test("fire damage sets the victim burning until the burn decays", function()
	local victim = create_dummy(200)
	damage.Deal(victim, {Damage = 50, Type = "fire"})
	T(victim.health.Health)["=="](150)
	T(status_effects.Get(victim, "fire"))["~"](0.5, 1e-6)
	tick(victim.status_effects, 1)
	T(victim.health.Health < 150)["=="](true)
	tick(victim.status_effects, 10)
	T(status_effects.Get(victim, "fire"))["=="](0)
	T(victim.status_effects:Encode())["=="]("")
end)

T.Test("status damage does not stack its own status again", function()
	local victim = create_dummy(1000)
	status_effects.Set(victim, "poison", 0.5)
	tick(victim.status_effects, 3)
	T(status_effects.Get(victim, "poison") < 0.5)["=="](true)
end)

T.Test("heal damage restores health and clears negative statuses", function()
	local victim = create_dummy(100)
	damage.Deal(victim, {Damage = 60, Type = "generic"})
	status_effects.Set(victim, "poison", 0.8)
	damage.Deal(victim, {Damage = 30, Type = "heal"})
	T(victim.health.Health)["=="](70)
	T(status_effects.Get(victim, "poison"))["=="](0)
end)

T.Test("ice freezes solid, which stops movement and attacks", function()
	local victim = create_dummy(100)
	damage.Deal(victim, {Damage = 40, Type = "ice"})
	T(status_effects.GetSpeedScale(victim))["~"](0.6, 1e-6)
	T(status_effects.CanAttack(victim))["=="](true)
	status_effects.Set(victim, "frozen", 0.9)
	T(status_effects.GetSpeedScale(victim))["=="](0)
	T(status_effects.CanAttack(victim))["=="](false)
	T(victim:CallLocalEvent("OnCanAttack"))["=="](false)
end)

T.Test("dead entities lose their statuses", function()
	local victim = create_dummy(10)
	status_effects.Set(victim, "fire", 1)
	damage.Deal(victim, {Damage = 100, Type = "generic"})
	T(victim.health:IsDead())["=="](true)
	T(status_effects.Get(victim, "fire"))["=="](0)
end)

T.TestPhysics("rpg mode raises the stats, gives the loadout and puts everything back", function()
	local entity = create_character(Vec3(0, 0.05, 0))
	entity.weapon_holder:Give("weapon_pistol")
	jrpg.SetEnabled(entity, true)
	T(entity.health:GetMaxHealth())["=="](200)
	T(entity.health:GetHealth())["=="](200)
	T(entity.rpg:GetMana())["=="](entity.rpg:GetMaxMana())
	T(entity.weapon_holder:GetActiveWeapon():GetName())["=="]("weapon_sword")
	T(entity.weapon_holder:GetOffhandWeapon():GetName())["=="]("weapon_shield")
	T(entity.weapon_holder:FindWeapon("weapon_magic_fire") ~= nil)["=="](true)
	jrpg.SetEnabled(entity, false)
	T(entity.rpg)["=="](nil)
	T(entity.health:GetMaxHealth())["=="](100)
	T(entity.weapon_holder:FindWeapon("weapon_sword"))["=="](nil)
	T(entity.weapon_holder:GetActiveWeapon():GetName())["=="]("weapon_pistol")
end)

T.TestPhysics("attributes scale damage, a raised shield blocks and a roll dodges", function()
	local attacker = create_character(Vec3(0, 0.05, -2))
	local victim = create_character(Vec3(0, 0.05, 0))
	jrpg.SetEnabled(attacker, true)
	jrpg.SetEnabled(victim, true)
	attacker.rpg:GetStats().magic_attack = 2
	damage.Deal(victim, {Attacker = attacker, Damage = 10, Type = "water"})
	T(victim.health:GetHealth())["=="](180)
	victim.transform:SetRotation(import("goluwa/structs/quat.lua")():Identity())
	victim.character_pose:SetBlocking(true)
	local stamina = victim.rpg:GetStamina()
	damage.Deal(victim, {Attacker = attacker, Damage = 30})
	T(victim.health:GetHealth())["=="](180)
	T(victim.rpg:GetStamina())["=="](stamina - 30)
	victim.character_pose:SetBlocking(false)
	victim.rpg.roll = {time = 0, direction = Vec3(1, 0, 0)}
	damage.Deal(victim, {Attacker = attacker, Damage = 30})
	T(victim.health:GetHealth())["=="](180)
	damage.Deal(victim, {Attacker = attacker, Damage = 10, Type = "fire"})
	T(victim.health:GetHealth() < 180)["=="](true)
end)

T.TestPhysics("kills give experience and levels give attribute points", function()
	local player = create_character(Vec3(0, 0.05, 0))
	jrpg.SetEnabled(player, true)
	local victim = create_dummy(300)
	damage.Deal(victim, {Attacker = player, Damage = 400})
	T(victim.health:IsDead())["=="](true)
	T(player.rpg:GetLevel() >= 1)["=="](true)
	T(player.rpg:GetAttributePoints())["=="](player.rpg:GetLevel())
	local health = player.health:GetMaxHealth()
	T(player.rpg:LevelAttribute("health"))["=="](true)
	T(player.health:GetMaxHealth())["=="](health + 25)
end)
