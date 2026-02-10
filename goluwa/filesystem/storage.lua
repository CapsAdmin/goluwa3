local fs = require("fs")
local vfs = require("filesystem.vfs")
local USERNAME = _G.USERNAME or
	tostring(os.getenv("USERNAME") or os.getenv("USER")):gsub(" ", "_"):gsub("%p", "")

local function working_directory()
	local dir = "./"
	local ffi = require("ffi")

	if jit.os == "Windows" then
		ffi.cdef("unsigned long GetCurrentDirectoryA(unsigned long, char *);")
		local buffer = ffi.new("char[260]")
		local length = ffi.C.GetCurrentDirectoryA(260, buffer)
		dir = ffi.string(buffer, length):gsub("\\", "/") .. "/"
	else
		ffi.cdef("char *strerror(int)")
		ffi.cdef("char *realpath(const char *, char *);")
		local resolved_name = ffi.new("char[?]", 1024)
		local ret = ffi.C.realpath("./", resolved_name)

		if ret == nil then
			local num = ffi.errno()
			local err = ffi.string(ffi.C.strerror(num))
			err = err == "" and tostring(num) or err
			print("realpath failed: " .. err)
			print("defaulting to ./")
			dir = ""
		else
			dir = ffi.string(ret) .. "/"
		end
	end

	return dir
end

local function get_root()
	return working_directory() .. "game/"
end

local function get(what)
	local root = get_root()
	local storage = root .. "storage/"

	if what == "working_directory" then
		return working_directory()
	elseif what == "root" then
		return root
	elseif what == "storage" then
		return storage
	elseif what == "userdata" then
		return storage .. "userdata/" .. USERNAME:lower() .. "/"
	elseif what == "shared" then
		return storage .. "shared/"
	elseif what == "cache" then
		return storage .. "cache/"
	elseif what == "temp" then
		return storage .. "temp/"
	end

	error("unknown storage type: " .. tostring(what))
end

local cache = {}

function vfs.GetStorageDirectory(what)
	if cache[what] == nil then cache[what] = get(what) end

	return cache[what]
end

function vfs.MountStorageDirectories()
	do
		local dir = vfs.GetStorageDirectory("storage")
		fs.create_directory_recursive(dir)
		vfs.Mount("os:" .. dir)
	end

	do
		local dir = vfs.GetStorageDirectory("userdata")
		fs.create_directory_recursive(dir)
		vfs.Mount("os:" .. dir, "os:data")
	end

	do
		local dir = vfs.GetStorageDirectory("cache")
		fs.create_directory_recursive(dir)
		vfs.Mount("os:" .. dir, "os:cache")
	end

	do
		local dir = vfs.GetStorageDirectory("shared")
		fs.create_directory_recursive(dir)
		vfs.Mount("os:" .. dir, "os:shared")
	end

	vfs.MountAddons(vfs.GetStorageDirectory("root") .. "addons/")
end
