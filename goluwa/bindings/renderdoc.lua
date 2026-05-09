local ffi = require("ffi")
local process = import("goluwa/bindings/process.lua")
local RENDERDOC_CaptureOption = ffi.typeof([[enum {
    eRENDERDOC_Option_AllowVSync = 0,
    eRENDERDOC_Option_AllowFullscreen = 1,
    eRENDERDOC_Option_APIValidation = 2,
    eRENDERDOC_Option_CaptureCallstacks = 3,
    eRENDERDOC_Option_CaptureCallstacksOnlyDraws = 4,
    eRENDERDOC_Option_DelayForDebugger = 5,
    eRENDERDOC_Option_VerifyBufferAccess = 6,
    eRENDERDOC_Option_HookIntoChildren = 7,
    eRENDERDOC_Option_RefAllResources = 8,
    eRENDERDOC_Option_SaveAllInitials = 9,
    eRENDERDOC_Option_CaptureAllCmdLists = 10,
    eRENDERDOC_Option_DebugOutputMute = 11
}]])
local RENDERDOC_API_1_6_0 = ffi.typeof(
	[[struct {
    int (*GetAPIVersion)(int* major, int* minor, int* patch);
    int (*SetCaptureOptionU32)($ opt, uint32_t val);
    int (*SetCaptureOptionF32)($ opt, float val);
    uint32_t (*GetCaptureOptionU32)($ opt);
    float (*GetCaptureOptionF32)($ opt);
    void (*SetFocusToggleKeys)(int* keys, int num);
    void (*SetCaptureKeys)(int* keys, int num);
    uint32_t (*GetOverlayBits)();
    void (*MaskOverlayBits)(uint32_t And, uint32_t Or);
    void (*Shutdown)();
    void (*UnloadCrashHandler)();
	void (*SetCaptureFilePathTemplate)(const char* pathtemplate);
	const char* (*GetCaptureFilePathTemplate)();
	uint32_t (*GetNumCaptures)();
	uint32_t (*GetCapture)(uint32_t idx, char* filename, uint32_t* pathlength, uint64_t* timestamp);
	void (*TriggerCapture)();
    uint32_t (*IsTargetControlConnected)();
    uint32_t (*LaunchReplayUI)(uint32_t connectTargetControl, const char* cmdline);
    void (*SetActiveWindow)(void* device, void* window);
    void (*StartFrameCapture)(void* device, void* window);
    uint32_t (*IsFrameCapturing)();
    uint32_t (*EndFrameCapture)(void* device, void* window);
    void (*TriggerMultiFrameCapture)(uint32_t numFrames);
    void (*SetCaptureFileComments)(const char* filePath, const char* comments);
    uint32_t (*DiscardFrameCapture)(void* device, void* window);
    uint32_t (*ShowReplayUI)();
    void (*SetCaptureTitle)(const char* title);
}]],
	RENDERDOC_CaptureOption,
	RENDERDOC_CaptureOption,
	RENDERDOC_CaptureOption,
	RENDERDOC_CaptureOption
)
local RENDERDOC_Version = ffi.typeof([[enum {
    Version_1_0_0 = 10000,
    Version_1_0_1 = 10001,
    Version_1_0_2 = 10002,
    Version_1_1_0 = 10100,
    Version_1_1_1 = 10101,
    Version_1_1_2 = 10102,
    Version_1_2_0 = 10200,
    Version_1_3_0 = 10300,
    Version_1_4_0 = 10400,
    Version_1_4_1 = 10401,
    Version_1_4_2 = 10402,
    Version_1_5_0 = 10500,
    Version_1_6_0 = 10600
}]])
ffi.cdef(
	[[
    int RENDERDOC_GetAPI($ version, void** outAPIPointers);
]],
	RENDERDOC_Version
)

if ffi.os ~= "Windows" then
	ffi.cdef[[
		void *dlopen(const char *filename, int flags);
		void *dlsym(void *handle, const char *symbol);
		char *dlerror(void);
	]]
end

local renderdoc = {}
local api = nil
local get_api
local capture_active = false

local function launch_ui(path, args)
	local renderdoc_lib = os.getenv("RENDERDOC_LIB")

	if not renderdoc_lib then
		return error("RENDERDOC_LIB environment variable not set")
	end

	local store_path = renderdoc_lib:match("(/nix/store/[^/]+)")

	if not store_path then
		error("Failed to determine Nix store path from RENDERDOC_LIB")
	end

	logf(
		"[renderdoc] launching ui %s\n",
		#args > 0 and table.concat(args, " ") or "<no-args>"
	)
	local process = import("goluwa/bindings/process.lua")
	return assert(process.spawn{
		command = store_path .. "/bin/qrenderdoc",
		args = args,
	})
end

