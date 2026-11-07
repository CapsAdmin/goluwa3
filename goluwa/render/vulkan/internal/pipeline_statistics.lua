local ffi = require("ffi")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local pipeline_statistics = {}
pipeline_statistics.ENABLED = os.getenv("GOLUWA_PIPELINE_STATS") == "1"
pipeline_statistics.GPUS = {
	["NVIDIA GeForce RTX 4090"] = {
		registers_per_sm = 65536,
		max_warps = 48,
		warp_size = 32,
		register_granularity = 256,
		register_statistic = "Register Count",
		spill_statistic = "Local Memory Size",
	},
}
local UInt32Box = ffi.typeof("uint32_t[1]")
local PropertiesArray = ffi.typeof("$[?]", vulkan.vk.VkPipelineExecutablePropertiesKHR)
local StatisticArray = ffi.typeof("$[?]", vulkan.vk.VkPipelineExecutableStatisticKHR)
local FORMAT = vulkan.vk.VkPipelineExecutableStatisticFormatKHR

local function statistic_value(statistic)
	local format = statistic.format

	if format == FORMAT.VK_PIPELINE_EXECUTABLE_STATISTIC_FORMAT_BOOL32_KHR then
		return statistic.value.b32 ~= 0
	elseif format == FORMAT.VK_PIPELINE_EXECUTABLE_STATISTIC_FORMAT_INT64_KHR then
		return tonumber(statistic.value.i64)
	elseif format == FORMAT.VK_PIPELINE_EXECUTABLE_STATISTIC_FORMAT_UINT64_KHR then
		return tonumber(statistic.value.u64)
	end

	return statistic.value.f64
end

function pipeline_statistics.Get(device, pipeline)
	local get_properties = device:GetExtension("vkGetPipelineExecutablePropertiesKHR")
	local get_statistics = device:GetExtension("vkGetPipelineExecutableStatisticsKHR")
	local pipeline_info = vulkan.vk.s.PipelineInfoKHR{pipeline = pipeline}
	local count = UInt32Box()
	vulkan.assert(
		get_properties(device.ptr[0], pipeline_info, count, nil),
		"vkGetPipelineExecutablePropertiesKHR"
	)
	local properties = PropertiesArray(count[0])

	for i = 0, count[0] - 1 do
		properties[i].sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_EXECUTABLE_PROPERTIES_KHR
	end

	vulkan.assert(
		get_properties(device.ptr[0], pipeline_info, count, properties),
		"vkGetPipelineExecutablePropertiesKHR"
	)
	local executables = {}

	for i = 0, count[0] - 1 do
		local executable_info = vulkan.vk.s.PipelineExecutableInfoKHR{pipeline = pipeline, executableIndex = i}
		local statistic_count = UInt32Box()
		vulkan.assert(
			get_statistics(device.ptr[0], executable_info, statistic_count, nil),
			"vkGetPipelineExecutableStatisticsKHR"
		)
		local statistics = StatisticArray(statistic_count[0])

		for j = 0, statistic_count[0] - 1 do
			statistics[j].sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_PIPELINE_EXECUTABLE_STATISTIC_KHR
		end

		vulkan.assert(
			get_statistics(device.ptr[0], executable_info, statistic_count, statistics),
			"vkGetPipelineExecutableStatisticsKHR"
		)
		local list = {}

		for j = 0, statistic_count[0] - 1 do
			list[j + 1] = {
				name = ffi.string(statistics[j].name),
				description = ffi.string(statistics[j].description),
				value = statistic_value(statistics[j]),
			}
		end

		executables[i + 1] = {
			name = ffi.string(properties[i].name),
			description = ffi.string(properties[i].description),
			stages = properties[i].stages,
			subgroup_size = properties[i].subgroupSize,
			statistics = list,
		}
	end

	return executables
end

function pipeline_statistics.Report(device, pipeline, kind, name)
	local gpu = device.pipeline_statistics_gpu

	for _, executable in ipairs(pipeline_statistics.Get(device, pipeline)) do
		local values = {}
		local parts = {}

		for _, statistic in ipairs(executable.statistics) do
			values[statistic.name] = statistic.value
			parts[#parts + 1] = statistic.name .. "=" .. tostring(statistic.value)
		end

		if pipeline_statistics.ENABLED then
			logf(
				"[pipeline stats] %s %s %s: %s\n",
				kind,
				tostring(name),
				executable.name,
				table.concat(parts, ", ")
			)
		end

		if gpu and values[gpu.register_statistic] then
			local registers = values[gpu.register_statistic]
			-- nvidia 615 reports the local memory size with bit 36 set
			local spill = values[gpu.spill_statistic] % 2 ^ 32
			local warp_registers = math.ceil(registers * gpu.warp_size / gpu.register_granularity) * gpu.register_granularity
			local warps = math.min(gpu.max_warps, math.floor(gpu.registers_per_sm / math.max(warp_registers, 1)))

			if spill > 0 then
				logf(
					"[pipeline] %s %s %s uses %d registers (%d of %d warps per sm) and spills %d bytes to local memory\n",
					kind,
					tostring(name),
					executable.name,
					registers,
					warps,
					gpu.max_warps,
					spill
				)
			end
		end
	end
end

return pipeline_statistics
