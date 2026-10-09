local event = import("goluwa/event.lua")
local message = import("goluwa/network/message.lua")
local objects = import("goluwa/objects/objects.lua")
local network_component = import("goluwa/entities/components/network.lua")
local use = import("goluwa/entities/use.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MESSAGE = "entity_use"

-- an entity is addressed by the nearest entity every process knows, its network id or guid
local function get_address(entity)
	local current = entity

	while current:IsValid() do
		if current.network then
			return current.network:GetNetworkId()
		elseif not current:GetTransient() then
			return current:GetGUID()
		end

		current = current:GetParent()
	end
end

local function resolve(key)
	local entity

	if type(key) == "number" then
		local component = network_component.GetByNetworkId(key)
		entity = component and component.Owner
	else
		entity = objects.GetObjectByGUID(key)
	end

	if entity and entity:IsValid() then return entity end
end

if SERVER then
	event.AddListener("EntityUsed", "use_sync", function(entity, user, hit)
		local key = get_address(entity)

		if not key then return end

		local point = hit.point or hit.position or Vec3()
		message.Broadcast(
			MESSAGE,
			{
				key = key,
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
		local entity = resolve(params.key)

		if not entity then return end

		local user = params.user and resolve(params.user)
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
