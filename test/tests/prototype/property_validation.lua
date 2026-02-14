local T = require("test.environment")
local prototype = require("prototype")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")

T.Test("prototype property validation", function()
	local META = prototype.CreateTemplate("test_property_validation")
	META:GetSet("Num", 123)
	META:GetSet("Str", "hello")
	META:GetSet("Pos", Vec2(0, 0))
	META:GetSet("Tbl", {a = 1})
	META:GetSet("Any", nil) -- type will be nil
	META:Register()
	local obj = prototype.CreateObject(META)
	-- Test correct types
	assert(prototype.SetProperty(obj, "Num", 456))
	T(obj:GetNum())["=="](456)
	assert(prototype.SetProperty(obj, "Str", "world"))
	T(obj:GetStr())["=="]("world")
	assert(prototype.SetProperty(obj, "Pos", Vec2(10, 10)))
	T(obj:GetPos())["=="](Vec2(10, 10))
	assert(prototype.SetProperty(obj, "Tbl", {b = 2}))
	T(obj:GetTbl().b)["=="](2)
	-- Test number conversion
	assert(prototype.SetProperty(obj, "Num", "789"))
	T(obj:GetNum())["=="](789)
	-- Test nil (should revert to default or just set nil)
	assert(prototype.SetProperty(obj, "Num", nil))
	T(obj:GetNum())["=="](123)

	-- Test mismatches (should error)
	local function fails(f)
		local ok, err = pcall(f)

		if ok then error("expected failure") end
	end

	fails(function()
		prototype.SetProperty(obj, "Num", "not a number")
	end)

	fails(function()
		prototype.SetProperty(obj, "Str", 123)
	end)

	fails(function()
		prototype.SetProperty(obj, "Pos", "not a vec2")
	end)

	fails(function()
		prototype.SetProperty(obj, "Tbl", 123)
	end)

	-- Test struct mismatch (Vec2 vs Vec3)
	fails(function()
		prototype.SetProperty(obj, "Pos", Vec3(1, 2, 3))
	end)

	-- Test 'any' type (no validation)
	assert(prototype.SetProperty(obj, "Any", 123))
	T(obj:GetAny())["=="](123)
	assert(prototype.SetProperty(obj, "Any", "string"))
	T(obj:GetAny())["=="]("string")
end)

T.Test("prototype property getter", function()
	local META = prototype.CreateTemplate("test_property_getter")
	META:GetSet("Foo", "bar")
	META:IsSet("Active", true)

	-- Manual getter
	function META:GetManual()
		return "manual"
	end

	META:Register()
	local obj = prototype.CreateObject(META)
	T(prototype.GetProperty(obj, "Foo"))["=="]("bar")
	T(prototype.GetProperty(obj, "Active"))["=="](true)
	T(prototype.GetProperty(obj, "Manual"))["=="]("manual")
	-- Direct field
	obj.Direct = 123
	T(prototype.GetProperty(obj, "Direct"))["=="](123)
end)
