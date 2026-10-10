local event = import("goluwa/event.lua")
local message = import("goluwa/network/message.lua")
local objects = import("goluwa/objects/objects.lua")
local network_component = import("goluwa/entities/components/network.lua")
local use = import("goluwa/entities/use.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MESSAGE = "entity_use"

-- an entity is addressed by the nearest entity every process knows, its network id or guid, and the prefab node ids below it
local function get_address(entity)
	local path = {}
	local current = entity

	while current:IsValid() do
		local instance = current.prefab_owner

		if instance then
			table.insert(path, 1, current.prefab_node)
			current = instance.Owner
		elseif current.network then
			return current.network:GetNetworkId(), path
		elseif not current:GetTransient() then
			return current:GetGUID(), path
		else
			path = {}
			current = current:GetParent()
		end
	end
end

local function resolve(key, path)
	local entity

	if type(key) == "number" then
		local component = network_component.GetByNetworkId(key)
		entity = component and component.Owner
	else
		entity = objects.GetObjectByGUID(key)
	end

	if not (entity and entity:IsValid()) then return end

	for _, id in ipairs(path) do
		local instance = entity.prefab

		if not (instance and instance.definition) then return end

		entity = instance:GetNode(id)

		if not (entity and entity:IsValid()) then return end
	end

	return entity
end

if SERVER then
	event.AddListener("EntityUsed", "use_sync", function(entity, user, hit)
		local key, path = get_address(entity)

		if not key then return end

		local point = hit.point or hit.position or Vec3()
		message.Broadcast(
			MESSAGE,
			{
				key = key,
				path = path,
				user = user and get_address(user),
				x = point.x,
				y = point.y,
				z = point.z,
				distance = hit.distance or 0,
			}
		)
	end)
end

if CLIENT then
	message.AddListener(MESSAGE, function(params)
		local entity = resolve(params.key, params.path or {})

		if not entity then return end

		local user = params.user and resolve(params.user, {})
		use.Fire(
			entity,
			user,
			{
				entity = entity,
				point = Vec3(params.x, params.y, params.z),
				distance = params.distance,
			}
		)
	end)
end
