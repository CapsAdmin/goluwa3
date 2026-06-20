local fs = import("goluwa/bindings/filesystem.lua")
local file_path = import("goluwa/filesystem/path.lua")

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
	return file_path.GetParentDirectoryFromPath(path)
end

function fs.create_directory_recursive(path)
	-- Handle empty or root path
	if path == "" or path == "/" then return true end

	path = file_path.FixPathSlashes(path)
	path = file_path.TrimTrailingPathSeparator(path)

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
return fs
