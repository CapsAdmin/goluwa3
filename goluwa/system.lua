local ffi = require("ffi")
local get_time = import("goluwa/bindings/time.lua")
local event = import("goluwa/event.lua")
local system = library()
import.loaded["goluwa/system.lua"] = system
local Window = import("goluwa/window.lua")
ffi.cdef([[
	int fflush(void *stream);
	int _exit(int status);
]])

function system.GetTime()
	return get_time()
end

local get_time_ns = import("goluwa/bindings/time_ns.lua")

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
		local output = import("goluwa/output.lua")
		output.Flush()
		output.Shutdown()
		io.flush()
		ffi.C.fflush(nil)

		if jit.os ~= "Windows" then ffi.C._exit(code or 0) end

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

	return true
end

local sleep = import("goluwa/bindings/threads.lua").sleep -- in ms
function system.Sleep(seconds)
	sleep(seconds * 1000)
end

do
	local refs = {}
	local obj_refs = setmetatable({}, {__mode = "v"})
	local is_running = false

	function system.KeepAlive(name)
		if type(name) == "table" then
			obj_refs[name] = debug.traceback()
		else
			refs[name] = debug.traceback()
		end

		is_running = true
		return function()
			refs[name] = nil
			obj_refs[name] = nil

			if not next(refs) and not next(obj_refs) then is_running = false end
		end
	end

	function system.IsRunning()
		return is_running
	end
end

function system.OpenURL(url)
	if jit.os == "Windows" then
		os.execute(string.format("start \"\" \"%s\"", url))
	elseif jit.os == "OSX" then
		os.execute(string.format("open \"%s\"", url))
	else
		os.execute(string.format("xdg-open \"%s\"", url))
	end
end

do
	local state = {
		active = {},
		current = nil,
	}

	function system.RegisterWindow(wnd)
		for _, active_wnd in ipairs(state.active) do
			if active_wnd == wnd then
				state.current = wnd
				return wnd
			end
		end

		list.insert(state.active, wnd)
		state.current = wnd
		return wnd
	end

	function system.UnregisterWindow(wnd)
		for i, active_wnd in ipairs(state.active) do
			if active_wnd == wnd then
				list.remove(state.active, i)

				if state.current == wnd then
					state.current = state.active[i] or state.active[i - 1]
				end

				break
			end
		end

		if not state.active[1] then state.current = nil end
	end

	function system.GetWindows()
		return state.active
	end

	function system.GetWindow(index)
		local wnd = state.active[index or 1]
		assert(wnd, "no window opened")
		return wnd
	end

	function system.GetCurrentWindow()
		return state.current or system.GetWindow()
	end

	function system.SetCurrentWindow(wnd)
		state.current = wnd
		return wnd
	end

	function system.CloseWindows()
		for i = #state.active, 1, -1 do
			local wnd = state.active[i]

			if wnd and wnd.IsValid and wnd:IsValid() then
				pcall(wnd.Remove, wnd)
			else
				list.remove(state.active, i)
			end
		end

		if not state.active[1] then state.current = nil end
	end

	function system.OpenWindow(...)
		return Window.New(...)
	end

	event.AddListener("Shutdown", "system_window_cleanup", function()
		system.CloseWindows()
	end)
end

return system
