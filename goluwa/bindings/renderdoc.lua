local ffi = require("ffi")
local process = require("bindings.process")
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
    void (*SetLogFile)(const char* logfile);
    const char* (*GetLogFile)();
    uint32_t (*IsTargetControlConnected)();
    uint32_t (*LaunchReplayUI)(uint32_t connectTargetControl, const char* cmdline);
    void (*SetActiveWindow)(void* device, void* window);
    void (*StartFrameCapture)(void* device, void* window);
    uint32_t (*IsFrameCapturing)();
    uint32_t (*EndFrameCapture)(void* device, void* window);
    void (*TriggerCapture)();
    void (*TriggerMultiFrameCapture)(uint32_t numFrames);
    uint32_t (*IsRemoteAccessConnected)();
    void (*SetCaptureFilePathTemplate)(const char* pathtemplate);
    const char* (*GetCaptureFilePathTemplate)();
    uint32_t (*GetNumCaptures)();
    uint32_t (*GetCapture)(uint32_t idx, char* filename, uint32_t* pathlength, uint64_t* timestamp);
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
local renderdoc = {}
local api = nil
local lib

local function launch_ui(path, args)
	local renderdoc_lib = os.getenv("RENDERDOC_LIB")

	if not renderdoc_lib then
		return error("RENDERDOC_LIB environment variable not set")
	end

	local store_path = renderdoc_lib:match("(/nix/store/[^/]+)")

	if not store_path then
		error("Failed to determine Nix store path from RENDERDOC_LIB")
	end

	print(table.concat(args, " "))
	local process = require("bindings.process")
	return assert(process.spawn({
		command = store_path .. "/bin/qrenderdoc",
		args = args,
	}))
end

local function find_renderdoc_lib()
	local renderdoc_lib_path = os.getenv("RENDERDOC_LIB")

	if renderdoc_lib_path then return ffi.load(renderdoc_lib_path) end

	local possible_paths = {
		"librenderdoc.so", -- Try system search path first (via LD_LIBRARY_PATH)
		"/run/current-system/sw/lib/librenderdoc.so",
		os.getenv("HOME") .. "/.nix-profile/lib/librenderdoc.so",
	}
	local errors = {}

	for _, path in ipairs(possible_paths) do
		local ok, handle = pcall(ffi.load, path)

		if ok then return handle end

		table.insert(errors, "Failed to load " .. path .. ": " .. tostring(handle))
	end

	error(
		"RenderDoc library not found in standard locations:\n" .. table.concat(errors, "\n")
	)
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
		lib = find_renderdoc_lib()
		api_ptr = ffi.new("void*[1]")
		local result = lib.RENDERDOC_GetAPI(RENDERDOC_Version("Version_1_6_0"), api_ptr)

		if result ~= 1 or api_ptr[0] == nil then error("Failed to get RenderDoc API") end

		api = ffi.cast(API_1_6_0, api_ptr[0])

		if api.GetAPIVersion == nil then
			error("Failed to cast RenderDoc API to version 1.6.0")
		end
	end
end

function renderdoc.GetVersion()
	local major, minor, patch = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("int[1]")
	api.GetAPIVersion(major, minor, patch)
	return major[0], minor[0], patch[0]
end

function renderdoc.IsCapturing()
	return api.IsFrameCapturing() == 1
end

function renderdoc.CaptureFrame()
	if renderdoc.IsCapturing() then error("Already capturing") end

	api.TriggerMultiFrameCapture(1)
end

function renderdoc.StartCapture(device, window)
	api.StartFrameCapture(device or nil, window or nil)
	return true
end

function renderdoc.StopCapture(device, window)
	local res = api.EndFrameCapture(device or nil, window or nil)

	if res ~= 1 then error("Failed to stop capture: " .. tostring(res), 2) end
end

function renderdoc.GetCaptures()
	local out = {}
	local num_captures = api.GetNumCaptures()

	for i = 0, num_captures - 1 do
		local pathlength = ffi.new("uint32_t[1]", 0)
		local timestamp = ffi.new("uint64_t[1]", 0)
		-- Get capture path length
		api.GetCapture(i, nil, pathlength, timestamp)
		print("\t", i, pathlength[0], "?!?!")

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

function renderdoc.OpenUI(...)
	local args = {...}
	table.insert(args, 1, "localhost:38920")
	table.insert(args, 1, "--targetcontrol")
	launch_ui(nil, args)
end

return renderdoc
