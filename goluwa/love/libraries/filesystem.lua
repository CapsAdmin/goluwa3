local love = ... or _G.love
local ENV = love._line_env
local line = import("goluwa/love/line.lua")
local vfs = import("goluwa/filesystem/vfs.lua")
local R = vfs.GetAbsolutePath
local event = import("goluwa/event.lua")
love.filesystem = love.filesystem or {}
ENV.filesystem_identity = ENV.filesystem_identity or "none"

local function get_identity_path(path)
	return "data/love/" .. ENV.filesystem_identity .. "/" .. path
end

local function get_identity_storage_path(path)
	local base = vfs.GetStorageDirectory("storage") .. "love/" .. ENV.filesystem_identity .. "/"

	if not path or path == "" then return base end

	return base .. path
end

local function each_candidate_path(path)
	local candidates = {get_identity_storage_path(path), get_identity_path(path)}

	if path ~= candidates[1] and path ~= candidates[2] then
		candidates[#candidates + 1] = path
	end

	return ipairs(candidates)
end

local function find_existing_path(path, kind)
	for _, candidate in each_candidate_path(path) do
		if kind == "directory" then
			if vfs.IsDirectory(candidate) then return candidate, "directory" end
		elseif kind == "file" then
			if vfs.IsFile(candidate) then return candidate, "file" end
		elseif vfs.IsDirectory(candidate) then
			return candidate, "directory"
		elseif vfs.IsFile(candidate) then
			return candidate, "file"
		end
	end

	return nil
end

function love.filesystem.getAppdataDirectory()
	return get_identity_storage_path()
end

function love.filesystem.getSaveDirectory()
	return get_identity_storage_path()
end

function love.filesystem.getUserDirectory()
	return get_identity_storage_path()
end

function love.filesystem.getWorkingDirectory()
	return get_identity_storage_path()
end

function love.filesystem.getSource()
	return ENV.filesystem_source or ""
end

function love.filesystem.getRealDirectory(path)
	local storage_path = get_identity_storage_path(path)

	if vfs.IsDirectory(storage_path) or vfs.IsFile(storage_path) then
		return get_identity_storage_path()
	end

	local source = ENV.filesystem_source

	if source and source ~= "" then
		local source_path = source

		if path and path ~= "" then source_path = source_path .. path end

		if vfs.IsDirectory(source_path) or vfs.IsFile(source_path) then return source end
	end

	local resolved = find_existing_path(path)

	if not resolved then return nil end

	return resolved:match("^(.*[/\\])") or resolved
end

function love.filesystem.getLastModified(path)
	local resolved = find_existing_path(path)

	if resolved then return vfs.GetLastModified(resolved) end
end

function love.filesystem.getInfo(path, filtertype)
	local resolved, info_type = find_existing_path(path)

	if not resolved then return nil end

	if filtertype and filtertype ~= info_type then return nil end

	local info = {
		type = info_type,
		modtime = vfs.GetLastModified(resolved),
	}

	if info_type == "file" then info.size = vfs.GetSize(resolved) end

	return info
end

function love.filesystem.enumerate(path)
	if path:sub(-1) ~= "/" then path = path .. "/" end

	if vfs.IsDirectory("data/love/" .. ENV.filesystem_identity .. "/" .. path) then
		return vfs.Find("data/love/" .. ENV.filesystem_identity .. "/" .. path)
	end

	return vfs.Find(path)
end

love.filesystem.getDirectoryItems = love.filesystem.enumerate

function love.filesystem.init() end

function love.filesystem.isDirectory(path)
	return vfs.IsDirectory("data/love/" .. ENV.filesystem_identity .. "/" .. path) or
		vfs.IsDirectory(path)
end

function love.filesystem.isFile(path)
	return vfs.IsFile("data/love/" .. ENV.filesystem_identity .. "/" .. path) or
		vfs.IsFile(path)
end

function love.filesystem.exists(path)
	return vfs.Exists("data/love/" .. ENV.filesystem_identity .. "/" .. path) or
		vfs.Exists(path)
end

function love.filesystem.lines(path)
	local file = vfs.Open("data/love/" .. ENV.filesystem_identity .. "/" .. path)

	if not file then file = vfs.Open(path) end

	if file then return file:Lines() end

	return function() end
end

function love.filesystem.load(path)
	local func, err

	if line.Type(path) == "FileData" then
		func, err = loadstring(path:getString())
	else
		func, err = vfs.LoadFile("data/love/" .. ENV.filesystem_identity .. "/" .. path, mode)

		if not func then func, err = vfs.LoadFile(path) end
	end

	if func then setfenv(func, getfenv(2)) end

	return func, err
end

function love.filesystem.mkdir(path)
	vfs.CreateDirectoriesFromPath("os:data/love/" .. ENV.filesystem_identity .. "/" .. path)
	return true
end

love.filesystem.createDirectory = love.filesystem.mkdir

function love.filesystem.read(path, size, bytes)
	local container = "string"

	if type(path) == "string" and (path == "string" or path == "data" or path == "file") then
		container = path
		path = size
		size = bytes
	end

	local file = vfs.Open("data/love/" .. ENV.filesystem_identity .. "/" .. path)

	if not file then file = vfs.Open(path) end

	if file then
		local str = file:ReadBytes(size or math.huge)

		if not str then return "", 0 end

		if container == "string" then return str, #str end

		if container == "data" or container == "file" then
			return love.filesystem.newFileData(str, path), #str
		end

		error("unsupported love.filesystem.read container: " .. tostring(container), 2)
	end
end

function love.filesystem.remove(path)
	wlog("attempted to remove folder/file " .. path)
end

function love.filesystem.setIdentity(name)
	vfs.CreateDirectoriesFromPath("os:data/love/" .. name .. "/")
	ENV.filesystem_identity = name
	vfs.Mount(love.filesystem.getUserDirectory())
end

function love.filesystem.getIdentity()
	return ENV.filesystem_identity
end

function love.filesystem.write(path, data)
	vfs.Write("data/love/" .. ENV.filesystem_identity .. "/" .. path, data)
	return true
end

function love.filesystem.isFused()
	return false
end

function love.filesystem.mount(from, to)
	if not vfs.IsDirectory("data/love/" .. ENV.filesystem_identity .. "/" .. from) then
		vfs.Mount(from, "data/love/" .. ENV.filesystem_identity .. "/" .. to)
		return vfs.IsDirectory(from)
	else
		vfs.Mount(
			"data/love/" .. ENV.filesystem_identity .. "/" .. from,
			"data/love/" .. ENV.filesystem_identity .. "/" .. to
		)
		return true
	end
end

function love.filesystem.unmount(from)
	vfs.Unmount("data/love/" .. ENV.filesystem_identity .. "/" .. from)
end

function love.filesystem.append(name, data, size) end

function love.filesystem.setSymlinksEnabled() end

do -- File object
	local File = line.TypeTemplate("File", love)

	function File:close()
		if not self.file then return end

		self.file:Close()
	end

	function File:eof()
		if not self.file then return 0 end

		return self.file:TheEnd() ~= nil
	end

	function File:setBuffer(mode, size)
		if self.file then return false, "file not opened" end

		self.file:setvbuf(mode == "none" and "no" or mode, size)
		self.mode = mode
		self.size = size
	end

	function File:getBuffer()
		return self.mode, self.size
	end

	function File:getMode()
		return self.mode
	end

	function File:getFilename()
		if self.dropped then
			return self.path
		else
			return self.path:match(".+/(.+)")
		end
	end

	function File:getSize()
		return 10
	end

	function File:isOpen()
		return self.file ~= nil
	end

	function File:lines()
		if not self.file then return function() end end

		return self.file:Lines()
	end

	function File:read(bytes)
		if not bytes then
			local size = self.file:GetSize()
			local str = self.file:ReadAll()
			return str, size
		end

		local str = self.file:ReadBytes(bytes)
		return str, #str
	end

	function File:write(data, size)
		if line.Type(data) == "string" then
			self.file:WriteBytes(data)
			return true
		elseif line.Type(data) == "Data" then
			line.ErrorNotSupported("Data not supported")
		end
	end

	function File:open(mode)
		if mode == "w" then mode = "write" end

		if mode == "r" then mode = "read" end

		llog("file open ", self.path, " ", mode)
		local path = self.path

		if mode == "w" then
			path = "data/love/" .. ENV.filesystem_identity .. "/" .. self.path
		end

		self.file = assert(vfs.Open(path, mode))
		self.mode = mode
	end

	function love.filesystem.newFile(path, mode)
		local self = line.CreateObject("File", love)
		self.path = path

		if mode then self:open(mode) end

		return self
	end

	line.RegisterType(File, love)
end

do -- FileData object
	local FileData = line.TypeTemplate("FileData", love)
	local ffi = require("ffi")
	ENV.transport_deserializers = ENV.transport_deserializers or {}

	local function get_filedata_name(data)
		local name = data.filename or "data"
		local ext = data.ext

		if ext and ext ~= "" then return name .. "." .. ext end

		return name
	end

	function FileData:getPointer()
		local ptr = ffi.new("uint8_t[?]", #self.contents)
		ffi.copy(ptr, self.contents, #self.contents)
		return ptr
	end

	function FileData:getSize()
		return #self.contents
	end

	function FileData:getString()
		return self.contents
	end

	function FileData:getExtension()
		return self.ext
	end

	function FileData:getFilename()
		return self.filename
	end

	function FileData:Serialize()
		return {
			contents = self:getString(),
			name = get_filedata_name(self),
		}
	end

	function FileData.Deserialize(payload, current_love)
		return current_love.filesystem.newFileData(payload.contents or "", payload.name or "data.bin")
	end

	ENV.transport_deserializers.FileData = FileData.Deserialize

	function love.filesystem.newFileData(contents, name, decoder)
		if name == nil and type(contents) == "string" then
			name = contents
			contents = assert(love.filesystem.read(name))
		elseif name then
			love.filesystem.write(name, contents)
		end

		local self = line.CreateObject("FileData", love)
		self.contents = contents
		self.filename = name or "data"
		self.filename, self.ext = self.filename:match("(.+)%.(.+)")

		if not self.filename then
			self.filename = name or "data"
			self.ext = "bin"
		end

		return self
	end

	line.RegisterType(FileData, love)
end

event.AddListener("LoveNewIndex", "line_filesystem", function(love, key, val)
	if key == "filedropped" then
		if val then
			event.AddListener("WindowDrop", "line_filedropped", function(wnd, paths)
				if love.filedropped then
					for _, path in ipairs(paths) do
						local file = love.filesystem.newFile(path)
						file.dropped = true
						love.filedropped(file)
					end
				end
			end)
		else
			event.AddListener("WindowDrop", "line_filedropped")
		end
	end
end)
