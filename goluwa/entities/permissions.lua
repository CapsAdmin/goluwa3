local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local permissions = {}
local policy = pvars.Setup2{
	key = "sv_entity_permissions",
	category = "Network",
	group = "Server",
	prefix = "sv_",
	default = "all",
	enums = {"all", "owner"},
	help = "who may change entities on the server, all or owner. owner: clients only change what they own and add to the world or to their own entities",
}

function permissions.Can(client, action, entity)
	local result = event.Call("EntityPermission", client, action, entity)

	if result ~= nil then return result end

	if policy:Get() == "all" then return true end

	local owned_by = entity:GetOwnedBy()

	if action == "create" and owned_by == entity.World then return true end

	return owned_by == client
end

function permissions.CanPushPrefab(client, name)
	local result = event.Call("EntityPermission", client, "prefab", name)

	if result ~= nil then return result end

	return policy:Get() == "all"
end

return permissions
