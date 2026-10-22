local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local damage = import("lua/damage.lua")
local death

event.AddListener("EntityKilled", "player_commands", function(victim)
	if victim ~= PLAYER_RIG then return end

	death = {
		position = victim.transform:GetPosition():Copy(),
		rotation = victim.player_input:GetRotation():Copy(),
	}
end)

commands.Add("kill", function()
	PLAYER_RIG.health:TakeDamage(damage.Info{Damage = PLAYER_RIG.health.Health, Attacker = PLAYER_RIG})
end)

commands.Add("revive", function()
	assert(death, "you have not died")
	local rig = PLAYER_RIG
	rig.health:Revive()
	rig.weapon_holder:GiveLoadout()
	rig.player_controller:Spawn(death.position, death.rotation)
end)
