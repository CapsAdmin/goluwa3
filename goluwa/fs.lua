local fs = require("bindings.filesystem")
local utility = require("utility")

function fs.write_file(path, data)
	local file, err = io.open(path, "wb")

	if not file then return false, err end

	file:write(data)
	file:close()
	return true
end

function fs.read_file(path)
	local file, err = io.open(path, "rb")

	if not file then return nil, err end

	local data = file:read("*all")
	data = data or ""
	file:close()
	return data
end

function fs.iterate(dir, pattern)
	local files = fs.get_files and fs.get_files(dir) or {}
	local i = 0
	local n = #files
	return function()
		i = i + 1

		while i <= n do
			local file = files[i]

			if not pattern or file:match(pattern) then return dir .. "/" .. file end

			i = i + 1
		end
	end
end

function fs.get_parent_directory(path)
	-- Normalize path separators to forward slash
	path = path:gsub("\\", "/")

	-- Remove trailing slash if present
	if path:sub(-1) == "/" and path ~= "/" then path = path:sub(1, -2) end

	-- Extract parent directory
	local parent = path:match("(.+)/[^/]+$")

	-- Handle special cases
	if not parent then
		if path == "/" then
			return nil -- Root has no parent
		else
			return "." -- Current directory is parent
		end
	end

	-- Return the parent directory
	return parent
end

function fs.create_directory_recursive(path)
	-- Handle empty or root path
	if path == "" or path == "/" then return true end

	-- Normalize path separators to forward slash
	path = path:gsub("\\", "/")

	-- Remove trailing slash if present
	if path:sub(-1) == "/" then path = path:sub(1, -2) end

	-- Check if directory already exists
	if fs.exists(path) then
		if fs.is_directory(path) then
			return true -- Already exists as directory
		else
			return nil, "Path exists but is not a directory" -- Path exists as a file
		end
	end

	-- Get parent directory
	local parent = path:match("(.+)/[^/]+$") or ""

	-- If parent directory doesn't exist, create it first
	if parent ~= "" and not fs.exists(parent) then
		local ok, err = fs.create_directory_recursive(parent)

		if not ok then
			return nil, "Failed to create parent directory: " .. (err or "unknown error")
		end
	end

	-- Create the directory
	return fs.create_directory(path)
end

function fs.get_files_recursive(path)
	if path == "" then path = "." end

	if path:sub(-1) ~= "/" then path = path .. "/" end

	local out = {}
	local errors = {}
	out.n = 0

	if not fs.walk(path, out, errors, nil, true) then
		return nil, errors[1].error
	end

	out.n = nil
	return out, errors[1] and errors or nil
end

function fs.is_file(path)
	return fs.get_type(path) == "file"
end

function fs.is_directory(path)
	return fs.get_type(path) == "directory"
end

function fs.get_type(path)
	local stat = fs.get_attributes(path)
	return stat and stat.type or nil
end

function fs.exists(path)
	return fs.get_type(path) ~= nil
end

do
	fs.SetWorkingDirectory = fs.set_current_directory
	fs.GetWorkingDirectory = fs.get_current_directory
	utility.MakePushPopFunction(fs, "WorkingDirectory")
end

fs.GetAttributes = fs.get_attributes
return fs
