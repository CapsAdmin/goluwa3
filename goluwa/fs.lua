local fs = import("goluwa/bindings/filesystem.lua")

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

local function glob_to_pattern(glob)
	local pattern = glob:gsub("[%^%$%(%)%.%[%]%+%-%?]", "%%%1")
	pattern = pattern:gsub("%*", ".*")
	pattern = pattern:gsub("%?", ".")
	return "^" .. pattern .. "$"
end

function fs.glob(pattern)
	local parts = {}

	for part in pattern:gmatch("[^/]+") do
		table.insert(parts, part)
	end

	local results = {}

	local function scan(current_path, part_index)
		local current_part = parts[part_index]

		if not current_part then
			table.insert(results, (current_path:gsub("/+$", "")))
			return
		end

		local function get_search_path()
			if current_path == "" then return "." end

			if current_path == "/" then return "/" end

			return current_path:gsub("/+$", "")
		end

		if current_part == "**" then
			-- Match current directory and recurse
			scan(current_path, part_index + 1)
			local files = fs.get_files(get_search_path())

			if files then
				for _, name in ipairs(files) do
					local full_path = current_path == "" and
						name or
						(
							current_path:sub(-1) == "/" and
							current_path .. name or
							current_path .. "/" .. name
						)

					if fs.is_directory(full_path) then scan(full_path .. "/", part_index) end
				end
			end
		elseif current_part:find("*") or current_part:find("?") then
			local part_pattern = glob_to_pattern(current_part)
			local files = fs.get_files(get_search_path())

			if files then
				for _, name in ipairs(files) do
					-- Remove leading/trailing whitespace from name if any, but readdir usually doesn't have it
					local trimmed_name = name:match("^%s*(.-)%s*$")

					if trimmed_name:match(part_pattern) then
						local full_path = current_path == "" and
							trimmed_name or
							(
								current_path:sub(-1) == "/" and
								current_path .. trimmed_name or
								current_path .. "/" .. trimmed_name
							)

						if part_index < #parts then
							if fs.is_directory(full_path) then scan(full_path .. "/", part_index + 1) end
						else
							table.insert(results, full_path)
						end
					end
				end
			end
		else
			local full_path = current_path == "" and
				current_part or
				(
					current_path:sub(-1) == "/" and
					current_path .. current_part or
					current_path .. "/" .. current_part
				)

			if fs.exists(full_path) then
				if part_index < #parts then
					if fs.is_directory(full_path) then scan(full_path .. "/", part_index + 1) end
				else
					table.insert(results, full_path)
				end
			end
		end
	end

	local start_path = ""

	if pattern:sub(1, 1) == "/" then
		start_path = "/"
	elseif pattern:sub(1, 2) == "./" then
		start_path = "./"
	end

	scan(start_path, 1)
	return results
end

-- Plain-text grep: globs files, reads each one, and uses string.find with plain=true.
-- Returns results (list of {file, line, text, is_match, separator}) and total match-line count.
function fs.grep(pattern, path, opts)
	opts = opts or {}
	local glob_filter = opts.glob_filter
	local max_results = opts.max_results or 50
	local context_lines = opts.context_lines or 0
	path = path or "."

	if path:sub(-1) == "/" then path = path:sub(1, -2) end

	local search_glob = (
			glob_filter and
			glob_filter ~= ""
		)
		and
		(
			path .. "/**/" .. glob_filter
		)
		or
		(
			path .. "/**/*"
		)
	search_glob = search_glob:gsub("^%./", "")
	local files = fs.glob(search_glob) or {}
	local results = {}
	local total_matches = 0

	for _, filepath in ipairs(files) do
		local content = fs.read_file(filepath)

		if content and content ~= "" then
			local len = #content
			-- Build newline index: nls[0]=0 (sentinel), nls[k] = byte position of k-th '\n'
			-- Line k occupies bytes [nls[k-1]+1 .. nls[k]-1] (or len for the last line)
			local nls = {[0] = 0}
			local nls_n = 0

			do
				local p = 1

				while true do
					local np = content:find("\n", p, true)

					if not np then break end

					nls_n = nls_n + 1
					nls[nls_n] = np
					p = np + 1
				end
			end

			local total_lines = (nls_n > 0 and nls[nls_n] == len) and nls_n or nls_n + 1
			-- Phase 1: collect all line numbers that contain the pattern
			-- binary search inline: which line does byte position ms fall on?
			local match_lines = {}
			local seen = {}
			local p = 1

			while p <= len do
				local ms = content:find(pattern, p, true)

				if not ms then break end

				local lo, hi = 0, nls_n

				while lo < hi do
					local mid = math.floor((lo + hi + 1) / 2)

					if nls[mid] < ms then lo = mid else hi = mid - 1 end
				end

				local lnum = lo + 1

				if not seen[lnum] then
					seen[lnum] = true
					total_matches = total_matches + 1
					table.insert(match_lines, lnum)
				end

				p = (nls[lnum] or len) + 1
			end

			-- Phase 2: expand context and emit results
			-- get_line(k) inlined as: content:sub(nls[k-1]+1, (nls[k] or len+1)-1)
			if context_lines == 0 then
				for _, lnum in ipairs(match_lines) do
					if #results < max_results then
						table.insert(
							results,
							{
								file = filepath,
								line = lnum,
								text = content:sub(nls[lnum - 1] + 1, (nls[lnum] or len + 1) - 1),
								is_match = true,
								separator = ":",
							}
						)
					end
				end
			else
				local include = {}

				for _, lnum in ipairs(match_lines) do
					for j = math.max(1, lnum - context_lines), math.min(total_lines, lnum + context_lines) do
						include[j] = true
					end
				end

				for j = 1, total_lines do
					if include[j] then
						if #results < max_results then
							table.insert(
								results,
								{
									file = filepath,
									line = j,
									text = content:sub(nls[j - 1] + 1, (nls[j] or len + 1) - 1),
									is_match = seen[j] == true,
									separator = seen[j] and ":" or "-",
								}
							)
						end
					end
				end
			end
		end
	end

	return results, total_matches
