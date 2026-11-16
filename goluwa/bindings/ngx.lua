local ffi = require("ffi")
local ngx = {}
ffi.cdef[[
	typedef struct NVSDK_NGX_Handle NVSDK_NGX_Handle;
	typedef struct NVSDK_NGX_Parameter {
		void **vtbl;
	} NVSDK_NGX_Parameter;
	typedef struct NVSDK_NGX_FeatureCommonInfo {
		const int32_t *const *Path;
		uint32_t Length;
		void *InternalData;
		void *LoggingCallback;
		uint32_t MinimumLoggingLevel;
		bool DisableOtherLoggingSinks;
	} NVSDK_NGX_FeatureCommonInfo;
	typedef struct NVSDK_NGX_Resource_VK {
		void *ImageView;
		void *Image;
		uint32_t aspect_mask;
		uint32_t base_mip_level;
		uint32_t level_count;
		uint32_t base_array_layer;
		uint32_t layer_count;
		int32_t Format;
		uint32_t Width;
		uint32_t Height;
		uint32_t Type;
		bool ReadWrite;
	} NVSDK_NGX_Resource_VK;
	uint32_t NVSDK_NGX_VULKAN_Init_ProjectID_Ext(const char *project_id, uint32_t engine_type, const char *engine_version, const int32_t *data_path, void *instance, void *physical_device, void *device, void *gipa, void *gdpa, uint32_t version, const NVSDK_NGX_FeatureCommonInfo *info);
	uint32_t NVSDK_NGX_VULKAN_Shutdown1(void *device);
	uint32_t NVSDK_NGX_VULKAN_GetCapabilityParameters(NVSDK_NGX_Parameter **out);
	uint32_t NVSDK_NGX_VULKAN_AllocateParameters(NVSDK_NGX_Parameter **out);
	uint32_t NVSDK_NGX_VULKAN_DestroyParameters(NVSDK_NGX_Parameter *params);
	uint32_t NVSDK_NGX_VULKAN_CreateFeature1(void *device, void *cmd, uint32_t feature, NVSDK_NGX_Parameter *params, NVSDK_NGX_Handle **out);
	uint32_t NVSDK_NGX_VULKAN_ReleaseFeature(NVSDK_NGX_Handle *handle);
	uint32_t NVSDK_NGX_VULKAN_EvaluateFeature(void *cmd, const NVSDK_NGX_Handle *handle, const NVSDK_NGX_Parameter *params, void *callback);
]]
ngx.API_VERSION = 0x15
ngx.Success = 0x1
ngx.Feature = {SuperSampling = 1, RayReconstruction = 13}
ngx.PerfQuality = {
	MaxPerf = 0,
	Balanced = 1,
	MaxQuality = 2,
	UltraPerformance = 3,
	UltraQuality = 4,
	DLAA = 5,
}
ngx.FeatureFlags = {
	IsHDR = 1,
	MVLowRes = 2,
	MVJittered = 4,
	DepthInverted = 8,
	AutoExposure = 64,
}
ngx.RESOURCE_IMAGE_VIEW = 0
ngx.ASPECT_COLOR = 1
ngx.ASPECT_DEPTH = 2
local DRIVER_DIRECTORIES = {
	"",
	"/run/opengl-driver/lib/",
	"/usr/lib/x86_64-linux-gnu/",
	"/usr/lib64/",
	"/usr/lib/",
}

local function driver_library_paths(name)
	local paths = {}

	for i, directory in ipairs(DRIVER_DIRECTORIES) do
		paths[i] = directory .. name
	end

	return paths
end

local CORE_LIBRARY_PATHS = driver_library_paths("libnvidia-ngx.so.1")
local NVML_LIBRARY_PATHS = driver_library_paths("libnvidia-ml.so.1")
local keep_alive_libraries

