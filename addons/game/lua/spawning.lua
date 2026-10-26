local packet = import("goluwa/network/packet.lua")
local SpawnPoint = import("goluwa/entities/components/spawn_point.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local FALLBACK_POSITION = Vec3(0, 3, 0)
local spawning = {}

function spawning.Pick()
	local spawn = SpawnPoint.Pick("deathmatch", "start") or SpawnPoint.Pick()

	if spawn then return spawn:GetPlacement(0) end

	return FALLBACK_POSITION:Copy(), Quat():Identity()
end

function spawning.SendStart(client, entity, position, rotation)
	local start = packet.CreateBuffer()
	start:WriteI32(entity.network.NetworkId)
	start:WriteVec3(position)
	start:WriteQuat(rotation)
	packet.Send("player_start", start, client, "reliable")
end

return spawning
