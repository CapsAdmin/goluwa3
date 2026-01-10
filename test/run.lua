local test = require("helpers.test")
local attest = require("helpers.attest")
local event = require("event")
local filter = nil
local logging = true
local profiling = false
local profiling_mode = nil

if ... then
	if ... == "--filter" then filter = select(2, ...) end

	if (...):starts_with("--filter=") then filter = assert((...):split("=")[2]) end

	if not filter then filter = ... end
end

event.AddListener("Initialize", "tests", function()
	test.RunTestsWithFilter(
		filter,
		{
			logging = logging,
			profiling = profiling,
			profiling_mode = profiling_mode,
		}
	)
end)

event.AddListener("ShutDown", "tests", function()
	test.EndTests()
end)
