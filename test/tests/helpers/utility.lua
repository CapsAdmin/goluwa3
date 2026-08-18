local T = import("test/environment.lua")
local utility = import("goluwa/utility.lua")

T.Test("utility.MakeFlags set/get roundtrip", function()
	local builder = utility.MakeFlags{
		{name = "A", map = {zero = 0, three = 3}},
		{name = "B", map = {zero = 0, ten = 10}},
		{name = "C"},
	}
	local flags = 0
	T(builder:get(flags, "A"))["=="]("zero")
	T(builder:get(flags, "B"))["=="]("zero")
	T(builder:get(flags, "C"))["=="](false)
	flags = builder:set(flags, "A", "three")
	flags = builder:set(flags, "B", "ten")
	flags = builder:set(flags, "C", true)
	T(builder:get(flags, "A"))["=="]("three")
	T(builder:get(flags, "B"))["=="]("ten")
	T(builder:get(flags, "C"))["=="](true)
	-- A: 2 bits (max id 3), B: 4 bits (max id 10), C: 1 bit
	-- A: bits 0-1, B: bits 2-5, C: bit 6
	T(flags)["=="](3 | (10 << 2) | (1 << 6))
	-- Overwriting one field leaves the others untouched
	flags = builder:set(flags, "A", "zero")
	T(builder:get(flags, "A"))["=="]("zero")
	T(builder:get(flags, "B"))["=="]("ten")
	T(builder:get(flags, "C"))["=="](true)
end)

T.Test("utility.MakeFlags bits are derived from the map", function()
	local builder = utility.MakeFlags{
		{name = "A", map = {a = 0, b = 1}},
		{name = "B", map = {a = 0, b = 3}},
		{name = "C", map = {a = 0, b = 7}},
		{name = "D", map = {a = 0, b = 8}},
		{name = "E"},
	}
	local a, b, c, d, e = builder.fields[1], builder.fields[2], builder.fields[3], builder.fields[4], builder.fields[5]
	-- max id 1 -> 1 bit, 3 -> 2 bits, 7 -> 3 bits, 8 -> 4 bits, no map -> 1 bit
	T(a.bits)["=="](1)
	T(a.shift)["=="](0)
	T(a.shifted_mask)["=="](1)
	T(b.bits)["=="](2)
	T(b.shift)["=="](1)
	T(b.shifted_mask)["=="](6)
	T(c.bits)["=="](3)
	T(c.shift)["=="](3)
	T(c.shifted_mask)["=="](56)
	T(d.bits)["=="](4)
	T(d.shift)["=="](6)
	T(d.shifted_mask)["=="](960)
	T(e.bits)["=="](1)
	T(e.shift)["=="](10)
	T(e.shifted_mask)["=="](1024)
end)

T.Test("utility.MakeFlags unmapped fields are booleans", function()
	local builder = utility.MakeFlags{
		{name = "ON"},
	}
	local flags = builder:set(0, "ON", true)
	T(builder:get(flags, "ON"))["=="](true)
	T(flags)["=="](1)
	flags = builder:set(flags, "ON", false)
	T(builder:get(flags, "ON"))["=="](false)
	T(flags)["=="](0)
	-- 0/1 numbers work too
	flags = builder:set(flags, "ON", 1)
	T(builder:get(flags, "ON"))["=="](true)
end)

T.Test("utility.MakeFlags rejects invalid values", function()
	local builder = utility.MakeFlags{
		{name = "A"},
		{name = "MODE", label = "shape mode", map = {rect = 0, circle = 1}},
	}
	local flags = builder:set(0, "A", true)
	-- nil is a missing argument, not "off"
	local ok, err = pcall(builder.set, builder, flags, "A", nil)
	T(ok)["=="](false)
	T(tostring(err):find("Invalid A"))["~="](nil)
	-- Mapped fields only accept names from the map
	ok, err = pcall(builder.set, builder, flags, "MODE", "bogus")
	T(ok)["=="](false)
	T(tostring(err):find("Invalid shape mode"))["~="](nil)
	-- Unknown flag name
	ok, err = pcall(builder.set, builder, flags, "B", true)
	T(ok)["=="](false)
	T(tostring(err):find("unknown flag"))["~="](nil)
	ok = pcall(builder.get, builder, flags, "B")
	T(ok)["=="](false)
end)

T.Test("utility.MakeFlags enum values", function()
	local builder = utility.MakeFlags{
		{
			name = "MODE",
			label = "shape mode",
			map = {rect = 0, circle = 1, ellipse = 2},
		},
	}
	local flags = builder:set(0, "MODE", "circle")
	-- get translates the stored id back to a name for mapped fields
	T(builder:get(flags, "MODE"))["=="]("circle")
	-- Mapped fields only accept names; raw ids are rejected
	local ok, err = pcall(builder.set, builder, flags, "MODE", 2)
	T(ok)["=="](false)
	T(tostring(err):find("Invalid shape mode"))["~="](nil)
	ok, err = pcall(builder.set, builder, flags, "MODE", "bogus")
	T(ok)["=="](false)
	err = tostring(err)
	T(err:find("Invalid shape mode"))["~="](nil)
	T(err:find("bogus"))["~="](nil)
	T(err:find("circle"))["~="](nil)
end)

T.Test("utility.MakeFlags validates definitions", function()
	local ok, err
	ok, err = pcall(utility.MakeFlags, {{name = "A", map = {a = -1}}})
	T(ok)["=="](false)
	T(tostring(err):find("non-negative"))["~="](nil)
	ok, err = pcall(utility.MakeFlags, {{name = "A", map = {a = 1.5}}})
	T(ok)["=="](false)
	T(tostring(err):find("non-negative"))["~="](nil)
	ok, err = pcall(utility.MakeFlags, {{name = "A", map = {a = 2147483648}}})
	T(ok)["=="](false)
	T(tostring(err):find("too large"))["~="](nil)
	-- 16-bit fields: two fit, three don't
	local big = {name = "A", map = {a = 0, b = 65535}}
	ok = pcall(utility.MakeFlags, {big, {name = "B", map = {a = 0, b = 65535}}})
	T(ok)["=="](true)
	ok, err = pcall(
		utility.MakeFlags,
		{big, {name = "B", map = {a = 0, b = 65535}}, {name = "C", map = {a = 0, b = 65535}}}
	)
	T(ok)["=="](false)
	T(tostring(err):find("max is 32"))["~="](nil)
	ok, err = pcall(utility.MakeFlags, {{name = "A", map = {x = 0}}, {name = "A", map = {x = 0}}})
	T(ok)["=="](false)
	T(tostring(err):find("duplicate"))["~="](nil)
	-- A single field can use all 31 positive bits
	ok = pcall(utility.MakeFlags, {{name = "ALL", map = {a = 0, b = 2147483647}}})
	T(ok)["=="](true)
end)
