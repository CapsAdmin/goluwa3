require("goluwa.global_environment")
local test = require("helpers.test")
local attest = require("helpers.attest")
local T = setmetatable(
	{
		test = test.Test,
		run_for = test.RunFor,
		run_until = test.RunUntil,
		run_until2 = test.RunUntil2,
	},
	{
		__call = function(_, val)
			return attest.AssertHelper(val)
		end,
	}
)
return T
