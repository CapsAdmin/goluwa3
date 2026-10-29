local event = import("goluwa/event.lua")
local clients = import("goluwa/network/clients.lua")
local spawning = import("lua/spawning.lua")

event.AddListener("PlayerRespawn", "player_respawn", function(entity, position, rotation)
	if not position then position, rotation = spawning.Pick() end

	local controller = entity.player_controller
	entity.health:Revive()
	entity.weapon_holder:GiveLoadout()

	if controller.Source == "local" then
		controller:Spawn(position, rotation)
		return
	end

	controller:Start(position)
	spawning.SendStart(clients.GetByUniqueID(entity.network:GetNetworkOwner()), entity, position, rotation)
end)
