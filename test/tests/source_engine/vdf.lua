local T = require("test.environment")
local vdf = require("codecs.vdf")

T.Test("vdf: basic", function()
	local test = [["basic"
{
    "key" "value"
}]]
	local out = vdf.Decode(test)
	T(out.basic.key)["=="]("value")
end)

T.Test("vdf: nested", function()
	local test = [["root"
{
    "nest"
    {
        "key" "value"
    }
}]]
	local out = vdf.Decode(test)
	T(out.root.nest.key)["=="]("value")
end)

T.Test("vdf: unquoted", function()
	local test = [[
root
{
    key value
    key2 123
    key3 true
    key4 false
}]]
	local out = vdf.Decode(test)
	T(out.root.key)["=="]("value")
	T(out.root.key2)["=="](123)
	T(out.root.key3)["=="](true)
	T(out.root.key4)["=="](false)
end)

T.Test("vdf: duplicate keys", function()
	local test = [[
"root"
{
    "key" "value1"
    "key" "value2"
    "key" "value3"
}]]
	local out = vdf.Decode(test)
	T(type(out.root.key))["=="]("table")
	T(#out.root.key)["=="](3)
	T(out.root.key[1])["=="]("value1")
	T(out.root.key[2])["=="]("value2")
	T(out.root.key[3])["=="]("value3")
end)

T.Test("vdf: comments", function()
	local test = [[
"root"
{
    "key" "value" // This is a comment
    // Another comment
    "key2" "value2"
}]]
	local out = vdf.Decode(test)
	T(out.root.key)["=="]("value")
	T(out.root.key2)["=="]("value2")
end)

T.Test("vdf: types (Color and Vec3)", function()
	local test = [[
"root"
{
    "color" "{255 128 0 255}"
    "vector" "[1.5 2.5 3.5]"
}]]
	local out = vdf.Decode(test)
	T(type(out.root.color))["=="]("cdata")
	T(out.root.color.r)["=="](1)
	T(out.root.color.g * 255)["~"](128)
	T(out.root.color.b)["=="](0)
	T(out.root.color.a)["=="](1)
	T(type(out.root.vector))["=="]("cdata")
	T(out.root.vector.x)["=="](1.5)
	T(out.root.vector.y)["=="](2.5)
	T(out.root.vector.z)["=="](3.5)
end)

T.Test("vdf: conditionals (basic)", function()
	-- We can't easily mock jit.os here without affecting other things, 
	-- but we can test that the parser handles the syntax.
	local test = [[
"root"
{
    "win_only" "val" [$WINDOWS]
    "linux_only" "val" [$LINUX]
    "not_win" "val" [!$WINDOWS]
}]]
	local out = vdf.Decode(test)

	if jit.os == "Windows" then
		T(out.root.win_only)["=="]("val")
		T(out.root.linux_only)["=="](nil)
		T(out.root.not_win)["=="](nil)
	elseif jit.os == "Linux" then
		T(out.root.win_only)["=="](nil)
		T(out.root.linux_only)["=="]("val")
		T(out.root.not_win)["=="]("val")
	end
end)

T.Test("vdf: escape sequences", function()
	local test = [["root"
{
    "key" "value with \"quotes\""
}]]
	local out = vdf.Decode(test)
	T(out.root.key)["=="]([[value with \"quotes\"]]) -- vdf.lua doesn't seem to unescape \", it just keeps them
end)

T.Test("vdf: key modification", function()
	local test = [[
"Root"
{
    "Key" "Value"
}]]
	local out = vdf.Decode(test, true) -- lower_or_modify_keys = true
	T(out.root.key)["=="]("Value")
end)

T.Test("vdf: preprocessing", function()
	local test = [[
"root"
{
    "key" "|MYVAR|/path"
}]]
	local out = vdf.Decode(test, nil, {MYVAR = "custom"})
	T(out.root.key)["=="]("custom/path")
end)

T.Test("vdf: complex nesting and mixed types", function()
	local test = [[
"Inline objects and arrayifying"
{
	"0"		{ "label" "#SFUI_CashColon"	}
	"1"		{ "label" "#SFUI_WinMatchColon"			"value" "#SFUI_Rounds" }
	"2"		{ "label" "#SFUI_TimePerRoundColon"		"value" "2 #SFUI_Minutes" }
	"2"		{ "label" "#SFUI_TimePerRoundColon"		"value" "2 #SFUI_Minutes" }
	"3" "value before object"
	"3"		{ "label" "#SFUI_BuyTimeColon"			"value" "45 #SFUI_Seconds" }
}]]
	local out = vdf.Decode(test)
	local root = out["Inline objects and arrayifying"]
	T(root["0"].label)["=="]("#SFUI_CashColon")
	T(root["1"].label)["=="]("#SFUI_WinMatchColon")
	T(root["1"].value)["=="]("#SFUI_Rounds")
	T(type(root["2"]))["=="]("table")
	T(#root["2"])["=="](2)
	T(root["2"][1].label)["=="]("#SFUI_TimePerRoundColon")
	T(type(root["3"]))["=="]("table")
	T(root["3"][1])["=="]("value before object")
	T(root["3"][2].label)["=="]("#SFUI_BuyTimeColon")
end)
