local simple = library()

function simple.Encode(tbl)
	local str = {}

	for k, v in pairs(tbl) do
		list.insert(str, tostring(k))
		list.insert(str, "=")
		list.insert(str, tostring(v))
		list.insert(str, "\n")
	end

	return list.concat(str)
end

function simple.Decode(str)
	local out = {}

	for k, v in str:gmatch("(.-)=(.-)\n") do
		out[from_string(k)] = from_string(v)
	end

	return out
end

return simple
