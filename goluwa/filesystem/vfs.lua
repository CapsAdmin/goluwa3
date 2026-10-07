local objects = import("goluwa/objects/objects.lua")
local file_path = import("goluwa/filesystem/path.lua")
local vfs = {}
vfs.use_appdata = false
vfs.mounted_paths = vfs.mounted_paths or {}
vfs.mount_generation = vfs.mount_generation or 0

do
	function vfs.Mount(where, to, userdata)
		to = to or ""

		if not vfs.IsDirectory(where) then
			llog("attempted to mount non existing directory ", where)
			return false
		end

		vfs.ClearCallCache()
		vfs.Unmount(where, to)
		local path_info_where = vfs.GetPathInfo(where, true)
		local path_info_to = vfs.GetPathInfo(to, true)

		if path_info_where.filesystem == "unknown" then
			for context, info in pairs(vfs.DescribePath(where, true)) do
				if info.is_folder then
					path_info_where.filesystem = context.Name
					where = context.Name .. ":" .. where
				end
			end
		end

		if to ~= "" and not path_info_to.filesystem then
			error("a filesystem has to be provided when mounting /to/ somewhere")
		end

		list.insert(
			vfs.mounted_paths,
			{
				where = path_info_where,
				to = path_info_to,
				full_where = where,
				full_to = to,
				userdata = userdata,
				to_length = #path_info_to.full_path,
				where_relative = path_info_where.full_path == "" or
					not vfs.IsPathAbsolute(path_info_where.full_path),
			}
		)
		vfs.mount_generation = vfs.mount_generation + 1
		vfs.ClearTranslateCache()
	end

	function vfs.Unmount(where, to)
		to = to or ""
		vfs.ClearCallCache()

		for i, v in ipairs(vfs.mounted_paths) do
			if v.full_where:lower() == where:lower() and v.full_to:lower() == to:lower() then
				list.remove(vfs.mounted_paths, i)
				vfs.mount_generation = vfs.mount_generation + 1
				vfs.ClearTranslateCache()
				return true
			end
		end

		return false
	end

	function vfs.GetMounts()
		local out = {}

		for _, v in ipairs(vfs.mounted_paths) do
			out[v.full_where] = v
		end

		return out
	end

	local translate_cache = {[true] = {}, [false] = {}}
	local translate_cache_count = 0
	local translate_cache_limit = 50000

	function vfs.ClearTranslateCache()
		table.clear(translate_cache[true])
		table.clear(translate_cache[false])
		translate_cache_count = 0
	end

	function vfs.TranslatePath(path, is_folder)
		is_folder = is_folder or false
		local cached = translate_cache[is_folder][path]

		if cached then return cached end

		local path_info = vfs.GetPathInfo(path, is_folder)
		local out = {}
		local out_i = 1

		if path_info.relative then
			local full_path = path_info.full_path
			local filesystems2 = vfs.filesystems2

			for _, mount_info in ipairs(vfs.mounted_paths) do
				local mount_where = mount_info.where
				local filesystem = mount_where.filesystem
				local where

				if mount_info.where_relative or not filesystems2[filesystem] then
					if full_path:sub(0, mount_info.to_length) == mount_info.to.full_path then
						where = vfs.GetPathInfo(
							filesystem .. ":" .. mount_where.full_path .. full_path:sub(mount_info.to_length + 1),
							is_folder
						)
					elseif full_path ~= "/" then
						where = vfs.GetPathInfo(filesystem .. ":" .. mount_where.full_path .. full_path, is_folder)
					else
						where = vfs.GetPathInfo(filesystem .. ":" .. mount_info.to.full_path, is_folder)
					end
				else
					local tail

					if full_path:sub(0, mount_info.to_length) == mount_info.to.full_path then
						tail = full_path:sub(mount_info.to_length + 1)
					elseif full_path ~= "/" then
						tail = full_path
					end

					if tail then
						where = {
							filesystem = filesystem,
							full_path = mount_where.full_path .. tail,
							relative = false,
							GetFolders = path_info.GetFolders,
						}
					else
						where = vfs.GetPathInfo(filesystem .. ":" .. mount_info.to.full_path, is_folder)
					end
				end

				out[out_i] = {
					path_info = where,
					context = filesystems2[filesystem],
					userdata = mount_info.userdata,
				}
				out_i = out_i + 1
			end

			if translate_cache_count >= translate_cache_limit then
				vfs.ClearTranslateCache()
			end

			translate_cache[is_folder][path] = out
			translate_cache_count = translate_cache_count + 1
		else
			local filesystems = vfs.GetFileSystems()

			if path_info.filesystem ~= "unknown" then
				filesystems = {vfs.GetFileSystem(path_info.filesystem)}
			end

			for _, context in ipairs(filesystems) do
				if
					(
						is_folder and
						context:IsFolder(path_info)
					) or
					(
						not is_folder and
						context:IsFile(path_info)
					)
				then
					out[out_i] = {path_info = path_info, context = context, userdata = path_info.userdata}
					out_i = out_i + 1
				elseif
					not is_folder and
					context:IsFolder{full_path = file_path.GetParentFolderFromPath(path_info.full_path)}
				then
					out[out_i] = {path_info = path_info, context = context, userdata = path_info.userdata}
					out_i = out_i + 1
				end
			end
		end

		return out
	end
end

