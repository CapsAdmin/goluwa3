local ffi = require("ffi")
local get_time = import("goluwa/bindings/time.lua")
local event = import("goluwa/event.lua")
local system = {}
import.loaded["goluwa/system.lua"] = system
local Window = import("goluwa/window.lua")
ffi.cdef([[
	int fflush(void *stream);
	int _exit(int status);
]])
local is_console

if ffi.os == "Windows" then
	ffi.cdef([[
		int GetConsoleMode(void *handle, uint32_t *mode);
		void *GetStdHandle(unsigned long id);
	]])
	local mode = ffi.new("uint32_t[1]")

	function is_console()
		return ffi.C.GetConsoleMode(ffi.C.GetStdHandle(-10), mode) ~= 0 and
			ffi.C.GetConsoleMode(ffi.C.GetStdHandle(-11), mode) ~= 0
	end
else
	ffi.cdef("int isatty(int fd);")

	function is_console()
		return ffi.C.isatty(0) ~= 0
	end
end

function system.GetTime()
	return get_time()
end

local get_time_ns = import("goluwa/bindings/time_ns.lua")

function system.GetTimeNS()
	return get_time_ns()
end

function system.GetDesktopSize()
	return Window.GetDesktopSize()
end

do
	function system.ShutDown(code)
		code = code or 0
		os.exitcode = code
		os.realexit(code)
	-- TODO: just exit for now
	end

	local old = os.exit

	function os.exit(code)
		system.ShutDown(code)
	end

	function os.realexit(code)
		local output = import("goluwa/cli/output.lua")
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

do
	local frame_time = 0.1

	function system.GetFrameTime()
		return frame_time
	end

	function system.SetFrameTime(dt)
		frame_time = dt
	end
end

do
	local frame_time = 0.1

	function system.GetInternalFrameTime()
		return frame_time
	end

	function system.SetInternalFrameTime(dt)
		frame_time = dt
	end
end

do
	local frame_number = 0

	function system.GetFrameNumber()
		return frame_number
	end

	function system.SetFrameNumber(num)
		frame_number = num
	end
end

do
	local elapsed_time = 0

	function system.GetElapsedTime()
		return elapsed_time
	end

	function system.SetElapsedTime(num)
		elapsed_time = num
	end
end

do
	local offset = 0
	local synced = false

	function system.SetServerTime(time)
		local sample = time - system.GetElapsedTime()

		if not synced or sample > offset then
			offset = sample
			synced = true
		else
			offset = offset + (sample - offset) * 0.02
		end
	end

	function system.ResetGameTime()
		offset = 0
		synced = false
	end

	function system.GetGameTime()
		return system.GetElapsedTime() + offset
	end
end

do
	local arg = _G.arg or {}
	local executable_path = arg[-1]
	local script_path = arg[0]

	function system.GetExecutablePath()
		return executable_path
	end

	function system.GetScriptPath()
		return script_path
	end

	local arguments = {}

	for i = 1, #arg do
		arguments[i] = arg[i]
	end

	function system.GetStartupArguments()
		return arguments
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

	return is_console()
end

local sleep = import("goluwa/bindings/threads.lua").sleep

function system.Sleep(seconds)
	sleep(seconds * 1000)
end

do
	local function read_file(path)
		local file = io.open(path, "rb")

		if not file then return nil end

		local content = file:read("*a")
		file:close()
		return content
	end

	-- returns the bytes this process tree may still use: limit is the tightest cgroup limit above the
	-- process (or physical memory), used is its working set without the reclaimable file cache
	function system.GetMemoryInfo()
		if jit.os ~= "Linux" then return nil end

		local meminfo = read_file("/proc/meminfo")
		local limit = tonumber(meminfo:match("MemTotal:%s+(%d+)")) * 1024
		local used = limit - tonumber(meminfo:match("MemAvailable:%s+(%d+)")) * 1024
		local cgroup = read_file("/proc/self/cgroup")
		local v2_path = ("\n" .. cgroup):match("\n0::(/[^\n]*)")
		local v1_path = ("\n" .. cgroup):match("\n%d+:[^\n:]*memory[^\n:]*:(/[^\n]*)")
		local root, path, limit_file, usage_file, inactive_key

		if v2_path and read_file("/sys/fs/cgroup/memory.max") then
			root, path = "/sys/fs/cgroup", v2_path
			limit_file, usage_file, inactive_key = "memory.max", "memory.current", "inactive_file"
		elseif v1_path then
			root, path = "/sys/fs/cgroup/memory", v1_path
			limit_file, usage_file, inactive_key = "memory.limit_in_bytes", "memory.usage_in_bytes", "total_inactive_file"
		else
			return {limit = limit, used = used}
		end

		while true do
			local dir = path == "/" and root or root .. path
			local group_limit = tonumber(read_file(dir .. "/" .. limit_file))

			if group_limit and group_limit < 2 ^ 60 then
				local group_usage = tonumber(read_file(dir .. "/" .. usage_file))

				if group_usage then
					local inactive = (read_file(dir .. "/memory.stat") or ""):match("\n" .. inactive_key .. " (%d+)")
					group_usage = group_usage - (tonumber(inactive) or 0)

					if group_limit - group_usage < limit - used then
						limit, used = group_limit, group_usage
					end
				end
			end

			if path == "/" then break end

			path = path:match("^(.*)/[^/]*$")

			if path == "" then path = "/" end
		end

		return {limit = limit, used = used}
	end
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

if jit.os == "Windows" then
	ffi.cdef([[
		long RegGetValueA(
			intptr_t hkey,
			const char *subkey,
			const char *value,
			uint32_t flags,
			uint32_t *type,
			void *data,
			uint32_t *size
		);
	]])
	local advapi32 = ffi.load("advapi32")
	local RRF_RT_REG_SZ = 0x2
	local hives = {
		ClassesRoot = 0x80000000,
		CurrentUser = 0x80000001,
		LocalMachine = 0x80000002,
		Users = 0x80000003,
	}
	local buffer = ffi.new("char[1024]")
	local size = ffi.new("uint32_t[1]")

	function system.GetRegistryValue(path)
		local hive, key, name = path:match("^(%w+)/(.+)/([^/]+)$")
		size[0] = 1024

		if
			advapi32.RegGetValueA(
				ffi.cast("int32_t", hives[hive]),
				key:gsub("/", "\\"),
				name,
				RRF_RT_REG_SZ,
				nil,
				buffer,
				size
			) ~= 0
		then
			return nil
		end

		return ffi.string(buffer, size[0] - 1)
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

	function system.IsWindowOpen(index)
		return state.active[index or 1] ~= nil
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