local function load_first(paths, global)
	local errors = {}

	for _, path in ipairs(paths) do
		local ok, result = pcall(ffi.load, path, global)

		if ok then return result end

		errors[#errors + 1] = result
	end

	return nil, table.concat(errors, "; ")
end

local ParameterPtr = ffi.typeof("NVSDK_NGX_Parameter *[1]")
local HandlePtr = ffi.typeof("NVSDK_NGX_Handle *[1]")
local ResourceType = ffi.typeof("NVSDK_NGX_Resource_VK")
local vtable_methods = {
	SetF = {1, "void (*)(void *, const char *, float)"},
	SetUI = {3, "void (*)(void *, const char *, uint32_t)"},
	SetI = {4, "void (*)(void *, const char *, int32_t)"},
	SetVoidPointer = {7, "void (*)(void *, const char *, void *)"},
	GetI = {12, "int32_t (*)(void *, const char *, int32_t *)"},
}

for name, info in pairs(vtable_methods) do
	local slot = info[1]
	local method_type = ffi.typeof(info[2])
	ngx[name] = function(params, key, value)
		return ffi.cast(method_type, params.vtbl[slot])(params, key, value)
	end
end

function ngx.ToWideString(str)
	local out = ffi.new("int32_t[?]", #str + 1)

	for i = 1, #str do
		out[i - 1] = str:byte(i)
	end

	return out
end

function ngx.CheckResult(result, what)
	if result ~= ngx.Success then
		error(string.format("%s failed: 0x%X", what, tonumber(result)), 2)
	end
end

function ngx.NewResource()
	local resource = ResourceType()
	resource.Type = 0
	resource.level_count = 1
	resource.layer_count = 1
	return resource
end

do
	local keep_alive

	function ngx.Initialize(config)
		local lib, err = load_first(CORE_LIBRARY_PATHS, false)

		if not lib then return nil, err end

		local nvml, nvml_err = load_first(NVML_LIBRARY_PATHS, true)

		if not nvml then
			return nil, "NGX needs NVML and crashes without it: " .. nvml_err
		end

		keep_alive_libraries = {nvml}
		local data_path = ngx.ToWideString(config.data_directory)
		local feature_path = ngx.ToWideString(config.feature_directory)
		local feature_paths = ffi.new("const int32_t*[1]", feature_path)
		local info = ffi.new("NVSDK_NGX_FeatureCommonInfo")
		info.Path = feature_paths
		info.Length = 1
		info.MinimumLoggingLevel = config.logging_level or 0
		keep_alive = {data_path, feature_path, feature_paths, info}
		local result = lib.NVSDK_NGX_VULKAN_Init_ProjectID_Ext(
			config.project_id,
			0,
			config.engine_version,
			data_path,
			config.instance,
			config.physical_device,
			config.device,
			config.get_instance_proc_addr,
			config.get_device_proc_addr,
			ngx.API_VERSION,
			info
		)

		if result ~= ngx.Success then
			return nil,
			string.format("NVSDK_NGX_VULKAN_Init_ProjectID_Ext failed: 0x%X", tonumber(result))
		end

		ngx.lib = lib
		return true
	end
end

function ngx.IsFeatureAvailable(feature)
	local params = ParameterPtr()
	ngx.CheckResult(ngx.lib.NVSDK_NGX_VULKAN_GetCapabilityParameters(params), "GetCapabilityParameters")
	local key = feature == ngx.Feature.RayReconstruction and
		"SuperSamplingDenoising" or
		"SuperSampling"
	local available = ffi.new("int32_t[1]")
	local init_result = ffi.new("int32_t[1]")
	ngx.GetI(params[0], key .. ".Available", available)
	ngx.GetI(params[0], key .. ".FeatureInitResult", init_result)
	return available[0] == 1 and init_result[0] == 1
end

function ngx.AllocateParameters()
	local params = ParameterPtr()
	ngx.CheckResult(ngx.lib.NVSDK_NGX_VULKAN_AllocateParameters(params), "AllocateParameters")
	return params[0]
end

function ngx.CreateFeature(device, cmd, feature, params)
	local handle = HandlePtr()
	ngx.CheckResult(
		ngx.lib.NVSDK_NGX_VULKAN_CreateFeature1(device, cmd, feature, params, handle),
		"CreateFeature"
	)
	return handle[0]
end

function ngx.ReleaseFeature(handle, params)
	ngx.CheckResult(ngx.lib.NVSDK_NGX_VULKAN_ReleaseFeature(handle), "ReleaseFeature")
	ngx.CheckResult(ngx.lib.NVSDK_NGX_VULKAN_DestroyParameters(params), "DestroyParameters")
end

function ngx.EvaluateFeature(cmd, handle, params)
	ngx.CheckResult(ngx.lib.NVSDK_NGX_VULKAN_EvaluateFeature(cmd, handle, params, nil), "EvaluateFeature")
end

return ngx
