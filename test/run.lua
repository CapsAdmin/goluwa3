require("goluwa.global_environment")
local test = require("goluwa.helpers.test")
local attest = require("goluwa.helpers.attest")
local event = require("event")
local filter = nil
local logging = true
local profiling = false
local profiling_mode = nil

event.AddListener("Initialize", "tests", function()
	test.BeginTests(logging, profiling, profiling_mode)
	local tests = test.FindTests(filter)
	test.SetTestPaths(tests)

	for _, test_item in ipairs(tests) do
		test.RunSingleTestSet(test_item)
	end
end)

event.AddListener("ShutDown", "tests", function()
	test.EndTests()
end)

require("main")() -- needed to keep it alive
