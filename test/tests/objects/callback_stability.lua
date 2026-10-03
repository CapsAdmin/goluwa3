local T = import("test/environment.lua")
local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

T.Test("objects property callback stabilizer", function()
	local META = objects.CreateTemplate("test_stabilizer")
	local call_count = 0

	function META:OnChanged()
		call_count = call_count + 1
	end

	META:GetSet("Val", 0, {callback = "OnChanged"})
	META:GetSet("Text", "hello", {callback = "OnChanged"})
	META:GetSet("Pos", Vec2(0, 0), {callback = "OnChanged"})
	META:Register()
	local obj = objects.CreateObject(META)
	obj:SetVal(10)
	T(call_count)["=="](1)
	obj:SetVal(10)
	T(call_count)["=="](1)
	obj:SetText("world")
	T(call_count)["=="](2)
	obj:SetText("world")
	T(call_count)["=="](2)
	obj:SetPos(Vec2(10, 20))
	T(call_count)["=="](3)
	obj:SetPos(Vec2(10, 20))
	T(call_count)["=="](3)
	obj:SetPos(Vec2(10, 21))
	T(call_count)["=="](4)
	obj:SetVal(100)
	T(call_count)["=="](5)
	T(obj:GetVal())["=="](100)
	obj:SetVal(nil)
	T(call_count)["=="](6)
	T(obj:GetVal())["=="](0)
	obj:SetVal(nil)
	T(call_count)["=="](6)
end)

T.Test("objects property callback stabilizer IsSet", function()
	local META = objects.CreateTemplate("test_stabilizer_is")
	local call_count = 0

	function META:OnChanged()
		call_count = call_count + 1
	end

	META:IsSet("Cool", false, {callback = "OnChanged"})
	META:Register()
	local obj = objects.CreateObject(META)
	obj:SetCool(true)
	T(call_count)["=="](1)
	obj:SetCool(true)
	T(call_count)["=="](1)
	obj:SetCool(false)
	T(call_count)["=="](2)
end)