end

do
	fs.SetWorkingDirectory = fs.set_current_directory
	fs.GetWorkingDirectory = fs.get_current_directory
	import("goluwa/utility.lua").MakePushPopFunction(fs, "WorkingDirectory")
end

fs.GetAttributes = fs.get_attributes

do
	local ffi = require("ffi")
	local bit = require("bit")
	local event = import("goluwa/event.lua")

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
	elseif jit.os == "OSX" then
		local active_watches = {}
		local ffi = require("ffi")
		ffi.cdef([[
            typedef uint32_t FSEventStreamCreateFlags;
            typedef uint32_t FSEventStreamEventFlags;
            typedef uint64_t FSEventStreamEventId;
            typedef struct __FSEventStream *FSEventStreamRef;
            typedef void (*FSEventStreamCallback)(
                FSEventStreamRef streamRef,
                void *clientCallBackInfo,
                size_t numEvents,
                void *eventPaths,
                const FSEventStreamEventFlags eventFlags[],
                const FSEventStreamEventId eventIds[]
            );

            typedef struct {
                long version;
                void *info;
                void *retain;
                void *release;
                void *copyDescription;
            } FSEventStreamContext;

            FSEventStreamRef FSEventStreamCreate(
                void *allocator,
                FSEventStreamCallback callback,
                FSEventStreamContext *context,
                void *pathsToWatch,
                FSEventStreamEventId sinceWhen,
                double latency,
                FSEventStreamCreateFlags flags
            );

            void FSEventStreamScheduleWithRunLoop(
                FSEventStreamRef streamRef,
                void *runLoop,
                void *runLoopMode
            );

            bool FSEventStreamStart(FSEventStreamRef streamRef);
            void FSEventStreamStop(FSEventStreamRef streamRef);
            void FSEventStreamInvalidate(FSEventStreamRef streamRef);
            void FSEventStreamRelease(FSEventStreamRef streamRef);

            void *CFArrayCreate(void *allocator, const void **values, long numValues, void *callBacks);
            void CFRelease(void *cf);
            void *CFStringCreateWithCString(void *alloc, const char *cStr, uint32_t encoding);
            extern void *kCFRunLoopDefaultMode;
            void *CFRunLoopGetCurrent(void);
            int32_t CFRunLoopRunInMode(void *mode, double seconds, bool returnAfterSourceHandled);
            void CFRunLoopRun(void);
            void CFRunLoopStop(void *runLoop);

			typedef void (*CFRunLoopTimerCallBack)(void *timer, void *info);
			void *CFRunLoopTimerCreate(void *allocator, double fireDate, double interval, uint32_t flags, int32_t order, CFRunLoopTimerCallBack callout, void *context);
			void CFRunLoopAddTimer(void *rl, void *timer, void *mode);
        ]])
		fs.kFSEventStreamCreateFlagNone = 0x00000000
		fs.kFSEventStreamCreateFlagUseCFTypes = 0x00000001
		fs.kFSEventStreamCreateFlagNoDefer = 0x00000002
		fs.kFSEventStreamCreateFlagWatchRoot = 0x00000004
		fs.kFSEventStreamCreateFlagIgnoreSelf = 0x00000008
		fs.kFSEventStreamCreateFlagFileEvents = 0x00000010
		fs.kFSEventStreamEventFlagNone = 0x00000000
		fs.kFSEventStreamEventFlagMustScanSubDirs = 0x00000001
		fs.kFSEventStreamEventFlagUserDropped = 0x00000002
		fs.kFSEventStreamEventFlagKernelDropped = 0x00000004
		fs.kFSEventStreamEventFlagEventIdsWrapped = 0x00000008
		fs.kFSEventStreamEventFlagHistoryDone = 0x00000010
		fs.kFSEventStreamEventFlagRootChanged = 0x00000020
		fs.kFSEventStreamEventFlagMount = 0x00000040
		fs.kFSEventStreamEventFlagUnmount = 0x00000080
		fs.kFSEventStreamEventFlagItemCreated = 0x00000100
		fs.kFSEventStreamEventFlagItemRemoved = 0x00000200
		fs.kFSEventStreamEventFlagItemInodeMetaMod = 0x00000400
		fs.kFSEventStreamEventFlagItemRenamed = 0x00000800
		fs.kFSEventStreamEventFlagItemModified = 0x00001000
		fs.kFSEventStreamEventFlagItemFinderInfoMod = 0x00002000
		fs.kFSEventStreamEventFlagItemChangeOwner = 0x00004000
		fs.kFSEventStreamEventFlagItemXattrMod = 0x00008000
		fs.kFSEventStreamEventFlagItemIsFile = 0x00010000
		fs.kFSEventStreamEventFlagItemIsDir = 0x00020000
		fs.kFSEventStreamEventFlagItemIsSymlink = 0x00040000
		fs.kCFStringEncodingUTF8 = 0x08000100
		fs.kFSEventStreamEventIdSinceNow = 0xFFFFFFFFFFFFFFFFULL
		local ok, lib = pcall(ffi.load, "/System/Library/Frameworks/CoreServices.framework/CoreServices")

		if ok then
			fs.CoreServices = lib
		else
			-- Fallback to default if load fails, though CF functions might be missing
			fs.CoreServices = ffi.C
		end

		local function setup_macos_watch_timer(lib)
			if _G.MACOS_WATCH_TIMER_SETUP then return end

			_G.MACOS_WATCH_TIMER_SETUP = true

			local function timer_callback(timer, info) -- Just a dummy callback to keep the run loop alive and returning
			end

			local c_timer_callback = ffi.cast("CFRunLoopTimerCallBack", timer_callback)
			-- Anchor the callback
			active_watches[c_timer_callback] = {timer_callback, c_timer_callback}
			local rl = lib.CFRunLoopGetCurrent()
			local timer = lib.CFRunLoopTimerCreate(nil, 0, 0.1, 0, 0, c_timer_callback, nil)
			lib.CFRunLoopAddTimer(rl, timer, lib.kCFRunLoopDefaultMode)
		end

		function fs.watch(path, callback, recursive)
			local lib = fs.CoreServices

			if not lib then return nil, "CoreServices not loaded" end

			if path:sub(-1) == "/" then path = path:sub(1, -2) end

			local results = {}

			local function internal_callback(streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds)
				local paths_ptr = ffi.cast("char **", eventPaths)

				for i = 0, tonumber(numEvents) - 1 do
					local full_path = ffi.string(paths_ptr[i])
					local flags = eventFlags[i]
					local type = "modified"

					if bit.band(flags, fs.kFSEventStreamEventFlagItemCreated) ~= 0 then
						type = "created"
					elseif bit.band(flags, fs.kFSEventStreamEventFlagItemRemoved) ~= 0 then
						type = "deleted"
					elseif bit.band(flags, fs.kFSEventStreamEventFlagItemRenamed) ~= 0 then
						type = "renamed"
					end

					table.insert(results, {path = full_path, type = type})
				end
			end

			if recursive == nil then recursive = true end

			local c_callback = ffi.cast("FSEventStreamCallback", internal_callback)
			local path_cf = lib.CFStringCreateWithCString(nil, path, fs.kCFStringEncodingUTF8)
			local paths_array = lib.CFArrayCreate(nil, ffi.cast("const void **", ffi.new("void *[1]", {path_cf})), 1, nil)
			local flags = bit.bor(
				fs.kFSEventStreamCreateFlagFileEvents,
				fs.kFSEventStreamCreateFlagNoDefer,
				fs.kFSEventStreamCreateFlagWatchRoot
			)
			local stream = lib.FSEventStreamCreate(
				nil,
				c_callback,
				nil,
				paths_array,
				fs.kFSEventStreamEventIdSinceNow,
				0.1,
				flags
			)

			if stream == nil then
				lib.CFRelease(paths_array)
				lib.CFRelease(path_cf)
				return nil, "Failed to create FSEventStream"
			end

			setup_macos_watch_timer(lib)
			active_watches[c_callback] = {internal_callback, c_callback}
			lib.FSEventStreamScheduleWithRunLoop(stream, lib.CFRunLoopGetCurrent(), lib.kCFRunLoopDefaultMode)

			if not lib.FSEventStreamStart(stream) then
				lib.FSEventStreamInvalidate(stream)
				lib.FSEventStreamRelease(stream)
				lib.CFRelease(paths_array)
				lib.CFRelease(path_cf)
				return nil, "Failed to start FSEventStream"
			end

			local remove_event = event.AddListener("Update", {}, function()
				if lib.CFRunLoopRunInMode then
					lib.CFRunLoopRunInMode(lib.kCFRunLoopDefaultMode, 0, true)
				end

				if #results > 0 then
					for i, res in ipairs(results) do
						callback(res.path, res.type)
						results[i] = nil
					end
				end
			end)
			return function()
				remove_event()
				lib.FSEventStreamStop(stream)
				lib.FSEventStreamInvalidate(stream)
				lib.FSEventStreamRelease(stream)
				lib.CFRelease(paths_array)
				lib.CFRelease(path_cf)
				active_watches[c_callback] = nil
				c_callback:free()
			end
		end
	end
end

return fs
