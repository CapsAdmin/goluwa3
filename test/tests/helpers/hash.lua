local T = import("test/environment.lua")
local Hash = import("goluwa/hash.lua")

T.Test("hash intern returns monotonically increasing IDs", function()
	local interner = Hash.New()
	local id1 = interner:intern("a", 1)
	local id2 = interner:intern("a", 1)
	local id3 = interner:intern("a", 2)
	T(id1)["=="](id2) -- same args = same ID
	T(id3)["=="](id1 + 1) -- different args = next ID
end)

T.Test("hash intern is stable for nil values", function()
	local interner = Hash.New()
	T(interner:intern(nil))["=="](interner:intern(nil))
	T(interner:intern("x", nil))["=="](interner:intern("x", nil))
	T(interner:intern(nil))["~="](interner:intern("x", nil))
end)

T.Test("hash intern distinguishes booleans", function()
	local interner = Hash.New()
	T(interner:intern(true))["~="](interner:intern(false))
	T(interner:intern(true))["=="](interner:intern(true))
	T(interner:intern(false))["=="](interner:intern(false))
end)

T.Test("hash intern distinguishes numbers", function()
	local interner = Hash.New()
	T(interner:intern(0))["~="](interner:intern(1))
	T(interner:intern(0.5))["~="](interner:intern(0.6))
	T(interner:intern(1))["=="](interner:intern(1))
end)

T.Test("hash intern distinguishes strings", function()
	local interner = Hash.New()
	T(interner:intern("foo"))["~="](interner:intern("bar"))
	T(interner:intern("foo"))["=="](interner:intern("foo"))
end)

T.Test("hash intern handles arrays by length then elements", function()
	local interner = Hash.New()
	T(interner:intern({1, 2}))["=="](interner:intern({1, 2}))
	T(interner:intern({1, 2}))["~="](interner:intern({2, 1}))
	T(interner:intern({1, 2}))["~="](interner:intern({1, 2, 3}))
	T(interner:intern({}))["=="](interner:intern({}))
end)

T.Test("hash intern handles empty tables with nil sentinel", function()
	local interner = Hash.New()
	T(interner:intern({}))["=="](interner:intern({}))
	T(interner:intern({}))["=="](interner:intern(nil)) -- empty table = nil
end)

T.Test("hash internWith extracts values by keys", function()
	local interner = Hash.New()
	local config = {a = 1, b = 2, c = 3}
	T(interner:internWith(config, "a", "b"))["=="](interner:internWith(config, "a", "b"))
	local config2 = {a = 1, b = 4, c = 3}
	T(interner:internWith(config, "a", "b"))["~="](interner:internWith(config2, "a", "b"))
	T(interner:internWith(nil, "a", "b"))["=="](interner:internWith(nil, "a", "b"))
end)

T.Test("hash internDict sorts keys for stable dict hashing", function()
	local interner = Hash.New()
	local a = {z = 1, a = 2, m = 3}
	local b = {a = 2, m = 3, z = 1}
	T(interner:internDict(a))["=="](interner:internDict(b))
end)

T.Test("hash internDict handles empty dicts", function()
	local interner = Hash.New()
	T(interner:internDict({}))["=="](interner:internDict({}))
end)

T.Test("hash __hash_serialize metamethod", function()
	local interner = Hash.New()
	local mt = {
		__hash_serialize = function(self)
			return {self.x, self.y, self.z}
		end,
	}
	local a = setmetatable({x = 1, y = 2, z = 3}, mt)
	local b = setmetatable({x = 1, y = 2, z = 3}, mt)
	local c = setmetatable({x = 1, y = 2, z = 4}, mt)
	T(interner:intern(a))["=="](interner:intern(b))
	T(interner:intern(a))["~="](interner:intern(c))
	T(interner:intern(a))["=="](interner:intern(1, 2, 3))
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
	T(interner:intern("first"))["=="](1)
	T(interner:intern("second"))["=="](2)
end)

T.Test("hash multiple values with mixed types", function()
	local interner = Hash.New()
	T(interner:intern("str", 42, true, nil))["~="](interner:intern("str", 42, false, nil))
	T(interner:intern("str", 42, true, nil))["~="](interner:intern("str", 42, true, "not_nil"))
	T(interner:intern("str", 42, true, nil))["=="](interner:intern("str", 42, true, nil))
end)

T.Test("hash internWith with missing keys returns nil", function()
	local interner = Hash.New()
	local config = {a = 1}
	T(interner:internWith(config, "a", "b", "c"))["=="](interner:internWith(config, "a", "b", "c"))
	local config2 = {a = 1, b = 2}
	T(interner:internWith(config, "a", "b", "c"))["~="](interner:internWith(config2, "a", "b", "c"))
end)

T.Test("hash internDict with number keys", function()
	local interner = Hash.New()
	local a = {[1] = "x", [2] = "y"}
	local b = {[2] = "y", [1] = "x"}
	T(interner:internDict(a))["=="](interner:internDict(b))
end)

T.Test("hash internDict with mixed key types", function()
	local interner = Hash.New()
	local a = {[1] = "x", ["key"] = "y"}
	local b = {["key"] = "y", [1] = "x"}
	T(interner:internDict(a))["=="](interner:internDict(b))
end)
