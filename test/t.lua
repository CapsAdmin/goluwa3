require("goluwa.global_environment")
local test = require("goluwa.helpers.test")
local attest = require("helpers.attest")
local T = setmetatable(
	{
		test = test.Test,
		pending = test.Pending,
		run_for = test.RunFor,
		run_until = test.WaitUntil,
		run_until2 = test.RunUntil2,
		yield = test.Yield,
		sleep = test.Sleep,
		wait_until = test.WaitUntil,
	},
	{
		__call = function(_, val)
			return attest.AssertHelper(val)
		end,
	}
)
return T
