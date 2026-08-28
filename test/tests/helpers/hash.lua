local T = import("test/environment.lua")
local Hash = import("goluwa/hash.lua")

T.Test("hash intern returns monotonically increasing IDs", function()
	local interner = Hash.New()
	local id1 = interner:intern({"a", 1})
	local id2 = interner:intern({"a", 1})
	local id3 = interner:intern({"a", 2})
	T(id1)["=="](id2) -- same args = same ID
	T(id3)["=="](id1 + 1) -- different args = next ID
end)

T.Test("hash intern is stable for nil values", function()
	local interner = Hash.New()
	T(interner:intern(nil))["=="](interner:intern(nil))
	T(interner:intern({"x", nil}, 2))["=="](interner:intern({"x", nil}, 2))
	T(interner:intern(nil))["~="](interner:intern({"x", nil}, 2))
end)

T.Test("hash intern distinguishes booleans", function()
	local interner = Hash.New()
	T(interner:intern({true}))["~="](interner:intern({false}))
	T(interner:intern({true}))["=="](interner:intern({true}))
	T(interner:intern({false}))["=="](interner:intern({false}))
end)

T.Test("hash intern distinguishes numbers", function()
	local interner = Hash.New()
	T(interner:intern({0}))["~="](interner:intern({1}))
	T(interner:intern({0.5}))["~="](interner:intern({0.6}))
	T(interner:intern({1}))["=="](interner:intern({1}))
end)

T.Test("hash intern distinguishes strings", function()
	local interner = Hash.New()
	T(interner:intern({"foo"}))["~="](interner:intern({"bar"}))
	T(interner:intern({"foo"}))["=="](interner:intern({"foo"}))
end)

T.Test("hash intern handles arrays by length then elements", function()
	local interner = Hash.New()
	T(interner:intern({{1, 2}}))["=="](interner:intern({{1, 2}}))
	T(interner:intern({{1, 2}}))["~="](interner:intern({{2, 1}}))
	T(interner:intern({{1, 2}}))["~="](interner:intern{{1, 2, 3}})
	T(interner:intern({{}}))["=="](interner:intern({{}}))
end)

T.Test("hash intern handles empty tables with nil sentinel", function()
	local interner = Hash.New()
	T(interner:intern({{}}))["=="](interner:intern({{}}))
	T(interner:intern({{}}))["=="](interner:intern({nil}, 1)) -- empty table = nil
end)

T.Test("hash internWith extracts values by keys", function()
	local interner = Hash.New()
	local config = {a = 1, b = 2, c = 3}
	T(interner:internWith(config, {"a", "b"}))["=="](interner:internWith(config, {"a", "b"}))
	local config2 = {a = 1, b = 4, c = 3}
	T(interner:internWith(config, {"a", "b"}))["~="](interner:internWith(config2, {"a", "b"}))
	T(interner:internWith(nil, {"a", "b"}))["=="](interner:internWith(nil, {"a", "b"}))
end)

T.Test("hash nested intern works correctly", function()
	local interner = Hash.New()
	local a = {{1, 2}, {3, 4}}
	local b = {{1, 2}, {3, 4}}
	local c = {{1, 2}, {3, 5}}
	T(interner:intern(a))["=="](interner:intern(b))
	T(interner:intern(a))["~="](interner:intern(c))
end)

T.Test("hash intern starts at 1", function()
	local interner = Hash.New()
	T(interner:intern({"first"}))["=="](1)
	T(interner:intern({"second"}))["=="](2)
end)

T.Test("hash multiple values with mixed types", function()
	local interner = Hash.New()
	T(interner:intern({"str", 42, true, nil}, 4))["~="](interner:intern({"str", 42, false, nil}, 4))
	T(interner:intern({"str", 42, true, nil}, 4))["~="](interner:intern({"str", 42, true, "not_nil"}, 4))
	T(interner:intern({"str", 42, true, nil}, 4))["=="](interner:intern({"str", 42, true, nil}, 4))
end)

T.Test("hash internWith with missing keys returns nil", function()
	local interner = Hash.New()
	local config = {a = 1}
	T(interner:internWith(config, {"a", "b", "c"}))["=="](interner:internWith(config, {"a", "b", "c"}))
	local config2 = {a = 1, b = 2}
	T(interner:internWith(config, {"a", "b", "c"}))["~="](interner:internWith(config2, {"a", "b", "c"}))
end)
