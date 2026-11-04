local clients = import("goluwa/network/clients.lua")
local players = {}
import.loaded["lua/players.lua"] = players
local registered = {}
local local_player

function players.Register(client, entity)
	registered[client:GetUniqueID()] = entity
end

function players.Unregister(client)
	registered[client:GetUniqueID()] = nil
end

function players.SetLocal(entity)
	local_player = entity
end

function players.GetLocal()
	if local_player and local_player:IsValid() then return local_player end
end

function players.IsLocal(entity)
	return entity == local_player
end

function players.Get(client)
	if client == clients.GetLocalClient() then return players.GetLocal() end

	local uid = client:GetUniqueID()
	local entity = registered[uid]

	if entity and entity:IsValid() then return entity end

	for _, controller in ipairs(import("lua/components/player_controller.lua").Instances or {}) do
		local network = controller.Owner.network

		if network and network:GetNetworkOwner() == uid then return controller.Owner end
	end
end

function players.GetClient(entity)
	if entity == local_player then return clients.GetLocalClient() end

	if entity.network then
		return clients.GetByUniqueID(entity.network:GetNetworkOwner())
	end
end

return players
