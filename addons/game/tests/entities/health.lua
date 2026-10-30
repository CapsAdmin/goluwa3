local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
import("lua/damage.lua")
import("addons/game/lua/autorun/characters.lua")

local function create(refill_delay)
	return Entity.New{
		ComponentSet = {"transform", "health"},
		health = {Health = 1000, MaxHealth = 1000, RefillDelay = refill_delay},
	}
end

T.Test("a health component with a refill delay dies and gains its maximum back later", function()
	local killed = 0

	event.AddListener("EntityKilled", "health_test", function()
		killed = killed + 1
	end)

	local entity = create(0.05)
	entity.health:TakeDamage({Damage = 5000})
	T(entity.health:IsDead())["=="](true)
	T(killed)["=="](1)

	T.WaitUntil(function()
		return not entity.health:IsDead()
	end)

	T(entity.health:GetHealth())["=="](1000)
	entity:Remove()
	local mortal = create(0)
	mortal.health:TakeDamage({Damage = 5000})
	T(mortal.health:IsDead())["=="](true)
	T(killed)["=="](2)
	mortal:Remove()
	event.RemoveListener("EntityKilled", "health_test")
end)