do
	vfs.env_override = vfs.env_override or {}

	function vfs.GetEnv(key)
		local val = vfs.env_override[key]

		if type(val) == "function" then val = val() end

		return val or os.getenv(key)
	end

	function vfs.SetEnv(key, val)
		vfs.env_override[key] = val
	end

	function vfs.PreprocessPath(path)
		if path:find("%", nil, true) or path:find("$", nil, true) then
			path = path:gsub("%%(.-)%%", vfs.GetEnv)
			path = path:gsub("%%", "")
			path = path:gsub("%$%((.-)%)", vfs.GetEnv)
			path = path:gsub("%$%((.-)%)", "%1")
		end

		return path
	end
end

do
	vfs.filesystems = vfs.filesystems or {}
	vfs.filesystems2 = vfs.filesystems2 or {}

	function vfs.InstantiateFilesystem(META)
		local context = META:CreateObject()
		context.mounted_paths = {}

		for k, v in ipairs(vfs.filesystems) do
			if v.Type == META.Type then
				list.remove(vfs.filesystems, k)
				context.mounted_paths = v.mounted_paths

				break
			end
		end

		list.insert(vfs.filesystems, context)

		list.sort(vfs.filesystems, function(a, b)
			return a.Position < b.Position
		end)

		vfs.filesystems2[context.Name] = context
		return META
	end

	function vfs.GetFileSystems()
		return vfs.filesystems
	end

	function vfs.GetFileSystem(name)
		return vfs.filesystems2[name]
	end
end

do
	function vfs.DescribePath(path, is_folder)
		local path_info = vfs.GetPathInfo(path, is_folder)
		local out = {}

		for _, context in ipairs(vfs.GetFileSystems()) do
			out[context] = {}

			if is_folder then
				out[context].is_folder = context:IsFolder(path_info)
			else
				out[context].is_folder = context:IsFolder(path_info)
				out[context].is_file = context:IsFile(path_info)
			end
		end

		return out
	end

	local function get_folders(self, typ)
		if typ == "full" then
			local folders = {}

			for i = 0, 100 do
				local folder = file_path.GetParentFolderFromPath(self.full_path, i)

				if folder == "" then break end

				list.insert(folders, 1, folder)
			end

			return folders
		else
			local folders = self.full_path:split("/")

			if self.full_path:sub(1, 1) == "/" then list.remove(folders, 1) end

			list.remove(folders)
			return folders
		end
	end

	function vfs.IsPathAbsolute(path)
		if jit.os == "Windows" then
			return path:sub(2, 2) == ":" or path:sub(1, 2) == [[//]]
		end

		return path:sub(1, 1) == "/"
	end

	function vfs.GetPathInfo(path, is_folder)
		local out = {}

		if not path then debug.trace() end

		local pos = path:find(":", 0, true)

		if pos then
			local filesystem = path:sub(0, pos - 1)

			if vfs.GetFileSystem(filesystem) then
				path = path:sub(pos + 1)
				out.filesystem = filesystem
			else
				out.filesystem = "unknown"
			end
		else
			out.filesystem = "unknown"
		end

		local relative = not vfs.IsPathAbsolute(path)

		if is_folder and not path:ends_with("/") then path = path .. "/" end

		out.full_path = path
		out.relative = relative
		out.GetFolders = get_folders
		return out
	end
end

function vfs.Open(path, mode, sub_mode)
	mode = mode or "read"
	local errors = {}
	local paths = vfs.TranslatePath(path)

	if #paths == 0 then list.insert(errors, path .. " does not exist") end

	for i, data in ipairs(paths) do
		local file = data.context:CreateObject()
		file:SetMode(mode)
		local ok, err = file:Open(data.path_info)
		file.path_used = data.path_info.full_path

		if ok ~= false then
			if mode == "write" then vfs.ClearCallCache() end

			return file
		else
			file:Remove()
			local err = "\t" .. data.context.Name .. ": " .. err

			if errors[#errors] ~= err then list.insert(errors, err) end
		end
	end

	return false, "unable to open file: \n" .. list.concat(errors, "\n")
end

import.loaded["goluwa/filesystem/vfs.lua"] = vfs

do
	local path_utilities = import("goluwa/filesystem/path_utilities.lua")

	for k, v in pairs(path_utilities) do
		if vfs[k] == nil then vfs[k] = v end
	end
end

import("goluwa/filesystem/base_file.lua")
import("goluwa/filesystem/find.lua")
import("goluwa/filesystem/helpers.lua")
import("goluwa/filesystem/addons.lua")
import("goluwa/filesystem/addon_library.lua")
import("goluwa/filesystem/lua_utilities.lua")
import("goluwa/filesystem/storage.lua")
vfs.InstantiateFilesystem(import("goluwa/filesystem/files/os.lua"))
vfs.InstantiateFilesystem(import("goluwa/filesystem/files/vpk.lua"))
vfs.InstantiateFilesystem(import("goluwa/filesystem/files/pak.lua"))
vfs.InstantiateFilesystem(import("goluwa/filesystem/files/zip.lua"))
vfs.InstantiateFilesystem(import("goluwa/filesystem/files/gma.lua"))
vfs.InstantiateFilesystem(import("goluwa/filesystem/files/lzma.lua"))

for _, context in ipairs(vfs.GetFileSystems()) do
	if context.VFSOpened then context:VFSOpened() end
end

return vfs
