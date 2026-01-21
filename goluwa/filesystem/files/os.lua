local fs = require("fs")
local ffi = desire("ffi")
local vfs = require("filesystem.vfs")
local prototype = require("prototype")
local CONTEXT = prototype.CreateTemplate("file_system_os")
CONTEXT.Base = require("filesystem.base_file")
CONTEXT.Name = "os"
CONTEXT.Position = 0

function CONTEXT:CreateFolder(path_info, force)
	if
		force or
		path_info.full_path:starts_with(vfs.GetStorageDirectory("storage")) or
		path_info.full_path:starts_with(vfs.GetStorageDirectory("userdata")) or
		path_info.full_path:starts_with(vfs.GetStorageDirectory("root"))
	then
		if self:IsFolder(path_info) then return true end

		if force then
			if VERBOSE then llog("creating directory: ", path_info.full_path) end
		end

		local path = path_info.full_path
		--if path:ends_with("/") then path = path:sub(0, -2) end
		local ok, err = fs.create_directory(path)
		vfs.ClearCallCache()
		return ok or false, err
	end

	return false, "directory does not start from goluwa"
end

function CONTEXT:GetFiles(path_info)
	local files, err = fs.get_files(path_info.full_path)

	if not files then return false, err end

	return files
end

function CONTEXT:IsFile(path_info)
	return fs.get_type(path_info.full_path) == "file"
end

function CONTEXT:IsFolder(path_info)
	local path = path_info.full_path

	if path:ends_with("/") and #path > 1 then path = path:sub(1, -2) end

	return fs.get_type(path) == "directory"
end

function CONTEXT:ReadAll()
	return self:ReadBytes(math.huge)
end

local translate_mode = {
	read = fs.O_RDONLY,
	read_plus = bit.bor(fs.O_RDWR),
	write = bit.bor(fs.O_WRONLY, fs.O_CREAT, fs.O_TRUNC),
	append = bit.bor(fs.O_WRONLY, fs.O_CREAT, fs.O_APPEND),
	read_write = bit.bor(fs.O_RDWR, fs.O_CREAT),
}

-- if CONTEXT:Open errors the virtual file system will assume
-- the file doesn't exist and will go to the next mounted context
function CONTEXT:Open(path_info, ...)
	local mode = translate_mode[self:GetMode()]

	if not mode then return false, "mode " .. self:GetMode() .. " not supported" end

	if self.Mode == "read_write" then
		local err
		local f, err = fs.fd_open_object(path_info.full_path, translate_mode.append)

		if not f then return false, "unable to open file: " .. err end

		local ok, err = f:close()

		if not ok then return false, "unable to open file: " .. err end

		self.file, err = fs.fd_open_object(path_info.full_path, translate_mode.read_plus)

		if not self.file then return false, "unable to open file: " .. err end
	else
		local err
		self.file, err = fs.fd_open_object(path_info.full_path, mode)

		if not self.file then return false, "unable to open file: " .. err end
	end

	local attr, err = fs.get_attributes(path_info.full_path)

	if not attr then
		if self.file then self.file:close() end

		return false, "unable to get file attributes: " .. err
	end

	self.attributes = attr
	return true
end

function CONTEXT:WriteBytes(str)
	return self.file:write(str)
end

local ctype = ffi.typeof("uint8_t[?]")
local ffi_string = ffi.string
local math_min = math.min
-- without this cache thing loading gm_construct takes 30 sec opposed to 15
local cache = {}

for i = 1, 32 do
	cache[i] = ctype(i)
end

function CONTEXT:ReadBytes(bytes)
	bytes = math_min(bytes, self.attributes.size)

	if self.memory then
		local buff = bytes > 32 and ctype(bytes) or cache[bytes]
		local mem_pos_start = math_min(tonumber(self.mem_pos), self.attributes.size)
		local mem_pos_stop = math_min(tonumber(mem_pos_start + bytes), self.attributes.size)
		local i = 0

		for mem_i = mem_pos_start, mem_pos_stop - 1 do
			buff[i] = self.memory[mem_i]
			i = i + 1
		end

		self.mem_pos = self.mem_pos + bytes
		return ffi.string(buff, mem_pos_stop - mem_pos_start)
	else
		return self.file:read(bytes)
	end
end

function CONTEXT:LoadToMemory()
	local bytes = self:GetSize()
	local buffer = ctype(bytes)
	local data = self.file:read(bytes)

	if data then ffi.copy(buffer, data, #data) end

	self.memory = buffer
	self:SetPosition(ffi.new("uint64_t", 0))
	self:OnRemove()
end

function CONTEXT:SetPosition(pos)
	if self.memory then
		self.mem_pos = pos
	else
		self.file:seek(pos, fs.SEEK_SET)
	end
end

function CONTEXT:GetPosition()
	if self.memory then
		return self.mem_pos
	else
		return self.file:seek(0, fs.SEEK_CUR)
	end
end

function CONTEXT:OnRemove()
	if self.file ~= nil then
		self.file:close()
		self.file = nil
		prototype.MakeNULL(self)
	end
end

function CONTEXT:GetSize()
	if self.Mode == "read" or self.memory then return self.attributes.size end

	local pos = self.file:seek(0, fs.SEEK_CUR)
	self.file:seek(0, fs.SEEK_END)
	local size = self.file:seek(0, fs.SEEK_CUR)
	self.file:seek(pos, fs.SEEK_SET)
	return tonumber(size) -- hmm, 64bit?
end

function CONTEXT:GetLastModified()
	return self.attributes.last_modified
end

function CONTEXT:GetLastAccessed()
	return self.attributes.last_accessed
end

function CONTEXT:Flush() --self.file:flush()
end

return CONTEXT:Register()
