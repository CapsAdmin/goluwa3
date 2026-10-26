local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
import("lua/damage.lua")
import("addons/game/lua/autorun/characters.lua")

local function create(refill)
	return Entity.New{
		ComponentSet = {"transform", "health"},
		health = {Health = 1000, MaxHealth = 1000, Refill = refill},
	}
end

T.Test("a refilling health component gains its maximum back instead of dying", function()
	local killed = 0

	event.AddListener("EntityKilled", "health_test", function()
		killed = killed + 1
	end)

	local entity = create(true)
	entity.health:TakeDamage({Damage = 400})
	T(entity.health:GetHealth())["=="](600)
	entity.health:TakeDamage({Damage = 5000})
	T(entity.health:GetHealth())["=="](1000)
	T(entity.health:IsDead())["=="](false)
	T(killed)["=="](0)
	entity:Remove()
	local mortal = create(false)
	mortal.health:TakeDamage({Damage = 5000})
	T(mortal.health:IsDead())["=="](true)
	T(killed)["=="](1)
	mortal:Remove()
	event.RemoveListener("EntityKilled", "health_test")
end)
