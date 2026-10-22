local T = import("test/environment.lua")
local track = import("goluwa/math/track.lua")

T.Test("track interpolates keys and clamps outside them", function()
	local t = track.New{{0, 1}, {0.5, 3}, {1, 0}}
	T(t:Get(-1))["=="](1)
	T(t:Get(0.25))["=="](2)
	T(t:Get(0.5))["=="](3)
	T(t:Get(0.75))["=="](1.5)
	T(t:Get(2))["=="](0)
	T(t:Get(0.1))["=="](1.4)
end)

T.Test("track applies the ease of the segment a key starts", function()
	local t = track.New{{0, 0, "inQuad"}, {1, 1, "hold"}, {2, 5}}
	T(t:Get(0.5))["=="](0.25)
	T(t:Get(1.5))["=="](1)
	T(track.New{{
		0,
		0,
		function(f)
			return 1 - f
		end,
	}, {1, 1}}:Get(0.25))["=="](0.75)
end)

T.Test("track accepts a function and rejects bad keys", function()
	T(track.New(function(f)
		return f * 2
	end):Get(0.25))["=="](0.5)
	T(pcall(track.New, {{0, 0}, {0, 1}}))["=="](false)
	T(pcall(track.New, {{0, 0, "nope"}, {1, 1}}))["=="](false)
end)
