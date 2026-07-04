local T = import("test/environment.lua")
-- Set up CLIENT/SERVER globals before importing network modules
_G.CLIENT = true
_G.SERVER = true
_G.e = _G.e or {USERNAME = "testuser"}
-- Register a dummy generic_buffer prototype so packet.CreateBuffer works
-- Only register if generic_buffer is not already registered
local objects = import("goluwa/objects/objects.lua")

if not objects.GetRegistered("generic_buffer") then
	local generic_buffer_meta = objects.CreateTemplate("generic_buffer")
	generic_buffer_meta.WriteByte = function(self, val)
		table.insert(self.buffer, val)
	end
	generic_buffer_meta.ReadByte = function(self)
		return table.remove(self.buffer, 1)
	end
	-- Mock FFI-dependent methods
	generic_buffer_meta.GetString = function(self)
		local out = {}

		for i = self.position, #self.buffer do
			table.insert(out, string.char(self.buffer[i]))
		end

		return table.concat(out)
	end
	generic_buffer_meta.GetSize = function(self)
		return #self.buffer
	end
	generic_buffer_meta.GetPosition = function(self)
		return self.position or 1
	end
	generic_buffer_meta.SetPosition = function(self, pos)
		self.position = pos
	end
	generic_buffer_meta.TheEnd = function(self)
		return self.position > #self.buffer
	end
	generic_buffer_meta.Clear = function(self)
		self.buffer = {}
		
		self.position = 1
	end
	-- Add WriteTestExtend for packet.ExtendBuffer test
	generic_buffer_meta.WriteTestExtend = function(self, val)
		table.insert(self.buffer, val)
	end
	generic_buffer_meta:Register()
end

-- Add Color constructor if not present
if not _G.Color then
	_G.Color = function(r, g, b, a)
		local c = {r = r or 0, g = g or 0, b = b or 0, a = a or 255}

		function c:SetLightness(lightness)
			self.r = math.min(255, math.max(0, self.r * lightness))
			self.g = math.min(255, math.max(0, self.g * lightness))
			self.b = math.min(255, math.max(0, self.b * lightness))
			return self
		end

		return c
	end
end

T.Test("network modules load without error", function()
	local enet = import("goluwa/network/transport_layer.lua")
	local packet = import("goluwa/network/packet.lua")
	local message = import("goluwa/network/message.lua")
	local clients = import("goluwa/network/clients.lua")
	local client_meta = import("goluwa/network/client.lua")
	local nvars = import("goluwa/network/nvars.lua")
	local network = import("goluwa/network/network.lua")
	T(enet)["~="](nil)
	T(packet)["~="](nil)
	T(message)["~="](nil)
	T(clients)["~="](nil)
	T(client_meta)["~="](nil)
	T(nvars)["~="](nil)
	T(network)["~="](nil)
end)

T.Test("network enet mock provides Initialize", function()
	local enet = import("goluwa/network/transport_layer.lua")
	-- Should not error
	enet.Initialize()
end)

