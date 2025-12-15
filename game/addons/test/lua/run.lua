_G.PROFILE = false
require("goluwa.global_environment")
local render = require("graphics.render")
local render2d = require("graphics.render2d")
local render3d = require("graphics.render3d")
local gfx = require("graphics.gfx")
local system = require("system")
local main_loop = require("main")
local vfs = require("vfs")
local fs = require("fs")

do
	local USERNAME = _G.USERNAME or
		tostring(os.getenv("USERNAME") or os.getenv("USER")):gsub(" ", "_"):gsub("%p", "")
	local INTERNAL_ADDON_NAME = "core"
	local ROOT_FOLDER = "./"
	local ffi = require("ffi")
	pcall(ffi.load, "pthread")

	if jit.os == "windows" then
		ffi.cdef("unsigned long GetCurrentDirectoryA(unsigned long, char *);")
		local buffer = ffi.new("char[260]")
		local length = ffi.C.GetCurrentDirectoryA(260, buffer)
		ROOT_FOLDER = ffi.string(buffer, length):gsub("\\", "/") .. "/"
	else
		ffi.cdef("char *strerror(int)")
		ffi.cdef("char *realpath(const char *, char *);")
		local resolved_name = ffi.new("char[?]", 256)
		local ret = ffi.C.realpath("./", resolved_name)

		if ret == nil then
			local num = ffi.errno()
			local err = ffi.string(ffi.C.strerror(num))
			err = err == "" and tostring(num) or err
			print("realpath failed: " .. err)
			print("defaulting to ./")
			ROOT_FOLDER = ""
		else
			ROOT_FOLDER = ffi.string(ret) .. "/"
		end
	end

	ROOT_FOLDER = ROOT_FOLDER .. "game/"
	local BIN_FOLDER = ROOT_FOLDER .. (os.getenv("GOLUWA_BINARY_DIR") or "core/bin/linux_x64/") .. "/"
	local CORE_FOLDER = ROOT_FOLDER .. INTERNAL_ADDON_NAME .. "/"
	local STORAGE_FOLDER = ROOT_FOLDER .. "storage/"
	local USERDATA_FOLDER = STORAGE_FOLDER .. "userdata/" .. USERNAME:lower() .. "/"
	local SHARED_FOLDER = STORAGE_FOLDER .. "shared/"
	local CACHE_FOLDER = STORAGE_FOLDER .. "cache/"
	local TEMP_FOLDER = STORAGE_FOLDER .. "temp/"
	local BIN_PATH = "bin/" .. jit.os .. "_" .. jit.arch .. "/"
	_G.e = {
		BIN_FOLDER = BIN_FOLDER,
		CORE_FOLDER = CORE_FOLDER,
		STORAGE_FOLDER = STORAGE_FOLDER,
		USERDATA_FOLDER = USERDATA_FOLDER,
		SHARED_FOLDER = SHARED_FOLDER,
		CACHE_FOLDER = CACHE_FOLDER,
		TEMP_FOLDER = TEMP_FOLDER,
		BIN_PATH = BIN_PATH,
		USERNAME = USERNAME,
		INTERNAL_ADDON_NAME = INTERNAL_ADDON_NAME,
		ROOT_FOLDER = ROOT_FOLDER,
	}
	fs.create_directory_recursive(STORAGE_FOLDER)
	fs.create_directory_recursive(USERDATA_FOLDER)
	fs.create_directory_recursive(CACHE_FOLDER)
	fs.create_directory_recursive(SHARED_FOLDER)
	vfs.Mount("os:" .. STORAGE_FOLDER) -- mount the storage folder to allow requiring files from bin/*
	vfs.Mount("os:" .. USERDATA_FOLDER, "os:data") -- mount "ROOT/data/users/*username*/" to "/data/"
	vfs.Mount("os:" .. CACHE_FOLDER, "os:cache")
	vfs.Mount("os:" .. SHARED_FOLDER, "os:shared")
	vfs.MountAddons(e.ROOT_FOLDER .. "addons/")
	_G.require = vfs.Require
	_G.runfile = function(...)
		local ret = list.pack(vfs.RunFile(...))

		-- not very ideal
		if ret[1] == false and type(ret[2]) == "string" then error(ret[2], 2) end

		return list.unpack(ret)
	end
	_G.R = vfs.GetAbsolutePath
end

render.Initialize()
render2d.Initialize()
render3d.Initialize()
gfx.Initialize()

do
	require("components.transform")
	require("components.model")
	require("components.light")
end

vfs.AutorunAddons()

do
	local unref = system.KeepAlive("game")
	main_loop()
	unref()
end
