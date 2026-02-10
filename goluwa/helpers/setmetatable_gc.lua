local rawset = rawset
local rawget = rawget
local getmetatable = getmetatable
local newproxy = newproxy
local setmetatable = setmetatable
local DEBUG = _G.DEBUG
local function gc(s)
	local tbl = getmetatable(s).__div
	local tr = DEBUG and getmetatable(s).__mul
	rawset(tbl, "__gc_proxy", nil)
	local new_meta = getmetatable(tbl)

	if new_meta then
		local __gc = rawget(new_meta, "__gc")

		if __gc then
			local ok, err = pcall(__gc, tbl)

			if not ok then
				if tr then
					print(err)
					print(tr)
				else
					print("Error in __gc metamethod: " .. err)
				end
			end
		end
	end
end

local function setmetatable_with_gc(tbl, meta)
	if meta and rawget(meta, "__gc") and not rawget(tbl, "__gc_proxy") then
		local proxy = newproxy(true)
		rawset(tbl, "__gc_proxy", proxy)
		getmetatable(proxy).__div = tbl
		if DEBUG then
			getmetatable(proxy).__mul = debug.traceback()
		end
		getmetatable(proxy).__gc = gc
	end

	return setmetatable(tbl, meta)
end

return setmetatable_with_gc
