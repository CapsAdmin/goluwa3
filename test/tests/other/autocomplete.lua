local T = import("test/environment.lua")
local autocomplete = import("goluwa/autocomplete.lua")

local function with_lists(lists, fn)
	local saved = autocomplete.lists
	autocomplete.lists = {}

	for _, entry in ipairs(lists) do
		autocomplete.AddList(entry[1], entry[2], entry[3])
	end

	local ok, err = pcall(fn)
	autocomplete.lists = saved

	if not ok then error(err, 0) end
end

local function values(results)
	local out = {}

	for i, result in ipairs(results) do
		out[i] = result.val
	end

	return table.concat(out, ",")
end

T.Test("autocomplete ranks prefix matches before word and inner matches", function()
	with_lists({{"a", {"xxhelloxx", "say hello", "hello world", "help", "hello"}}}, function()
		T(values(autocomplete.Search("hel")))["=="]("help,hello,hello world,say hello,xxhelloxx")
	end)
end)

T.Test("autocomplete reports the matched range", function()
	with_lists({{"a", {"say hello"}}}, function()
		local result = autocomplete.Search("hello")[1]
		T(result.start)["=="](5)
		T(result.stop)["=="](9)
		T(result.id)["=="]("a")
	end)
end)

T.Test("autocomplete is case insensitive unless asked", function()
	with_lists({{"a", {"Hello", "hello"}}}, function()
		T(#autocomplete.Search("HELLO"))["=="](2)
		T(#autocomplete.Search("Hello", {CaseSensitive = true}))["=="](1)
	end)
end)

T.Test("autocomplete treats the query as plain text", function()
	with_lists({{"a", {"f(x) = 1", "a.b", "axb"}}}, function()
		T(values(autocomplete.Search("(x")))["=="]("f(x) = 1")
		T(values(autocomplete.Search("a.")))["=="]("a.b")
		T(values(autocomplete.Search("%")))["=="]("")
	end)
end)

T.Test("autocomplete returns nothing for empty text", function()
	with_lists({{"a", {"one"}}}, function()
		T(#autocomplete.Search(""))["=="](0)
	end)
end)

T.Test("autocomplete prefix match mode skips inner matches", function()
	with_lists({{"a", {"hello", "say hello"}}}, function()
		T(values(autocomplete.Search("hello", {Match = "prefix"})))["=="]("hello")
	end)
end)

T.Test("autocomplete supports table entries and function sources", function()
	with_lists(
		{
			{"a", {{val = "alpha"}, "alps"}},
			{"b", function(text)
				return {text .. "bet", "other"}
			end},
		},
		function()
			T(values(autocomplete.Search("al")))["=="]("alps,alpha,albet")
			T(values(autocomplete.Search("zz")))["=="]("zzbet")
		end
	)
end)

T.Test("autocomplete filters by list id and respects the maximum", function()
	with_lists({{"a", {"one1", "one2", "one3"}}, {"b", {"one4"}}}, function()
		T(values(autocomplete.Search("one", {Lists = {"b"}})))["=="]("one4")
		T(#autocomplete.Search("one", {Max = 2}))["=="](2)
		T(#autocomplete.Search("one", {MaxPerList = 1}))["=="](2)
	end)
end)

T.Test("autocomplete remove list removes the matching list", function()
	with_lists({{"a", {"x1"}}, {"b", {"x2"}}, {"c", {"x3"}}}, function()
		T(autocomplete.RemoveList("b"))["=="](true)
		T(autocomplete.RemoveList("b"))["=="](false)
		T(table.concat(autocomplete.GetLists(), ","))["=="]("a,c")
		T(autocomplete.HasList("a"))["=="](true)
	end)
end)

T.Test("autocomplete replaces a list in place with new entries", function()
	with_lists({{"a", {"old1"}}}, function()
		autocomplete.AddList("a", {"new1"})
		T(values(autocomplete.Search("1")))["=="]("new1")
	end)
end)

T.Test("autocomplete rebuilds its index when a list grows", function()
	local words = {"alpha"}

	with_lists({{"a", words}}, function()
		T(#autocomplete.Search("al"))["=="](1)
		table.insert(words, "also")
		T(#autocomplete.Search("al"))["=="](2)
	end)
end)

T.Test("autocomplete list names resolve functions", function()
	autocomplete.SetListName("test_named", "plain")
	T(autocomplete.GetListName("test_named"))["=="]("plain")
	autocomplete.SetListName("test_named", function()
		return "dynamic"
	end)
	T(autocomplete.GetListName("test_named"))["=="]("dynamic")
	autocomplete.SetListName("test_named", nil)
end)

T.Test("autocomplete session ghost only completes prefix matches", function()
	with_lists({{"a", {"helicopter", "say hello"}}}, function()
		local session = autocomplete.NewSession()
		session:SetText("hel")
		T(session:GetGhost())["=="]("icopter")
		session:Move(1)
		T(session:GetGhost())["=="]("")
		session:SetText("")
		T(session:HasResults())["=="](false)
	end)
end)

T.Test("autocomplete session tab cycling keeps the query", function()
	with_lists({{"a", {"help", "hello", "helmet"}}}, function()
		local session = autocomplete.NewSession()
		session:SetText("hel")
		T(session:Cycle(1))["=="]("help")
		session:SetText("help")
		T(session:Cycle(1))["=="]("hello")
		session:SetText("hello")
		T(session:Cycle(-1))["=="]("help")
		T(session:Cycle(-1))["=="]("helmet")
		session:SetText("hel")
		T(session:GetSelectedIndex())["=="](1)
		T(session:IsExplicit())["=="](false)
	end)
end)

T.Test("autocomplete session has no ghost while cycling", function()
	with_lists({{"a", {"help", "hello"}}}, function()
		local session = autocomplete.NewSession()
		session:SetText("hel")
		T(session:GetGhost())["=="]("p")
		session:Cycle(1)
		T(session:GetGhost())["=="]("")
	end)
end)

T.Test("autocomplete session accept dismisses and dismiss resets on new text", function()
	with_lists({{"a", {"help", "hello"}}}, function()
		local session = autocomplete.NewSession()
		session:SetText("hel")
		session:Move(1)
		T(session:IsExplicit())["=="](true)
		T(session:Accept())["=="]("hello")
		T(session:HasResults())["=="](false)
		session:SetText("hel")
		T(session:HasResults())["=="](true)
		session:Dismiss()
		T(session:HasResults())["=="](false)
		T(session:GetGhost())["=="]("")
		session:SetText("he")
		T(session:HasResults())["=="](true)
	end)
end)

T.Test("autocomplete session bumps its version on changes", function()
	with_lists({{"a", {"help", "hello"}}}, function()
		local session = autocomplete.NewSession()
		local version = session.version
		session:SetText("hel")
		T(session.version)[">"](version)
		version = session.version
		session:SetText("hel")
		T(session.version)["=="](version)
		session:Move(1)
		T(session.version)[">"](version)
	end)
end)

T.Test("autocomplete session completes the last token with a custom query", function()
	with_lists({{"a", {"print", "pairs"}}}, function()
		local session = autocomplete.NewSession{
			GetQuery = function(text)
				local prefix, token = text:match("^(.-)([%w_]*)$")
				return prefix, token
			end,
		}
		session:SetText("x = pr")
		T(session:GetCompletion())["=="]("x = print")
		T(session:GetGhost())["=="]("int")
	end)
end)

T.Test("autocomplete session min length and clear", function()
	with_lists({{"a", {"help"}}}, function()
		local session = autocomplete.NewSession{MinLength = 2}
		session:SetText("h")
		T(session:HasResults())["=="](false)
		session:SetText("he")
		T(session:HasResults())["=="](true)
		session:Clear()
		T(session:HasResults())["=="](false)
		T(session.text)["=="]("")
	end)
end)

T.Test("autocomplete random picks distinct entries from table lists and is seeded", function()
	local words = {}

	for i = 1, 60 do
		words[i] = "word" .. i
	end

	with_lists({{"a", words}, {"b", {"other1", "other2"}}, {"c", function() return {"x"} end}}, function()
		local first = autocomplete.Random(20, {Seed = 5})
		T(#first)["=="](20)
		local seen = {}

		for _, result in ipairs(first) do
			T(seen[result.val])["=="](nil)
			seen[result.val] = true
		end

		T(first.ungrouped)["=="](true)
		T(values(autocomplete.Random(20, {Seed = 5})))["=="](values(first))
		T(values(autocomplete.Random(20, {Seed = 6})))["~="](values(first))
		T(#autocomplete.Random(500, {Seed = 1}))["<="](62)
		T(autocomplete.Random(3, {Lists = {"b"}, Seed = 1})[1].id)["=="]("b")
	end)
end)

T.Test("autocomplete session cycles a persistent random list on empty text", function()
	local words = {}

	for i = 1, 30 do
		words[i] = "word" .. i
	end

	with_lists({{"a", words}}, function()
		local session = autocomplete.NewSession{RandomCount = 10}
		session:Reseed(3)
		local first = session:Cycle(1)
		T(first)["~="](nil)
		session:SetText(first)
		local second = session:Cycle(1)
		T(second)["~="](first)
		session:SetText("")
		T(session:HasResults())["=="](false)
		local third = session:Cycle(1)
		T(third)["=="](session.random_results[3].val)
		local list = values(session.random_results)
		session:Reseed(3)
		session:SetText("")
		session:Cycle(1)
		T(values(session.random_results))["=="](list)
		session:Reseed(4)
		session:SetText("")
		session:Cycle(1)
		T(values(session.random_results))["~="](list)
	end)
end)

T.Test("autocomplete session without random count does nothing on empty text", function()
	with_lists({{"a", {"help"}}}, function()
		local session = autocomplete.NewSession()
		T(session:Cycle(1))["=="](nil)
	end)
end)

T.Test("autocomplete keep order lists rank by source order and match anywhere", function()
	with_lists({{"a", {"zzz hello", "hello", "xx hello yy"}, {KeepOrder = true}}}, function()
		T(values(autocomplete.Search("hello")))["=="]("zzz hello,hello,xx hello yy")
	end)
end)

T.Test("autocomplete empty queries only match when asked", function()
	with_lists({{"a", {"one", "two", "three"}}}, function()
		T(#autocomplete.Search(""))["=="](0)
		T(values(autocomplete.Search("", {MatchEmpty = true})))["=="]("one,two,three")
		local session = autocomplete.NewSession{MinLength = 0, MatchEmpty = true}
		session:SetText("x")
		session:SetText("")
		T(#session:GetResults())["=="](3)
	end)
end)
