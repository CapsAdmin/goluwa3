local crypto = import("goluwa/crypto.lua")
local utility = import("goluwa/utility.lua")
local timer = import("goluwa/timer.lua")
local Tree = import("goluwa/structs/tree.lua")
local vfs = import("goluwa/filesystem/vfs.lua")
local objects = import("goluwa/objects/objects.lua")
local CONTEXT = objects.CreateTemplate("file_system_generic_archive")
CONTEXT.Base = import("goluwa/filesystem/base_file.lua")
CONTEXT.Name = "generic_archive"
CONTEXT.Position = 0

function CONTEXT:AddEntry(entry)
	self.tree.done_directories = self.tree.done_directories or {}
	local directory = entry.full_path:match("(.+)/") or "./"
	entry.file_name = entry.full_path:match(".+/(.+)") or entry.full_path
	entry.size = tonumber(entry.size) or 0
	entry.offset = tonumber(entry.offset) or 0
	entry.is_file = true
	local full_path = entry.full_path
	entry.full_path = nil
	self.tree:SetEntry(full_path, entry)
	self.tree:SetEntry(
		directory,
		{
			path = directory,
			is_dir = true,
			file_name = directory:match(".+/(.+)") or directory,
		}
	)

	for i = #directory, 1, -1 do
		local char = directory:sub(i, i)

		if char == "/" then
			local dir = directory:sub(0, i)

			if dir == "" or self.tree.done_directories[dir] then break end

			local file_name = dir:match(".+/(.+)") or dir

			if file_name:sub(-1) == "/" then file_name = file_name:sub(0, -2) end

			self.tree:SetEntry(dir, {path = dir, is_dir = true, file_name = file_name})
			self.tree.done_directories[dir] = true
		end
	end
end

local cache = {}
local last_used = {}

local function get_cache(key)
	last_used[key] = os.clock()
	return cache[key]
end

local function set_cache(key, value)
	cache[key] = value
end

timer.Repeat(
	"archive_cache_cleanup",
	10,
	0,
	function()
		local now = os.clock()

		for k, v in pairs(last_used) do
			if now - v > 5 then
				cache[k] = nil
				last_used[k] = nil
			end
		end
	end
)

local function save_vpk_disk_cache(cache_path, tree)
	local codec = import("goluwa/codec.lua")
	codec.WriteFile("msgpack", cache_path, tree.tree)
end

local never
local modified_cache = {}

function CONTEXT:OpenArchive(archive_path)
	return vfs.Open("os:" .. archive_path)
end

function CONTEXT:GetArchiveVersion(archive_path)
	return vfs.GetLastModified(archive_path) or ""
end

function CONTEXT:GetFileTree(path_info)
	if never then return false, "recursive call to GetFileTree" end

	local extensions = self.Extension

	if type(extensions) == "string" then extensions = {extensions} end

	local archive_path, relative

	for _, extension in ipairs(extensions) do
		archive_path, relative = path_info.full_path:slice((self.NameEndsWith or "") .. "." .. extension .. "/", 0, 1)

		if not archive_path then
			archive_path, relative = path_info.full_path:slice("." .. extension .. "/", 0, 1)
		end

		if archive_path then break end
	end

	if not archive_path then
		return false, "not a valid archive path: " .. path_info.full_path
	end

	local modified = modified_cache[archive_path]
	local now = os.time()

	if not modified or now - modified.checked >= 2 then
		never = not self.NestedArchives
		modified = {value = self:GetArchiveVersion(archive_path), checked = now}
		never = false
		modified_cache[archive_path] = modified
	end

	local last_modified = modified.value
	local cache_key = archive_path .. last_modified

	if get_cache(cache_key) then
		return get_cache(cache_key), relative, archive_path
	end

	if not vfs.IsFile(archive_path) then
		return false, "not a valid archive path: " .. archive_path
	end

	local cache_path = "os:cache/archive/" .. crypto.CRC32(cache_key)

	if vfs.IsFile(cache_path) then
		local codec = import("goluwa/codec.lua")
		never = true
		local tree_data, err, what = codec.ReadFile("msgpack", cache_path)
		never = false

		if tree_data then
			local tree = Tree.New("/", tree_data)
			set_cache(cache_key, tree)
			return tree, relative, archive_path
		end
	end

	never = not self.NestedArchives
	local file, err = self:OpenArchive(archive_path)
	never = false

	if not file then return false, err end

	if VERBOSE then llog("generating tree data cache for ", archive_path) end

	local tree = Tree.New("/")
	self.tree = tree
	local ok, err = self:OnParseArchive(file, archive_path)
	self.tree.done_directories = nil
	file:Close()

	if not ok then return false, err end

	set_cache(cache_key, tree)
	local codec = import("goluwa/codec.lua")
	utility.RunOnNextGarbageCollection(save_vpk_disk_cache, cache_path, tree)
	return tree, relative, archive_path
