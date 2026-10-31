local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local pvars = import("goluwa/cli/pvars.lua")
Entity.RegisterComponent("health", import("lua/components/health.lua"))
local damage = {}
local godmode = pvars.Setup2{
	key = "sv_godmode",
	category = "Game",
	group = "Server",
	prefix = "sv_",
	default = false,
	help = "players take no damage (each player can also toggle it for themselves with the god command)",
}

function damage.IsGod(victim)
	return victim.health:IsGodMode() or godmode:Get() and victim.player_controller ~= nil
end

function damage.Info(fields)
	fields.Damage = fields.Damage or 0
	fields.Type = fields.Type or "generic"
	fields.Position = fields.Position or Vec3()
	fields.Normal = fields.Normal or Vec3(0, 1, 0)
	fields.Force = fields.Force or Vec3()
	return fields
end

local TRACE_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

local function is_target(entity)
	return entity.ragdoll_part ~= nil or not entity.ragdoll
end

function damage.Sweep(origin, movement, attacker, radius)
	return physics.Sweep(origin, movement, radius or 0, attacker, is_target, TRACE_OPTIONS)
end

function damage.GetVictim(entity)
	local part = entity.ragdoll_part

	if part then return part.Character, part.Multiplier end

	return entity, 1
end

function damage.Deal(victim, info)
	assert(network.HasAuthority(), "damage is only dealt by the authority")
	damage.Info(info)
	event.Call("ModifyDamage", victim, info)

	if info.Cancel or info.Damage > 0 and damage.IsGod(victim) then return 0 end

	victim.health:TakeDamage(info)
	return info.Damage
end

return damage
