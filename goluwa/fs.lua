local fs = require("bindings.filesystem")

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
	require("utility").MakePushPopFunction(fs, "WorkingDirectory")
end

fs.GetAttributes = fs.get_attributes

do
	local ffi = require("ffi")
	local bit = require("bit")
	local event = require("event")

	if jit.os == "Linux" then
		function fs.watch(path, callback, recursive)
			local inotify_fd = ffi.C.inotify_init1(fs.IN_NONBLOCK)

			if inotify_fd == -1 then return nil, "Failed to initialize inotify" end

			if path:sub(-1) == "/" then path = path:sub(1, -2) end

			local wd_to_path = {}

			local function add_watch(dir_path)
				local wd = ffi.C.inotify_add_watch(
					inotify_fd,
					dir_path,
					bit.bor(
						fs.IN_MODIFY,
						fs.IN_CREATE,
						fs.IN_DELETE,
						fs.IN_MOVE,
						fs.IN_CLOSE_WRITE
					)
				)

				if wd ~= -1 then wd_to_path[wd] = dir_path end

				return wd
			end

			local function add_recursive(dir_path)
				add_watch(dir_path)
				local files = fs.get_files(dir_path)

				if files then
					for _, name in ipairs(files) do
						local full = dir_path .. "/" .. name

						if fs.is_directory(full) then add_recursive(full) end
					end
				end
			end

			if recursive then add_recursive(path) else add_watch(path) end

			local buffer = ffi.new("char[4096]")
			local remove_event = event.AddListener("Update", {}, function()
				while true do
					local length = ffi.C.read(inotify_fd, buffer, 4096)

					if length <= 0 then break end

					local i = 0

					while i < length do
						local event = ffi.cast("struct inotify_event *", ffi.cast("char *", buffer) + i)
						local dir_path = wd_to_path[event.wd]

						if dir_path then
							local name = ffi.string(event.name)
							local full_path = dir_path .. "/" .. name
							local type = "modified"

							if bit.band(event.mask, fs.IN_CREATE) ~= 0 then
								type = "created"
							elseif bit.band(event.mask, fs.IN_DELETE) ~= 0 then
								type = "deleted"
							elseif bit.band(event.mask, fs.IN_MOVE) ~= 0 then
								type = "renamed"
							end

							callback(full_path, type)

							if
								recursive and
								bit.band(event.mask, fs.IN_ISDIR) ~= 0 and
								bit.band(bit.bor(fs.IN_CREATE, fs.IN_MOVED_TO), event.mask) ~= 0
							then
								add_recursive(full_path)
							end
						end

						i = i + ffi.sizeof("struct inotify_event") + event.len
					end
				end
			end)
			return function()
				for wd, _ in pairs(wd_to_path) do
					ffi.C.inotify_rm_watch(inotify_fd, wd)
				end

				ffi.C.close(inotify_fd)
				remove_event()
			end
		end
	elseif jit.os == "Windows" then
		function fs.watch(path, callback, recursive)
			if path:sub(-1) == "/" then path = path:sub(1, -2) end

			local handle = ffi.C.CreateFileA(
				path,
				fs.FILE_LIST_DIRECTORY,
				7,
				nil,
				3,
				bit.bor(fs.FILE_FLAG_BACKUP_SEMANTICS, fs.FILE_FLAG_OVERLAPPED),
				nil
			)

			if handle == ffi.cast("void *", -1) then return nil end

			local buffer = ffi.new("uint8_t[4096]")
			local overlapped = ffi.new("OVERLAPPED")

			local function read_changes()
				ffi.C.ReadDirectoryChangesW(
					handle,
					buffer,
					4096,
					recursive and 1 or 0,
					bit.bor(
						fs.FILE_NOTIFY_CHANGE_FILE_NAME,
						fs.FILE_NOTIFY_CHANGE_DIR_NAME,
						fs.FILE_NOTIFY_CHANGE_LAST_WRITE
					),
					nil,
					overlapped,
					nil
				)
			end

			read_changes()
			local remove_event = event.AddListener("Update", {}, function()
				if ffi.cast("uintptr_t", overlapped.Internal) ~= 0x103 then
					local offset = 0

					while true do
						local info = ffi.cast(
							[[
						struct {
							uint32_t NextEntryOffset;
							uint32_t Action;
							uint32_t FileNameLength;
							uint16_t FileName[1];
						} *
					]],
							ffi.cast("char *", buffer) + offset
						)
						local filename_w = info.FileName
						local filename_len = info.FileNameLength / 2
						local bytes_needed = ffi.C.WideCharToMultiByte(
							65001,
							0,
							filename_w,
							filename_len,
							nil,
							0,
							nil,
							nil
						)
						local out_buf = ffi.new("char[?]", bytes_needed)
						ffi.C.WideCharToMultiByte(
							65001,
							0,
							filename_w,
							filename_len,
							out_buf,
							bytes_needed,
							nil,
							nil
						)
						local filename = ffi.string(out_buf, bytes_needed)
						local type = "modified"

						if info.Action == fs.FILE_ACTION_ADDED then
							type = "created"
						elseif info.Action == fs.FILE_ACTION_REMOVED then
							type = "deleted"
						elseif
							info.Action == fs.FILE_ACTION_RENAMED_OLD_NAME or
							info.Action == fs.FILE_ACTION_RENAMED_NEW_NAME
						then
							type = "renamed"
						end

						callback(path .. "/" .. filename, type)

						if info.NextEntryOffset == 0 then break end

						offset = offset + info.NextEntryOffset
					end

					read_changes()
				end
			end)
			return function()
				remove_event()
				ffi.C.CloseHandle(handle)
			end
		end
	end
end

return fs
