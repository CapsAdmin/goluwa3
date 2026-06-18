local vfs = import("goluwa/filesystem/vfs.lua")
local file_path = import("goluwa/helpers/file_path.lua")
local mixed_case_path_cache = {}
local recursive_basename_index_cache = {}

do
	local old_clear_call_cache = vfs.ClearCallCache

	function vfs.ClearCallCache()
		old_clear_call_cache()
		table.clear(mixed_case_path_cache)
		table.clear(recursive_basename_index_cache)
	end
end

local function get_recursive_basename_index(root)
	root = file_path.FixPathSlashes(root)
	local cached = recursive_basename_index_cache[root]

	if cached then return cached end

	local index = {}

	vfs.GetFilesRecursive(root, nil, function(found_path)
		local basename = file_path.GetFileNameFromPath(found_path):lower()

		if basename ~= "" and not index[basename] then index[basename] = found_path end
	end)

	recursive_basename_index_cache[root] = index
	return index
end

function vfs.FindFileByNameRecursive(root, file_name)
	if type(root) ~= "string" or type(file_name) ~= "string" then return nil end

	local normalized_root = file_path.FixPathSlashes(root)
	local normalized_name = file_path.GetFileNameFromPath(file_path.FixPathSlashes(file_name)):lower()

	if normalized_root == "" or normalized_name == "" then return nil end

	return get_recursive_basename_index(normalized_root)[normalized_name]
end

