local T = import("test/environment.lua")
local logging = import("goluwa/logging.lua")

T.Test("global print survives rebound environment", function()
	local old_env = getfenv(print)
	local old_raw_log = logging.RawLog
	local captured
	local ok, err = pcall(function()
		logging.RawLog = function(str)
			captured = str
		end
		setfenv(print, {})
		print("hello", 123)
	end)
	logging.RawLog = old_raw_log
	setfenv(print, old_env)

	if not ok then error(err, 0) end

	T(type(captured))["=="]("string")
	T(captured:find("hello", 1, true) ~= nil)["=="](true)
	T(captured:find("123", 1, true) ~= nil)["=="](true)
end)
