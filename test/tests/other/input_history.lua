local T = import("test/environment.lua")
local InputHistory = import("goluwa/input_history.lua")

local function make(entries)
	local history = InputHistory.New()

	for _, entry in ipairs(entries or {}) do
		history:Add(entry)
	end

	return history
end

T.Test("input history add ignores blank and consecutive duplicates", function()
	local history = make()
	T(history:Add("one"))["=="](true)
	T(history:Add("one"))["=="](false)
	T(history:Add("   "))["=="](false)
	T(history:Add(""))["=="](false)
	T(history:GetCount())["=="](1)
end)

T.Test("input history add moves older duplicates to the end", function()
	local history = make{"a", "b", "c"}
	history:Add("a")
	T(table.concat(history:GetEntries(), ","))["=="]("b,c,a")
end)

T.Test("input history respects max entries", function()
	local history = InputHistory.New{MaxEntries = 3}

	for _, entry in ipairs{"1", "2", "3", "4", "5"} do
		history:Add(entry)
	end

	T(table.concat(history:GetEntries(), ","))["=="]("3,4,5")
end)

T.Test("input history older and newer walk entries and restore the draft", function()
	local history = make{"one", "two", "three"}
	T(history:Older("draft"))["=="]("three")
	T(history:Older("three"))["=="]("two")
	T(history:Older("two"))["=="]("one")
	T(history:Older("one"))["=="](nil)
	T(history:GetIndex())["=="](1)
	T(history:Newer("one"))["=="]("two")
	T(history:Newer("two"))["=="]("three")
	T(history:Newer("three"))["=="]("draft")
	T(history:IsBrowsing())["=="](false)
	T(history:Newer("draft"))["=="](nil)
end)

T.Test("input history keeps edits to an entry while browsing", function()
	local history = make{"one", "two"}
	T(history:Older(""))["=="]("two")
	T(history:Older("two edited"))["=="]("one")
	T(history:Newer("one"))["=="]("two edited")
	T(history:Newer("two edited"))["=="]("")
	history:Reset()
	T(history:Older(""))["=="]("two")
end)

T.Test("input history prefix search skips other entries", function()
	local history = make{"help me", "say hi", "help you", "quit"}
	T(history:Older("hel", "hel"))["=="]("help you")
	T(history:Older("help you"))["=="]("help me")
	T(history:Older("help me"))["=="](nil)
	T(history:Newer("help me"))["=="]("help you")
	T(history:Newer("help you"))["=="]("hel")
end)

T.Test("input history older with no entries does not start browsing", function()
	local history = make()
	T(history:Older("draft"))["=="](nil)
	T(history:IsBrowsing())["=="](false)
end)

T.Test("input history search is case insensitive and newest first", function()
	local history = make{"Hello world", "other", "say hello"}
	local results = history:Search("HELLO")
	T(#results)["=="](2)
	T(results[1].text)["=="]("say hello")
	T(results[2].index)["=="](1)
end)

T.Test("input history remove and clear", function()
	local history = make{"a", "b", "c"}
	history:Remove(2)
	T(table.concat(history:GetEntries(), ","))["=="]("a,c")
	history:Clear()
	T(history:GetCount())["=="](0)
end)
