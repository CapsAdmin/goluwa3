local T = import("test/environment.lua")
_G.CLIENT = true
_G.SERVER = true
local packet = import("goluwa/network/packet.lua")

T.Test("Packet creates buffer with correct initial state", function()
	local buffer = packet.CreateBuffer()
	T(buffer)["~="](nil)
	T(buffer.buffer)["~="](nil)
	T(buffer:GetPosition())["=="](1)
end)

T.Test("Packet buffer write and read string", function()
	local buffer = packet.CreateBuffer()
	buffer:WriteString("hello world")
	buffer:SetPosition(1)
	local read_str = buffer:ReadString()
	T(read_str)["=="]("hello world")
end)

T.Test("Packet buffer write and read bytes", function()
	local buffer = packet.CreateBuffer()
	buffer:WriteByte(65) -- 'A'
	buffer:WriteByte(66) -- 'B'
	buffer:WriteByte(67) -- 'C'
	buffer:SetPosition(1)
	local b1 = buffer:ReadByte()
	local b2 = buffer:ReadByte()
	local b3 = buffer:ReadByte()
	T(b1)["=="](65)
	T(b2)["=="](66)
	T(b3)["=="](67)
end)

T.Test("Packet buffer write and read boolean", function()
	local buffer = packet.CreateBuffer()
	buffer:WriteBoolean(true)
	buffer:WriteBoolean(false)
	buffer:SetPosition(1)
	T(buffer:ReadBoolean())["=="](true)
	T(buffer:ReadBoolean())["=="](false)
end)

T.Test("Packet buffer clear resets state", function()
	local buffer = packet.CreateBuffer()
	buffer:WriteString("test")
	buffer:Clear()
	T(#buffer.buffer)["=="](0)
	T(buffer:GetPosition())["=="](0)
end)

T.Test("Packet buffer position advances on read", function()
	local buffer = packet.CreateBuffer()
	buffer:WriteByte(42)
	buffer:WriteByte(43)
	buffer:SetPosition(1)
	local pos_before = buffer:GetPosition()
	buffer:ReadByte()
	local pos_after = buffer:GetPosition()
	T(pos_after)[">"](pos_before)
end)

T.Test("Packet buffer size", function()
	local buffer = packet.CreateBuffer()
	T(buffer:GetSize())["=="](0)
	buffer:WriteByte(1)
	T(buffer:GetSize())["=="](1)
	buffer:WriteBytes("hello", 5)
	T(buffer:GetSize())["=="](6)
end)

T.Test("Packet add and remove listener", function()
	local called = false

	packet.AddListener(100, function(buffer)
		called = true
	end)

	T(packet.listeners[100])["~="](nil)
	packet.RemoveListener(100)
	T(packet.listeners[100])["=="](nil)
end)

T.Test("Packet listener receives buffer", function()
	local received_buffer = nil

	packet.AddListener(200, function(buffer)
		received_buffer = buffer
	end)

	local test_buffer = packet.CreateBuffer()
	test_buffer:WriteByte(42)
	packet.listeners[200](test_buffer)
	T(received_buffer)["~="](nil)
	T(received_buffer:GetSize())[">="](1)
	packet.RemoveListener(200)
end)

T.Test("Packet extend buffer with custom type", function()
	packet.ExtendBuffer("CustomByte", function(buffer, val)
		buffer:WriteByte(val)
	end, function(buffer)
		return buffer:ReadByte()
	end)

	local buffer = packet.CreateBuffer()
	buffer:WriteCustomByte(42)
	buffer:SetPosition(0)
	T(buffer:ReadCustomByte())["=="](42)
end)

T.Test("Packet buffer read beyond end", function()
	local buffer = packet.CreateBuffer()
	buffer:WriteByte(1)
	buffer:SetPosition(1)
	buffer:ReadByte()
	T(buffer:TheEnd())["=="](true)
end)
