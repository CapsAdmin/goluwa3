require("goluwa.global_environment")
local test = require("goluwa.helpers.test")
local attest = require("goluwa.helpers.attest")
local event = require("event")
local filter = nil
local logging = true
local profiling = false
local profiling_mode = nil

-- Setup tests to run on Initialize event
event.AddListener("Initialize", "test_initialization", function()
	test.BeginTests(logging, profiling, profiling_mode)
	local tests = test.FindTests(filter)
	test.SetTestPaths(tests)

	for _, test_item in ipairs(tests) do
		test.RunSingleTest(test_item)
	end
end)

-- Hook into shutdown to print test results
event.AddListener("ShutDown", "test_shutdown", function()
	test.EndTests()
end)

-- Run the main loop
require("goluwa.main")
