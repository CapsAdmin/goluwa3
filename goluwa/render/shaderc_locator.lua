local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local shaderc = import("goluwa/bindings/shaderc.lua")
local bin_download = import("goluwa/bin_download.lua")
local locator = {}
local SMOKE_SOURCE = "#version 450\nlayout(local_size_x = 1) in;\nvoid main() {}\n"
local SPIRV_MAGIC = 0x07230203
local shared_library_extension = jit.os == "Windows" and ".dll" or jit.os == "OSX" and ".dylib" or ".so"
local shared_library_pattern = jit.os == "Windows" and
	"%.dll$" or
	jit.os == "OSX" and
	"%.dylib$" or
	"%.so[%.%d]*$"
local platform = bin_download.platform
local manifest = import("goluwa/bin_manifest.lua").shaderc
locator.asset = manifest.assets[platform]
locator.download_url = locator.asset and
	manifest.release .. locator.asset.file or
	"(no prebuilt binary is published for " .. platform .. ")"

function locator.GetDirectory()
	return vfs.GetStorageDirectory("root") .. "storage/bin/libshaderc/"
end

local function is_shared_library(name)
	return name:find(shared_library_pattern) ~= nil
end

local function list_directory()
	local found = {}

	for _, name in ipairs(fs.get_files(locator.GetDirectory()) or {}) do
		if is_shared_library(name) then table.insert(found, name) end
	end

	return found
end

local get_loaded_path

local function try_load(path)
	local ok, lib = pcall(ffi.load, path)

	if not ok then return nil, tostring(lib) end

	local ok, err = pcall(shaderc.Initialize, lib)

	if not ok then return nil, "could not initialize shaderc: " .. tostring(err) end

	local ok, data, size = pcall(shaderc.compile, SMOKE_SOURCE, "compute")

	if not ok then return nil, "smoke test failed to compile: " .. tostring(data) end

	if size < 20 or ffi.cast("const uint32_t *", data)[0] ~= SPIRV_MAGIC then
		return nil, "smoke test produced invalid SPIR-V"
	end

	local resolved = path:find("/", nil, true) and path or get_loaded_path(path)
	local stat = fs.get_attributes(resolved)
	shaderc.identity = resolved .. ":" .. tostring(stat.size) .. ":" .. stat.last_modified
	return true
end

if jit.os == "Windows" then
	ffi.cdef[[
		void *GetModuleHandleA(const char *name);
		uint32_t GetModuleFileNameA(void *module, char *buffer, uint32_t size);
	]]

	function get_loaded_path(name)
		local module = ffi.C.GetModuleHandleA(name)

		if module == nil then return nil end

		local buffer = ffi.new("char[1024]")
		local length = ffi.C.GetModuleFileNameA(module, buffer, 1024)

		if length == 0 then return nil end

		return ffi.string(buffer, length)
	end
elseif jit.os == "OSX" then
	ffi.cdef[[
		uint32_t _dyld_image_count(void);
		const char *_dyld_get_image_name(uint32_t index);
	]]

	function get_loaded_path()
		for i = 0, ffi.C._dyld_image_count() - 1 do
			local name = ffi.string(ffi.C._dyld_get_image_name(i))

			if name:find("shaderc", nil, true) and is_shared_library(name) then
				return name
			end
		end
	end
else
	function get_loaded_path()
		for line in io.lines("/proc/self/maps") do
			local path = line:match("%s(/[^%s]*shaderc[^%s]*)$")

			if path and is_shared_library(path) then return path end
		end
	end
end

local function get_candidates()
	local candidates = {}
	local vulkan_sdk = os.getenv("VULKAN_SDK")

	if jit.os == "Windows" then
		if vulkan_sdk then
			table.insert(candidates, {path = vulkan_sdk .. "/Bin/shaderc_shared.dll"})
		else
			local versions = fs.get_files("C:/VulkanSDK/") or {}
			table.sort(versions, function(a, b)
				return a > b
			end)

			for _, version in ipairs(versions) do
				table.insert(candidates, {path = "C:/VulkanSDK/" .. version .. "/Bin/shaderc_shared.dll"})
			end
		end

		table.insert(candidates, {name = "shaderc_shared.dll"})
	elseif jit.os == "OSX" then
		local home = os.getenv("HOME")

		if vulkan_sdk then
			table.insert(candidates, {path = vulkan_sdk .. "/lib/libshaderc_shared.dylib"})
			table.insert(candidates, {path = vulkan_sdk .. "/lib/libshaderc_shared.1.dylib"})
		end

		if home then
			table.insert(candidates, {path = home .. "/VulkanSDK/1.4.328.1/macOS/lib/libshaderc_shared.dylib"})
		end

		table.insert(candidates, {path = "/opt/homebrew/lib/libshaderc_shared.dylib"})
		table.insert(candidates, {path = "/usr/local/lib/libshaderc_shared.dylib"})
		table.insert(candidates, {name = "libshaderc_shared.dylib"})
	else
		if vulkan_sdk then
			table.insert(candidates, {path = vulkan_sdk .. "/lib/libshaderc_shared.so"})
			table.insert(candidates, {path = vulkan_sdk .. "/lib/libshaderc_shared.so.1"})
		end

		table.insert(candidates, {name = "libshaderc_shared.so"})
		table.insert(candidates, {name = "libshaderc_shared.so.1"})
	end

	return candidates
end

