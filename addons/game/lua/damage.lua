local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Entity.RegisterComponent("health", import("lua/components/health.lua"))
local damage = {}

function damage.Info(fields)
	fields.Damage = fields.Damage or 0
	fields.Type = fields.Type or "generic"
	fields.Position = fields.Position or Vec3()
	fields.Normal = fields.Normal or Vec3(0, 1, 0)
	fields.Force = fields.Force or Vec3()
	return fields
end

function damage.Deal(victim, info)
	assert(network.HasAuthority(), "damage is only dealt by the authority")
	damage.Info(info)
	event.Call("ModifyDamage", victim, info)
	victim.health:TakeDamage(info)
	return info.Damage
end

return damage
