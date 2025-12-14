require("goluwa.global_environment")
local test = require("goluwa.helpers.test")
local attest = require("goluwa.helpers.attest")
local filter = nil
local logging = true
local profiling = false
local profiling_mode = nil
test.BeginTests(logging, profiling, profiling_mode)
local tests = test.FindTests(filter)
test.SetTestPaths(tests)

for _, test_item in ipairs(tests) do
	test.RunSingleTest(test_item)
end

test.EndTests()
