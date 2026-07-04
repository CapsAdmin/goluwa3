local T = import("test/environment.lua")
local ffi = require("ffi")
local Buffer = import("goluwa/structs/buffer.lua")

T.Test("Buffer WriteTable ReadTable simple types", function()
	local buf = ffi.new("uint8_t[1000]")
	local buffer = Buffer.New(buf, 1000):MakeWritable()
	local tbl = {
		["name"] = "test",
		["value"] = 42,
		["pi"] = 3.14159,
		["active"] = true,
	}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(read_tbl["name"])["=="]("test")
	T(read_tbl["value"])["=="](42)
	T(read_tbl["pi"])["=="](3.14159)
	T(read_tbl["active"])["=="](true)
end)

T.Test("Buffer WriteTable ReadTable empty table", function()
	local buf = ffi.new("uint8_t[100]")
	local buffer = Buffer.New(buf, 100):MakeWritable()
	local tbl = {}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(#read_tbl)["=="](0)
end)

T.Test("Buffer WriteTable ReadTable strings only", function()
	local buf = ffi.new("uint8_t[1000]")
	local buffer = Buffer.New(buf, 1000):MakeWritable()
	local tbl = {
		["key1"] = "value1",
		["key2"] = "value2",
		["key3"] = "value3",
	}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(read_tbl["key1"])["=="]("value1")
	T(read_tbl["key2"])["=="]("value2")
	T(read_tbl["key3"])["=="]("value3")
end)

T.Test("Buffer WriteTable ReadTable numbers only", function()
	local buf = ffi.new("uint8_t[1000]")
	local buffer = Buffer.New(buf, 1000):MakeWritable()
	local tbl = {
		["int"] = 42,
		["float"] = 3.14159,
		["negative"] = -100,
		["zero"] = 0,
	}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(read_tbl["int"])["=="](42)
	T(read_tbl["float"])["=="](3.14159)
	T(read_tbl["negative"])["=="](-100)
	T(read_tbl["zero"])["=="](0)
end)

T.Test("Buffer WriteTable ReadTable booleans only", function()
	local buf = ffi.new("uint8_t[100]")
	local buffer = Buffer.New(buf, 100):MakeWritable()
	local tbl = {
		["true_val"] = true,
		["false_val"] = false,
	}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(read_tbl["true_val"])["=="](true)
	T(read_tbl["false_val"])["=="](false)
end)

T.Test("Buffer WriteTable ReadTable mixed types", function()
	local buf = ffi.new("uint8_t[1000]")
	local buffer = Buffer.New(buf, 1000):MakeWritable()
	local tbl = {
		["string_key"] = "string_value",
		["int_key"] = 123,
		["float_key"] = 2.718,
		["bool_key"] = false,
		["empty_string"] = "",
	}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(read_tbl["string_key"])["=="]("string_value")
	T(read_tbl["int_key"])["=="](123)
	T(read_tbl["float_key"])["=="](2.718)
	T(read_tbl["bool_key"])["=="](false)
	T(read_tbl["empty_string"])["=="]("")
end)

T.Test("Buffer WriteTable ReadTable special string values", function()
	local buf = ffi.new("uint8_t[1000]")
	local buffer = Buffer.New(buf, 1000):MakeWritable()
	local tbl = {
		["newline"] = "line1\nline2",
		["tab"] = "col1\tcol2",
		["unicode"] = "Hello 世界",
		["long"] = string.rep("x", 1000),
	}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(read_tbl["newline"])["=="]("line1\nline2")
	T(read_tbl["tab"])["=="]("col1\tcol2")
	T(read_tbl["unicode"])["=="]("Hello 世界")
	T(read_tbl["long"])["=="](string.rep("x", 1000))
end)

T.Test("Buffer WriteTable ReadTable large table", function()
	local buf = ffi.new("uint8_t[10000]")
	local buffer = Buffer.New(buf, 10000):MakeWritable()
	local tbl = {}

	for i = 1, 100 do
		tbl[string.format("key_%d", i)] = i * 10
	end

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	-- Count entries manually (string keys don't count with #)
	local count = 0
	for _ in pairs(read_tbl) do
		count = count + 1
	end
	T(count)["=="](100)
	T(read_tbl["key_50"])["=="](500)
	T(read_tbl["key_100"])["=="](1000)
end)

T.Test("Buffer WriteTable ReadTable multiple roundtrips", function()
	local buf = ffi.new("uint8_t[10000]")
	local buffer = Buffer.New(buf, 10000):MakeWritable()

	-- First table
	local tbl1 = {["a"] = 1, ["b"] = 2}
	buffer:WriteTable(tbl1)

	-- Second table
	local tbl2 = {["x"] = "hello", ["y"] = 42}
	buffer:WriteTable(tbl2)

	-- Read first table
	buffer:SetPosition(0)
	local read_tbl1 = buffer:ReadTable()
	T(read_tbl1["a"])["=="](1)
	T(read_tbl1["b"])["=="](2)

	-- Read second table
	local read_tbl2 = buffer:ReadTable()
	T(read_tbl2["x"])["=="]("hello")
	T(read_tbl2["y"])["=="](42)
end)

T.Test("Buffer WriteTable ReadTable numeric keys", function()
	local buf = ffi.new("uint8_t[1000]")
	local buffer = Buffer.New(buf, 1000):MakeWritable()
	local tbl = {
		[1] = "one",
		[2] = "two",
		[100] = "hundred",
	}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(read_tbl[1])["=="]("one")
	T(read_tbl[2])["=="]("two")
	T(read_tbl[100])["=="]("hundred")
end)

T.Test("Buffer WriteTable ReadTable negative numbers", function()
	local buf = ffi.new("uint8_t[1000]")
	local buffer = Buffer.New(buf, 1000):MakeWritable()
	local tbl = {
		["neg_int"] = -42,
		["neg_float"] = -3.14,
		["min_int"] = -2147483648,
	}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(read_tbl["neg_int"])["=="](-42)
	T(read_tbl["neg_float"])["=="](-3.14)
	T(read_tbl["min_int"])["=="](-2147483648)
end)

T.Test("Buffer WriteTable ReadTable very large number", function()
	local buf = ffi.new("uint8_t[1000]")
	local buffer = Buffer.New(buf, 1000):MakeWritable()
	local tbl = {
		["large"] = 1.7976931348623157e+308, -- near double max
	}

	buffer:WriteTable(tbl)
	buffer:SetPosition(0)
	local read_tbl = buffer:ReadTable()

	T(read_tbl["large"])["=="](1.7976931348623157e+308)
end)
