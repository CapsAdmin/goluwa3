local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local system = import("goluwa/system.lua")
local shaderc = import("goluwa/bindings/shaderc.lua")
local sleep = import("goluwa/bindings/threads.lua").sleep
local locator = {}
local SMOKE_SOURCE = "#version 450\nlayout(local_size_x = 1) in;\nvoid main() {}\n"
local SPIRV_MAGIC = 0x07230203
local shared_library_extension = jit.os == "Windows" and ".dll" or jit.os == "OSX" and ".dylib" or ".so"
local shared_library_pattern = jit.os == "Windows" and
	"%.dll$" or
	jit.os == "OSX" and
	"%.dylib$" or
	"%.so[%.%d]*$"
local platform = (jit.os == "Windows" and "windows" or jit.os == "OSX" and "macos" or "linux") .. "-" .. jit.arch:lower()
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

local function get_file_name(path)
	return path:match("([^/\\]+)$")
end

local function read_binary(path)
	local file = assert(io.open(path, "rb"))
	local data = file:read("*a")
	file:close()
	return data
end

local function write_binary(path, data)
	local file = assert(io.open(path, "wb"))
	file:write(data)
	file:close()
end

local function list_directory()
	local found = {}

	for _, name in ipairs(fs.get_files(locator.GetDirectory()) or {}) do
		if is_shared_library(name) then table.insert(found, name) end
	end

	return found
end

-- loads the library at `path` (or by name), hands it to the binding and compiles a trivial shader
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

	return true
end

-- the path of the file the loader resolved a bare library name to
local get_loaded_path

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
	local target = locator.GetDirectory() .. get_file_name(source)

	if #list_directory() > 0 then
		logf("[shaderc] %s already contains a library, not copying %s\n", locator.GetDirectory(), source)
		return
	end

	write_binary(target, read_binary(source))
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

	local target = locator.GetDirectory() .. get_file_name(found[1])
	write_binary(target, read_binary(found[1]))
	logf("[shaderc] copied %s to %s\n", found[1], target)
	return try_load(target)
end

local function fetch(url, label)
	local http = import("goluwa/sockets/http.lua")
	import("goluwa/sockets/http/download.lua")
	local socket_pool = import("goluwa/sockets/socket_pool.lua")
	local body, err
	local next_percent = 0
	http.DownloadSocket(
		url,
		function(data)
			body = data
		end,
		function(reason)
			err = reason
		end,
		function(chunk, written, total)
			if total ~= math.huge and total and written * 100 / total >= next_percent then
				logf("[shaderc] downloading %s: %d%%\n", label, next_percent)
				next_percent = next_percent + 10
			end
		end
	)
	local start = system.GetTime()

	while not body and not err do
		socket_pool.Update()
		sleep(5)

		if system.GetTime() - start > 600 then err = "timed out" end
	end

	if err then return nil, tostring(err) end

	return body
end

local function download()
	if not locator.asset then
		return nil, "no prebuilt shaderc is published for " .. platform
	end

	if not locator.asset.sha256 then
		return nil,
		"bin_manifest.lua has no sha256 for " .. locator.asset.file .. " yet, run the build-binaries workflow and paste its hashes"
	end

	local data, err = fetch(locator.download_url, locator.asset.file)

	if not data then return nil, "could not fetch " .. locator.download_url .. ": " .. err end

	local hash = import("goluwa/crypto.lua").SHA256(data)

	if hash ~= locator.asset.sha256 then
		return nil, "sha256 mismatch for " .. locator.asset.file .. ": expected " .. locator.asset.sha256 .. " got " .. hash
	end

	local target = locator.GetDirectory() .. get_file_name(locator.asset.file)
	write_binary(target, data)
	logf("[shaderc] downloaded %s\n", target)
	return try_load(target)
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

local function get_terminal()
	return import("goluwa/cli/repl.lua").GetTerminal()
end

local function read_key()
	local term = get_terminal()

	while true do
		local event = term:ReadEvent()

		if event and not event.mouse and event.key then
			if event.modifiers and event.modifiers.ctrl and event.key == "c" then
				error("aborted while locating shaderc", 0)
			end

			return event.key
		end

		sleep(10)
	end
end

function locator.Prompt(reason)
	if not get_terminal() then
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
		local key = read_key()
		local ok, err

		if key == "1" then
			ok, err = copy_from_steam()
		elseif key == "2" then
			logn("This downloads a prebuilt shaderc from this repository's releases and verifies its sha256.")
			logn("Download from " .. locator.download_url .. " ? [y/N]")

			if read_key() == "y" then
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
				local key = read_key()

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
	local ok, directory_error = try_directory()

	if ok then return end

	local ok, search_error = search_automatically()

	if ok then return end

	locator.Prompt(directory_error .. "\n" .. search_error)
end

return locator
