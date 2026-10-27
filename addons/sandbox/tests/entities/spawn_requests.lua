local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local objects = import("goluwa/objects/objects.lua")
import("addons/game/lua/autorun/characters.lua")
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/weapons.lua")
import("lua/interactives.lua")
local spawn_requests = import("lua/spawn_requests.lua")
local history = import("lua/game_history.lua").history

local function find(name)
	for _, entity in ipairs(Entity.World:GetChildrenList()) do
		if entity:GetName() == name then return entity end
	end

	return NULL
end

T.Test("spawn requests spawn locally when there is no server and can be undone", function()
	local player = Entity.New{ComponentSet = {"transform", "weapon_holder"}}
	_G.PLAYER_RIG = player
	local before = #history:GetEntries()
	spawn_requests.Spawn("weapon", "weapon_grenade", Vec3(0, 0, 3), 0)
	local weapon = find("weapon_grenade")
	T(weapon:IsValid())["=="](true)
	T(#history:GetEntries())["=="](before + 1)
	T(history:Undo())["=="](true)
	T(find("weapon_grenade"):IsValid())["=="](false)
	T(history:Redo())["=="](true)
	T(find("weapon_grenade"):IsValid())["=="](true)
	find("weapon_grenade"):Remove()
	player:Remove()
	_G.PLAYER_RIG = nil
end)

T.Test("spawn requests only know how to spawn what the sandbox offers", function()
	T(spawn_requests.IsValid("weapon", "weapon_grenade"))["=="](true)
	T(spawn_requests.IsValid("weapon", "weapon_nonexistent"))["=="](false)
	T(spawn_requests.IsValid("interactive", "door"))["=="](true)
	T(spawn_requests.IsValid("interactive", "lamp_nonexistent"))["=="](false)
	T(spawn_requests.IsValid("prop", "models/props_c17/oildrum001.mdl"))["=="](true)
	T(spawn_requests.IsValid("prop", "../../etc/passwd"))["=="](false)
	T(spawn_requests.IsValid("prop", "models/../secret.mdl"))["=="](false)
	T(spawn_requests.IsValid("nothing", "x"))["=="](false)
end)
