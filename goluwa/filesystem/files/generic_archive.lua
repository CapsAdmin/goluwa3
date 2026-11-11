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
	entry.size = tonumber(entry.size) or 0
	entry.offset = tonumber(entry.offset) or 0
	local full_path = entry.full_path
	entry.full_path = nil
	entry.file_name = nil
	self.tree:SetEntry(full_path, entry)
end

local cache = {}
local last_used = {}
local EVICT_AFTER = 60

local function get_cache(key)
	last_used[key] = os.time()
	return cache[key]
end

local function set_cache(key, value)
	last_used[key] = os.time()
	cache[key] = value
end

timer.Repeat(
	"archive_cache_cleanup",
	10,
	0,
	function()
		local now = os.time()

		for k, v in pairs(last_used) do
			if now - v > EVICT_AFTER then
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

function CONTEXT:SplitArchivePath(path_info)
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

	return archive_path, relative
end

local function get_cache_key(self, archive_path)
	local modified = modified_cache[archive_path]
	local now = os.time()

	if not modified or now - modified.checked >= 2 then
		never = not self.NestedArchives
		modified = {value = self:GetArchiveVersion(archive_path), checked = now}
		never = false
		modified_cache[archive_path] = modified
	end

	return "tree2:" .. archive_path .. modified.value
end

function CONTEXT:GetFileTree(path_info)
	if never then return false, "recursive call to GetFileTree" end

	local archive_path, relative = self:SplitArchivePath(path_info)

	if not archive_path then
		return false, "not a valid archive path: " .. path_info.full_path
	end

	local cache_key = get_cache_key(self, archive_path)

	if get_cache(cache_key) then
		return get_cache(cache_key), relative, archive_path
	end

	never = not self.NestedArchives
	local archive_exists = vfs.IsFile(archive_path)
	never = false

	if not archive_exists then
		return false, "not a valid archive path: " .. archive_path
	end

	local cache_path = "os:cache/archive/" .. crypto.CRC32(cache_key)
	never = true
	local cache_exists = vfs.IsFile(cache_path)
	never = false

	if cache_exists then
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

	if entry and Tree.IsLeaf(entry) then return true end
end

function CONTEXT:IsFolder(path_info)
	local archive_path, relative = self:SplitArchivePath(path_info)

	if archive_path and relative == "" and not never then
		never = not self.NestedArchives
		local archive_exists = vfs.IsFile(archive_path)
		never = false
		return archive_exists
	end

	local tree
	tree, relative, archive_path = self:GetFileTree(path_info)

	if relative == "" then return true end

	if not tree then return tree, relative end

	local entry = tree:GetEntry(relative)

	if entry and not Tree.IsLeaf(entry) then return true end
end

function CONTEXT:GetFiles(path_info)
	local tree, relative, archive_path = self:GetFileTree(path_info)

	if not tree then return tree, relative end

	local children, err = tree:GetEntry(relative:match("(.*)/") or relative)

	if not children then return false, err end

	local out = {}

	if Tree.IsLeaf(children) then return out end

	for name in pairs(children) do
		out[#out + 1] = name
	end

	return out
end

do
	local ffi = require("ffi")
	local msgpack = import("goluwa/codecs/msgpack.lua")
	local uint32_ptr = ffi.typeof("const uint32_t*")
	local uint32_array = ffi.typeof("uint32_t[?]")

	local function by_lower_path(a, b)
		return a[1] < b[1]
	end

	local function pack_list(list)
		local count = #list
		local numbers = uint32_array(2 * count + 2)
		local paths = {}
		local offset = 0
		numbers[0] = count

		for i, item in ipairs(list) do
			numbers[i] = offset
			numbers[count + 1 + i] = item[3]
			paths[i] = item[2]
			offset = offset + #item[2] + 1
		end

		numbers[count + 1] = offset
		return ffi.string(numbers, ffi.sizeof(numbers)) .. table.concat(paths, "\n") .. "\n"
	end

	local function open_list(blob)
		local numbers = ffi.cast(uint32_ptr, blob)
		local count = numbers[0]
		return {blob = blob, numbers = numbers, count = count, base = 4 * (2 * count + 2)}
	end

	local function get_list_path(list, i)
		local numbers = list.numbers
		return list.blob:sub(list.base + numbers[i + 1] + 1, list.base + numbers[i + 2] - 1)
	end

	local function lower_bound(list, key)
		local low, high = 0, list.count

		while low < high do
			local mid = math.floor((low + high) / 2)

			if get_list_path(list, mid):lower() < key then low = mid + 1 else high = mid end
		end

		return low
	end

	local function build_extension_blobs(tree)
		local by_ext = {}

		local function collect(node, prefix)
			for name, child in pairs(node) do
				if Tree.IsLeaf(child) then
					local ext = name:match("(%.[^./]+)$")

					if ext then
						ext = ext:lower()
						local list = by_ext[ext]

						if not list then
							list = {}
							by_ext[ext] = list
						end

						local path = prefix .. name
						list[#list + 1] = {path:lower(), path, child.size}
					end
				else
					collect(child, prefix .. name .. "/")
				end
			end
		end

		collect(tree, "")

		for ext, list in pairs(by_ext) do
			table.sort(list, by_lower_path)
			by_ext[ext] = pack_list(list)
		end

		return by_ext
	end

	local function save_extension_blobs(path, blobs)
		local parts = {}
		local dir = {}
		local offset = 0

		for ext, blob in pairs(blobs) do
			dir[ext] = {offset, #blob}
			parts[#parts + 1] = blob
			offset = offset + #blob
		end

		dir.total = offset
		local header = msgpack.Encode(dir)
		vfs.Write(path, ("%08x"):format(#header) .. header .. table.concat(parts))
	end

	local function get_extension_index(self, path_info, archive_path)
		local ext_key = get_cache_key(self, archive_path) .. ".ext"
		local handle = get_cache(ext_key)

		if handle then return handle end

		local ext_path = "os:cache/archive/" .. crypto.CRC32(ext_key)
		never = true
		local file = vfs.IsFile(ext_path) and vfs.Open(ext_path)
		never = false

		if file then
			local header_length = tonumber(file:ReadBytes(8), 16)
			local header = header_length and file:ReadBytes(header_length)
			local dir = header and msgpack.Decode(header)

			if
				type(dir) == "table" and
				dir.total and
				file:GetSize() == 8 + header_length + dir.total
			then
				handle = {path = ext_path, base = 8 + header_length, dir = dir, lists = {}}
			end

			file:Close()
		end

		if not handle then
			local tree = self:GetFileTree(path_info)

			if not tree then return end

			local blobs = build_extension_blobs(tree.tree)
			handle = {blobs = blobs, lists = {}}
			utility.RunOnNextGarbageCollection(save_extension_blobs, ext_path, blobs)
		end

		set_cache(ext_key, handle)
		return handle
	end

	local function read_extension_list(handle, ext)
		local list = handle.lists[ext]

		if list ~= nil then return list end

		local blob

		if handle.blobs then
			blob = handle.blobs[ext]
		else
			local info = handle.dir[ext]

			if info then
				never = true
				local file = vfs.Open(handle.path)
				never = false
				file:SetPosition(handle.base + info[1])
				blob = file:ReadBytes(info[2])
				file:Close()
			end
		end

		list = blob and open_list(blob) or false
		handle.lists[ext] = list
		return list
	end

	function CONTEXT:GetFilesRecursiveByExtension(path_info, callback, virtual_path, filter)
		local archive_path, relative = self:SplitArchivePath(path_info)

		if not archive_path or never then return end

		local handle = get_extension_index(self, path_info, archive_path)

		if not handle then return end

		local prefix = relative:lower()

		if prefix ~= "" and prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end

		local prefix_length = #prefix
		local prefix_is_real = prefix_length == #virtual_path
		local upper = prefix_length > 0 and prefix:sub(1, -2) .. string.char(prefix:byte(-1) + 1)

		for ext in pairs(filter.set) do
			local list = read_extension_list(handle, ext)

			if list then
				local numbers = list.numbers
				local sizes_offset = list.count + 2
				local last = upper and lower_bound(list, upper) or list.count

				for i = lower_bound(list, prefix), last - 1 do
					local path = get_list_path(list, i)

					if not prefix_is_real then
						path = virtual_path .. path:sub(prefix_length + 1)
					end

					callback(path, numbers[sizes_offset + i], ext)
				end
			end
		end
	end
end

do
	local function walk(node, prefix, callback)
		for name, child in pairs(node) do
			if Tree.IsLeaf(child) then
				callback(prefix .. name, child.size)
			else
				walk(child, prefix .. name .. "/", callback)
			end
		end
	end

	function CONTEXT:GetFilesRecursive(path_info, callback, virtual_path, filter)
		if filter then
			return self:GetFilesRecursiveByExtension(path_info, callback, virtual_path, filter)
		end

		local tree, relative = self:GetFileTree(path_info)

		if not tree then return end

		local node = tree.tree
		local real = {}

		for key in relative:gmatch("[^/]+") do
			if Tree.IsLeaf(node) then return end

			local child = node[key]

			if child then
				real[#real + 1] = key
			else
				local lower = key:lower()

				for name, other in pairs(node) do
					if name:lower() == lower then
						child = other
						real[#real + 1] = name

						break
					end
				end
			end

			if not child then return end

			node = child
		end

		if Tree.IsLeaf(node) then return end

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

-- the os file, offset and size holding the bytes of an entry, nothing for entries that are stored in the archive's directory
function CONTEXT:GetReadLocation(path_info)
	local tree, relative, archive_path = self:GetFileTree(path_info)

	if not tree then return end

	local file_info = tree:GetEntry(relative)

	if
		not file_info or
		not Tree.IsLeaf(file_info)
		or
		(
			file_info.preload_data and
			#file_info.preload_data > 0
		)
	then
		return
	end

	local os_path = self:TranslateArchivePath(file_info, archive_path)

	if os_path:starts_with("os:") then
		return os_path:sub(4), file_info.offset, file_info.size
	end
end

local cache = table.weak("kv")

function CONTEXT:Open(path_info, mode, ...)
	if self:GetMode() == "read" then
		local tree, relative, archive_path = self:GetFileTree(path_info)

		if not tree then return false, relative end

		local file_info = tree:GetEntry(relative)

		if not file_info then return false, "file not found in archive" end

		if not Tree.IsLeaf(file_info) then return false, "file is a directory" end

		if self.PreloadAll and not file_info.preload_data then
			file_info.preload_data = ""
		end

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
