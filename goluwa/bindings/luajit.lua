local ffi = require("ffi")
local setmetatable = import("goluwa/table/setmetatable_gc.lua")
local LuaState = {}
LuaState.__index = LuaState
ffi.cdef[[
    typedef struct lua_State lua_State;
    lua_State *luaL_newstate(void);
    void luaL_openlibs(lua_State *L);
    void lua_close(lua_State *L);
    int luaL_loadstring(lua_State *L, const char *s);
    int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
    void lua_settop(lua_State *L, int index);
    const char *lua_tolstring(lua_State *L, int index, size_t *len);
    void lua_pushlstring(lua_State *L, const char *p, size_t len);
	unsigned long long strtoull(const char *nptr, char **endptr, int base);

	typedef struct lua_Debug {
		int event;
		const char *name;
		const char *namewhat;
		const char *what;
		const char *source;
		int currentline;
		int nups;
		int linedefined;
		int lastlinedefined;
		char short_src[60];
		int i_ci;
	} lua_Debug;

	const void *lua_topointer(lua_State *L, int index);
	int lua_getstack(lua_State *L, int level, lua_Debug *ar);
	int lua_getinfo(lua_State *L, const char *what, lua_Debug *ar);

]]

local function check_error(L, ret)
	if ret == 0 then return end

	local chr = ffi.C.lua_tolstring(L, -1, nil)
	local msg = chr ~= nil and ffi.string(chr) or "unknown Lua state error"
	error(msg, 2)
end

function LuaState:Load(source)
	assert(type(source) == "string", "source must be a string")
	check_error(self.lua_state, ffi.C.luaL_loadstring(self.lua_state, source))
	return true
end

function LuaState:GetTopString()
	local out = ffi.C.lua_tolstring(self.lua_state, -1, nil)

	if out == nil then return nil end

	return ffi.string(out)
end

function LuaState:__gc()
	self:Close()
end

function LuaState.New()
	local L = ffi.C.luaL_newstate()

	if L == nil then error("Failed to create new Lua state: Out of memory", 2) end

	ffi.C.luaL_openlibs(L)
	return LuaState.FromLuaState(L)
end

function LuaState.FromLuaState(L)
	return setmetatable({
		lua_state = L,
	}, LuaState)
end

function LuaState.GetMainLuaState()
	local thread = coroutine.running()

	if thread == nil then error("coroutine is nil") end

	local addr = tostring(thread):match("0x%x+")

	if addr == nil then error("unable to parse address") end

	return ffi.cast("lua_State*", tonumber(addr))
end

function LuaState:Run(source, args)
	self:Load(source)
	local nargs = 0

	if args ~= nil then
		assert(type(args) == "string", "args must be a string")
		ffi.C.lua_pushlstring(self.lua_state, args, #args)
		nargs = 1
	end

	check_error(self.lua_state, ffi.C.lua_pcall(self.lua_state, nargs, 1, 0))
	local out = ffi.C.lua_tolstring(self.lua_state, -1, nil)

	if out == nil then
		ffi.C.lua_settop(self.lua_state, -2)
		error("Lua state did not return a pointer string", 2)
	end

	local result = ffi.C.strtoull(out, nil, 10)

	if result == nil then
		ffi.C.lua_settop(self.lua_state, -2)
		error("Lua state did not return a pointer string", 2)
	end

	ffi.C.lua_settop(self.lua_state, -2)
	return result
end

function LuaState:Close()
	if not self.lua_state then return true end

	--ffi.C.lua_close(self.lua_state)
	self.lua_state = nil
	self.func_ptr = nil
	return true
end

function LuaState:TraceBack()
	local frames = {}
	local ar = ffi.new("lua_Debug[1]")
	local level = 0

	while level < 64 and ffi.C.lua_getstack(self.lua_state, level, ar) ~= 0 do
		if ffi.C.lua_getinfo(self.lua_state, "Sl", ar) == 0 then break end

		local info = ar[0]
		local short_src = ffi.string(info.short_src)
		local what = info.what ~= nil and ffi.string(info.what) or "?"
		local line = info.currentline >= 0 and info.currentline or info.linedefined

		if what == "Lua" then
			frames[#frames + 1] = string.format("\t%s:%d", short_src, line)
		end

		level = level + 1
	end

	if #frames == 0 then return nil end

	return table.concat(frames, "\n")
end

return LuaState
