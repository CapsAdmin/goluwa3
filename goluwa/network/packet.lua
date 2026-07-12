local packet = library()
import.loaded["goluwa/network/packet.lua"] = packet
local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local clients = import("goluwa/network/clients.lua")
local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
packet.listeners = packet.listeners or {}

function packet.AddListener(id, callback)
	packet.listeners[id] = callback
end

function packet.RemoveListener(id)
	packet.listeners[id] = nil
end

local function prepend_header(id, buffer)
	if CLIENT then id = network.StringToID(id) end

	if SERVER then id = network.AddString(id) end

	if not id then return end

	-- Create a new buffer with the header prepended
	local header_buf = packet.CreateBuffer():WriteI16(id)
	local result = packet.CreateBuffer()

	-- Write header bytes first
	for _, byte in ipairs(header_buf.buffer) do
		result:WriteByte(byte)
	end

	-- Write original buffer bytes
	if buffer.buffer then
		for _, byte in ipairs(buffer.buffer) do
			result:WriteByte(byte)
		end
	end

	return result:GetString()
end

local function read_header(buffer)
	local id = buffer:ReadI16()
	id = network.IDToString(id)
	list.remove(buffer.buffer, 1)
	list.remove(buffer.buffer, 1)
	buffer:SetPosition(0)
	return id
end

if CLIENT then
	function packet.Send(id, buffer, flags, channel)
		flags = flags or "unsequenced"
		local data = prepend_header(id, buffer)

		if data then network.SendPacketToHost(data, flags, channel) end
	end

	function packet.OnPacketReceived(str)
		local buffer = packet.CreateBuffer(str)
		local id = read_header(buffer)

		if packet.listeners[id] then packet.listeners[id](buffer) end
	end

	event.AddListener(
		"NetworkPacketReceived",
		"packet",
		packet.OnPacketReceived,
		{on_error = system.OnError}
	)
end

if SERVER then
	function packet.Send(id, buffer, filter, flags, channel)
		flags = flags or "unsequenced"
		local data = prepend_header(id, buffer)

		if data then
			if typex(filter) == "client" then
				network.SendPacketToPeer(filter.socket, data, flags, channel)
			elseif typex(filter) == "client_filter" then
				for _, client in pairs(filter:GetAll()) do
					network.SendPacketToPeer(client.socket, data, flags, channel)
				end
			else
				for _, client in ipairs(clients.GetAll()) do
					if client.socket:IsValid() then
						network.SendPacketToPeer(client.socket, data, flags, channel)
					end
				end
			end
		end
	end

	function packet.Broadcast(id, buffer, flags, channel)
		return packet.Send(id, buffer, flags, channel)
	end

	function packet.OnPacketReceived(str, client)
		local buffer = packet.CreateBuffer(str)
		local id = read_header(buffer)

		if packet.listeners[id] then packet.listeners[id](buffer, client) end
	end

	event.AddListener(
		"NetworkPacketReceived",
		"packet",
		packet.OnPacketReceived,
		{on_error = system.OnError}
	)
end

do -- buffer object
	local META = objects.CreateTemplate("packet_buffer")

	-- byte
	function META:WriteByte(byte)
		list.insert(self.buffer, byte)
		return self
	end

	function META:ReadByte()
		local val = self.buffer[self.position]
		self.position = self.position + 1
		return val
	end

	-- this adds ReadI32, WriteI16, WriteFloat, WriteStructure, etc
	local buffer_template = import("goluwa/buffer_template.lua")
	buffer_template.AddBasicFunctions(META)
	buffer_template.AddBasicDataTypes(META)
	buffer_template.AddStringFunctions(META)
	buffer_template.AddStructFunctions(META)

	do -- generic
		function META:GetBuffer()
			return self.buffer
		end

		function META:GetSize()
			return #self.buffer
		end

		function META:TheEnd()
			return self:GetPosition() > self:GetSize()
		end

		function META:Clear()
			list.clear(self.buffer)
			self.position = 0
		end

		function META:GetString()
			local temp = {}

			for _, v in ipairs(self.buffer) do
				temp[#temp + 1] = string.char(v)
			end

			return list.concat(temp)
		end

		function META:GetStringSlice(start, stop)
			start = start or 1
			stop = stop or self:GetSize()

			if start > self:GetSize() then return "" end

			stop = math.min(stop, self:GetSize())
			local temp = {}

			for i = start, stop do
				temp[#temp + 1] = string.char(self.buffer[i])
			end

			return list.concat(temp)
		end

		function META:SetPosition(pos)
			self.position = math.clamp(pos, 1, self:GetSize())
			return self:GetPosition()
		end

		function META:GetPosition()
			return self.position
		end

		do -- push pop position
			function META:PushPosition(pos)
				self.stack = self.stack or {}
				list.insert(self.stack, self:GetPosition())
				self:SetPosition(pos)
			end

			function META:PopPosition()
				self:SetPosition(list.remove(self.stack))
			end
		end

		function META:Advance(i)
			i = i or 1
			self:SetPosition(self:GetPosition() + i)
		end

		META.__len = META.GetSize

		function META:GetDebugString()
			return self:GetString():hex_readable()
		end

		function META:AddHeader(buffer)
			for i, b in ipairs(buffer.buffer) do
				list.insert(self.buffer, i, b)
			end

			return self
		end
	end

	META.WriteNetString = function(self, str)
		self:WriteI16(network.AddString(str))
	end
	META.ReadNetString = function(self)
		return network.IDToString(self:ReadI16())
	end

	function packet.CreateBuffer(val)
		local self = META:CreateObject()

		if type(val) == "string" or type(val) == "table" or not val then
			self.buffer = {}
			self.position = 1

			if type(val) == "table" then
				self:WriteStructure(val)
			elseif val then
				self:WriteBytes(val)
			end
		end

		return self
	end

	-- this must be done shared or else you'll mess up Write/ReadType on the other side
	function packet.ExtendBuffer(name, write_callback, read_callback)
		META["Read" .. name] = read_callback
		META["Write" .. name] = write_callback
		META:GenerateTypes()
		objects.Register(META, true)
	end

	objects.Register(META)
end

return packet