local function copy_into_directory(source)
	local target = locator.GetDirectory() .. bin_download.GetFileName(source)

	if #list_directory() > 0 then
		logf("[shaderc] %s already contains a library, not copying %s\n", locator.GetDirectory(), source)
		return
	end

	bin_download.WriteBinary(target, bin_download.ReadBinary(source))
	logf("[shaderc] found %s, copied to %s\n", source, target)
end

local function search_automatically()
	local last_error = "no candidate libraries"

	for _, candidate in ipairs(get_candidates()) do
		if candidate.name or fs.exists(candidate.path) then
			local ok, err = try_load(candidate.name or candidate.path)

			if ok then
				local source = candidate.path or get_loaded_path(candidate.name)

				if source then
					copy_into_directory(source)
				else
					logf("[shaderc] found %s but could not resolve its path to copy it\n", candidate.name)
				end

				return true
			end

			last_error = (candidate.name or candidate.path) .. ": " .. err
		end
	end

	return nil, last_error
end

do
	local function scan(directory, depth, skip, found)
		for _, name in ipairs(fs.get_files(directory) or {}) do
			local path = directory .. name

			if fs.is_directory(path) then
				if depth > 0 and not skip[name:lower()] then
					scan(path .. "/", depth - 1, skip, found)
				end
			elseif is_shared_library(name) and name:lower():find("shaderc", nil, true) then
				table.insert(found, path)
			end
		end
	end

	function locator.FindInSteam()
		local steam = import("goluwa/steam/steam.lua")
		local found = {}
		local install = steam.GetInstallPath()

		if install and fs.is_directory(install) then
			install = install:gsub("\\", "/")

			if install:sub(-1) ~= "/" then install = install .. "/" end

			scan(install, 5, {steamapps = true, shadercache = true, htmlcache = true}, found)
		end

		for _, library in ipairs(steam.GetLibraryFolders()) do
			scan(library .. "common/", 4, {shadercache = true, compatdata = true}, found)
		end

		return found
	end
end

local function copy_from_steam()
	local found = locator.FindInSteam()

	if #found == 0 then return nil, "no shaderc library found in the Steam installation" end

	if #found > 1 then
		logf("[shaderc] found %s libraries in Steam, using the first:\n", #found)

		for _, path in ipairs(found) do
			logf("\t%s\n", path)
		end
	end

	local target = locator.GetDirectory() .. bin_download.GetFileName(found[1])
	bin_download.WriteBinary(target, bin_download.ReadBinary(found[1]))
	logf("[shaderc] copied %s to %s\n", found[1], target)
	return try_load(target)
end

local function download()
	if not locator.asset then
		return nil, "no prebuilt shaderc is published for " .. platform
	end

	local path, err = bin_download.Download(manifest.release, locator.asset, locator.GetDirectory())

	if not path then return nil, err end

	return try_load(path)
end

local function try_directory()
	local files = list_directory()

	if #files > 1 then
		return nil,
		"multiple shared libraries in " .. locator.GetDirectory() .. ", keep only one:\n\t" .. table.concat(files, "\n\t")
	end

	if #files == 0 then
		return nil, "no shared library in " .. locator.GetDirectory()
	end

	return try_load(locator.GetDirectory() .. files[1])
end

function locator.Prompt(reason)
	if not bin_download.GetTerminal() then
		error(
			string.format(
				"shaderc was not found (%s)\n" .. "Put the shaderc shared library in %s\n" .. "or get it from %s",
				reason,
				locator.GetDirectory(),
				locator.download_url
			),
			0
		)
	end

	while true do
		logn("")
		logn("[shaderc] libshaderc is needed to compile shaders but could not be loaded:")
		logn("  " .. tostring(reason):gsub("\n", "\n  "))
		logn("")
		logn("  [1] copy it from your Steam installation")
		logn("  [2] download it from " .. locator.download_url)
		logn("  [3] install it manually into " .. locator.GetDirectory())
		logn("")
		logn("Press 1, 2 or 3 (Ctrl+C aborts)")
		local key = bin_download.ReadKey()
		local ok, err

		if key == "1" then
			ok, err = copy_from_steam()
		elseif key == "2" then
			logn("This downloads a prebuilt shaderc from this repository's releases and verifies its sha256.")
			logn("Download from " .. locator.download_url .. " ? [y/N]")

			if bin_download.ReadKey() == "y" then
				ok, err = download()
			else
				err = "download declined"
			end
		elseif key == "3" then
			logn("Copy the shared library (" .. shared_library_extension .. ") into")
			logn("  " .. locator.GetDirectory())
			logn("it can be downloaded from " .. locator.download_url)
			logn("then press Enter (b goes back)")

			while true do
				local key = bin_download.ReadKey()

				if key == "b" then
					err = "cancelled"

					break
				elseif key == "enter" then
					ok, err = try_directory()

					if ok then break end

					logn("[shaderc] " .. tostring(err))
					logn("fix it and press Enter again (b goes back)")
				end
			end
		end

		if ok then return end

		reason = err or reason
	end
end

function locator.Locate()
	fs.create_directory_recursive(locator.GetDirectory())

	if os.getenv("GOLUWA_FORCE_DOWNLOAD") == "1" then
		logn("[shaderc] GOLUWA_FORCE_DOWNLOAD is set, skipping local libraries and downloading shaderc")
		assert(download())

		return
	end

	local ok, directory_error = try_directory()

	if ok then return end

	local ok, search_error = search_automatically()

	if ok then return end

	locator.Prompt(directory_error .. "\n" .. search_error)
end

return locator