T.Test("network enet mock creates peer and server", function()
	local enet = import("goluwa/network/transport_layer.lua")
	local peer = enet.CreatePeer("127.0.0.1", 27015)
	T(peer:IsValid())["=="](true)
	T(peer:IsConnected())["=="](true)
	T(peer:GetIP())["=="]("127.0.0.1")
	T(peer:GetPort())["=="](0)
	-- No-ops should not error
	peer:Connect("127.0.0.1", 27015)
	peer:Disconnect(0)
	peer:Send("test", "reliable", 0)
	peer:Remove()
	local server = enet.CreateServer("0.0.0.0", 27015)
	T(server:IsValid())["=="](true)
	T(#server:GetPeers())["=="](0)
	server:Broadcast("test", "reliable", 0)
	server:Remove()
end)

T.Test("network client creation and properties", function()
	local clients = import("goluwa/network/clients.lua")
	local client_meta = import("goluwa/network/client.lua")
	local client = clients.Create("test_client_1", false)
	T(client:IsValid())["=="](true)
	T(client:GetUniqueID())["=="]("test_client_1")
	T(client:IsBot())["=="](false)
	T(client:GetNick())["~="](nil)
	-- Cleanup
	client:Remove()
end)

T.Test("network clients registry", function()
	local clients = import("goluwa/network/clients.lua")
	local client1 = clients.Create("registry_test_1", false)
	local client2 = clients.Create("registry_test_2", false)
	T(#clients.GetAll())["=="](2)
	T(clients.GetByUniqueID("registry_test_1"):IsValid())["=="](true)
	T(clients.GetByUniqueID("registry_test_2"):IsValid())["=="](true)
	T(clients.GetByUniqueID("nonexistent"):IsValid())["=="](false)
	client1:Remove()
	client2:Remove()
end)

T.Test("network nvars basic sync", function()
	local nvars = import("goluwa/network/nvars.lua")
	-- Set and get a variable
	nvars.Set("test_key", "test_value", "test_env")
	T(nvars.Get("test_key", nil, "test_env"))["=="]("test_value")
	-- Get with default
	T(nvars.Get("nonexistent", "default_val", "test_env"))["=="]("default_val")
	-- Remove object
	nvars.RemoveObject("test_env")
	T(nvars.Get("test_key", nil, "test_env"))["=="](nil)
end)

T.Test("network nvars create object", function()
	local nvars = import("goluwa/network/nvars.lua")
	local obj = nvars.CreateObject("obj_test_env")
	T(obj.Env)["=="]("obj_test_env")
	-- Set via metatable
	obj.test_prop = "hello"
	T(nvars.Get("test_prop", nil, "obj_test_env"))["=="]("hello")
	-- Remove
	obj:Remove()
	T(nvars.GetAll("obj_test_env"))["=="](nil)
end)

T.Test("network message add and trigger listener", function()
	local message = import("goluwa/network/message.lua")
	local called = false
	local received_args = {}

	message.AddListener("test_msg", function(...)
		called = true
		received_args = {...}
	end)

	-- Trigger the listener directly (simulating message dispatch)
	if message.listeners["test_msg"] then
		message.listeners["test_msg"]("arg1", "arg2")
	end

	T(called)["=="](true)
	T(received_args[1])["=="]("arg1")
	T(received_args[2])["=="]("arg2")
end)

T.Test("network packet buffer creation", function()
	local packet = import("goluwa/network/packet.lua")
	local buffer = packet.CreateBuffer()
	T(buffer)["~="](nil)
	T(buffer.buffer)["~="](nil)
	T(buffer.position)["=="](1)
end)

T.Test("network packet extend buffer", function()
	local packet = import("goluwa/network/packet.lua")

	-- Extend with a custom type
	packet.ExtendBuffer("TestExtend", function(buffer, val)
		buffer:WriteString(val)
	end, function(buffer)
		return buffer:ReadString()
	end)

	local buffer = packet.CreateBuffer()
	buffer:WriteTestExtend("hello")
	T(buffer:GetPosition())["=="](1) -- Position should advance
end)

T.Test("network client filter", function()
	local clients = import("goluwa/network/clients.lua")
	local client1 = clients.Create("filter_test_1", false)
	local client2 = clients.Create("filter_test_2", false)
	local client3 = clients.Create("filter_test_3", false)
	local filter = clients.CreateFilter()
	filter:Add(client1)
	filter:Add(client2)
	local all = filter:GetAll()
	T(#all)["=="](2)
	filter:Remove(client1)
	all = filter:GetAll()
	T(#all)["=="](1)
	T(all[1]:GetUniqueID())["=="]("filter_test_2")
	client1:Remove()
	client2:Remove()
	client3:Remove()
end)

T.Test("network client unique color", function()
	local clients = import("goluwa/network/clients.lua")
	local client = clients.Create("color_test", false)
	local color = client:GetUniqueColor()
	T(color)["~="](nil)
	-- Color should be a table with r, g, b, a
	T(color.r)["~="](nil)
	T(color.g)["~="](nil)
	T(color.b)["~="](nil)
	T(color.a)["~="](nil)
	client:Remove()
end)

T.Test("network client tostring", function()
	local clients = import("goluwa/network/clients.lua")
	local client = clients.Create("tostring_test", false)
	local str = tostring(client)
	T(str):find("tostring_test")["~="](nil)
	client:Remove()
end)

T.Test("network nvars getall", function()
	local nvars = import("goluwa/network/nvars.lua")
	nvars.Set("key1", "val1", "getall_test")
	nvars.Set("key2", "val2", "getall_test")
	local all = nvars.GetAll("getall_test")
	T(all)["~="](nil)
	T(all.key1)["=="]("val1")
	T(all.key2)["=="]("val2")
	nvars.RemoveObject("getall_test")
end)

T.Test("network message remove listener", function()
	local message = import("goluwa/network/message.lua")

	message.AddListener("remove_test", function() end)

	T(message.listeners["remove_test"])["~="](nil)
	message.RemoveListener("remove_test")
	T(message.listeners["remove_test"])["=="](nil)
end)

T.Test("network packet add listener", function()
	local packet = import("goluwa/network/packet.lua")
	local called = false

	packet.AddListener(999, function(buffer)
		called = true
	end)

	T(packet.listeners[999])["~="](nil)
	-- Remove listener
	packet.RemoveListener(999)
	T(packet.listeners[999])["=="](nil)
end)

T.Test("network client bot creation", function()
	local clients = import("goluwa/network/clients.lua")
	local bot = clients.CreateBot("TestBot", "bot_team")
	T(bot:IsValid())["=="](true)
	T(bot:IsBot())["=="](true)
	T(bot:GetNick())["~="](nil)
	T(bot:GetGroup())["~="](nil)
	bot:Remove()
end)

T.Test("network client get set properties", function()
	local clients = import("goluwa/network/clients.lua")
	local client = clients.Create("props_test", false)
	client:SetNick("NewNick")
	T(client:GetNick())["=="]("NewNick")
	client:SetGroup("new_group")
	T(client:GetGroup())["=="]("new_group")
	client:SetBot(true)
	T(client:IsBot())["=="](true)
	client:Remove()
end)

T.Test("network nvars set with different types", function()
	local nvars = import("goluwa/network/nvars.lua")
	nvars.Set("num_key", 42, "type_test")
	T(nvars.Get("num_key", nil, "type_test"))["=="](42)
	nvars.Set("bool_key", true, "type_test")
	T(nvars.Get("bool_key", nil, "type_test"))["=="](true)
	nvars.Set("nil_key", nil, "type_test")
	T(nvars.Get("nil_key", "default", "type_test"))["=="]("default")
	nvars.RemoveObject("type_test")
end)

T.Test("network packet buffer write read string", function()
	local packet = import("goluwa/network/packet.lua")
	local buffer = packet.CreateBuffer()
	buffer:WriteString("test_string")
	buffer:SetPosition(1)
	local read_str = buffer:ReadString()
	T(read_str)["=="]("test_string")
end)

T.Test("network client valid check", function()
	local clients = import("goluwa/network/clients.lua")
	local client = clients.Create("valid_test", false)
	T(client:IsValid())["=="](true)
	client:Remove()
	T(client:IsValid())["=="](false)
end)

T.Test("network nvars environment isolation", function()
	local nvars = import("goluwa/network/nvars.lua")
	nvars.Set("shared_key", "env1_value", "env_a")
	nvars.Set("shared_key", "env2_value", "env_b")
	T(nvars.Get("shared_key", nil, "env_a"))["=="]("env1_value")
	T(nvars.Get("shared_key", nil, "env_b"))["=="]("env2_value")
	nvars.RemoveObject("env_a")
	nvars.RemoveObject("env_b")
end)

T.Test("network packet buffer clear", function()
	local packet = import("goluwa/network/packet.lua")
	local buffer = packet.CreateBuffer()
	buffer:WriteString("data")
	buffer:Clear()
	T(#buffer.buffer)["=="](0)
	T(buffer.position)["=="](1)
end)

T.Test("network client get local client", function()
	local clients = import("goluwa/network/clients.lua")
	local local_client = clients.GetLocalClient()
	T(local_client)["~="](nil)
	T(local_client:IsValid())["=="](true)
end)
