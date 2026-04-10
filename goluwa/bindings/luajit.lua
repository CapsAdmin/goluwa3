local ffi = require("ffi")
local setmetatable = import("goluwa/helpers/setmetatable_gc.lua")
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

	return setmetatable({
		lua_state = L,
	}, LuaState)
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
	ffi.C.lua_settop(self.lua_state, -2)
	return result
end
function LuaState:Close()
	if not self.lua_state then return true end

	ffi.C.lua_close(self.lua_state)
    
    self.lua_state = nil
	self.func_ptr = nil
	return true
end

return LuaState