local objects = import("goluwa/objects/objects.lua")

do
	local NULL = {}
	NULL.Type = "null"
	NULL.IsNull = true

	local function FALSE()
		return false
	end

	function NULL:IsValid()
		return false
	end

	function NULL:__tostring()
		return "NULL"
	end

	function NULL:__copy()
		return self
	end

	function NULL:__index2(key)
		if type(key) == "string" and key:sub(0, 2) == "Is" then return FALSE end
	end

	objects.Register(NULL)
end

function objects.MakeNULL(tbl)
	local proxy = rawget(tbl, "__gc_proxy")

	if proxy then
		local meta = getmetatable(proxy)
		meta.__gc = nil
		meta.__div = nil
	end

	table.clear(tbl)
	tbl.Type = "null"
	setmetatable(tbl, objects.GetRegistered("null"))

	if objects.created_objects then objects.created_objects[tbl] = nil end
end

_G.NULL = setmetatable({Type = "null"}, objects.GetRegistered("null"))
