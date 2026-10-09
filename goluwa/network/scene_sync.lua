local event = import("goluwa/event.lua")
local message = import("goluwa/network/message.lua")
local packet = import("goluwa/network/packet.lua")
local Entity = import("goluwa/entities/entity.lua")
local scene = import("goluwa/entities/scene.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local scene_sync = library()
local BLOB_BEGIN = "scene_blob_begin"
local BLOB_CHUNK = "scene_blob_chunk"
local READY = "scene_ready"
local PROPERTY = "scene_property"
local REMOVE = "scene_remove"
local CHUNK_SIZE = 16384
local CHUNKS_PER_FRAME = 4
local CHANNEL = 15
local SERVER_SENDER = "server"
local outgoing = {}
local incoming = {}
local handlers = {}
local next_id = 1
local LOG_SIZE = 8
scene_sync.stats = {
	state = "none",
	kind = "",
	received = 0,
	size = 0,
	checksum = 0,
	records = 0,
	snapshot_bytes = 0,
	snapshot_time = 0,
	deltas = 0,
	delta_bytes = 0,
	last_delta = "",
	applies = 0,
	removes = 0,
	pushes = 0,
	push_bytes = 0,
	log = {},
}

local function note(...)
	local log = scene_sync.stats.log
	log[#log + 1] = {time = system.GetTime(), text = string.format(...)}

	if #log > LOG_SIZE then table.remove(log, 1) end
end

local function send_packet(id, buffer, target)
	if SERVER then
		packet.Send(id, buffer, target, "reliable", CHANNEL)
	else
		packet.Send(id, buffer, "reliable", CHANNEL)
	end
end

local function send_chunk(blob)
	local chunk = blob.payload:sub(blob.offset, blob.offset + CHUNK_SIZE - 1)
	local buffer = packet.CreateBuffer()
	buffer:WriteU32(blob.id)
	buffer:WriteU32(#chunk)
	buffer:WriteBytes(chunk)
	send_packet(BLOB_CHUNK, buffer, blob.target)
	blob.offset = blob.offset + #chunk
	return blob.offset > #blob.payload
end

-- a paced blob is streamed a few chunks per frame, otherwise it is sent at once so it stays ordered with the packets sent after it
local function send_blob(target, kind, payload, parent_guid, paced)
	local blob = {target = target, id = next_id, payload = payload, offset = 1}
	next_id = next_id + 1
	local buffer = packet.CreateBuffer()
	buffer:WriteString(kind)
	buffer:WriteU32(blob.id)
	buffer:WriteU32(#payload)
	buffer:WriteU32(scene.GetChecksum(payload))
	buffer:WriteString(parent_guid or "")
	send_packet(BLOB_BEGIN, buffer, target)

	if paced then
		outgoing[#outgoing + 1] = blob
	else
		while not send_chunk(blob) do

		end
	end

	return blob.id
end

local function resolve_parent(guid)
	if guid == "" then return Entity.World end

	local parent = objects.GetObjectByGUID(guid)
	assert(parent and parent:IsValid(), "scene parent " .. guid .. " does not exist")
	return parent
end

packet.AddListener(BLOB_BEGIN, function(buffer, client)
	local sender = client or SERVER_SENDER
	incoming[sender] = incoming[sender] or {}
	local kind = buffer:ReadString()
	local id = buffer:ReadU32()
	local blob = {
		kind = kind,
		id = id,
		size = buffer:ReadU32(),
		checksum = buffer:ReadU32(),
		parent = buffer:ReadString(),
		chunks = {},
		received = 0,
		start = system.GetTime(),
	}
	incoming[sender][id] = blob
	local stats = scene_sync.stats
	stats.kind = kind
	stats.size = blob.size
	stats.received = 0
	stats.checksum = blob.checksum

	if kind == "snapshot" then stats.state = "downloading" end

	note("%s #%d begin %d bytes crc %08x", kind, id, blob.size, blob.checksum)
end)

packet.AddListener(BLOB_CHUNK, function(buffer, client)
	local sender = client or SERVER_SENDER
	local blob = incoming[sender] and incoming[sender][buffer:ReadU32()]

	if not blob then return end

	local chunk = buffer:ReadBytes(buffer:ReadU32())
	blob.chunks[#blob.chunks + 1] = chunk
	blob.received = blob.received + #chunk
	scene_sync.stats.received = blob.received

	if blob.received < blob.size then return end

	incoming[sender][blob.id] = nil
	local payload = table.concat(blob.chunks)
	assert(
		scene.GetChecksum(payload) == blob.checksum,
		"scene checksum differs from the announced one"
	)
	handlers[blob.kind](sender, payload, blob)
end)

event.AddListener("Update", "scene_sync_outgoing", function()
	for i = #outgoing, 1, -1 do
		local blob = outgoing[i]

		if SERVER and not blob.target:IsValid() then
			table.remove(outgoing, i)
		else
			for _ = 1, CHUNKS_PER_FRAME do
				if send_chunk(blob) then
					table.remove(outgoing, i)

					break
				end
			end
		end
	end
end)

if SERVER then
	local clients = import("goluwa/network/clients.lua")
	local pvars = import("goluwa/cli/pvars.lua")
	local transfers = {}
	local applying = false
	local push_allowed = pvars.Setup(
		"sv_scene_push",
		true,
		nil,
		"allow clients to send scene entities to the server"
	)

	packet.AddListener(PROPERTY, function() end)

	local function queue_or_send(client, item)
		if client.scene_ready then
			if item.buffer then
				packet.Send(item.id, item.buffer, client, "reliable", CHANNEL)
			else
				send_blob(client, "apply", item.payload, item.parent)
			end
		else
			local transfer = transfers[client]

			if transfer and transfer.id then
				transfer.deltas[#transfer.deltas + 1] = item
			end
		end
	end

	local function on_property_changed(object, var_name, new_value, _, info)
		if applying or not info or not info.storable then return end

		if new_value ~= nil and not scene.IsSerializable(new_value) then return end

		local entity = object.component_map and object or object.Owner
		local encoded = scene.EncodeValue(new_value)
		local buffer = packet.CreateBuffer()
		buffer:WriteString(entity:GetGUID())
		buffer:WriteString(entity == object and "" or object.Type)
		buffer:WriteString(var_name)
		buffer:WriteU32(#encoded)
		buffer:WriteBytes(encoded)
		local item = {id = PROPERTY, buffer = buffer}

		for _, client in ipairs(clients.GetAll()) do
			queue_or_send(client, item)
		end
	end

	local function attach_listeners(entity)
		if not entity.network then
			entity:AddPropertyListener(on_property_changed, "scene_sync")

			for _, component in pairs(entity.component_map) do
				component:AddPropertyListener(on_property_changed, "scene_sync")
			end
		end

		for _, child in ipairs(entity:GetChildren()) do
			attach_listeners(child)
		end
	end

	local function restart(client)
		client.scene_ready = nil
		transfers[client] = {waiting = true}
	end

	event.AddListener("ClientEntered", "scene_sync", function(client)
		if not client:IsBot() then restart(client) end
	end)

	event.AddListener("ClientLeft", "scene_sync", function(client)
		transfers[client] = nil
		incoming[client] = nil
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
		if scene_loading.IsLoading() or scene.IsSpawning() then return end

		for client, transfer in pairs(transfers) do
			if not client:IsValid() then
				transfers[client] = nil
			elseif transfer.waiting then
				for _, root in ipairs(scene.GetRoots()) do
					attach_listeners(root)
				end

				transfer.waiting = nil
				transfer.deltas = {}
				transfer.id = send_blob(
					client,
					"snapshot",
					scene.Encode(scene.SerializeEntities(scene.GetRoots())),
					"",
					true
				)
			end
		end
	end)

	message.AddListener(READY, function(client, id)
		local transfer = transfers[client]

		if not transfer or transfer.id ~= id then return end

		transfers[client] = nil
		client.scene_ready = true

		for _, item in ipairs(transfer.deltas) do
			queue_or_send(client, item)
		end

		event.Call("ClientSceneReady", client)
	end)

	packet.AddListener(REMOVE, function(buffer, client)
		if not push_allowed:Get() then
			wlog("%s tried to remove a scene entity but sv_scene_push is off", client)
			return
		end

		local guid = buffer:ReadString()
		local entity = objects.GetObjectByGUID(guid)
		assert(entity and entity:IsValid(), "scene entity " .. guid .. " does not exist")
		assert(
			entity ~= Entity.World and
				not entity:GetSingleton()
				and
				not entity:GetTransient(),
			"scene entity " .. guid .. " cannot be removed"
		)
		applying = true
		entity:Remove()
		applying = false
		logf("%s removed scene entity %s\n", client, guid)
		local forward = packet.CreateBuffer()
		forward:WriteString(guid)
		local item = {id = REMOVE, buffer = forward}

		for _, other in ipairs(clients.GetAll()) do
			if not other:IsBot() then queue_or_send(other, item) end
		end
	end)

	handlers.push = function(client, payload, blob)
		if not push_allowed:Get() then
			wlog("%s tried to push a scene entity but sv_scene_push is off", client)
			return
		end

		local data = scene.Decode(payload)
		local parent = resolve_parent(blob.parent)
		applying = true
		local ok, roots = pcall(scene.Apply, data, parent)
		applying = false

		if not ok then error(roots, 0) end

		for _, root in ipairs(roots) do
			attach_listeners(root)
		end

		logf("%s pushed %i scene records\n", client, #data.entities)
		local item = {payload = payload, parent = blob.parent}

		for _, other in ipairs(clients.GetAll()) do
			if other ~= client and not other:IsBot() then queue_or_send(other, item) end
		end
	end
end

if CLIENT and not SERVER then
	handlers.snapshot = function(_, payload, blob)
		local stats = scene_sync.stats
		local data = scene.Decode(payload)
		stats.state = "spawning"
		stats.records = #data.entities
		scene.Clear()

		scene.SpawnAsync(
			data,
			Entity.World,
			{skip_unavailable = not RENDER_3D},
			function()
				stats.state = "ready"
				stats.snapshot_bytes = blob.size
				stats.snapshot_time = system.GetTime() - blob.start
				note("snapshot ready: %d records in %.2f s", stats.records, stats.snapshot_time)
				message.Send(READY, blob.id)
			end
		)
	end
	handlers.apply = function(_, payload, blob)
		local data = scene.Decode(payload)
		scene.Apply(data, resolve_parent(blob.parent), {skip_unavailable = not RENDER_3D})
		scene_sync.stats.applies = scene_sync.stats.applies + 1
		note(
			"apply %d records under %s",
			#data.entities,
			blob.parent == "" and "world" or blob.parent
		)
	end

	packet.AddListener(PROPERTY, function(buffer)
		local guid = buffer:ReadString()
		local entity = objects.GetObjectByGUID(guid)
		local component_name = buffer:ReadString()
		local var_name = buffer:ReadString()
		local value = scene.DecodeValue(buffer:ReadBytes(buffer:ReadU32()))
		local stats = scene_sync.stats
		stats.deltas = stats.deltas + 1
		stats.delta_bytes = stats.delta_bytes + buffer:GetSize()
		stats.last_delta = guid .. (
				component_name == "" and
				"." or
				"/" .. component_name .. "."
			) .. var_name

		if not entity or not entity:IsValid() then return end

		local target = component_name == "" and entity or entity[component_name]

		if target then target["Set" .. var_name](target, value) end
	end)

	packet.AddListener(REMOVE, function(buffer)
		local guid = buffer:ReadString()
		local entity = objects.GetObjectByGUID(guid)
		scene_sync.stats.removes = scene_sync.stats.removes + 1
		note("remove %s", guid)

		if entity and entity:IsValid() then entity:Remove() end
	end)

	-- removes the entity on the server, which tells every client including this one
	function scene_sync.RemoveOnServer(entity)
		assert(not entity:GetTransient(), "transient entities do not exist on the server")
		local buffer = packet.CreateBuffer()
		buffer:WriteString(entity:GetGUID())
		send_packet(REMOVE, buffer)
		note("remove request %s", entity:GetGUID())
	end

	-- sends the entity and everything below it once, the server applies it and passes it on to the other clients
	function scene_sync.Push(entity)
		local data = scene.SerializeEntities({entity})
		assert(#data.entities > 0, "transient entities cannot be sent to the server")
		local parent = entity:GetParent()
		local payload = scene.Encode(data)
		send_blob(nil, "push", payload, parent == Entity.World and "" or parent:GetGUID())
		scene_sync.stats.pushes = scene_sync.stats.pushes + 1
		scene_sync.stats.push_bytes = scene_sync.stats.push_bytes + #payload
		note("push %s (%d records, %d bytes)", entity:GetGUID(), #data.entities, #payload)
	end
end

return scene_sync
