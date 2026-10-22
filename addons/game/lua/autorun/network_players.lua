local event = import("goluwa/event.lua")
local packet = import("goluwa/network/packet.lua")
local network = import("goluwa/network/network.lua")
local system = import("goluwa/system.lua")
local clients = import("goluwa/network/clients.lua")
local timer = import("goluwa/timer.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Entity = import("goluwa/entities/entity.lua")
local spawning = import("lua/spawning.lua")
local CharacterMovement = import("lua/components/character_movement.lua")
local outfit = import("lua/outfit.lua")
import("lua/weapons.lua")
import("lua/damage.lua")
import("lua/outfit_source.lua")
Entity.RegisterComponent("player_avatar", import("lua/components/player_avatar.lua"))
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))

local ACK_INTERVAL = 1 / 20
local RELAY_BATCH = 4
local OUTFIT_PUSH_DELAY = 0.2

if SERVER then
	local players = {}

	function _G.GetPlayerEntity(client)
		return players[client:GetUniqueID()]
	end

	event.AddListener("ClientWorldReady", "network_players", function(client)
		if client:IsBot() then return end

		local uid = client:GetUniqueID()

		if players[uid] and players[uid]:IsValid() then return end

		local position, rotation = spawning.Pick()

		players[uid] = Entity.New{
			Name = client:GetNick(),
			ComponentSet = {
				"transform",
				"player_controller",
				"character_movement",
				"character_pose",
				"attachment_points",
				"procedural_pose",
				"weapon_holder",
				"health",
			},
			transform = {Position = position:Copy(), Rotation = rotation:Copy()},
			player_controller = {Source = "queue"},
			player_avatar = {},
			network = {NetworkOwner = uid},
		}
		players[uid].weapon_holder:GiveLoadout()
		spawning.SendStart(client, position, rotation)
	end)

	event.AddListener("EntityPermission", "network_players", function(client, action, name)
		if action == "prefab" and name == outfit.GetName(client:GetUniqueID()) then
			return true
		end
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
				buffer:WriteBoolean(ent.character_pose:IsHolding())
				packet.Send("player_ack", buffer, clients.GetByUniqueID(uid), "sequenced")
			end
		end
	end)
end

if CLIENT and not SERVER then
	local scene_sync = import("goluwa/network/scene_sync.lua")
	local outfit_due

	event.AddListener("Connected", "network_players_outfit", function()
		outfit_due = 0
	end)

	event.AddListener("PrefabChanged", "network_players_outfit", function(definition)
		if network.IsConnected() and definition.name == outfit.GetLocalName() then
			outfit_due = system.GetElapsedTime() + OUTFIT_PUSH_DELAY
		end
	end)

	-- the unique id is only known once the server has created the local client
	event.AddListener("PersistentVariableChanged", "network_players_outfit", function(key)
		if network.IsConnected() and (key == "cl_outfit" or key == "cl_outfit_model") then
			outfit_due = system.GetElapsedTime() + OUTFIT_PUSH_DELAY
		end
	end)

	event.AddListener("Update", "network_players_outfit", function()
		if not outfit_due or system.GetElapsedTime() < outfit_due then return end

		local uid = clients.GetLocalClient():GetUniqueID()

		if uid == "unconnected" then return end

		outfit_due = nil
		local name, inputs = outfit.LoadLocal()
		scene_sync.PushPrefab(name, outfit.GetName(uid), inputs)
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
		local rotation = buffer:ReadQuat()

		for _, controller in ipairs(import("lua/components/player_controller.lua").Instances or {}) do
			if controller:GetNetworked() then controller:Spawn(position, rotation) end
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
		local_player.character_pose:SetHolding(buffer:ReadBoolean())
		local_player.player_controller:Reconcile(number, position, velocity)
	end)

	packet.AddListener("usercmd_relay", function(buffer)
		local owner = buffer:ReadString()
		local commands = usercmd.ReadBatch(buffer)
		event.Call("RemotePlayerCommands", owner, commands)
	end)
end
