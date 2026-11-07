local ffi = require("ffi")
local bit = require("bit")
local ngfx = {}
-- also declared by the renderdoc and tls bindings
pcall(
	ffi.cdef,
	"void *dlopen(const char *filename, int flags); void *dlsym(void *handle, const char *symbol);"
)
local RTLD_NOW, RTLD_NOLOAD = 0x2, 0x4
local TARGET_LIBRARY = "libWarpVizTarget.so"
local function_t = ffi.typeof("int (*)(void *)")
local version_params_t = ffi.typeof("struct { uint32_t version; }")
local activate_params_t = ffi.typeof("struct { uint32_t version; void *queue; }")
local status_params_t = ffi.typeof("struct { uint32_t version; uint32_t status; }")
local STATUSES = {[0] = "inactive", "active", "tracing", "draining", "errored"}
local RESULTS = {
	[1] = "not implemented",
	[2] = "library not found",
	[3] = "invalid library",
	[4] = "invalid parameter",
	[5] = "invalid state",
}
local module
local activated = false

-- NGFX_MAKE_STRUCT_VERSION: the struct size in the low 16 bits, the version above
local function new_params(ct)
	local params = ct()
	params.version = bit.bor(ffi.sizeof(ct), bit.lshift(1, 16))
	return params
end

local function call(name, params)
	local symbol = ffi.C.dlsym(module, "NGFX_GPUTrace_" .. name)

	if symbol == nil then
		error("NGFX_GPUTrace_" .. name .. " is missing from " .. TARGET_LIBRARY, 3)
	end

	local result = ffi.cast(function_t, symbol)(params)

	if result ~= 0 then
		error("NGFX_GPUTrace_" .. name .. " failed: " .. (RESULTS[result] or result), 3)
	end

	return params
end

-- true when Nsight Graphics injected GPU Trace into this process (luajit glw ngfx --capture)
function ngfx.IsInjected()
	if module == nil then
		module = ffi.C.dlopen(TARGET_LIBRARY, bit.bor(RTLD_NOW, RTLD_NOLOAD))

		if module == nil then module = false end
	end

	return module ~= false
end

-- the host must have been told to wait for the sdk (--start-with-ngfx-sdk); it stops the trace by itself
-- after its frame limit. queue is the VkQueue the trace creates its resources on.
function ngfx.StartTrace(queue)
	if not ngfx.IsInjected() then
		error(
			"Nsight Graphics GPU Trace is not injected, launch with luajit glw ngfx --capture",
			2
		)
	end

	if not activated then
		call("InitializeTraceActivityVulkan", new_params(version_params_t))
		local activate = new_params(activate_params_t)
		activate.queue = queue
		call("ActivateTraceVulkan", activate)
		activated = true
	end

	call("StartTraceVulkan", new_params(version_params_t))
end

function ngfx.GetStatus()
	return STATUSES[call("GetStatus", new_params(status_params_t)).status]
end

return ngfx
