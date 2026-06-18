local vfs = import.loaded["goluwa/filesystem/vfs.lua"] or {}

do
	local ext = jit.os == "OSX" and
		"dylib" or
		jit.os == "Linux" and
		"so" or
		jit.os == "Windows" and
		"dll"

	function vfs.GetSharedLibraryExtension()
		return ext
	end
end

function vfs.GetAddonFromPath(path)
	local abs = vfs.GetPathInfo(path).full_path
	local path = abs:sub(#vfs.GetStorageDirectory("root") + 1)
	return path:match("(.-)/")
end

function vfs.AbsoluteToRelativePath(root, abs)
	local root_info = vfs.GetPathInfo(root)
	local abs_info = vfs.GetPathInfo(abs)
	return abs_info.full_path:sub(#root_info.full_path + 2)
end

function vfs.ParsePathVariables(path)
	-- windows
	path = path:gsub("%%(.-)%%", vfs.GetEnv)
	path = path:gsub("%%", "")
	path = path:gsub("%$%((.-)%)", vfs.GetEnv)
	-- linux
	path = path:gsub("%$%((.-)%)", "%1")
	return path
end

function vfs.CreateDirectoriesFromPath(path, force)
	local path_info = vfs.GetPathInfo(path, true)
	local folders = path_info:GetFolders("full")
	local max = #folders

	if not path:ends_with("/") then max = max - 1 end

	for i = 1, max do
		local folder = folders[i]
		local ok, err = vfs.CreateDirectory(path_info.filesystem .. ":" .. folder, force)

		if not ok then return nil, err end
	end

	return true
end

function vfs.GetAbsolutePath(path, is_folder)
	if vfs.IsPathAbsolute(path) then
		if
			(
				is_folder == true and
				vfs.IsDirectory(path)
			) or
			(
				is_folder == false and
				vfs.IsFile(path)
			)
			or
			vfs.Exists(path)
		then
			return path
		end
	end

	local err = {}

	for _, data in ipairs(vfs.TranslatePath(path, is_folder)) do
		local ok1, err1 = data.context:CacheCall("IsFile", data.path_info)

		if ok1 then return data.path_info.full_path end

		local ok2, err2 = data.context:CacheCall("IsFolder", data.path_info)

		if ok2 then return data.path_info.full_path end

		table.insert(err, data.path_info.full_path .. " does not exist")
		table.insert(err, "  " .. (err1 or "unknown error"))
		table.insert(err, "  " .. (err2 or "unknown error"))
	end

	return nil, path .. " does not exist\n" .. table.concat(err, "\n")
end

return vfs
