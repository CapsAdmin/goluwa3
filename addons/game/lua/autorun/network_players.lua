local event = import("goluwa/event.lua")
local packet = import("goluwa/network/packet.lua")
local network = import("goluwa/network/network.lua")
local clients = import("goluwa/network/clients.lua")
local timer = import("goluwa/timer.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Entity.RegisterComponent("player_avatar", import("lua/components/player_avatar.lua"))
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("player_movement", import("lua/components/player_movement.lua"))
Entity.RegisterComponent("player_physgun", import("lua/components/player_physgun.lua"))
local ACK_INTERVAL = 1 / 20
local SPAWN_POSITION = Vec3(0, 3, 0)
local RELAY_BATCH = 4

if SERVER then
	local players = {}

	function _G.GetPlayerEntity(client)
		return players[client:GetUniqueID()]
	end

	event.AddListener("ClientWorldReady", "network_players", function(client)
		if client:IsBot() then return end

		local uid = client:GetUniqueID()

		if players[uid] and players[uid]:IsValid() then return end

		players[uid] = Entity.New{
			Name = client:GetNick(),
			ComponentSet = {"transform", "player_controller", "player_movement", "player_physgun"},
			transform = {Position = SPAWN_POSITION:Copy()},
			player_controller = {Source = "queue"},
			player_avatar = {},
			network = {NetworkOwner = uid},
		}
		local start = packet.CreateBuffer()
		start:WriteVec3(SPAWN_POSITION)
		packet.Send("player_start", start, client, "reliable")
	end)

	event.AddListener("ClientLeft", "network_players", function(client)
		local uid = client:GetUniqueID()
		local ent = players[uid]

		if ent and ent:IsValid() then ent:Remove() end

		players[uid] = nil
	end)

	packet.AddListener("usercmd", function(buffer, client)
		local ent = players[client:GetUniqueID()]

		if not ent or not ent:IsValid() then return end

		local commands = usercmd.ReadBatch(buffer)
		ent.player_controller:PushCommands(commands)
		local relay = packet.CreateBuffer()
		relay:WriteString(client:GetUniqueID())
		usercmd.WriteBatch(relay, commands)
		packet.Send("usercmd_relay", relay, clients.CreateFilter():AddAllExcept(client), "sequenced")
	end)

	timer.Repeat("network_players_ack", ACK_INTERVAL, function()
		for uid, ent in pairs(players) do
			if ent:IsValid() then
				local processed = ent.player_controller.processed
				local buffer = packet.CreateBuffer()
				buffer:WriteU32(processed.number)
				buffer:WriteVec3(processed.position)
				buffer:WriteVec3(processed.velocity)
				buffer:WriteBoolean(ent.player_controller:IsHolding())
				packet.Send("player_ack", buffer, clients.GetByUniqueID(uid), "sequenced")
			end
		end
	end)
end

if CLIENT then
	local local_player

	event.AddListener("PlayerCommand", "network_players", function(ent, cmd)
		if not ent.player_controller:GetNetworked() or not network.IsConnected() then
			return
		end

		local_player = ent
		local buffer = packet.CreateBuffer()
		local recent = ent.player_controller.recent
		local first = math.max(1, #recent - RELAY_BATCH + 1)
		local batch = {}

		for i = first, #recent do
			batch[#batch + 1] = recent[i]
		end

		usercmd.WriteBatch(buffer, batch)
		packet.Send("usercmd", buffer, "sequenced")
	end)

	packet.AddListener("player_start", function(buffer)
		local position = buffer:ReadVec3()

		for _, controller in ipairs(import("lua/components/player_controller.lua").Instances or {}) do
			if controller:GetNetworked() then controller:Start(position) end
		end
	end)

	event.AddListener("Disconnected", "network_players", function()
		for _, controller in ipairs(import("lua/components/player_controller.lua").Instances or {}) do
			controller.synced = false
		end
	end)

	packet.AddListener("player_ack", function(buffer)
		if not local_player or not local_player:IsValid() then return end

		local number = buffer:ReadU32()
		local position = buffer:ReadVec3()
		local velocity = buffer:ReadVec3()
		local controller = local_player.player_controller
		controller:SetHolding(buffer:ReadBoolean())
		controller:Reconcile(number, position, velocity)
	end)

	packet.AddListener("usercmd_relay", function(buffer)
		local owner = buffer:ReadString()
		local commands = usercmd.ReadBatch(buffer)
		event.Call("RemotePlayerCommands", owner, commands)
	end)
end
