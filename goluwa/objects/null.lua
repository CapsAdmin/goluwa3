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
	--error(("tried to index %q on a NULL value"):format(key), 2)
	end

	objects.Register(NULL)
end

function objects.MakeNULL(tbl)
	table.clear(tbl)
	tbl.Type = "null"
	setmetatable(tbl, objects.GetRegistered("null"))

	if objects.created_objects then objects.created_objects[tbl] = nil end
end

_G.NULL = setmetatable({Type = "null"}, objects.GetRegistered("null"))
