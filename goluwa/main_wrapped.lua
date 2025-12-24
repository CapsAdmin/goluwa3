-- this will attempt to print a traceback from C and Lua on segfault
local ffi = require("ffi")
local signals = {
	SIGSEGV = 11,
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
]])
local LUA_GLOBALSINDEX = -10002

local function wrap(path, ...)
	local state = ffi.C.luaL_newstate()
	io.stdout:setvbuf("no")

	for _, what in ipairs({"SIGSEGV"}) do
		local enum = signals[what]

		ffi.C.signal(enum, function(int)
			io.write("received signal ", what, "\n")

			if what == "SIGSEGV" then
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
				ffi.C.signal(int, nil)
				ffi.C.kill(ffi.C.getpid(), int)
			end
		end)
	end

	ffi.C.luaL_openlibs(state)

	local function check_error(ok)
		if ok ~= 0 then
			error("glw errored: \n" .. ffi.string(ffi.C.lua_tolstring(state, -1, nil)))
			ffi.C.lua_close(state)
		end
	end

	check_error(
		ffi.C.luaL_loadstring(state, [[
			require("goluwa.global_environment")
			require("main")(...)
		]])
	)
	ffi.C.lua_pushlstring(state, path, #path)

	for i = 1, select("#", ...) do
		local arg = select(i, ...)
		ffi.C.lua_pushlstring(state, arg, #arg)
	end

	check_error(ffi.C.lua_pcall(state, 1 + select("#", ...), 0, 0))
	os.exit(0)
end

return wrap
