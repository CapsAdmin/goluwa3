local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local bin_download = import("goluwa/bin_download.lua")
local locator = {}
local manifest = import("goluwa/bin_manifest.lua").kosmickrisp
local assets = manifest.assets[bin_download.platform]

function locator.GetDirectory()
	return vfs.GetStorageDirectory("root") .. "storage/bin/vulkan/"
end

local function try_load(paths)
	local errors = {}

	for _, path in ipairs(paths) do
		local ok, lib = pcall(ffi.load, path)

		if ok then return lib end

		table.insert(errors, lib)
	end

	return nil, table.concat(errors, "\n")
end

local function load_system_loader()
	local home = os.getenv("HOME")
	local vulkan_sdk = os.getenv("VULKAN_SDK")
	local paths = {
		"/opt/homebrew/lib/libvulkan.dylib",
		"/opt/homebrew/lib/libvulkan.1.dylib",
		"/usr/local/lib/libvulkan.dylib",
		"libvulkan.dylib",
		"libvulkan.1.dylib",
	}

	if vulkan_sdk then
		table.insert(paths, vulkan_sdk .. "/lib/libvulkan.dylib")
		table.insert(paths, vulkan_sdk .. "/lib/libvulkan.1.dylib")
	end

	if home and vulkan_sdk then
		table.insert(paths, home .. "/VulkanSDK/1.4.328.1/macOS/lib/libvulkan.1.dylib")
	end

	return try_load(paths)
end

local function load_bundled()
	local directory = locator.GetDirectory()
	local loader_path = directory .. assets.loader.file
	local driver_path = directory .. assets.driver.file

	if not fs.exists(loader_path) or not fs.exists(driver_path) then
		return nil, "the bundled vulkan loader and driver are not in " .. directory
	end

	local icd_path = directory .. "kosmickrisp_icd.json"
	bin_download.WriteBinary(
		icd_path,
		string.format(
			'{"file_format_version": "1.0.1", "ICD": {"library_path": "%s", "api_version": "1.4.0"}}\n',
			driver_path
		)
	)

	if not os.getenv("VK_DRIVER_FILES") and not os.getenv("VK_ICD_FILENAMES") then
		local process = import("goluwa/bindings/process.lua")
		process.setenv("VK_DRIVER_FILES", icd_path)
		process.setenv("VK_ICD_FILENAMES", icd_path)
	end

	local ok, lib = pcall(ffi.load, loader_path)

	if not ok then return nil, tostring(lib) end

	return lib
end

local function download_bundled()
	if not assets then
		error("no bundled vulkan driver is published for " .. bin_download.platform, 0)
	end

	local handle = io.popen("sw_vers -productVersion")
	local version = handle:read("*l")
	handle:close()

	if tonumber(version:match("^(%d+)")) < 26 then
		error("the bundled vulkan driver (KosmicKrisp) needs macOS 26 or later, this is " .. version, 0)
	end

	if not bin_download.GetTerminal() then
		error(
			string.format(
				"no vulkan loader found. Put the files from %s\n(%s and %s) in %s",
				manifest.release,
				assets.loader.file,
				assets.driver.file,
				locator.GetDirectory()
			),
			0
		)
	end

	logn("")
	logn("[vulkan] no vulkan loader was found on this system.")
	logn("  Download the Khronos Vulkan loader and the KosmicKrisp driver (Vulkan on Metal) from")
	logn("  " .. manifest.release .. " ? [y/N]")

	if bin_download.ReadKey() ~= "y" then error("vulkan download declined", 0) end

	for _, asset in pairs({assets.loader, assets.driver}) do
		assert(bin_download.Download(manifest.release, asset, locator.GetDirectory()))
	end
end

function locator.Locate()
	if jit.os == "Windows" then
		if not os.getenv("VK_ICD_FILENAMES") and not os.getenv("VK_DRIVER_FILES") then
			local file = io.open("vk_swiftshader_icd.json", "rb")

			if file then
				file:close()
				local process = import("goluwa/bindings/process.lua")
				process.setenv("VK_ICD_FILENAMES", "vk_swiftshader_icd.json")
				process.setenv("VK_DRIVER_FILES", "vk_swiftshader_icd.json")
			end
		end

		return assert(try_load({"vulkan-1.dll"}))
	elseif jit.os ~= "OSX" then
		return assert(try_load({"libvulkan.so", "libvulkan.so.1"}))
	end

	fs.create_directory_recursive(locator.GetDirectory())

	if os.getenv("GOLUWA_VULKAN_BUNDLED") ~= "1" then
		local lib = load_system_loader()

		if lib then return lib end
	end

	local lib, err = load_bundled()

	if lib then return lib end

	download_bundled()
	lib, err = load_bundled()

	return assert(lib, err)
end

return locator
