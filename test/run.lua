local test = require("helpers.test")
local attest = require("helpers.attest")
local event = require("event")
local filter = nil
local logging = true
local verbose = false
local profiling = false
local profiling_mode = nil

if ... then
	local args = {...}

	for i, arg in ipairs(args) do
		if arg == "--filter" then
			filter = args[i + 1]
		elseif arg:starts_with("--filter=") then
			filter = arg:split("=")[2]
		elseif arg == "--verbose" then
			verbose = true
		elseif not arg:starts_with("-") then
			filter = arg
		end
	end
end

event.AddListener("Initialize", "tests", function()
	test.RunTestsWithFilter(
		filter,
		{
			logging = logging,
			verbose = verbose,
			profiling = profiling,
			profiling_mode = profiling_mode,
		}
	)
end)

event.AddListener("ShutDown", "tests", function()
	test.EndTests()
end)
