local T = import("test/environment.lua")
local objects = import("goluwa/objects/objects.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

T.Test("objects property validation", function()
	local META = objects.CreateTemplate("test_property_validation")
	META:GetSet("Num", 123)
	META:GetSet("Str", "hello")
	META:GetSet("Pos", Vec2(0, 0))
	META:GetSet("Tbl", {a = 1})
	META:GetSet("Any", nil) -- type will be nil
	META:Register()
	local obj = objects.CreateObject(META)
	-- Test correct types
	assert(objects.SetProperty(obj, "Num", 456))
	T(obj:GetNum())["=="](456)
	assert(objects.SetProperty(obj, "Str", "world"))
	T(obj:GetStr())["=="]("world")
	assert(objects.SetProperty(obj, "Pos", Vec2(10, 10)))
	T(obj:GetPos())["=="](Vec2(10, 10))
	assert(objects.SetProperty(obj, "Tbl", {b = 2}))
	T(obj:GetTbl().b)["=="](2)
	-- Test number conversion
	assert(objects.SetProperty(obj, "Num", "789"))
	T(obj:GetNum())["=="](789)
	-- Test nil (should revert to default or just set nil)
	assert(objects.SetProperty(obj, "Num", nil))
	T(obj:GetNum())["=="](123)

	-- Test mismatches (should error)
	local function fails(f)
		local ok, err = pcall(f)

		if ok then error("expected failure") end
	end

	fails(function()
		objects.SetProperty(obj, "Num", "not a number")
	end)

	fails(function()
		objects.SetProperty(obj, "Str", 123)
	end)

	fails(function()
		objects.SetProperty(obj, "Pos", "not a vec2")
	end)

	fails(function()
		objects.SetProperty(obj, "Tbl", 123)
	end)

	-- Test struct mismatch (Vec2 vs Vec3)
	fails(function()
		objects.SetProperty(obj, "Pos", Vec3(1, 2, 3))
	end)

	-- Test 'any' type (no validation)
	assert(objects.SetProperty(obj, "Any", 123))
	T(obj:GetAny())["=="](123)
	assert(objects.SetProperty(obj, "Any", "string"))
	T(obj:GetAny())["=="]("string")
end)

T.Test("objects property getter", function()
	local META = objects.CreateTemplate("test_property_getter")
	META:GetSet("Foo", "bar")
	META:IsSet("Active", true)

	-- Manual getter
	function META:GetManual()
		return "manual"
	end

	META:Register()
	local obj = objects.CreateObject(META)
	T(objects.GetProperty(obj, "Foo"))["=="]("bar")
	T(objects.GetProperty(obj, "Active"))["=="](true)
	T(objects.GetProperty(obj, "Manual"))["=="]("manual")
	-- Direct field
	obj.Direct = 123
	T(objects.GetProperty(obj, "Direct"))["=="](123)
end)
