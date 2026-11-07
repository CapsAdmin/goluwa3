local ffi = require("ffi")
local ngfx_perfworks = {}
local Image = {}
Image.__index = Image
ffi.cdef[[
	int NVPW_InitializeHost(void *params);
	int NVPW_CounterData_GetChipName(void *params);
	int NVPW_PeriodicSampler_CounterData_GetInfo(void *params);
	int NVPW_PeriodicSampler_CounterData_GetSampleTime(void *params);
	int NVPW_PeriodicSampler_CounterData_IsDataComplete(void *params);
	int NVPW_VK_MetricsEvaluator_CalculateScratchBufferSize(void *params);
	int NVPW_VK_MetricsEvaluator_Initialize(void *params);
	int NVPW_MetricsEvaluator_GetMetricNames(void *params);
	int NVPW_MetricsEvaluator_ConvertMetricNameToMetricEvalRequest(void *params);
	int NVPW_MetricsEvaluator_SetDeviceAttributes(void *params);
	int NVPW_MetricsEvaluator_EvaluateToGpuValues(void *params);
	int NVPW_MetricsEvaluator_Destroy(void *params);
]]
local initialize_host_t = ffi.typeof("struct { size_t struct_size; void *priv; }")
local chip_name_t = ffi.typeof(
	"struct { size_t struct_size; void *priv; const uint8_t *image; size_t image_size; const char *chip_name; }"
)
local periodic_info_t = ffi.typeof(
	"struct { size_t struct_size; void *priv; const uint8_t *image; size_t image_size; size_t total_ranges; size_t populated_ranges; size_t completed_ranges; }"
)
local sample_time_t = ffi.typeof(
	"struct { size_t struct_size; void *priv; const uint8_t *image; size_t range_index; uint64_t start; uint64_t stop; }"
)
local scratch_size_t = ffi.typeof(
	"struct { size_t struct_size; void *priv; const char *chip_name; size_t scratch_size; const uint8_t *counter_availability; }"
)
local initialize_t = ffi.typeof(
	"struct { size_t struct_size; void *priv; uint8_t *scratch; size_t scratch_size; const char *chip_name; const uint8_t *counter_availability; size_t counter_availability_size; void *evaluator; const uint8_t *counter_data; size_t counter_data_size; }"
)
local request_t = ffi.typeof(
	"struct { size_t metric_index; uint8_t metric_type; uint8_t rollup; uint16_t submetric; }"
)
local metric_names_t = ffi.typeof(
	"struct { size_t struct_size; void *priv; void *evaluator; uint8_t metric_type; const char *names; const size_t *name_offsets; size_t count; }"
)
local convert_t = ffi.typeof(
	"struct { size_t struct_size; void *priv; void *evaluator; const char *metric_name; $ *request; size_t request_size; }",
	request_t
)
local device_attributes_t = ffi.typeof(
	"struct { size_t struct_size; void *priv; void *evaluator; const uint8_t *counter_data; size_t counter_data_size; }"
)
local evaluate_t = ffi.typeof(
	"struct { size_t struct_size; void *priv; void *evaluator; const $ *requests; size_t request_count; size_t request_size; size_t request_stride; const uint8_t *counter_data; size_t counter_data_size; size_t range_index; uint8_t isolated; double *values; }",
	request_t
)
local destroy_t = ffi.typeof("struct { size_t struct_size; void *priv; void *evaluator; }")
local request_array_t = ffi.typeof("$[?]", request_t)
local double_array_t = ffi.typeof("double[?]")
local byte_array_t = ffi.typeof("uint8_t[?]")
local REQUEST_SIZE = ffi.offsetof(request_t, "submetric") + 2
local METRIC_KINDS = {counter = 0, ratio = 1, throughput = 2}
local library

-- PerfWorks params carry the size up to the end of their last field, without trailing padding
local function params(ct, last_field, last_size)
	local value = ct()
	value.struct_size = ffi.offsetof(ct, last_field) + last_size
	return value
end

local function call(name, value)
	local status = library[name](value)

	if status ~= 0 then error(name .. " failed with status " .. status, 3) end

	return value
end

-- libnvperf_grfx_host.so ships with Nsight Graphics next to the ngfx tools
function ngfx_perfworks.Load(path)
	if library then return library end

	library = ffi.load(path)
	call("NVPW_InitializeHost", params(initialize_host_t, "priv", ffi.sizeof("void *")))
	return library
end

