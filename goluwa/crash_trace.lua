local ffi = require("ffi")
local installed_handlers = {}
local installed = false
local crash_trace = {}
local write_stderr

if ffi.os == "Windows" then
	ffi.cdef([[ 
		typedef long LONG;
		typedef unsigned long DWORD;
		typedef unsigned short WORD;
		typedef int BOOL;
		typedef void *HANDLE;
		typedef void *PVOID;
		typedef DWORD *PDWORD;
		typedef struct _EXCEPTION_RECORD {
			DWORD ExceptionCode;
			DWORD ExceptionFlags;
			struct _EXCEPTION_RECORD *ExceptionRecord;
			PVOID ExceptionAddress;
			DWORD NumberParameters;
			uintptr_t ExceptionInformation[15];
		} EXCEPTION_RECORD;
		typedef struct _EXCEPTION_POINTERS {
			EXCEPTION_RECORD *ExceptionRecord;
			void *ContextRecord;
		} EXCEPTION_POINTERS;
		typedef LONG (__stdcall *PVECTORED_EXCEPTION_HANDLER)(EXCEPTION_POINTERS *ExceptionInfo);
		typedef LONG (__stdcall *PTOP_LEVEL_EXCEPTION_FILTER)(EXCEPTION_POINTERS *ExceptionInfo);
		typedef void (__cdecl *sighandler_t)(int32_t);
		PVOID AddVectoredExceptionHandler(DWORD first, PVECTORED_EXCEPTION_HANDLER handler);
		DWORD RemoveVectoredExceptionHandler(PVOID handle);
		PTOP_LEVEL_EXCEPTION_FILTER SetUnhandledExceptionFilter(PTOP_LEVEL_EXCEPTION_FILTER top_level_exception_filter);
		sighandler_t signal(int32_t signum, sighandler_t handler);
		BOOL SetConsoleCtrlHandler(void *handler, BOOL add);
		HANDLE GetStdHandle(DWORD nStdHandle);
		BOOL WriteFile(HANDLE hFile, const void *lpBuffer, DWORD nNumberOfBytesToWrite, DWORD *lpNumberOfBytesWritten, void *lpOverlapped);
		HANDLE GetCurrentProcess(void);
		BOOL TerminateProcess(HANDLE hProcess, unsigned int uExitCode);
		WORD RtlCaptureStackBackTrace(DWORD frames_to_skip, DWORD frames_to_capture, void **backtrace, DWORD *backtrace_hash);
	]])
	local kernel32 = ffi.load("kernel32")
	local STDERR_HANDLE = ffi.cast("DWORD", -12)
	local EXCEPTION_CONTINUE_SEARCH = 0
	local EXCEPTION_EXECUTE_HANDLER = 1
	local exception_codes = {
		[0xC0000005] = "EXCEPTION_ACCESS_VIOLATION",
		[0xC000001D] = "EXCEPTION_ILLEGAL_INSTRUCTION",
		[0xC000008C] = "EXCEPTION_ARRAY_BOUNDS_EXCEEDED",
		[0xC0000094] = "EXCEPTION_INT_DIVIDE_BY_ZERO",
		[0xC0000095] = "EXCEPTION_INT_OVERFLOW",
		[0xC00000FD] = "EXCEPTION_STACK_OVERFLOW",
		[0x80000003] = "EXCEPTION_BREAKPOINT",
	}
	local fatal_exception_lookup = {
		[0xC0000005] = true,
		[0xC000001D] = true,
		[0xC000008C] = true,
		[0xC0000094] = true,
		[0xC0000095] = true,
		[0xC00000FD] = true,
	}
	write_stderr = function(str)
		local stderr_handle = kernel32.GetStdHandle(STDERR_HANDLE)

		if stderr_handle == nil then return end

		local written = ffi.new("DWORD[1]")
		kernel32.WriteFile(stderr_handle, str, #str, written, nil)
	end

	local function write_lua_trace(prefix)
		local ok, trace = pcall(debug.traceback, prefix, 2)

		if ok and trace and trace ~= "" then write_stderr(trace .. "\n") end
	end

	local function write_native_stack()
		local frames = ffi.new("void *[64]")
		local count = tonumber(kernel32.RtlCaptureStackBackTrace(0, 64, frames, nil)) or 0

		if count == 0 then
			write_stderr("native stack traceback unavailable\n")
			return
		end

		write_stderr("native stack traceback:\n")

		for i = 0, count - 1 do
			write_stderr(string.format("  #%02d %p\n", i, frames[i]))
		end
	end

	local reported_exception = false

	local function handle_windows_exception(info)
		local record = info ~= nil and info.ExceptionRecord or nil
		local code = record ~= nil and tonumber(record.ExceptionCode) or 0

		if not fatal_exception_lookup[code] then
			return EXCEPTION_CONTINUE_SEARCH
		end

		if reported_exception then return EXCEPTION_CONTINUE_SEARCH end

		reported_exception = true
		local address = record ~= nil and record.ExceptionAddress or nil
		local name = exception_codes[code] or string.format("0x%08X", code)
		write_stderr("\nreceived structured exception " .. name)

		if address ~= nil then write_stderr(string.format(" at %p", address)) end

		write_stderr("\n")
		write_lua_trace("Lua stack traceback:")
		write_native_stack()
		kernel32.TerminateProcess(kernel32.GetCurrentProcess(), code ~= 0 and code or 1)
		return EXCEPTION_EXECUTE_HANDLER
	end

	function crash_trace.Install()
		if installed then return end

		installed_handlers.vectored_exception = ffi.cast("PVECTORED_EXCEPTION_HANDLER", handle_windows_exception)
		installed_handlers.unhandled_exception = ffi.cast("PTOP_LEVEL_EXCEPTION_FILTER", handle_windows_exception)
		installed_handlers.vectored_handle = kernel32.AddVectoredExceptionHandler(1, installed_handlers.vectored_exception)
		kernel32.SetUnhandledExceptionFilter(installed_handlers.unhandled_exception)
		installed = true
	end
else
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
	local crash_signals = {"SIGSEGV", "SIGILL", "SIGFPE", "SIGABRT"}
	local term_signals = {"SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"}
	ffi.cdef([[ 
		typedef void (*sighandler_t)(int32_t);
		sighandler_t signal(int32_t signum, sighandler_t handler);
		uint32_t getpid(void);
		int kill(uint32_t pid, int sig);
		int backtrace(void **buffer, int size);
		void backtrace_symbols_fd(void *const *buffer, int size, int fd);
		intptr_t write(int fd, const void *buf, size_t count);
	]])
	write_stderr = function(str)
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
end

function crash_trace.Run(func, ...)
	crash_trace.Install()
	local args = {...}
	local result = {
		xpcall(function()
			return func(unpack(args))
		end, debug.traceback),
	}

	if result[1] then return unpack(result, 2) end

	io.stderr:write(result[2], "\n")
	os.exit(1)
end

return crash_trace
