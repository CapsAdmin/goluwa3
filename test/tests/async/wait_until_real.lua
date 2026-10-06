local T = import("test/environment.lua")
local attest = import("goluwa/attest.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")

T.Test("WaitUntilReal returns once the condition becomes true", function()
	local done = false

	timer.Delay(0.2, function()
		done = true
	end)

	local start = system.GetTime()
	T(T.WaitUntilReal(function()
		return done
	end, 5))["=="](true)
	T(system.GetTime() - start)["<"](2)
end)

T.Test("WaitUntilReal times out in wall clock time", function()
	local start = system.GetTime()

	attest.fails(
		function()
			T.WaitUntilReal(function()
				return false
			end, 0.3)
		end,
		"WaitUntilReal"
	)

	local elapsed = system.GetTime() - start
	T(elapsed)[">="](0.3)
	T(elapsed)["<"](2)
end)

T.Test("WaitUntilReal keeps a long wait from tripping the stall timeout", function()
	local start = system.GetTime()
	local done = false

	timer.Delay(0.1, function()
		done = true
	end)

	T.WaitUntilReal(function()
		return done
	end, 30)

	T(system.GetTime() - start)["<"](5)
end)
