local startup = import("goluwa/startup.lua")
local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local shaderc = import("goluwa/bindings/shaderc.lua")
local fs = import("goluwa/filesystem/fs.lua")
local crypto = import("goluwa/crypto.lua")
local ShaderModule = objects.CreateTemplate("vulkan_shader_module")
local shader_module_cache = setmetatable({}, {__mode = "k"})
local VkShaderModuleBox = ffi.typeof("$[1]", vulkan.vk.VkShaderModule)

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
local CACHE_MAGIC = "GLWSPV01"
local CACHE_HEADER = ffi.typeof("struct { char magic[8]; uint32_t spirv_size; uint32_t glsl_size; }")
local CACHE_HEADER_PTR = ffi.typeof("const $ *", CACHE_HEADER)
local CACHE_HEADER_SIZE = ffi.sizeof(CACHE_HEADER)
local SPIRV_MAGIC = 0x07230203

local function ensure_disk_cache_dir()
	if shaders_disk_cache_dir_ready then return end

	fs.create_directory_recursive(shaders_disk_cache_dir)
	shaders_disk_cache_dir_ready = true
end

local function get_source_key(glsl)
	return shaderc.identity .. "\0" .. glsl
end

local function disk_cache_path(glsl, shader_type)
	local key = shader_type .. "|" .. get_source_key(glsl)
	return shaders_disk_cache_dir .. crypto.CRC32(key) .. "_" .. #key .. ".spv"
end

local function load_disk_cache(path, glsl)
	if not fs.is_file(path) then return nil, "not cached" end

	local data = fs.read_file(path)

	if not data or #data < CACHE_HEADER_SIZE then return nil, "file is truncated" end

	local header = ffi.cast(CACHE_HEADER_PTR, data)

	if ffi.string(header.magic, 8) ~= CACHE_MAGIC then
		return nil, "unknown format"
	end

	local spirv_size = header.spirv_size
	local glsl_size = header.glsl_size

	if #data ~= CACHE_HEADER_SIZE + spirv_size + glsl_size then
		return nil, "file is truncated"
	end

	if spirv_size < 20 or spirv_size % 4 ~= 0 then return nil, "invalid spir-v size" end

	local source_key = get_source_key(glsl)

	if glsl_size ~= #source_key or data:sub(CACHE_HEADER_SIZE + spirv_size + 1) ~= source_key then
		return nil, "made from other glsl or by another shaderc, a hash collision or a stale file"
	end

	local copy = ffi.new("uint8_t[?]", spirv_size)
	ffi.copy(copy, ffi.cast("const uint8_t *", data) + CACHE_HEADER_SIZE, spirv_size)

	if ffi.cast("const uint32_t *", copy)[0] ~= SPIRV_MAGIC then
		return nil, "invalid spir-v"
	end

	return copy, spirv_size
end

local legacy_removed = false

local function remove_legacy_files()
	if legacy_removed then return end

	legacy_removed = true
	local count = 0

	for _, name in ipairs(fs.get_files(shaders_disk_cache_dir) or {}) do
		if name:find("^%d+%.spv$") and os.remove(shaders_disk_cache_dir .. name) then
			count = count + 1
		end
	end

	if count > 0 then logf("[shader] removed %d cached shaders of the old format\n", count) end
end

-- written to a temporary file and renamed, so a reader (another process, a test worker) never
-- sees half a file
local function save_disk_cache(path, glsl, spirv_data, spirv_size)
	ensure_disk_cache_dir()
	remove_legacy_files()
	local header = CACHE_HEADER()
	ffi.copy(header.magic, CACHE_MAGIC, 8)
	header.spirv_size = spirv_size
	header.glsl_size = #get_source_key(glsl)
	local temp_path = path .. "." .. tostring(spirv_data):gsub("%W", "") .. ".tmp"
	local ok = fs.write_file(temp_path, ffi.string(header, CACHE_HEADER_SIZE) .. ffi.string(spirv_data, spirv_size) .. get_source_key(glsl))

	if ok and os.rename(temp_path, path) then return end

	logf("[shader] could not write %s\n", path)
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

	local path = disk_cache_path(glsl, type)
	local spirv_data, spirv_size = load_disk_cache(path, glsl)

	if not spirv_data then
		local reason = spirv_size
		local start = os.clock()
		local started = startup.Start()
		spirv_data, spirv_size = shaderc.compile(glsl, type)
		startup.Add("shader: shaderc compile", started)
		logf(
			"[shader] compiled %s shader %s (%d bytes of glsl) in %.0f ms%s\n",
			type,
			path:match("([^/]+)%.spv$"),
			#glsl,
			(os.clock() - start) * 1000,
			reason == "not cached" and "" or " because the cache is off: " .. reason
		)
		save_disk_cache(path, glsl, spirv_data, spirv_size)
	end

	local ptr = VkShaderModuleBox()
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
		spirv = spirv_data,
		spirv_size = spirv_size,
	}
	type_cache[glsl] = record
	return record
end

function ShaderModule.New(device, glsl, type)
	local record = get_or_create_cached_module(device, glsl, type)
	record.ref_count = record.ref_count + 1
	return ShaderModule:CreateObject{ptr = record.ptr, device = device, cache_record = record}
end

function ShaderModule.FromSPIRV(device, spirv_data, spirv_size)
	local ptr = VkShaderModuleBox()
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
		"failed to create shader module from SPIR-V"
	)
	return ShaderModule:CreateObject{ptr = ptr, device = device}
end

function ShaderModule:Data()
	local record = self.cache_record

	if not record then return nil, 0 end

	return record.spirv, record.spirv_size
end

function ShaderModule:OnRemove()
	local record = self.cache_record

	if not record then
		if self.device:IsValid() then
			local device = self.device
			local device_ptr = device.ptr[0]
			local shader_module_ptr = self.ptr[0]
			self.ptr[0] = nil

			device:DeferRelease(function()
				vulkan.lib.vkDestroyShaderModule(device_ptr, shader_module_ptr, nil)
			end)
		end

		return
	end

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
