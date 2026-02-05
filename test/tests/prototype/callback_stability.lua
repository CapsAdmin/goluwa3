local T = require("test.environment")
local prototype = require("prototype")
local Vec2 = require("structs.vec2")

T.Test("prototype property callback stabilizer", function()
	local META = prototype.CreateTemplate("test_stabilizer")
	local call_count = 0

	function META:OnChanged()
		call_count = call_count + 1
	end

	META:GetSet("Val", 0, {callback = "OnChanged"})
	META:GetSet("Text", "hello", {callback = "OnChanged"})
	META:GetSet("Pos", Vec2(0, 0), {callback = "OnChanged"})
	META:Register()
	local obj = prototype.CreateObject(META)
	-- 1. Initial set to a NEW value
	obj:SetVal(10)
	T(call_count)["=="](1)
	-- 2. Set to the SAME value (number)
	obj:SetVal(10)
	T(call_count)["=="](1) -- Should NOT increase
	-- 3. Set to a NEW value (string)
	obj:SetText("world")
	T(call_count)["=="](2)
	-- 4. Set to the SAME value (string)
	obj:SetText("world")
	T(call_count)["=="](2) -- Should NOT increase
	-- 5. Set to a NEW value (Vec2)
	obj:SetPos(Vec2(10, 20))
	T(call_count)["=="](3)
	-- 6. Set to the SAME value (Vec2)
	-- This works because Vec2 has __eq overloaded in structs.lua
	obj:SetPos(Vec2(10, 20))
	T(call_count)["=="](3) -- Should NOT increase
	-- 7. Set to a different Vec2
	obj:SetPos(Vec2(10, 21))
	T(call_count)["=="](4)
	-- 8. Set via nil (should reset to default)
	obj:SetVal(100)
	T(call_count)["=="](5)
	T(obj:GetVal())["=="](100)
	obj:SetVal(nil)
	T(call_count)["=="](6)
	T(obj:GetVal())["=="](0)
	obj:SetVal(nil)
	T(call_count)["=="](6) -- Should NOT increase
end)

T.Test("prototype property callback stabilizer IsSet", function()
	local META = prototype.CreateTemplate("test_stabilizer_is")
	local call_count = 0

	function META:OnChanged()
		call_count = call_count + 1
	end

	META:IsSet("Cool", false, {callback = "OnChanged"})
	META:Register()
	local obj = prototype.CreateObject(META)
	obj:SetCool(true)
	T(call_count)["=="](1)
	obj:SetCool(true)
	T(call_count)["=="](1)
	obj:SetCool(false)
	T(call_count)["=="](2)
end)
