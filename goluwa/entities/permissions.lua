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

-- action is "create" (entity is the parent that gets a child), "modify" or "remove"
-- a listener of EntityPermission returns false to deny or true to allow, before the policy is looked at
function permissions.Can(client, action, entity)
	local result = event.Call("EntityPermission", client, action, entity)

	if result ~= nil then return result end

	if policy:Get() == "all" then return true end

	local owned_by = entity:GetOwnedBy()

	if action == "create" and owned_by == entity.World then return true end

	return owned_by == client
end

-- prefab definitions are shared by everyone, with the owner policy only a listener can allow one (a player's outfit)
function permissions.CanPushPrefab(client, name)
	local result = event.Call("EntityPermission", client, "prefab", name)

	if result ~= nil then return result end

	return policy:Get() == "all"
end

return permissions