end

function CONTEXT:IsFile(path_info)
	local tree, relative, archive_path = self:GetFileTree(path_info)

	if not tree then return tree, relative end

	local entry, err = tree:GetEntry(relative)

	if entry and entry.is_file then return true end
end

function CONTEXT:IsFolder(path_info)
	local tree, relative, archive_path = self:GetFileTree(path_info)

	if relative == "" then return true end

	if not tree then return tree, relative end

	local entry = tree:GetEntry(relative)

	if entry and entry.is_dir then return true end
end

function CONTEXT:GetFiles(path_info)
	local tree, relative, archive_path = self:GetFileTree(path_info)

	if not tree then return tree, relative end

	local children, err = tree:GetChildren(relative:match("(.*)/") or relative)

	if not children then return false, err end

	local out = {}

	for _, v in pairs(children) do
		if type(v) == "table" and v.v then list.insert(out, v.v.file_name) end
	end

	return out
end

do
	local function walk(node, prefix, callback)
		for name, child in pairs(node) do
			if name ~= "k" and name ~= "v" then
				local entry = child.v

				if entry and entry.is_file then
					callback(prefix .. name, entry.size)
				else
					walk(child, prefix .. name .. "/", callback)
				end
			end
		end
	end

	function CONTEXT:GetFilesRecursive(path_info, callback, virtual_path)
		local tree, relative = self:GetFileTree(path_info)

		if not tree then return end

		local node = tree.tree
		local real = {}

		for key in relative:gmatch("[^/]+") do
			local child = node[key]

			if child then
				real[#real + 1] = key
			else
				local lower = key:lower()

				for name, other in pairs(node) do
					if name ~= "k" and name ~= "v" and name:lower() == lower then
						child = other
						real[#real + 1] = name

						break
					end
				end
			end

			if not child then return end

			node = child
		end

		local prefix = virtual_path

		if #real > 0 then
			local real_path = table.concat(real, "/") .. "/"

			if #real_path == #virtual_path then prefix = real_path end
		end

		walk(node, prefix, callback)
	end
end

function CONTEXT:TranslateArchivePath(file_info)
	return file_info.archive_path
end

local cache = table.weak("kv")

function CONTEXT:Open(path_info, mode, ...)
	if self:GetMode() == "read" then
		local tree, relative, archive_path = self:GetFileTree(path_info)

		if not tree then return false, relative end

		local file_info = tree:GetEntry(relative)

		if not file_info then return false, "file not found in archive" end

		if file_info.is_dir then return false, "file is a directory" end

		local archive_path = self:TranslateArchivePath(file_info, archive_path)
		local file, err = get_cache(archive_path) or vfs.Open(archive_path)
		set_cache(archive_path, file)

		if not file then return false, err end

		file:SetPosition(file_info.offset)
		self.position = 0
		self.file_info = file_info

		if file_info.preload_data then
			if file_info.size == #file_info.preload_data then
				self.data = file_info.preload_data
			else
				self.data = file_info.preload_data .. file:ReadBytes(file_info.size - #file_info.preload_data)
			end

			self.file = nil
		else
			self.file = file
		end

		return true
	elseif self:GetMode() == "write" then
		return false, "write mode not implemented"
	end

	return false, "read mode " .. self:GetMode() .. " not supported"
end

function CONTEXT:ReadByte()
	if self.file_info.preload_data then
		local char = self.data:sub(self.position + 1, self.position + 1)
		self.position = math.clamp(self.position + 1, 0, self.file_info.size)
		return char:byte()
	else
		self.file:SetPosition(self.file_info.offset + self.position)
		local char = self.file:ReadByte(1)
		self.position = math.clamp(self.position + 1, 0, self.file_info.size)
		return char
	end
end

function CONTEXT:ReadBytes(bytes)
	if bytes == math.huge then bytes = self:GetSize() end

	if self.file_info.preload_data then
		local str = self.data:sub(self.position + 1, self.position + bytes)
		self.position = math.clamp(self.position + #str, 0, self.file_info.size)
		return str
	else
		bytes = math.min(bytes, self.file_info.size - self.position)
		self.file:SetPosition(self.file_info.offset + self.position)
		local str = self.file:ReadBytes(bytes)
		self.position = math.clamp(self.position + bytes, 0, self.file_info.size)

		if str == "" then str = nil end

		return str
	end
end

function CONTEXT:SetPosition(pos)
	self.position = math.clamp(pos, 0, self.file_info.size)
end

function CONTEXT:GetPosition()
	return self.position
end

function CONTEXT:OnRemove()
	if self.file and self.file:IsValid() then self.file = nil end
end

function CONTEXT:GetSize()
	return self.file_info.size
end

return CONTEXT:Register()
