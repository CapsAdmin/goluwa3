local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local glslang = import("goluwa/bindings/glslang.lua")
local bin_download = import("goluwa/bin_download.lua")
local android = import("goluwa/bindings/android.lua")
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
local manifest = import("goluwa/bin_manifest.lua").glslang
locator.asset = manifest.assets[platform]
locator.download_url = locator.asset and
	manifest.release .. "{" .. locator.asset.library.file .. "," .. locator.asset.limits.file .. "}" or
	"(no prebuilt binary is published for " .. platform .. ")"

function locator.GetDirectory()
	return vfs.GetStorageDirectory("root") .. "storage/bin/libglslang/"
end

local function try_load(library_path, limits_path)
	local ok, lib = pcall(ffi.load, library_path)

	if not ok then return nil, tostring(lib) end

	local ok, limits = pcall(ffi.load, limits_path)

	if not ok then return nil, tostring(limits) end

	local ok, err = pcall(glslang.Initialize, lib, limits)

	if not ok then return nil, "could not initialize glslang: " .. tostring(err) end

	local ok, data, size = pcall(glslang.compile, SMOKE_SOURCE, "compute")

	if not ok then return nil, "smoke test failed to compile: " .. tostring(data) end

	if size < 20 or ffi.cast("const uint32_t *", data)[0] ~= SPIRV_MAGIC then
		return nil, "smoke test produced invalid SPIR-V"
	end

	return true
end

local function try_directory()
	local library, limits

	for _, name in ipairs(fs.get_files(locator.GetDirectory()) or {}) do
		if name:find(shared_library_pattern) then
			if name:find("resource-limits", nil, true) then
				limits = name
			elseif name:find("glslang", nil, true) then
				library = name
			end
		end
	end

	if not library or not limits then
		return nil,
		"glslang and glslang-default-resource-limits shared libraries are not both in " .. locator.GetDirectory()
	end

	return try_load(locator.GetDirectory() .. library, locator.GetDirectory() .. limits)
end

local function search_automatically()
	local prefix = jit.os == "Windows" and "" or "lib"
	local suffixes = jit.os == "Windows" and
		{".dll"} or
		jit.os == "OSX" and
		{".dylib"} or
		{".so", ".so.16"}
	local last_error = "no candidate libraries"

	for _, suffix in ipairs(suffixes) do
		local ok, err = try_load(
			prefix .. "glslang" .. suffix,
			prefix .. "glslang-default-resource-limits" .. suffix
		)

		if ok then return true end

		last_error = err
	end

	return nil, last_error
end

local function download()
	if not locator.asset then
		return nil, "no prebuilt glslang is published for " .. platform
	end

	for _, asset in pairs(locator.asset) do
		local path, err = bin_download.Download(manifest.release, asset, locator.GetDirectory())

		if not path then return nil, err end
	end

	return try_directory()
end

function locator.Prompt(reason)
	if not bin_download.GetTerminal() then
		error(
			string.format(
				"glslang was not found (%s)\n" .. "Put the glslang and glslang-default-resource-limits shared libraries in %s\n" .. "or get them from %s",
				reason,
				locator.GetDirectory(),
				locator.download_url
			),
			0
		)
	end

	while true do
		logn("")
		logn("[glslang] libglslang is needed to compile shaders but could not be loaded:")
		logn("  " .. tostring(reason):gsub("\n", "\n  "))
		logn("")
		logn("  [1] download it from " .. locator.download_url)
		logn("  [2] install it manually into " .. locator.GetDirectory())
		logn("")
		logn("Press 1 or 2 (Ctrl+C aborts)")
		local key = bin_download.ReadKey()
		local ok, err

		if key == "1" then
			logn(
				"This downloads a prebuilt glslang from this repository's releases and verifies its sha256."
			)
			logn("Download from " .. locator.download_url .. " ? [y/N]")

			if bin_download.ReadKey() == "y" then
				ok, err = download()
			else
				err = "download declined"
			end
		elseif key == "2" then
			logn(
				"Copy the glslang and glslang-default-resource-limits shared libraries (" .. shared_library_extension .. ") into"
			)
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

					logn("[glslang] " .. tostring(err))
					logn("fix it and press Enter again (b goes back)")
				end
			end
		end

		if ok then return end

		reason = err or reason
	end
end

function locator.Locate()
	if android.active then
		assert(try_load("libglslang.so", "libglslang-default-resource-limits.so"))
		return
	end

	fs.create_directory_recursive(locator.GetDirectory())

	if os.getenv("GOLUWA_FORCE_DOWNLOAD") == "1" then
		logn(
			"[glslang] GOLUWA_FORCE_DOWNLOAD is set, skipping local libraries and downloading glslang"
		)
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
