local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local clients = import("goluwa/network/clients.lua")
local permissions = import("goluwa/entities/permissions.lua")
local pvars = import("goluwa/cli/pvars.lua")
local event = import("goluwa/event.lua")

local function with_policy(value, callback)
	local old = pvars.Get("sv_entity_permissions")
	pvars.SetSession("sv_entity_permissions", value)
	local ok, err = pcall(callback)
	pvars.SetSession("sv_entity_permissions", old)

	if not ok then error(err, 0) end
end

T.Test("Everything is allowed by default", function()
	local client = clients.Create("permission_test_1")
	local other = clients.Create("permission_test_2")
	local entity = Entity.New{}
	entity:SetOwnedBy(other)
	T(permissions.Can(client, "modify", entity))["=="](true)
	T(permissions.Can(client, "remove", entity))["=="](true)
	T(permissions.CanPushPrefab(client, "anything"))["=="](true)
	entity:Remove()
end)

T.Test("The owner policy lets clients change only what they own", function()
	local client = clients.Create("permission_test_3")
	local other = clients.Create("permission_test_4")
	local mine = Entity.New{}
	local theirs = Entity.New{}
	local world = Entity.New{}
	local child = Entity.New{Parent = mine}
	mine:SetOwnedBy(client)
	theirs:SetOwnedBy(other)

	with_policy("owner", function()
		T(permissions.Can(client, "modify", mine))["=="](true)
		T(permissions.Can(client, "remove", child))["=="](true)
		T(permissions.Can(client, "modify", theirs))["=="](false)
		T(permissions.Can(client, "remove", world))["=="](false)
		T(permissions.Can(client, "create", world))["=="](true)
		T(permissions.Can(client, "create", mine))["=="](true)
		T(permissions.Can(client, "create", theirs))["=="](false)
		T(permissions.CanPushPrefab(client, "shared"))["=="](false)
	end)

	for _, entity in ipairs{mine, theirs, world} do
		entity:Remove()
	end
end)

T.Test("A listener decides before the policy", function()
	local client = clients.Create("permission_test_5")
	local entity = Entity.New{}

	event.AddListener("EntityPermission", "permission_test", function(who, action, what)
		if action == "prefab" and what == "mine" then return true end

		if action == "remove" and what == entity then return false end
	end)

	with_policy("owner", function()
		T(permissions.CanPushPrefab(client, "mine"))["=="](true)
		T(permissions.CanPushPrefab(client, "other"))["=="](false)
	end)

	T(permissions.Can(client, "remove", entity))["=="](false)
	event.RemoveListener("EntityPermission", "permission_test")
	entity:Remove()
end)
