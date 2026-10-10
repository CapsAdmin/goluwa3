local event = import("goluwa/event.lua")
local packet = import("goluwa/network/packet.lua")
local network = import("goluwa/network/network.lua")
local system = import("goluwa/system.lua")
local clients = import("goluwa/network/clients.lua")
local timer = import("goluwa/timer.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local SpawnPoint = import("goluwa/entities/components/spawn_point.lua")
local PlayerMovement = import("lua/components/player_movement.lua")
local outfit = import("lua/outfit.lua")
import("lua/weapon_models.lua")
import("lua/weapons.lua")
import("lua/outfit_source.lua")
Entity.RegisterComponent("player_avatar", import("lua/components/player_avatar.lua"))
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("player_movement", import("lua/components/player_movement.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
Entity.RegisterComponent("weapon_physgun", import("lua/components/weapon_physgun.lua"))
Entity.RegisterComponent("weapon_pistol", import("lua/components/weapon_pistol.lua"))
Entity.RegisterComponent("weapon_camera", import("lua/components/weapon_camera.lua"))

if RENDER_3D then
	-- the points of a player that things attach to, player_avatar moves them
	import("goluwa/entities/components/armature.lua").RegisterSkeleton(
		"player",
		{
			{"root"},
			{"body", "root"},
			{"spine", "body"},
			{"chest", "spine"},
			{"neck", "chest"},
			{"head", "neck"},
			{"clavicle_r", "chest"},
			{"upperarm_r", "clavicle_r"},
			{"forearm_r", "upperarm_r"},
			{"hand_r", "forearm_r"},
			{"clavicle_l", "chest"},
			{"upperarm_l", "clavicle_l"},
			{"forearm_l", "upperarm_l"},
			{"hand_l", "forearm_l"},
			{"thigh_r", "body"},
			{"calf_r", "thigh_r"},
			{"foot_r", "calf_r"},
			{"thigh_l", "body"},
			{"calf_l", "thigh_l"},
			{"foot_l", "calf_l"},
		}
	)
end

local ACK_INTERVAL = 1 / 20
local SPAWN_POSITION = Vec3(0, 3, 0)
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

		local position = SPAWN_POSITION:Copy()
		local rotation = Quat():Identity()
		local spawn = SpawnPoint.Pick("deathmatch", "start") or SpawnPoint.Pick()

		if spawn then
			position, rotation = spawn:GetPlacement(0)
		end

		players[uid] = Entity.New{
			Name = client:GetNick(),
			ComponentSet = {"transform", "player_controller", "player_movement", "weapon_holder"},
			transform = {Position = position:Copy(), Rotation = rotation:Copy()},
			player_controller = {Source = "queue"},
			player_avatar = {},
			network = {NetworkOwner = uid},
		}
		players[uid].weapon_holder:GiveLoadout()
		local start = packet.CreateBuffer()
		start:WriteVec3(position)
		start:WriteQuat(rotation)
		packet.Send("player_start", start, client, "reliable")
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
				buffer:WriteBoolean(ent.player_controller:IsHolding())
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
	event.AddListener("Update", "network_players_outfit", function()
		if not outfit_due or system.GetElapsedTime() < outfit_due then return end

		local uid = clients.GetLocalClient():GetUniqueID()

		if uid == "unconnected" then return end

		outfit_due = nil
		scene_sync.PushPrefab(outfit.LoadLocal(), outfit.GetName(uid))
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
