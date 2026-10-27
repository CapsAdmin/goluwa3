local objects = import("goluwa/objects/objects.lua")
local message = import("goluwa/network/message.lua")
local network = import("goluwa/network/network.lua")
local clients = import("goluwa/network/clients.lua")
local permissions = import("goluwa/entities/permissions.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
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
local weapon_offset = Vec3(0, 0.3, 0)
local interactive_names = {}

for _, name in ipairs(interactives.Names) do
	interactive_names[name] = true
end

local spawners = {}
local validators = {}

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

function spawners.weapon(player, name, position, yaw, done)
	local holder = player.weapon_holder
	local existing = holder:FindWeapon(name)

	if existing then
		holder:Equip(existing, existing.weapon:GetDefaultPlace())
		return
	end

	done(weapons.Spawn(name, position + weapon_offset, QuatFromAxis(yaw, Vec3(0, 1, 0))))
end

function spawners.interactive(player, name, position, yaw, done)
	done(interactives.Spawn(name, position, yaw))
end

function spawners.vehicle(player, name, position, yaw, done)
	done(vehicles.Spawn(name, position, yaw))
end

function spawners.npc(player, name, position, yaw, done)
	local npc = npcs.Spawn(name, position, yaw)
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

if SERVER then
	message.AddListener("sandbox_spawn", function(client, id, kind, name, position, yaw)
		local player = _G.GetPlayerEntity(client)

		if not (player and player:IsValid()) then return end

		if
			type(id) ~= "number" or
			type(kind) ~= "string" or
			type(name) ~= "string" or
			#name > MAX_NAME_LENGTH or
			typex(position) ~= "vec3" or
			type(yaw) ~= "number"
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
				message.Send("sandbox_spawned", client, id, entity:GetGUID())
			end
		)
	end)

	message.AddListener("sandbox_remove", function(client, guid)
		if type(guid) ~= "string" then return end

		local entity = objects.GetObjectByGUID(guid)

		if entity:IsValid() and permissions.Can(client, "remove", entity) then
			entity:Remove()
		end
	end)
end

if CLIENT then
	local pending = {}
	local next_id = 0

	message.AddListener("sandbox_spawned", function(id, guid)
		local callback = pending[id]
		pending[id] = nil

		if callback then callback(guid) end
	end)

	local function request(kind, name, position, yaw, on_spawn)
		if network.IsConnected() then
			next_id = next_id + 1
			pending[next_id] = on_spawn
			message.Send("sandbox_spawn", next_id, kind, name, position, yaw)
			return
		end

		spawners[kind](
			_G.PLAYER_RIG,
			name,
			position,
			yaw,
			function(entity)
				entity:SetOwnedBy(clients.GetLocalClient())
				on_spawn(entity:GetGUID(), entity)
			end
		)
	end

	function spawn_requests.Spawn(label, kind, name, position, yaw)
		request(
			kind,
			name,
			position,
			yaw,
			function(guid, entity)
				if entity then
					game_history.RecordSpawn(label, entity)
					return
				end

				game_history.history:Push{
					Name = label,
					Undo = function()
						message.Send("sandbox_remove", guid)
					end,
					Redo = function()
						request(kind, name, position, yaw, function(new_guid)
							guid = new_guid
						end)
					end,
				}
			end
		)
	end
end

return spawn_requests
