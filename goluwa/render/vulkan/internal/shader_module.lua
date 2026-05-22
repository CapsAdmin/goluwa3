local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local shaderc = import("goluwa/bindings/shaderc.lua")
local fs = import("goluwa/fs.lua")
local crypto = import("goluwa/crypto.lua")
local ShaderModule = prototype.CreateTemplate("vulkan_shader_module")
local shader_module_cache = setmetatable({}, {__mode = "k"})

local function get_device_cache(device)
	local cache = shader_module_cache[device]

	if not cache then
		cache = {}
		shader_module_cache[device] = cache
	end

	return cache
end

local shaders_disk_cache_dir = "./storage/cache/shaders/"
local shaders_disk_cache_dir_ready = false

local function ensure_disk_cache_dir()
	if shaders_disk_cache_dir_ready then return end

	fs.create_directory_recursive(shaders_disk_cache_dir)
	shaders_disk_cache_dir_ready = true
end

local function disk_cache_path(glsl, shader_type)
	return shaders_disk_cache_dir .. crypto.CRC32(shader_type .. "|" .. glsl) .. ".spv"
end

local function load_disk_cache(glsl, shader_type)
	local path = disk_cache_path(glsl, shader_type)

	if not fs.is_file(path) then return nil end

	local data = fs.read_file(path)

	if not data or data == "" then return nil end

	local copy = ffi.new("uint8_t[?]", #data)
	ffi.copy(copy, data, #data)
	return copy, #data
end

local function save_disk_cache(glsl, shader_type, spirv_data, spirv_size)
	ensure_disk_cache_dir()
	fs.write_file(disk_cache_path(glsl, shader_type), ffi.string(spirv_data, spirv_size))
end

local function get_or_create_cached_module(device, glsl, type)
	local device_cache = get_device_cache(device)
	local type_cache = device_cache[type]

	if not type_cache then
		type_cache = {}
		device_cache[type] = type_cache
	end

	local record = type_cache[glsl]

	if record then return record end

	local spirv_data, spirv_size = load_disk_cache(glsl, type)

	if not spirv_data then
		spirv_data, spirv_size = shaderc.compile(glsl, type)
		save_disk_cache(glsl, type, spirv_data, spirv_size)
	end

	local ptr = vulkan.T.Box(vulkan.vk.VkShaderModule)()
	vulkan.assert(
		vulkan.lib.vkCreateShaderModule(
			device.ptr[0],
			vulkan.vk.s.ShaderModuleCreateInfo{
				codeSize = spirv_size,
				pCode = ffi.cast("const uint32_t*", spirv_data),
				flags = 0,
			},
			nil,
			ptr
		),
		"failed to create shader module"
	)
	record = {
		ptr = ptr,
		device = device,
		type = type,
		glsl = glsl,
		ref_count = 0,
	}
	type_cache[glsl] = record
	return record
end

function ShaderModule.New(device, glsl, type)
	local record = get_or_create_cached_module(device, glsl, type)
	record.ref_count = record.ref_count + 1
	return ShaderModule:CreateObject{ptr = record.ptr, device = device, cache_record = record}
end

function ShaderModule:OnRemove()
	local record = self.cache_record

	if not record then return end

	self.cache_record = nil
	record.ref_count = math.max((record.ref_count or 1) - 1, 0)

	if record.ref_count > 0 then return end

	local device_cache = shader_module_cache[record.device]
	local type_cache = device_cache and device_cache[record.type]

	if type_cache and type_cache[record.glsl] == record then
		type_cache[record.glsl] = nil

		if not next(type_cache) then device_cache[record.type] = nil end

		if not next(device_cache) then shader_module_cache[record.device] = nil end
	end

	if record.device:IsValid() then
		local device = record.device
		local device_ptr = device.ptr[0]
		local shader_module_ptr = record.ptr[0]
		record.ptr[0] = nil

		device:DeferRelease(function()
			vulkan.lib.vkDestroyShaderModule(device_ptr, shader_module_ptr, nil)
		end)
	end
end

return ShaderModule:Register()
