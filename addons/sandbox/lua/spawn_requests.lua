local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
local clients = import("goluwa/network/clients.lua")
local permissions = import("goluwa/entities/permissions.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local players = import("lua/players.lua")
local weapons = import("lua/weapons.lua")
local npcs = import("lua/npcs.lua")
local interactives = import("lua/interactives.lua")
local vehicles = import("lua/vehicles.lua")
local props = import("lua/props.lua")
local game_history = import("lua/game_history.lua")
local spawn_requests = {}
spawn_requests.Range = 40
local RANGE_SLACK = 10
local PROP_PATTERN = "^models/[%w_%-%./]+$"
local MAX_NAME_LENGTH = 200
local MAX_NPC_HEALTH = 1e6
local REACTIONS = {flinch = true, stagger = true, knockdown = true}
local weapon_offset = Vec3(0, 0.3, 0)
local interactive_names = {}

for _, name in ipairs(interactives.Names) do
	interactive_names[name] = true
end

local spawners = {}
local validators = {}
local option_validators = {}

function validators.weapon(name)
	return weapons.Definitions[name] ~= nil
end

function validators.interactive(name)
	return interactive_names[name] == true
end

function validators.vehicle(name)
	return vehicles.Definitions[name] ~= nil
end

function validators.npc(name)
	return npcs.Definitions[name] ~= nil
end

function validators.prop(name)
	return name:find(PROP_PATTERN) ~= nil and not name:find("..", 1, true)
end

function option_validators.weapon(roll)
	return weapons.Roller ~= nil and weapons.Roller.IsValidRoll(roll)
end

function option_validators.npc(options)
	return type(options) == "table" and
		(
			options.Faction == nil or
			options.Faction == "friend" or
			options.Faction == "enemy"
		)
		and
		(
			options.Weapon == nil or
			validators.weapon(options.Weapon)
		)
		and
		(
			options.Roll == nil or
			option_validators.weapon(options.Roll)
		)
		and
		(
			options.Reaction == nil or
			REACTIONS[options.Reaction] == true
		)
		and
		(
			options.Health == nil or
			type(options.Health) == "number" and
			options.Health > 0 and
			options.Health <= MAX_NPC_HEALTH
		)
		and
		(
			options.God == nil or
			type(options.God) == "boolean"
		)
end

function spawners.weapon(player, name, position, yaw, done, roll)
	done(weapons.Spawn(name, position + weapon_offset, QuatFromAxis(yaw, Vec3(0, 1, 0)), roll))
end

function spawners.interactive(player, name, position, yaw, done)
	done(interactives.Spawn(name, position, yaw))
end

function spawners.vehicle(player, name, position, yaw, done)
	done(vehicles.Spawn(name, position, yaw))
end

function spawners.npc(player, name, position, yaw, done, options)
	local npc = npcs.Spawn(name, position, yaw, options)
	npc:SetTransient(false)
	done(npc)
end

function spawners.prop(player, name, position, yaw, done)
	props.Spawn(name, position, QuatFromAxis(yaw, Vec3(0, 1, 0)), done)
end

function spawn_requests.IsValid(kind, name)
	local validator = validators[kind]
	return validator ~= nil and validator(name)
end

function spawn_requests.GetLabel(kind, name)
	return "spawn " .. (kind == "prop" and name:match("([^/]+)%.%w+$") or name)
end

if SERVER then
	message.AddListener("sandbox_give", function(client, name, roll)
		local player = players.Get(client)

		if not (player and player:IsValid()) then return end

		if type(name) ~= "string" or not validators.weapon(name) then return end

		if roll ~= nil and not (weapons.Roller and weapons.Roller.IsValidRoll(roll)) then
			return
		end

		if not permissions.CanSpawn(client, "weapon", name) then
			wlog("%s was not allowed to give %s", client, name)
			return
		end

		player.weapon_holder:Give(name, roll)
	end)

	message.AddListener("sandbox_spawn", function(client, kind, name, position, yaw, options)
		local player = players.Get(client)

		if not (player and player:IsValid()) then return end

		if
			type(kind) ~= "string" or
			type(name) ~= "string" or
			#name > MAX_NAME_LENGTH or
			typex(position) ~= "vec3" or
			type(yaw) ~= "number"
		then
			return
		end

		if
			options ~= nil and
			not (
				option_validators[kind] and
				option_validators[kind](options)
			)
		then
			return
		end

		if
			not (
				spawn_requests.IsValid(kind, name) and
				permissions.CanSpawn(client, kind, name)
			)
		then
			wlog("%s was not allowed to spawn %s %s", client, kind, name)
			return
		end

		local eye = player.transform:GetPosition() + player.character_movement:GetViewOffset()

		if not (position:Distance(eye) <= spawn_requests.Range + RANGE_SLACK) then
			wlog("%s asked to spawn %s too far away", client, name)
			return
		end

		spawners[kind](
			player,
			name,
			position,
			yaw,
			function(entity)
				entity:SetOwnedBy(client)
				game_history.GetHistory(client):Push(game_history.Spawned(spawn_requests.GetLabel(kind, name), entity))
			end,
			options
		)
	end)
end

if CLIENT then
	function spawn_requests.Give(name, roll)
		if network.IsConnected() then
			message.Send("sandbox_give", name, roll)
			return
		end

		players.GetLocal().weapon_holder:Give(name, roll)
	end

	function spawn_requests.Spawn(kind, name, position, yaw, options)
		if network.IsConnected() then
			message.Send("sandbox_spawn", kind, name, position, yaw, options)
			return
		end

		spawners[kind](
			players.GetLocal(),
			name,
			position,
			yaw,
			function(entity)
				entity:SetOwnedBy(clients.GetLocalClient())
				game_history.RecordSpawn(spawn_requests.GetLabel(kind, name), entity)
			end,
			options
		)
	end
end

return spawn_requests
