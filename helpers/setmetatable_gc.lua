local rawset = rawset
local rawget = rawget
local getmetatable = getmetatable
local newproxy = newproxy
local setmetatable = setmetatable

local function gc(s)
	local tbl = getmetatable(s).__div
	rawset(tbl, "__gc_proxy", nil)
	local new_meta = getmetatable(tbl)

	if new_meta then
		local __gc = rawget(new_meta, "__gc")

		if __gc then __gc(tbl) end
	end
end

local function setmetatable_with_gc(tbl, meta)
	if meta and rawget(meta, "__gc") and not rawget(tbl, "__gc_proxy") then
		local proxy = newproxy(true)
		rawset(tbl, "__gc_proxy", proxy)
		getmetatable(proxy).__div = tbl
		getmetatable(proxy).__gc = gc
	end

	return setmetatable(tbl, meta)
end

return setmetatable_with_gc
