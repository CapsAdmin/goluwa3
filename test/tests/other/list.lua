local T = import("test/environment.lua")
local list = import("goluwa/list.lua")

T.Test("list flatten_with_holes flattens nested arrays", function()
	local result = list.flatten_with_holes({1, {2, 3}, {4}})
	T(#result)["=="](4)
	T(result[1])["=="](1)
	T(result[2])["=="](2)
	T(result[3])["=="](3)
	T(result[4])["=="](4)
end)

T.Test("list flatten_with_holes handles holes", function()
	local t = {}
	t[1] = 1
	t[3] = 3
	local result = list.flatten_with_holes(t)
	T(#result)["=="](2)
	T(result[1])["=="](1)
	T(result[2])["=="](3)
end)

T.Test("list flatten_with_holes does not flatten tables with IsValid", function()
	local ui_obj = {IsValid = function(self) return true end, Type = "panel"}
	local result = list.flatten_with_holes({1, ui_obj, 3})
	T(#result)["=="](3)
	T(result[1])["=="](1)
	T(result[2])["=="](ui_obj)
	T(result[3])["=="](3)
end)

T.Test("list flatten_with_holes does not flatten nested tables with IsValid", function()
	local ui_obj = {IsValid = function(self) return true end, Type = "panel"}
	ui_obj[1] = "should_not_appear"
	ui_obj[2] = "nor_this"
	local result = list.flatten_with_holes({{ui_obj}})
	T(#result)["=="](1)
	T(result[1])["=="](ui_obj)
end)

T.Test("list flatten_with_holes preserves non-array tables", function()
	local dict = {a = 1, b = 2}
	local result = list.flatten_with_holes({dict})
	T(#result)["=="](1)
	T(result[1])["=="](dict)
end)
