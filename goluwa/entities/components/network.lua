local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local network = import("goluwa/network/network.lua")
local packet = import("goluwa/network/packet.lua")
local message = import("goluwa/network/message.lua")
local clients = import("goluwa/network/clients.lua")
local Entity = import("goluwa/entities/entity.lua")
local META = objects.CreateTemplate("network")
META.Network = {
	Name = {"string", 0.5, "reliable"},
	Parent = {"entity", 0.5, "reliable"},
}
META:GetSet("NetworkId", -1)
META:GetSet("NetworkChannel", 0)
META:GetSet("NetworkOwner", "")
META:GetSet("Debug", false)
local spawned = {}
local queued_packets = {}
local next_id = 1
local client_version = 0
local SPAWN = "entity_networked_spawn"
local REMOVE = "entity_networked_remove"
local UPDATE = "entity_networked_update"
local COMPONENT_ADDED = "entity_networked_component_added"
local COMPONENT_REMOVED = "entity_networked_component_removed"
local PACKET = "ecs_network"
local CALL = "ecs_network_call_on_client"
local MAX_QUEUED_PACKETS = 512
local SPAWNS_PER_FRAME = 32
local INTERP_DELAY = 0.1
local MAX_SAMPLES = 16
local SNAP_DISTANCE = 50
local get_time = system.GetTime

function META.GetByNetworkId(id)
	return spawned[id]
end

function META.GetAllNetworked()
	return spawned
end

function META:GetTarget(component_name)
	if component_name == "entity" then return self.Owner end

	return self.Owner[component_name]
end

function META:Initialize()
	self.vars = {}
	self.var_map = {}
	self.known_components = {}
	self.component_count = -1
	self.call_on_client_persist = {}
	self.pending_clients = {}
end

local function copy_value(value)
	if type(value) == "cdata" then return value:Copy() end

	return value
end

local function write_value(buffer, var, value)
	local sub = packet.CreateBuffer()
	sub:WriteType(value, var.type, typex)
	buffer:WriteNetString(var.key2)
	buffer:WriteU16(sub:GetSize())
	buffer:WriteBytes(sub:GetString())
end

local function get_component_definition(name)
	if name == "entity" then return META.Network end

	return Entity.GetValidComponents()[name].Network
end

local function create_var(name, key, info, target)
	local key2 = name .. key
	return {
		component = name,
		key = key,
		key2 = key2,
		get_name = target["Get" .. key] and "Get" .. key or "Is" .. key,
		set_name = "Set" .. key,
		type = info[1],
		rate = info[2],
		flags = info[3],
		interp = info[4],
		client = info.client,
		next_send = 0,
	}
end