local function find_renderdoc_get_api()
	if ffi.os == "Windows" then
		local renderdoc_lib_path = os.getenv("RENDERDOC_LIB")

		if not renderdoc_lib_path then
			error(
				"RenderDoc library path not set and passive module lookup is not implemented on Windows"
			)
		end

		local loaded = assert(ffi.load(renderdoc_lib_path))
		return loaded.RENDERDOC_GetAPI
	end

	local RTLD_NOW = 0x2
	local RTLD_NOLOAD = 0x4
	local module = ffi.C.dlopen("librenderdoc.so", bit.bor(RTLD_NOW, RTLD_NOLOAD))

	if module == nil then
		error(
			"RenderDoc module is not already loaded; relaunch under renderdoccmd capture or another RenderDoc launcher"
		)
	end

	local symbol = ffi.C.dlsym(module, "RENDERDOC_GetAPI")

	if symbol == nil then
		error("RENDERDOC_GetAPI symbol not found in already-loaded RenderDoc module")
	end

	local GetAPIType = ffi.typeof("int (*)(int, void**)")
	return ffi.cast(GetAPIType, symbol)
end

-- Initialize RenderDoc
local api_ptr = nil
local API_1_6_0 = ffi.typeof("$*", RENDERDOC_API_1_6_0)

function renderdoc.init()
	local renderdoc_lib = os.getenv("RENDERDOC_LIB")

	if renderdoc_lib then
		local store_path = renderdoc_lib:match("(/nix/store/[^/]+)")

		if store_path then
			local current_path = os.getenv("PATH") or ""
			local new_path = store_path .. "/bin:" .. current_path
			process.setenv("PATH", new_path)
		end
	end

	do
		get_api = find_renderdoc_get_api()
		api_ptr = ffi.new("void*[1]")
		local result = get_api(RENDERDOC_Version("Version_1_6_0"), api_ptr)

		if result ~= 1 or api_ptr[0] == nil then error("Failed to get RenderDoc API") end

		api = ffi.cast(API_1_6_0, api_ptr[0])
		capture_active = false

		if api.GetAPIVersion == nil then
			error("Failed to cast RenderDoc API to version 1.6.0")
		end
	end
end

function renderdoc.IsInitialized()
	return api ~= nil
end

function renderdoc.DisableDefaultKeys()
	if not api then error("RenderDoc is not initialized", 2) end

	api.SetFocusToggleKeys(nil, 0)
	api.SetCaptureKeys(nil, 0)
end

local function normalize_device_pointer(device)
	if device == nil then return nil end

	if type(device) == "table" and device.ptr then return device.ptr[0] end

	return device
end

local function normalize_window_handle(window)
	if window == nil then return nil end

	if type(window) == "table" and window.GetSurfaceHandle then
		local surface_handle = assert(window:GetSurfaceHandle())
		return surface_handle
	end

	return window
end

function renderdoc.SetActiveWindow(device, window)
	if not api then error("RenderDoc is not initialized", 2) end

	api.SetActiveWindow(normalize_device_pointer(device), normalize_window_handle(window))
end

function renderdoc.GetVersion()
	local major, minor, patch = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
	api.GetAPIVersion(major, minor, patch)
	return major[0], minor[0], patch[0]
end

function renderdoc.IsCapturing()
	return capture_active
end

function renderdoc.CaptureFrame(device, window)
	capture_active = false

	if device ~= nil or window ~= nil then
		renderdoc.SetActiveWindow(device, window)
	end

	api.TriggerMultiFrameCapture(1)
end

function renderdoc.ToggleCapture(device, window)
	if capture_active then
		renderdoc.StopCapture(device, window)
		return false
	end

	renderdoc.StartCapture(device, window)
	return true
end

function renderdoc.StartCapture(device, window)
	if device ~= nil or window ~= nil then
		renderdoc.SetActiveWindow(device, window)
	end

	api.StartFrameCapture(nil, nil)
	capture_active = true
	return true
end

function renderdoc.StopCapture(device, window)
	local res = api.EndFrameCapture(nil, nil)

	if res ~= 1 then
		capture_active = false
		return false
	end

	capture_active = false
	return true
end

function renderdoc.GetCaptures()
	local out = {}
	local num_captures = api.GetNumCaptures()

	for i = 0, num_captures - 1 do
		local pathlength = ffi.new("uint32_t[1]", 0)
		local timestamp = ffi.new("uint64_t[1]", 0)
		-- Get capture path length
		api.GetCapture(i, nil, pathlength, timestamp)

		if pathlength[0] > 0 then
			local filename = ffi.new("char[?]", pathlength[0])
			api.GetCapture(i, filename, pathlength, timestamp)
			table.insert(
				out,
				{
					filename = ffi.string(filename),
					timestamp = tonumber(timestamp[0]),
				}
			)
		end
	end

	return out
end

function renderdoc.GetLastCapture()
	local captures = renderdoc.GetCaptures()
	return captures[#captures]
end

function renderdoc.SetCaptureFilePathTemplate(path)
	if not api then error("RenderDoc is not initialized", 2) end

	api.SetCaptureFilePathTemplate(assert(path))
end

function renderdoc.OpenUI(...)
	local args = {...}
	launch_ui(nil, args)
end

return renderdoc