function vfs.CopyRecursively(from, to)
	assert(vfs.CreateDirectory(to))

	vfs.GetFilesRecursive(from .. "/", nil, function(_, _, path_info)
		local relative = path_info.full_path:sub(#from + #path_info.filesystem + 3)
		vfs.CopyFile(path_info.full_path, to .. "/" .. relative)
	end)
end

function vfs.FindMixedCasePath(path)
	if type(path) ~= "string" then return nil end

	path = file_path.FixPathSlashes(path)
	local cached = mixed_case_path_cache[path]

	if cached ~= nil then return cached ~= false and cached or nil end

	-- try exact path first
	if vfs.IsFile(path) then
		mixed_case_path_cache[path] = path
		return path
	end

	-- try exact lowercase
	if vfs.IsFile(path:lower()) then
		mixed_case_path_cache[path] = path:lower()
		return path:lower()
	end

	local parts = path:split("/")
	local dir = ""

	for i, str in ipairs(parts) do
		local found_match = false
		local entries = vfs.Find(dir == "" and "." or dir) -- handle root case
		for _, found in ipairs(entries) do
			if found:lower() == str:lower() then
				dir = dir == "" and found or (dir .. "/" .. found)
				found_match = true

				break
			end
		end

		if not found_match then
			-- VFS search failed, try using fs module with absolute path
			local abs_dir = vfs.GetAbsolutePath(dir == "" and "." or dir, true)

			if abs_dir then
				local fs = import("goluwa/fs.lua")
				local files = fs.get_files(abs_dir)

				if files then
					for _, found in ipairs(files) do
						if found:lower() == str:lower() then
							dir = dir == "" and found or (dir .. "/" .. found)
							found_match = true

							break
						end
					end
				end
			end

			if not found_match then return nil end
		end
	end

	if vfs.IsFile(dir) then
		mixed_case_path_cache[path] = dir
		return dir
	end

	mixed_case_path_cache[path] = false
	return nil
end

local fs = import("goluwa/fs.lua")

function vfs.Delete(path, ...)
	local abs_path = vfs.GetAbsolutePath(path, ...)

	if abs_path then
		local ok, err = os.remove(abs_path)
		return ok, err
	end

	local err = ("No such file or directory %q"):format(path)
	return nil, err
end

function vfs.Rename(path, name, ...)
	local abs_path = vfs.GetAbsolutePath(path, ...)

	if abs_path then
		local dst = abs_path:match("(.+/)") .. name

		if jit.os == "Windows" then if vfs.IsFile(dst) then vfs.Delete(dst) end end

		local ok, err = os.rename(abs_path, dst)
		vfs.ClearCallCache()
		return ok, err
	end

	local err = ("No such file or directory %q"):format(path)
	return nil, err
end

function vfs.SetAttribute(path, key, val)
	local abs_path, err = vfs.GetAbsolutePath(path)

	if not abs_path then return nil, err end

	local tbl = codec.LookupInFile("luadata", "vfs_file_attributes", abs_path) or {}
	tbl[key] = val
	codec.StoreInFile("luadata", "vfs_file_attributes", abs_path, tbl)
end

function vfs.GetAttributes(path)
	local abs_path, err = vfs.GetAbsolutePath(path)

	if not abs_path then return nil, err end

	local tbl = codec.LookupInFile("luadata", "vfs_file_attributes", abs_path) or {}
	return tbl
end

function vfs.GetAttribute(path, key)
	local store = vfs.GetAttributes(path)

	if store then return store[key] end
end

function vfs.CopyFile(from, to)
	local ok, err = vfs.CreateDirectoriesFromPath(file_path.GetFolderFromPath(to))

	if not ok then return ok, err end

	local content, err = vfs.Read(from)

	if not content then return content, err end

	return vfs.Write(to, content)
end

function vfs.CopyFileFileOnBoot(from, to)
	from = vfs.GetAbsolutePath(from)

	if not from then return nil, "source does not exist" end

	local ok, err = vfs.CreateDirectoriesFromPath(file_path.GetFolderFromPath(to:starts_with("os:") and to or ("os:" .. to)))

	if not ok then return ok, err end

	if not vfs.GetAbsolutePath(file_path.GetFolderFromPath(to)) then
		return nil, "destination directory does not exist"
	end

	if vfs.IsFile(to) then
		local path = "shared/copy_binaries_instructions"
		local str = vfs.Read(path) or ""

		for _, line in ipairs(str:split("\n")) do
			if line == (from .. ";" .. to) then return "deferred" end
		end

		str = str .. R(from) .. ";" .. R(to) .. "\n"
		vfs.Write(path, str)
		return "deferred"
	end

	if not ok then return ok, err end

	local content, err = vfs.Read(from)

	if not content then return content, err end

	return vfs.Write(to, content)
end

function vfs.LinkFile(from, to)
	from = vfs.GetAbsolutePath(from)

	if not from then return nil, "source does not exist" end

	local dir = file_path.GetFolderFromPath(to)
	dir = R(dir)

	if not dir then return nil, "destination directory does not exist" end

	local to = dir .. file_path.GetFileNameFromPath(to)

	if jit.os == "Linux" or jit.os == "OSX" then
		os.execute("ln -s '" .. from .. "' '" .. to .. "'")
	end

	if jit.os == "Windows" then
		os.execute("MKLINK /H '" .. to .. "' '" .. from .. "'")
	end
end

local function add_helper(name, func, mode, cb)
	vfs[name] = function(path, ...)
		if cb then cb(path, ...) end

		local file, err = vfs.Open(path, mode)

		if file then
			local args = {...}

			do
				local ret

				if codec then
					if name == "Write" then
						local ext = file_path.GetExtensionFromPath(path)

						if codec.GetLibrary(ext) then ret = {codec.Encode(ext, data)} end
					end
				end

				if not ret and event then
					ret = {event.Call("VFSPre" .. name, path, ...)}
				end

				if ret and ret[1] ~= nil then
					for i, v in ipairs(args) do
						if ret[i] ~= nil then args[i] = ret[i] end
					end
				end
			end

			local res, err = file[func](file, unpack(args))
			file:Close()

			if res ~= nil then
				if event then
					local res_post, err_post = event.Call("VFSPost" .. name, path, res)

					if res_post ~= nil or err_post then return res_post, err_post end
				end

				if codec then
					if name == "Read" then
						local ext = file_path.GetExtensionFromPath(path)

						if codec.GetLibrary(ext) then
							local res, err = codec.Decode(ext, res)

							if not res then
								if not err then
									debug.trace()
									error("cannot return nil without error!")
								end

								return nil, err
							end

							return res
						end
					end
				end

				return res
			end

			if not err then
				debug.trace()
				error("cannot return nil without error!")
			end

			return nil, err
		end

		if not err then
			debug.trace()
			error("cannot return nil without error!")
		end

		return nil, err
	end
end

add_helper("Read", "ReadAll", "read")

add_helper(
	"Write",
	"WriteBytes",
	"write",
	function(path, content, on_change)
		path = path:gsub("(.+/)(.+)", function(folder, file_name)
			for _, char in ipairs{--[['\\', '/', ]]
			":", "%*", "%?", "\"", "<", ">", "|"} do
				file_name = file_name:gsub(char, "_il" .. char:byte() .. "_")
			end

			return folder .. file_name
		end)

		if type(on_change) == "function" and vfs.MonitorFile then
			vfs.MonitorFile(path, function(file_path)
				on_change(vfs.Read(file_path), file_path)
			end)

			on_change(content)
		end

		local found = false
		local fs = vfs.GetFileSystem("os")

		if fs then
			for _, dir in ipairs({"data", "cache", "shared"}) do
				if path:starts_with(dir .. "/") or path:starts_with("os:" .. dir .. "/") then
					if path:starts_with("os:") then path = path:sub(4) end

					path = path:sub(#(dir .. "/") + 1)
					local base = vfs.GetStorageDirectory("storage")

					if dir == "cache" then
						base = vfs.GetStorageDirectory("cache")
					elseif dir == "shared" then
						base = vfs.GetStorageDirectory("shared")
					end

					local dir = ""

					for folder in path:gmatch("(.-/)") do
						dir = dir .. folder
						fs:CreateFolder({full_path = base .. dir})
					end

					found = true

					break
				end
			end
		end

		if not found then vfs.CreateDirectoriesFromPath(path, true) end
	end
)

add_helper("GetLastModified", "GetLastModified", "read")
add_helper("GetLastAccessed", "GetLastAccessed", "read")
add_helper("GetSize", "GetSize", "read")

function vfs.CreateDirectory(path, force)
	if vfs.IsDirectory(path) then return true end

	local path_info = vfs.GetPathInfo(path, true)
	local dir_name = file_path.GetFolderNameFromPath(path_info.full_path) or path_info.full_path
	local parent_dir = file_path.GetParentFolderFromPath(path_info.full_path)
	local full_path = vfs.GetAbsolutePath(parent_dir, true)

	if not full_path then
		return nil, "directory " .. parent_dir .. " does not exist"
	end

	local path_info = vfs.GetPathInfo(path_info.filesystem .. ":" .. full_path)

	if path_info.filesystem == "unknown" then
		return nil, "filesystem must be explicit when creating directories"
	end

	path_info.full_path = path_info.full_path .. dir_name .. "/"
	return vfs.GetFileSystem(path_info.filesystem):CreateFolder(path_info, force)
end

function vfs.IsDirectory(path)
	if path == "" then return false end

	for _, data in ipairs(vfs.TranslatePath(path, true)) do
		if data.context:CacheCall("IsFolder", data.path_info) then return true end
	end

	return false
end

function vfs.IsFile(path)
	if path == "" then return false end

	for _, data in ipairs(vfs.TranslatePath(path)) do
		if data.context:CacheCall("IsFile", data.path_info) then return true end
	end

	return false
end

function vfs.IsFolderValid(path)
	if path == "" then return false, "path is nothing" end

	local path, err = vfs.GetAbsolutePath(path)

	if not path then return false, err end

	local path_info = vfs.GetPathInfo(path, true)
	local errors = ""

	for _, context in ipairs(vfs.GetFileSystems()) do
		if context:IsArchive(path_info) then
			local ok, err = context:IsFolderValid(path_info)

			if ok then return true end

			if err then errors = errors .. err .. "\n" end
		end
	end

	return false, errors
end

function vfs.Exists(path)
	return vfs.IsDirectory(path) or vfs.IsFile(path)
end
