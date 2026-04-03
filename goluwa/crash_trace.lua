local ffi = require("ffi")

local signals = {
	SIGHUP = 1,
	SIGINT = 2,
	SIGQUIT = 3,
	SIGILL = 4,
	SIGABRT = 6,
	SIGFPE = 8,
	SIGSEGV = 11,
	SIGPIPE = 13,
	SIGALRM = 14,
	SIGTERM = 15,
}

ffi.cdef([[ 
	typedef void (*sighandler_t)(int32_t);
	sighandler_t signal(int32_t signum, sighandler_t handler);
	uint32_t getpid(void);
	int kill(uint32_t pid, int sig);
	int backtrace(void **buffer, int size);
	void backtrace_symbols_fd(void *const *buffer, int size, int fd);
	intptr_t write(int fd, const void *buf, size_t count);
]])

local installed_handlers = {}
local installed = false
local crash_signals = {"SIGSEGV", "SIGILL", "SIGFPE", "SIGABRT"}
local term_signals = {"SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"}
local crash_trace = {}

local function write_stderr(str)
	ffi.C.write(2, str, #str)
end

local function reset_signal(signum)
	ffi.C.signal(signum, ffi.cast("sighandler_t", 0))
end

function crash_trace.Install()
	if installed then return end

	for _, what in ipairs(crash_signals) do
		local signum = signals[what]

		installed_handlers[what] = ffi.cast("sighandler_t", function(received)
			write_stderr("\nreceived signal " .. what .. "\n")

			local ok, trace = pcall(debug.traceback, "Lua stack traceback:", 2)

			if ok and trace and trace ~= "" then write_stderr(trace .. "\n") end

			write_stderr("C stack traceback:\n")
			local frames = ffi.new("void *[64]")
			local size = ffi.C.backtrace(frames, 64)
			ffi.C.backtrace_symbols_fd(frames, size, 2)
			reset_signal(received)
			ffi.C.kill(ffi.C.getpid(), received)
		end)

		ffi.C.signal(signum, installed_handlers[what])
	end

	for _, what in ipairs(term_signals) do
		local signum = signals[what]

		installed_handlers[what] = ffi.cast("sighandler_t", function(received)
			write_stderr("\nreceived signal " .. what .. ", exiting\n")
			os.exit(128 + received)
		end)

		ffi.C.signal(signum, installed_handlers[what])
	end

	installed = true
end

function crash_trace.Run(func, ...)
	crash_trace.Install()
	local args = {...}

	local result = {
		xpcall(
		function()
			return func(unpack(args))
		end,
		debug.traceback
		)
	}

	if result[1] then return unpack(result, 2) end

	io.stderr:write(result[2], "\n")
	os.exit(1)
end

return crash_trace