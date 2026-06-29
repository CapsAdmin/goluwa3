local file_path = library and library() or {}

function file_path.Normalize(path)
	local is_absolute = path:sub(1, 1) == "/"
	local parts = {}
	local count = 0
	path = path:gsub("\\", "/")
	path = path:gsub("/+", "/")

	for part in path:gmatch("[^/]+") do
		if part ~= "." and part ~= "" then
			if part == ".." then
				if count > 0 and parts[count] ~= ".." then
					parts[count] = nil
					count = count - 1
				elseif not is_absolute then
					count = count + 1
					parts[count] = part
				end
			else
				count = count + 1
				parts[count] = part
			end
		end
	end

	path = table.concat(parts, "/")

	if is_absolute then path = "/" .. path end

	if path == "" then return is_absolute and "/" or "." end

	if #path > 1 then path = path:gsub("/+$", "") end

	return path
end

function file_path.GetParentFolderFromPath(str, level)
	level = level or 1

	for i = #str, 1, -1 do
		local char = str:sub(i, i)

		if char == "/" then level = level - 1 end

		if level == -1 then return str:sub(0, i) end
	end

	return ""
end

function file_path.GetFolderNameFromPath(str)
	if str:sub(#str, #str) == "/" then str = str:sub(0, #str - 1) end

	return str:match(".+/(.+)") or
		str:match(".+/(.+)/") or
		str:match(".+/(.+)") or
		str:match("(.+)/")
end

function file_path.GetFileNameFromPath(str)
	local pos = (str):reverse():find("/", 0, true)
	return pos and str:sub(-pos + 1) or str
end

function file_path.RemoveExtensionFromPath(str)
	return str:match("(.+)%..+") or str
end

function file_path.GetExtensionFromPath(str)
	return file_path.GetFileNameFromPath(str):match(".-%.([%w-_%.]+)") or ""
end

function file_path.GetFolderFromPath(str)
	local pre = str:match("(.*)/")

	if not pre then return nil end

	return pre .. "/"
end

function file_path.TrimTrailingPathSeparator(path)
	if path == "/" then return path end

	if path:sub(-1) == "/" then return path:sub(1, -2) end

	return path
end

function file_path.GetParentDirectoryFromPath(path)
	path = file_path.FixPathSlashes(path)
	path = file_path.TrimTrailingPathSeparator(path)
	local parent = path:match("(.+)/[^/]+$")

	if not parent then
		if path == "/" then return nil end

		return "."
	end

	return parent
end

function file_path.GetFileFromPath(str)
	return str:match(".*/(.*)")
end

function file_path.IsPathAbsolutePath(path)
	if jit.os == "Windows" then return path:sub(1, 2):find("%a:") ~= nil end

	return path:sub(1, 1) == "/"
end

local character_translation = {
	["\\"] = "⟍",
	[":"] = "⠅",
	["*"] = "✱",
	["?"] = "❔",
	["<"] = "ᐸ",
	[">"] = "𝈷",
	["|"] = "ᥣ",
	["~"] = "𝀈",
	["#"] = "⧣",
	["\""] = "‟",
	["^"] = "ᣔ",
}

function file_path.ReplaceIllegalPathSymbols(path, forward_slash)
	local out = path:gsub(".", character_translation)

	if forward_slash then out = out:gsub("/", "⟋") end

	return out
end

function file_path.FixPathSlashes(path)
	return (path:gsub("\\", "/"):gsub("(/+)", "/"))
end

return file_path
