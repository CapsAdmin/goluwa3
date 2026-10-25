local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local system = import("goluwa/system.lua")
local startup = import("goluwa/startup.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local event = import("goluwa/event.lua")
local PipelineCache = objects.CreateTemplate("vulkan_pipeline_cache")
local VkPipelineCacheBox = ffi.typeof("$[1]", vulkan.vk.VkPipelineCache)
local SizeBox = ffi.typeof("size_t[1]")
local ByteArray = ffi.typeof("uint8_t[?]")
local HeaderPtr = ffi.typeof("const $*", vulkan.vk.VkPipelineCacheHeaderVersionOne)
local SLOW_PIPELINE_SECONDS = 0.05

function PipelineCache.GetTime()
	return system.GetTime()
end

function PipelineCache.LogIfSlow(kind, name, start)
	local seconds = system.GetTime() - start

	if seconds >= SLOW_PIPELINE_SECONDS then
		logf(
			"[pipeline] the driver compiled %s pipeline %s in %.0f ms (not in the pipeline cache)\n",
			kind,
			tostring(name),
			seconds * 1000
		)
	end
end

local function address(pointer)
	return tostring(ffi.cast("uint64_t", ffi.cast("uintptr_t", pointer)))
end

-- vkCreateGraphicsPipelines and vkCreateComputePipelines block for as long as the driver compiles, which
-- is tens of seconds for the lighting shaders on a cold start, so they run on a worker thread and the
-- pipeline is waited for when it is bound
local CREATE_JOB = [[
	local ffi = require("ffi")
	local input = ...
	local create = ffi.cast("int (*)(void *, void *, uint32_t, const void *, const void *, void *)", input.create)

	if input.ray_tracing then
		local create_ray_tracing = ffi.cast("int (*)(void *, void *, void *, uint32_t, const void *, const void *, void *)", input.create)
		create = function(device, cache, count, info, allocator, out)
			return create_ray_tracing(device, nil, cache, count, info, allocator, out)
		end
	end

	local function handle(text)
		return ffi.cast("void *", loadstring("return " .. text)())
	end

	local start = os.clock()
	local result = create(handle(input.device), handle(input.cache), 1, handle(input.info), nil, handle(input.out))

	if result ~= 0 then error("failed to create pipeline: VkResult " .. result) end

	return (os.clock() - start) * 1000
]]

function PipelineCache:RunCreate(create, info, out, ray_tracing)
	local job = thread_pool.Run(
		CREATE_JOB,
		{
			create = tonumber(ffi.cast("uintptr_t", ffi.cast("void *", create))),
			device = address(self.device.ptr[0]),
			cache = address(self.ptr[0]),
			info = address(info),
			out = address(out),
			ray_tracing = ray_tracing,
		},
		math.huge
	)
	self:AddJob(job)
	return job
end

function PipelineCache:WaitForJob(job, kind, name)
	local start = system.GetTime()

	while not job:IsDone() and system.GetTime() - start < SLOW_PIPELINE_SECONDS do
		thread_pool.Update()
	end

	if not job:IsDone() then
		logf(
			"[pipeline] the driver is compiling %s pipeline %s, this can take a while...\n",
			kind,
			tostring(name)
		)
	end

	local milliseconds = job:Block()
	startup.Add("pipeline: " .. kind .. " wait", start)

	if milliseconds >= 50 then
		logf(
			"[pipeline] the driver compiled %s pipeline %s in %.0f ms (not in the pipeline cache)\n",
			kind,
			tostring(name),
			milliseconds
		)
	end
end

local function is_compatible(device, data)
	if #data < ffi.sizeof(vulkan.vk.VkPipelineCacheHeaderVersionOne) then
		return false
	end

	local header = ffi.cast(HeaderPtr, data)
	local properties = device.physical_device:GetProperties()
	return header.headerVersion == vulkan.vk.VkPipelineCacheHeaderVersion.VK_PIPELINE_CACHE_HEADER_VERSION_ONE and
		header.vendorID == properties.vendorID and
		header.deviceID == properties.deviceID and
		ffi.string(header.pipelineCacheUUID, 16) == ffi.string(properties.pipelineCacheUUID, 16)
end

function PipelineCache.New(device, initial_data)
	if initial_data and not is_compatible(device, initial_data) then
		logn("[vulkan] ignoring pipeline cache from another device or driver")
		initial_data = nil
	end

	local ptr = VkPipelineCacheBox()
	vulkan.assert(
		vulkan.lib.vkCreatePipelineCache(
			device.ptr[0],
			vulkan.vk.s.PipelineCacheCreateInfo{
				initialDataSize = initial_data and #initial_data or 0,
				pInitialData = initial_data and ffi.cast("const void*", initial_data) or nil,
			},
			nil,
			ptr
		),
		"failed to create pipeline cache"
	)
	return PipelineCache:CreateObject{
		device = device,
		ptr = ptr,
		initial_data = initial_data,
		generation = 0,
		jobs = {},
	}
end

do
	local function on_job_done(job)
		job.pipeline_cache.generation = job.pipeline_cache.generation + 1
		event.Call("PipelineCompiled")
	end

	function PipelineCache:AddJob(job)
		job.pipeline_cache = self
		table.insert(self.jobs, job)
		job:OnDone(on_job_done)
	end
end

function PipelineCache:HasJobsInFlight()
	local jobs = self.jobs

	for i = #jobs, 1, -1 do
		if jobs[i]:IsDone() then table.remove(jobs, i) end
	end

	return #jobs > 0
end

function PipelineCache:GetDataSize()
	local size = SizeBox()
	vulkan.assert(
		vulkan.lib.vkGetPipelineCacheData(self.device.ptr[0], self.ptr[0], size, nil),
		"failed to get pipeline cache size"
	)
	return tonumber(size[0])
end

function PipelineCache:GetData()
	local size = SizeBox()
	vulkan.assert(
		vulkan.lib.vkGetPipelineCacheData(self.device.ptr[0], self.ptr[0], size, nil),
		"failed to get pipeline cache size"
	)
	local data = ByteArray(size[0])
	vulkan.assert(
		vulkan.lib.vkGetPipelineCacheData(self.device.ptr[0], self.ptr[0], size, data),
		"failed to get pipeline cache data"
	)
	return ffi.string(data, size[0])
end

function PipelineCache:OnRemove()
	if self.device:IsValid() then
		vulkan.lib.vkDestroyPipelineCache(self.device.ptr[0], self.ptr[0], nil)
	end
end

return PipelineCache:Register()
