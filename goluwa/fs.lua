local filesystem = require("bindings.filesystem")

function filesystem.write_file(path, data)
	local file, err = io.open(path, "wb")

	if not file then return false, err end

	file:write(data)
	file:close()
	return true
end

function filesystem.read_file(path)
	local file, err = io.open(path, "rb")

	if not file then return nil, err end

	local data = file:read("*all")
	data = data or ""
	file:close()
	return data
end

return filesystem
