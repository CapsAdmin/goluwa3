local players = import("lua/players.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local damage = import("lua/damage.lua")
local death

event.AddListener("EntityKilled", "player_commands", function(victim)
	if not players.IsLocal(victim) then return end

	death = {
		position = victim.transform:GetPosition():Copy(),
		rotation = victim.player_input:GetRotation():Copy(),
	}
end)

commands.Add("kill", function()
	players.GetLocal().health:TakeDamage(damage.Info{Damage = players.GetLocal().health.Health, Attacker = players.GetLocal()})
end)

commands.Add("revive", function()
	assert(death, "you have not died")
	local rig = players.GetLocal()
	rig.health:Revive()
	rig.weapon_holder:GiveLoadout()
	rig.player_controller:Spawn(death.position, death.rotation)
end)