-- the counter section of a trace (a LOPDATA periodic sampler image); ptr must stay alive with the image
function ngfx_perfworks.OpenImage(ptr, size)
	assert(library, "call ngfx_perfworks.Load first")
	local self = setmetatable({ptr = ptr, size = size}, Image)
	local chip = params(chip_name_t, "chip_name", ffi.sizeof("void *"))
	chip.image, chip.image_size = ptr, size
	call("NVPW_CounterData_GetChipName", chip)
	self.chip_name = ffi.string(chip.chip_name)
	local info = params(periodic_info_t, "completed_ranges", ffi.sizeof("size_t"))
	info.image, info.image_size = ptr, size
	call("NVPW_PeriodicSampler_CounterData_GetInfo", info)
	self.range_count = tonumber(info.populated_ranges)
	local scratch_size = params(scratch_size_t, "counter_availability", ffi.sizeof("void *"))
	scratch_size.chip_name = self.chip_name
	call("NVPW_VK_MetricsEvaluator_CalculateScratchBufferSize", scratch_size)
	self.scratch = byte_array_t(scratch_size.scratch_size)
	local initialize = params(initialize_t, "counter_data_size", ffi.sizeof("size_t"))
	initialize.scratch, initialize.scratch_size = self.scratch, scratch_size.scratch_size
	initialize.chip_name = self.chip_name
	call("NVPW_VK_MetricsEvaluator_Initialize", initialize)
	self.evaluator = initialize.evaluator
	local attributes = params(device_attributes_t, "counter_data_size", ffi.sizeof("size_t"))
	attributes.evaluator, attributes.counter_data, attributes.counter_data_size = self.evaluator, ptr, size
	call("NVPW_MetricsEvaluator_SetDeviceAttributes", attributes)
	return self
end

-- start and end ns of a range, in the same ptimer clock as the trace's gpu timestamps
function Image:GetRangeTime(index)
	local time = params(sample_time_t, "stop", 8)
	time.image, time.range_index = self.ptr, index
	call("NVPW_PeriodicSampler_CounterData_GetSampleTime", time)
	return time.start, time.stop
end

-- base names of the metrics the evaluator knows, kind is "counter", "ratio" or "throughput"
function Image:GetMetricNames(kind)
	local names = params(metric_names_t, "count", ffi.sizeof("size_t"))
	names.evaluator, names.metric_type = self.evaluator, METRIC_KINDS[kind]
	call("NVPW_MetricsEvaluator_GetMetricNames", names)
	local out = {}

	for i = 0, tonumber(names.count) - 1 do
		out[i + 1] = ffi.string(names.names + names.name_offsets[i])
	end

	return out
end

-- full metric names such as "sm__throughput.avg.pct_of_peak_sustained_elapsed". Returns {[name] = {per range
-- value or false}} for the names the evaluator accepts and a list of the names it rejected
function Image:Evaluate(metric_names)
	local accepted, rejected = {}, {}
	local requests = request_array_t(#metric_names)

	for _, name in ipairs(metric_names) do
		local convert = params(convert_t, "request_size", ffi.sizeof("size_t"))
		convert.evaluator, convert.metric_name = self.evaluator, name
		convert.request, convert.request_size = requests + #accepted, REQUEST_SIZE

		if library.NVPW_MetricsEvaluator_ConvertMetricNameToMetricEvalRequest(convert) == 0 then
			accepted[#accepted + 1] = name
		else
			rejected[#rejected + 1] = name
		end
	end

	local out = {}

	for _, name in ipairs(accepted) do
		out[name] = {}
	end

	if not accepted[1] then return out, rejected end

	local values = double_array_t(#accepted)
	local evaluate = params(evaluate_t, "values", ffi.sizeof("void *"))
	evaluate.evaluator, evaluate.requests = self.evaluator, requests
	evaluate.request_count, evaluate.request_size, evaluate.request_stride = #accepted, REQUEST_SIZE, ffi.sizeof(request_t)
	evaluate.counter_data, evaluate.counter_data_size, evaluate.isolated = self.ptr, self.size, 1
	evaluate.values = values

	for range = 0, self.range_count - 1 do
		evaluate.range_index = range
		call("NVPW_MetricsEvaluator_EvaluateToGpuValues", evaluate)

		for i, name in ipairs(accepted) do
			local value = values[i - 1]
			out[name][range + 1] = value == value and value ~= math.huge and value ~= -math.huge and value
		end
	end

	return out, rejected
end

-- NGFX_NVPERF, else the library of the Nsight Graphics whose ngfx-ui is on PATH
function ngfx_perfworks.FindLibrary()
	local configured = os.getenv("NGFX_NVPERF")

	if configured then return configured end

	local pipe = io.popen("readlink -f \"$(command -v ngfx-ui)\" 2>/dev/null")
	local ui = pipe:read("*l")
	pipe:close()

	if not ui or ui == "" then return end

	local directory = ui:match("^(.*)/[^/]+$")

	for _, candidate in ipairs{
		directory .. "/libnvperf_grfx_host.so",
		directory .. "/../host/linux-desktop-nomad-x64/libnvperf_grfx_host.so",
	} do
		local file = io.open(candidate, "rb")

		if file then
			file:close()
			return candidate
		end
	end
end

return ngfx_perfworks
