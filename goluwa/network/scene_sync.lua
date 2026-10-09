local event = import("goluwa/event.lua")
local message = import("goluwa/network/message.lua")
local packet = import("goluwa/network/packet.lua")
local Entity = import("goluwa/entities/entity.lua")
local scene = import("goluwa/entities/scene.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local BEGIN = "scene_begin"
local CHUNK = "scene_chunk"
local READY = "scene_ready"
local CHUNK_SIZE = 16384
local CHUNKS_PER_FRAME = 4
local CHANNEL = 15

if SERVER then
	local clients = import("goluwa/network/clients.lua")
	local transfers = {}
	local next_id = 1

	packet.AddListener(BEGIN, function() end)

	packet.AddListener(CHUNK, function() end)

	local function restart(client)
		client.scene_ready = nil
		transfers[client] = {waiting = true}
	end

	event.AddListener("ClientEntered", "scene_sync", function(client)
		if not client:IsBot() then restart(client) end
	end)

	event.AddListener("ClientLeft", "scene_sync", function(client)
		transfers[client] = nil
	end)

	event.AddListener("SceneLoad", "scene_sync", function()
		for client in pairs(transfers) do
			restart(client)
		end

		for _, client in ipairs(clients.GetAll()) do
			if client.network_entered and not client:IsBot() then restart(client) end
		end
	end)

	event.AddListener("Update", "scene_sync", function()
		local ready = not scene_loading.IsLoading() and not scene.IsSpawning()

		for client, transfer in pairs(transfers) do
			if not client:IsValid() then
				transfers[client] = nil
			elseif transfer.waiting then
				if ready then
					local payload = scene.Encode(scene.SerializeEntities(scene.GetRoots()))
					transfer.waiting = nil
					transfer.id = next_id
					transfer.payload = payload
					transfer.offset = 1
					next_id = next_id + 1
					local buffer = packet.CreateBuffer()
					buffer:WriteU32(transfer.id)
					buffer:WriteU32(#payload)
					buffer:WriteU32(scene.GetChecksum(payload))
					packet.Send(BEGIN, buffer, client, "reliable", CHANNEL)
				end
			elseif transfer.offset then
				for _ = 1, CHUNKS_PER_FRAME do
					local payload = transfer.payload
					local chunk = payload:sub(transfer.offset, transfer.offset + CHUNK_SIZE - 1)
					local buffer = packet.CreateBuffer()
					buffer:WriteU32(transfer.id)
					buffer:WriteU32(#chunk)
					buffer:WriteBytes(chunk)
					packet.Send(CHUNK, buffer, client, "reliable", CHANNEL)
					transfer.offset = transfer.offset + #chunk

					if transfer.offset > #payload then
						transfer.offset = nil
						transfer.payload = nil

						break
					end
				end
			end
		end
	end)

	message.AddListener(READY, function(client, id)
		local transfer = transfers[client]

		if not transfer or transfer.id ~= id then return end

		transfers[client] = nil
		client.scene_ready = true
		event.Call("ClientSceneReady", client)
	end)
end

if CLIENT and not SERVER then
	local incoming

	packet.AddListener(BEGIN, function(buffer)
		incoming = {
			id = buffer:ReadU32(),
			size = buffer:ReadU32(),
			checksum = buffer:ReadU32(),
			chunks = {},
			received = 0,
		}
	end)

	packet.AddListener(CHUNK, function(buffer)
		local id = buffer:ReadU32()

		if not incoming or incoming.id ~= id then return end

		local chunk = buffer:ReadBytes(buffer:ReadU32())
		incoming.chunks[#incoming.chunks + 1] = chunk
		incoming.received = incoming.received + #chunk

		if incoming.received < incoming.size then return end

		local transfer = incoming
		incoming = nil
		local data, checksum = scene.Decode(table.concat(transfer.chunks))
		assert(checksum == transfer.checksum, "scene checksum differs from the announced one")
		scene.Clear()

		scene.SpawnAsync(
			data,
			Entity.World,
			{skip_unavailable = not RENDER_3D},
			function()
				message.Send(READY, transfer.id)
			end
		)
	end)
end
