local get_time = require("bindings.time")
local event = require("event")
local system = library()

function system.GetTime()
	return get_time()
end

local get_time_ns = require("bindings.time_ns")

function system.GetTimeNS()
	return get_time_ns()
end

do
	function system.ShutDown(code)
		code = code or 0

		if VERBOSE then logn("shutting down with code ", code) end

		os.exitcode = code
	end

	local old = os.exit

	function os.exit(code)
		wlog("os.exit() called with code %i", code or 0, 2)
	--system.ShutDown(code)
	end

	function os.realexit(code)
		-- Flush stdout pipe before exiting so any pending output is captured
		local ok, output = pcall(require, "output")

		if ok and output.Flush then pcall(output.Flush) end

		io.flush()
		old(code)
	end
end

local function not_implemented()
	debug.trace()
	logn("this function is not yet implemented!")
end

do -- frame time
	local frame_time = 0.1

	function system.GetFrameTime()
		return frame_time
	end

	-- used internally in main_loop.lua
	function system.SetFrameTime(dt)
		frame_time = dt
	end
end

do -- frame time
	local frame_time = 0.1

	function system.GetInternalFrameTime()
		return frame_time
	end

	-- used internally in main_loop.lua
	function system.SetInternalFrameTime(dt)
		frame_time = dt
	end
end

do -- frame number
	local frame_number = 0

	function system.GetFrameNumber()
		return frame_number
	end

	-- used internally in main_loop.lua
	function system.SetFrameNumber(num)
		frame_number = num
	end
end

do -- elapsed time (avanved from frame time)
	local elapsed_time = 0

	function system.GetElapsedTime()
		return elapsed_time
	end

	-- used internally in main_loop.lua
	function system.SetElapsedTime(num)
		elapsed_time = num
	end
end

do -- server time (synchronized across client and server)
	local server_time = 0

	function system.SetServerTime(time)
		server_time = time
	end

	function system.GetServerTime()
		return server_time
	end
end

do -- arg is made from luajit.exe
	local arg = _G.arg or {}
	_G.arg = nil
	arg[0] = nil
	arg[-1] = nil
	list.remove(arg, 1)

	function system.GetStartupArguments()
		return arg
	end
end

function system.IsTTY()
	if
		os.getenv("CI") or
		os.getenv("GITHUB_ACTIONS") or
		os.getenv("TRAVIS") or
		os.getenv("CIRCLECI") or
		os.getenv("GITLAB_CI") or
		os.getenv("JENKINS_HOME")
	then
		return false
	end

	-- Try to detect if stdout is a terminal
	local handle = io.popen("test -t 1 && echo yes || echo no", "r")

	if handle then
		local result = handle:read("*a"):match("^%s*(.-)%s*$")
		return result == "yes"
	end

	return true
end

local sleep = require("bindings.threads").sleep -- in ms
function system.Sleep(seconds)
	sleep(seconds * 1000)
end

do
	local refs = {}
	local is_running = false

	function system.KeepAlive(name)
		refs[name] = debug.traceback()
		is_running = true
		return function()
			refs[name] = nil

			if not next(refs) then is_running = false end
		end
	end

	function system.IsRunning()
		return is_running
	end
end

return system
