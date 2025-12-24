-- this will attempt to print a traceback from C and Lua on segfault
local ffi = require("ffi")
local signals = {
	SIGHUP = 1, -- Hangup detected on controlling terminal
	SIGINT = 2, -- Interrupt from keyboard (Ctrl+C)
	SIGQUIT = 3, -- Quit from keyboard (Ctrl+\)
	SIGILL = 4, -- Illegal Instruction
	SIGABRT = 6, -- Abort signal from abort()
	SIGFPE = 8, -- Floating point exception
	SIGSEGV = 11, -- Invalid memory reference
	SIGPIPE = 13, -- Broken pipe
	SIGALRM = 14, -- Timer signal from alarm()
	SIGTERM = 15, -- Termination signal
}
ffi.cdef([[
    typedef struct lua_State lua_State;
    lua_State *luaL_newstate(void);
    void luaL_openlibs(lua_State *L);
    void lua_close(lua_State *L);
    int luaL_loadstring(lua_State *L, const char *s);
    int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
    void lua_getfield(lua_State *L, int index, const char *k);
    void lua_settop(lua_State *L, int index);
    void lua_pop(lua_State *L, int n);
    const char *lua_tolstring(lua_State *L, int index, size_t *len);
    ptrdiff_t lua_tointeger(lua_State *L, int index);
    int lua_gettop(lua_State *L);
    void lua_pushstring(lua_State *L, const char *s);
    const void *lua_topointer(lua_State *L, int index);
    double lua_tonumber(lua_State *L, int index);
    void *lua_touserdata(lua_State *L, int idx);
    void lua_pushlstring(lua_State *L, const char *p, size_t len);

    void luaL_traceback(lua_State *L, lua_State *L1, const char *msg, int level);
    int luaL_loadfile(lua_State *L, const char *filename);

	typedef void (*sighandler_t)(int32_t);
	sighandler_t signal(int32_t signum, sighandler_t handler);
	uint32_t getpid();
	int backtrace (void **buffer, int size);
	char ** backtrace_symbols_fd(void *const *buffer, int size, int fd);
	int kill(uint32_t pid, int sig);
	
	typedef struct FILE FILE;
	int fflush(FILE* stream);
	size_t fwrite(const void* ptr, size_t size, size_t count, FILE* stream);
	FILE *fdopen(int fd, const char *mode);
]])
local LUA_GLOBALSINDEX = -10002

-- Emergency terminal cleanup function to restore terminal state on crash
local function cleanup_terminal()
	print("EMERGENCY TERMINAL CLEANUP")
	local cleanup_seq = "\27[0m" .. -- Reset all attributes (NoAttributes)
		"\27[?1006l" .. -- Disable SGR mouse mode
		"\27[?1000l" .. -- Disable mouse tracking
		"\27[?1049l" .. -- Return to main screen
		"\27[?25h" -- Show cursor
	io.write(cleanup_seq)
	io.stdout:flush()
end

local function wrap(...)
	local state = ffi.C.luaL_newstate()
	io.stdout:setvbuf("no")
	-- Signals that should trigger cleanup and traceback
	local crash_signals = {"SIGSEGV", "SIGILL", "SIGFPE", "SIGABRT"}
	-- Signals that should just cleanup and exit gracefully
	local term_signals = {"SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"}

	-- Handle crash signals with full traceback
	for _, what in ipairs(crash_signals) do
		local enum = signals[what]

		ffi.C.signal(enum, function(int)
			cleanup_terminal()
			io.write("received signal ", what, "\n")
			io.write("C stack traceback:\n")
			local max = 64
			local array = ffi.new("void *[?]", max)
			local size = ffi.C.backtrace(array, max)
			ffi.C.backtrace_symbols_fd(array, size, 0)
			io.write()
			local header = "========== attempting lua traceback =========="
			io.write("\n\n", header, "\n")
			ffi.C.luaL_traceback(state, state, nil, 0)
			local len = ffi.new("uint64_t[1]")
			local ptr = ffi.C.lua_tolstring(state, -1, len)
			io.write(ffi.string(ptr, len[0]))
			io.write("\n", ("="):rep(#header), "\n")
			cleanup_terminal()
			ffi.C.signal(int, nil)
			ffi.C.kill(ffi.C.getpid(), int)
		end)
	end

	-- Handle termination signals with just cleanup
	for _, what in ipairs(term_signals) do
		local enum = signals[what]

		ffi.C.signal(enum, function(int)
			cleanup_terminal()
			io.write("\nreceived signal ", what, ", exiting gracefully\n")
			os.exit(128 + int)
		end)
	end

	ffi.C.luaL_openlibs(state)

	local function check_error(ok)
		if ok ~= 0 then
			error("glw errored: \n" .. ffi.string(ffi.C.lua_tolstring(state, -1, nil)))
			ffi.C.lua_close(state)
		end
	end

	check_error(ffi.C.luaL_loadstring(state, [[
			require("goluwa.main")(...)
		]]))

	for i = 1, select("#", ...) do
		local arg = select(i, ...)
		ffi.C.lua_pushlstring(state, arg, #arg)
	end

	check_error(ffi.C.lua_pcall(state, select("#", ...), 0, 0))
	cleanup_terminal()
	os.exit(0)
end

return wrap