function META:RefreshVars()
	local owner = self.Owner
	local count = #owner.component_list

	if self.component_count == count then return end

	self.component_count = count
	local present = {entity = true}
	local added = {}

	for name, component in pairs(owner.component_map) do
		if component == self then name = "entity" else present[name] = true end

		local definition = component.Network

		if definition then
			if not self.known_components[name] then
				self.known_components[name] = true
				added[#added + 1] = name
			end

			for key, info in pairs(definition) do
				local key2 = name .. key

				if not self.var_map[key2] then
					local var = create_var(name, key, info, component == self and owner or component)

					if SERVER then network.AddString(key2) end

					self.var_map[key2] = var
					list.insert(self.vars, var)
				end
			end
		end
	end

	local removed = {}

	for name in pairs(self.known_components) do
		if not present[name] then
			removed[#removed + 1] = name
			self.known_components[name] = nil

			for i = #self.vars, 1, -1 do
				local var = self.vars[i]

				if var.component == name then
					self.var_map[var.key2] = nil
					table.remove(self.vars, i)
				end
			end
		end
	end

	return added, removed
end

if SERVER then
	local pending_spawns = {}
	local awaiting_world = {}

	event.AddListener("ClientEntered", "network_component_entered", function(client)
		client.network_entered = true
		client_version = client_version + 1

		if not client:IsBot() then awaiting_world[client] = true end
	end)

	function META:GetSendFilter()
		if self.filter_version ~= client_version then
			self.filter_version = client_version
			local filter = clients.CreateFilter()

			for _, client in ipairs(clients.GetAll()) do
				if
					client.network_entered and
					not client:IsBot()
					and
					client:GetUniqueID() ~= self.NetworkOwner and
					not self.pending_clients[client]
				then
					filter:Add(client)
				end
			end

			self.filter = filter
		end

		return self.filter
	end

	function META:IsOwnedBy(client)
		return self.NetworkOwner == client:GetUniqueID()
	end

	function META:WriteComponent(buffer, name)
		local body = packet.CreateBuffer()
		local count = 0
		local target = self:GetTarget(name)

		for _, var in ipairs(self.vars) do
			if var.component == name then
				local value = target[var.get_name](target)

				if value ~= nil then
					write_value(body, var, value)
					count = count + 1
				end
			end
		end

		buffer:WriteNetString(name)
		buffer:WriteI32(body:GetSize() + 1)
		buffer:WriteByte(count)
		buffer:WriteBytes(body:GetString())
	end

	function META:SnapshotLast(name)
		for _, var in ipairs(self.vars) do
			if not name or var.component == name then
				local target = self:GetTarget(var.component)
				var.last = copy_value(target[var.get_name](target))
			end
		end
	end

	function META:SendSpawn(client)
		local buffer = packet.CreateBuffer()
		buffer:WriteNetString(SPAWN)
		buffer:WriteI32(self.NetworkId)
		buffer:WriteString(self.NetworkOwner)
		local names = {}

		for name in pairs(self.known_components) do
			names[#names + 1] = name
		end

		table.sort(names)
		buffer:WriteByte(#names)

		for _, name in ipairs(names) do
			self:WriteComponent(buffer, name)
		end

		packet.Send(PACKET, buffer, client or self:GetSendFilter(), "reliable", self.NetworkChannel)
	end

	function META:SendComponentAdded(name)
		local buffer = packet.CreateBuffer()
		buffer:WriteNetString(COMPONENT_ADDED)
		buffer:WriteI32(self.NetworkId)
		self:WriteComponent(buffer, name)
		packet.Send(PACKET, buffer, self:GetSendFilter(), "reliable", self.NetworkChannel)
		self:SnapshotLast(name)
	end

	function META:SendComponentRemoved(name)
		local buffer = packet.CreateBuffer()
		buffer:WriteNetString(COMPONENT_REMOVED)
		buffer:WriteI32(self.NetworkId)
		buffer:WriteString(name)
		packet.Send(PACKET, buffer, self:GetSendFilter(), "reliable", self.NetworkChannel)
	end

	do
		local reliable = {}
		local sequenced = {}

		local function send_batch(self, batch, count, flags, filter)
			if count == 0 then return end

			local buffer = packet.CreateBuffer()
			buffer:WriteNetString(UPDATE)
			buffer:WriteI32(self.NetworkId)
			buffer:WriteByte(count)

			for i = 1, count do
				write_value(buffer, batch[i * 2 - 1], batch[i * 2])
			end

			packet.Send(PACKET, buffer, filter, flags, self.NetworkChannel)

			if self.Debug then
				llog("%s: sent %i vars (%i bytes, %s)", self, count, buffer:GetSize(), flags)
			end
		end

		function META:UpdateVars()
			local added, removed = self:RefreshVars()

			if added and self.spawned then
				for _, name in ipairs(added) do
					if name ~= "entity" then self:SendComponentAdded(name) end
				end

				for _, name in ipairs(removed) do
					self:SendComponentRemoved(name)
				end
			end

			local now = get_time()
			local reliable_count = 0
			local sequenced_count = 0

			for _, var in ipairs(self.vars) do
				if now >= var.next_send then
					var.next_send = now + var.rate
					local target = self:GetTarget(var.component)
					local value = target[var.get_name](target)

					if value ~= nil and value ~= var.last then
						if var.flags == "reliable" then
							reliable_count = reliable_count + 1
							reliable[reliable_count * 2 - 1] = var
							reliable[reliable_count * 2] = value
						else
							sequenced_count = sequenced_count + 1
							sequenced[sequenced_count * 2 - 1] = var
							sequenced[sequenced_count * 2] = value
						end

						var.last = copy_value(value)
					end
				end
			end

			if reliable_count + sequenced_count == 0 then return end

			local filter = self:GetSendFilter()
			send_batch(self, reliable, reliable_count, "reliable", filter)
			send_batch(self, sequenced, sequenced_count, "sequenced", filter)
		end
	end

	function META:OnAdd()
		self.NetworkId = next_id
		next_id = next_id + 1
		spawned[self.NetworkId] = self
		self:AddGlobalEvent("Update")
		self:AddGlobalEvent("ClientEntered")
		self:AddGlobalEvent("ClientLeft")
		self:RefreshVars()
		self:SendSpawn()
		self:SnapshotLast()
		self.spawned = true
	end

	function META:OnUpdate()
		self:UpdateVars()
	end

	function META:OnClientEntered(client)
		if client:IsBot() or self:IsOwnedBy(client) then return end

		self.pending_clients[client] = true
		client_version = client_version + 1
		pending_spawns[#pending_spawns + 1] = {self, client}
	end

	function META:OnClientLeft()
		client_version = client_version + 1
	end

	event.AddListener("Update", "network_component_spawn_queue", function()
		if not pending_spawns[1] then return end

		local count = math.min(#pending_spawns, SPAWNS_PER_FRAME)

		for i = 1, count do
			local self, client = unpack(pending_spawns[i])
			self.pending_clients[client] = nil

			if self:IsValid() and client:IsValid() then
				self:SendSpawn(client)
				self:SendPersistentCalls(client)
			end
		end

		client_version = client_version + 1
		local total = #pending_spawns
		table.move(pending_spawns, count + 1, total, 1)

		for i = total - count + 1, total do
			pending_spawns[i] = nil
		end
	end)

	event.AddListener("Update", "network_component_world_ready", function()
		if not next(awaiting_world) then return end

		local pending = {}

		for i = 1, #pending_spawns do
			pending[pending_spawns[i][2]] = true
		end

		for client in pairs(awaiting_world) do
			if not pending[client] then
				awaiting_world[client] = nil

				if client:IsValid() then event.Call("ClientWorldReady", client) end
			end
		end
	end)

	function META:OnRemove()
		if spawned[self.NetworkId] == self then
			local buffer = packet.CreateBuffer()
			buffer:WriteNetString(REMOVE)
			buffer:WriteI32(self.NetworkId)
			packet.Send(PACKET, buffer, self:GetSendFilter(), "reliable", self.NetworkChannel)
			spawned[self.NetworkId] = nil
		end
	end

	function META:CallOnClient(filter, component, name, ...)
		message.Send(CALL, filter, self.NetworkId, component, name, ...)
	end

	function META:CallOnClients(component, name, ...)
		message.Send(CALL, self:GetSendFilter(), self.NetworkId, component, name, ...)
	end

	function META:CallOnClientsPersist(component, name, ...)
		list.insert(self.call_on_client_persist, {component, name, ...})
		return self:CallOnClients(component, name, ...)
	end

	function META:SendPersistentCalls(client)
		for _, args in ipairs(self.call_on_client_persist) do
			self:CallOnClient(client, unpack(args))
		end
	end
end

if CLIENT then
	function META:OnAdd()
		assert(self.NetworkId ~= -1, "networked entities can only be created by the server")
		spawned[self.NetworkId] = self
		self:AddGlobalEvent("Update")
		self:RefreshVars()
	end

	function META:OnRemove()
		if spawned[self.NetworkId] == self then spawned[self.NetworkId] = nil end
	end

	function META:ApplyVar(var, value)
		if var.client then value = var.client(value) end

		if var.interp and type(value) ~= "string" and type(value) ~= "boolean" then
			local samples = var.samples

			if not samples then
				samples = {}
				var.samples = samples
				local target = self:GetTarget(var.component)
				target[var.set_name](target, copy_value(value))
				var.applied = copy_value(value)
			end

			local last = samples[#samples]
			local snap = false

			if last and var.type == "vec3" then
				snap = (value - last.value):GetLength() > SNAP_DISTANCE
			end

			samples[#samples + 1] = {t = get_time(), value = copy_value(value), snap = snap}

			if #samples > MAX_SAMPLES then table.remove(samples, 1) end
		else
			local target = self:GetTarget(var.component)
			target[var.set_name](target, value)
		end

		if self.Debug then llog("%s: received %s = %s", self, var.key2, value) end
	end

	function META:OnUpdate()
		local render_time = get_time() - INTERP_DELAY

		for _, var in ipairs(self.vars) do
			local samples = var.samples

			if samples then
				local count = #samples
				local value

				if count == 1 or render_time >= samples[count].t then
					value = samples[count].value
				elseif render_time <= samples[1].t then
					value = samples[1].value
				else
					for i = 1, count - 1 do
						local a, b = samples[i], samples[i + 1]

						if render_time <= b.t then
							local fraction = (render_time - a.t) / math.max(b.t - a.t, 0.0001)

							if b.snap then
								value = fraction < 1 and a.value or b.value
							elseif type(a.value) == "number" then
								value = a.value + (b.value - a.value) * fraction
							elseif var.type == "quat" then
								value = a.value:Interpolate(b.value, fraction)
							else
								value = a.value:Copy():Lerp(fraction, b.value)
							end

							for _ = 2, i do
								table.remove(samples, 1)
							end

							break
						end
					end
				end

				if value ~= nil and value ~= var.applied then
					var.applied = copy_value(value)
					local target = self:GetTarget(var.component)
					target[var.set_name](target, copy_value(value))
				end
			end
		end
	end

	local function get_vars_by_key(name)
		local vars = {}

		for key, info in pairs(get_component_definition(name)) do
			vars[name .. key] = {key = key, type = info[1], client = info.client}
		end

		return vars
	end

	local function read_component(buffer)
		local name = buffer:ReadNetString()
		local length = buffer:ReadI32()
		local body = packet.CreateBuffer(buffer:ReadBytes(length))

		if name ~= "entity" and not Entity.GetValidComponents()[name] then
			return name
		end

		local vars = get_vars_by_key(name)
		local values = {}

		for _ = 1, body:ReadByte() do
			local key2 = body:ReadNetString()
			local data = body:ReadBytes(body:ReadU16())
			local info = vars[key2]

			if info then
				local value = packet.CreateBuffer(data):ReadType(info.type)

				if info.client then value = info.client(value) end

				values[info.key] = value
			end
		end

		return name, values
	end

	local function handle_packet(buffer)
		local what = buffer:ReadNetString()
		local id = buffer:ReadI32()
		local self = spawned[id]

		if what == SPAWN then
			local config = {network = {NetworkId = id, NetworkOwner = buffer:ReadString()}}

			for _ = 1, buffer:ReadByte() do
				local name, values = read_component(buffer)

				if values then
					if name == "entity" then
						for key, value in pairs(values) do
							if key == "Parent" then
								if value:IsValid() then config.Parent = value end
							else
								config[key] = value
							end
						end
					elseif name ~= "network" then
						config[name] = values
					end
				end
			end

			if self then self.Owner:Remove() end

			Entity.New(config)
			return true
		end

		if not self then return false end

		if what == REMOVE then
			self.Owner:Remove()
			return true
		end

		if what == COMPONENT_ADDED then
			local name, values = read_component(buffer)

			if values and not self.Owner:HasComponent(name) then
				self.Owner:AddComponent(name, values)
			end

			return true
		end

		if what == COMPONENT_REMOVED then
			local name = buffer:ReadString()

			if self.Owner:HasComponent(name) then self.Owner:RemoveComponent(name) end

			return true
		end

		if what == UPDATE then
			self:RefreshVars()

			for _ = 1, buffer:ReadByte() do
				local key2 = buffer:ReadNetString()
				local data = buffer:ReadBytes(buffer:ReadU16())
				local var = self.var_map[key2]

				if var then self:ApplyVar(var, packet.CreateBuffer(data):ReadType(var.type)) end
			end

			return true
		end

		error("unknown ecs network packet " .. tostring(what))
	end

	packet.AddListener(PACKET, function(buffer)
		if not handle_packet(buffer) then
			if #queued_packets < MAX_QUEUED_PACKETS then
				buffer:SetPosition(1)
				buffer.queued_retries = 0
				list.insert(queued_packets, buffer)
			end
		end
	end)

	event.AddListener("Update", "network_component_queue", function()
		if not queued_packets[1] then return end

		local pending = queued_packets
		queued_packets = {}

		for _, buffer in ipairs(pending) do
			buffer:SetPosition(1)
			buffer.queued_retries = buffer.queued_retries + 1

			if not handle_packet(buffer) and buffer.queued_retries < 120 then
				list.insert(queued_packets, buffer)
			end
		end
	end)

	event.AddListener("Disconnected", "network_component", function()
		for _, component in pairs(spawned) do
			component.Owner:Remove()
		end

		queued_packets = {}
	end)

	message.AddListener(CALL, function(id, component, name, ...)
		local self = spawned[id]

		if not self then
			llog("call on client: entity (%s) does not exist", id)
			return
		end

		local target = self:GetTarget(component)
		assert(target, "call on client: component " .. component .. " does not exist")
		assert(target[name], "call on client: " .. name .. " does not exist in " .. component)
		target[name](target, ...)
	end)
end

function META.WriteEntity(buffer, ent)
	local component = ent:IsValid() and ent.network
	buffer:WriteI32(component and component.NetworkId or -1)
end

function META.ReadEntity(buffer)
	local component = spawned[buffer:ReadI32()]

	if component then return component.Owner end

	return NULL
end

return META:Register()
