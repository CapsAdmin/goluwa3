local ffi = require("ffi")
local threads = import("goluwa/bindings/threads.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local Texture = import("goluwa/render/texture.lua")
local Semaphore = import("goluwa/render/vulkan/internal/semaphore.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local CommandPool = import("goluwa/render/vulkan/internal/command_pool.lua")
local frame_pacer = {}
frame_pacer.SLOTS = 3
frame_pacer.GENERATED = 0
frame_pacer.REAL = 1
local MAX_IMAGES = 8
local JOBS = 16
local PRESENTS = frame_pacer.SLOTS * 2
local STATE_DECL = string.format(
	[[
	struct {
		void *device;
		void *queue;
		void *swapchain;
		void *acquire_next_image;
		void *queue_submit;
		void *queue_present;
		void *reset_fences;
		void *wait_for_fences;
		void *frame_fences[%d];
		uint32_t image_count;
		void *acquire_semaphores[%d];
		void *ready_semaphores[%d];
		void *done_semaphores[%d];
		void *copy_fences[%d];
		void *copy_commands[%d];
		int32_t job_slots[%d];
		int32_t job_masks[%d];
		int32_t write_count;
		int32_t read_count;
		int32_t pause;
		int32_t paused;
		int32_t quit;
		int32_t out_of_date;
		double interval;
		int32_t present_count;
		double present_times[64];
	}
]],
	frame_pacer.SLOTS,
	PRESENTS,
	PRESENTS,
	MAX_IMAGES,
	PRESENTS,
	PRESENTS * MAX_IMAGES,
	JOBS,
	JOBS
)
local state_t = ffi.typeof(STATE_DECL)
-- runs in its own lua state: it only touches the swapchain and the present queue, through function pointers the main thread looked up
local WORKER = "local STATE_DECL = [==[" .. STATE_DECL .. "]==]\nlocal JOBS, MAX_IMAGES = " .. JOBS .. ", " .. MAX_IMAGES .. "\n" .. [==[
	local ptr = ...
	local ffi = require("ffi")
	local threads = import("goluwa/bindings/threads.lua")
	local now = import("goluwa/bindings/time.lua")
	local s = ffi.cast(ffi.typeof("$*", ffi.typeof(STATE_DECL)), ptr)
	local submit_info_t = ffi.typeof([[
		struct {
			uint32_t sType;
			const void *pNext;
			uint32_t waitSemaphoreCount;
			void *const *pWaitSemaphores;
			const uint32_t *pWaitDstStageMask;
			uint32_t commandBufferCount;
			void *const *pCommandBuffers;
			uint32_t signalSemaphoreCount;
			void *const *pSignalSemaphores;
		}
	]])
	local present_info_t = ffi.typeof([[
		struct {
			uint32_t sType;
			const void *pNext;
			uint32_t waitSemaphoreCount;
			void *const *pWaitSemaphores;
			uint32_t swapchainCount;
			void *const *pSwapchains;
			const uint32_t *pImageIndices;
			int32_t *pResults;
		}
	]])
	local acquire_next_image = ffi.cast("int32_t (*)(void *, void *, uint64_t, void *, void *, uint32_t *)", s.acquire_next_image)
	local queue_submit = ffi.cast(ffi.typeof("int32_t (*)(void *, uint32_t, const $ *, void *)", submit_info_t), s.queue_submit)
	local queue_present = ffi.cast(ffi.typeof("int32_t (*)(void *, const $ *)", present_info_t), s.queue_present)
	local reset_fences = ffi.cast("int32_t (*)(void *, uint32_t, void *const *)", s.reset_fences)
	local wait_for_fences = ffi.cast("int32_t (*)(void *, uint32_t, void *const *, uint32_t, uint64_t)", s.wait_for_fences)
	local frame_fence = ffi.new("void *[1]")
	local SUBOPTIMAL = 1000001003
	local OUT_OF_DATE = -1000001004
	local TRANSFER_STAGE = 0x1000
	local image_index = ffi.new("uint32_t[1]")
	local wait_semaphores = ffi.new("void *[2]")
	local wait_stages = ffi.new("uint32_t[2]", TRANSFER_STAGE, TRANSFER_STAGE)
	local commands = ffi.new("void *[1]")
	local signal_semaphores = ffi.new("void *[1]")
	local fences = ffi.new("void *[1]")
	local swapchains = ffi.new("void *[1]")
	local submit_info = submit_info_t{
		sType = 4,
		waitSemaphoreCount = 2,
		pWaitSemaphores = wait_semaphores,
		pWaitDstStageMask = wait_stages,
		commandBufferCount = 1,
		pCommandBuffers = commands,
		signalSemaphoreCount = 1,
		pSignalSemaphores = signal_semaphores,
	}
	local present_info = present_info_t{
		sType = 1000001001,
		waitSemaphoreCount = 1,
		pWaitSemaphores = signal_semaphores,
		swapchainCount = 1,
		pSwapchains = swapchains,
		pImageIndices = image_index,
	}

	local function present(index)
		swapchains[0] = s.swapchain
		local result = acquire_next_image(s.device, s.swapchain, 0xFFFFFFFFFFFFFFFFULL, s.acquire_semaphores[index], nil, image_index)

		if result == OUT_OF_DATE then
			s.out_of_date = 1
			return
		end

		assert(result == 0 or result == SUBOPTIMAL, "frame pacer: acquire failed " .. result)
		local image = image_index[0]
		wait_semaphores[0] = s.acquire_semaphores[index]
		wait_semaphores[1] = s.ready_semaphores[index]
		commands[0] = s.copy_commands[index * MAX_IMAGES + image]
		signal_semaphores[0] = s.done_semaphores[image]
		fences[0] = s.copy_fences[index]
		assert(reset_fences(s.device, 1, fences) == 0)
		assert(queue_submit(s.queue, 1, submit_info, s.copy_fences[index]) == 0, "frame pacer: submit failed")
		result = queue_present(s.queue, present_info)
		wait_for_fences(s.device, 1, fences, 1, 0xFFFFFFFFFFFFFFFFULL)
		s.present_times[s.present_count % 64] = now()
		s.present_count = s.present_count + 1

		if result == OUT_OF_DATE then s.out_of_date = 1 end
	end

	local last_arrival
	local interval = 1 / 60

	while s.quit == 0 do
		if s.pause ~= 0 or s.read_count == s.write_count then
			s.paused = s.pause
			threads.sleep(0.1)
		else
			s.paused = 0
			local job = s.read_count % JOBS
			local slot = s.job_slots[job]
			local mask = s.job_masks[job]
			-- pace from when the gpu finished the frame: the cpu submits a gpu bound frame long before it is done, and presents queued behind it would all go out together
			frame_fence[0] = s.frame_fences[slot]
			wait_for_fences(s.device, 1, frame_fence, 1, 0xFFFFFFFFFFFFFFFFULL)
			local arrival = now()

			if last_arrival then
				interval = interval + (math.min(arrival - last_arrival, 0.25) - interval) * 0.1
			end

			last_arrival = arrival
			s.interval = interval

			if bit.band(mask, 1) ~= 0 and s.out_of_date == 0 then
				present(slot * 2)
				local target = now() + interval * 0.5

				while target - now() > 0.0015 do
					threads.sleep(1)
				end

				while target - now() > 0.0002 do
					threads.sleep(0.1)
				end

				while now() < target do end
			end

			if bit.band(mask, 2) ~= 0 and s.out_of_date == 0 then present(slot * 2 + 1) end

			s.read_count = s.read_count + 1
		end
	end
]==]

do
	local META = {}
	META.__index = META

	function frame_pacer.New(config)
		local vulkan_instance = config.vulkan_instance
		local device = vulkan_instance.device
		local self = setmetatable(
			{
				vulkan_instance = vulkan_instance,
				device = device,
				queue = assert(vulkan_instance.present_queue, "frame generation needs a second graphics queue to present from"),
				format = config.format,
				width = config.width,
				height = config.height,
				state = state_t(),
				slot = 0,
				images = {},
				acquire_semaphores = {},
				ready_semaphores = {},
				done_semaphores = {},
				copy_fences = {},
			},
			META
		)
		self.command_pool = CommandPool.New(device, vulkan_instance.graphics_queue_family)

		for i = 1, PRESENTS do
			self.images[i] = Texture.New{
				width = self.width,
				height = self.height,
				format = self.format,
				image = {
					usage = {"color_attachment", "transfer_src", "sampled"},
					properties = "device_local",
				},
				sampler = false,
			}
			self.images[i]:SetDebugName("frame pacer present " .. i)
			self.images[i]:GetImage().frame_target = true
			self.acquire_semaphores[i] = Semaphore.New(device)
			self.ready_semaphores[i] = Semaphore.New(device)
			self.copy_fences[i] = Fence.New(device)
		end

		local s = self.state
		s.device = device.ptr[0]
		s.queue = self.queue.ptr[0]
		s.acquire_next_image = ffi.cast("void *", vulkan.lib.vkGetDeviceProcAddr(device.ptr[0], "vkAcquireNextImageKHR"))
		s.queue_submit = ffi.cast("void *", vulkan.lib.vkGetDeviceProcAddr(device.ptr[0], "vkQueueSubmit"))
		s.queue_present = ffi.cast("void *", vulkan.lib.vkGetDeviceProcAddr(device.ptr[0], "vkQueuePresentKHR"))
		s.reset_fences = ffi.cast("void *", vulkan.lib.vkGetDeviceProcAddr(device.ptr[0], "vkResetFences"))
		s.wait_for_fences = ffi.cast("void *", vulkan.lib.vkGetDeviceProcAddr(device.ptr[0], "vkWaitForFences"))
		self.frame_fences = {}

		for i = 1, frame_pacer.SLOTS do
			self.frame_fences[i] = Fence.New(device)
			s.frame_fences[i - 1] = self.frame_fences[i].ptr[0]
		end

		s.interval = 1 / 60

		for i = 1, PRESENTS do
			s.acquire_semaphores[i - 1] = self.acquire_semaphores[i].ptr[0]
			s.ready_semaphores[i - 1] = self.ready_semaphores[i].ptr[0]
			s.copy_fences[i - 1] = self.copy_fences[i].ptr[0]
		end

		self:SetSwapchain(config.swapchain, config.swapchain_images)
		self.thread = threads.new(WORKER)
		self.thread:run(self.state, true)
		device.present_thread = self
		return self
	end

	function META:SetSwapchain(swapchain, swapchain_images)
		assert(#swapchain_images <= MAX_IMAGES, "frame pacer: too many swapchain images")

		for _, semaphore in ipairs(self.done_semaphores) do
			semaphore:Remove()
		end

		self.done_semaphores = {}
		self.swapchain = swapchain
		local s = self.state
		s.swapchain = swapchain.ptr[0]
		s.image_count = #swapchain_images
		s.out_of_date = 0

		for i = 1, #swapchain_images do
			self.done_semaphores[i] = Semaphore.New(self.device)
			s.done_semaphores[i - 1] = self.done_semaphores[i].ptr[0]
		end

		self.copy_commands = self.copy_commands or {}

		for index = 1, PRESENTS do
			for image_index = 1, #swapchain_images do
				local key = (index - 1) * MAX_IMAGES + image_index
				local cmd = self.copy_commands[key] or self.command_pool:AllocateCommandBuffer()
				self.copy_commands[key] = cmd
				local source = self.images[index]:GetImage()
				local target = swapchain_images[image_index]
				cmd:Reset()
				cmd:Begin(true)
				cmd:PipelineBarrier{
					srcStage = "transfer",
					dstStage = "transfer",
					imageBarriers = {
						{
							image = target,
							srcAccessMask = "none",
							dstAccessMask = "transfer_write",
							oldLayout = "undefined",
							newLayout = "transfer_dst_optimal",
						},
					},
				}
				cmd:CopyImageToImage{
					src_image = source,
					dst_image = target,
					width = self.width,
					height = self.height,
				}
				cmd:PipelineBarrier{
					srcStage = "transfer",
					dstStage = "bottom_of_pipe",
					imageBarriers = {
						{
							image = target,
							srcAccessMask = "transfer_write",
							dstAccessMask = "none",
							oldLayout = "transfer_dst_optimal",
							newLayout = "present_src_khr",
						},
					},
				}
				cmd:End()
				s.copy_commands[key - 1] = cmd.ptr[0]
			end
		end
	end

	function META:Pause()
		local s = self.state
		s.pause = 1

		while s.paused == 0 and s.quit == 0 do
			threads.sleep(0)
		end
	end

	function META:Resume()
		self.state.pause = 0
		self.state.paused = 0
	end

	function META:IsOutOfDate()
		return self.state.out_of_date ~= 0
	end

	function META:GetInterval()
		return self.state.interval
	end

	function META:GetPresentIntervals()
		local s = self.state
		local intervals = {}
		local count = math.min(s.present_count, 64)

		for i = s.present_count - count + 1, s.present_count - 1 do
			intervals[#intervals + 1] = s.present_times[i % 64] - s.present_times[(i - 1) % 64]
		end

		return intervals
	end

	function META:BeginFrame()
		local s = self.state

		while s.write_count - s.read_count >= frame_pacer.SLOTS - 1 do
			threads.sleep(0)
		end

		self.slot = (self.slot + 1) % frame_pacer.SLOTS
		local generated = self.slot * 2 + 1
		self.copy_fences[generated]:Wait()
		self.copy_fences[generated + 1]:Wait()
		self.frame_fences[self.slot + 1]:Wait()
		self.frame_fences[self.slot + 1]:Reset()
		return self.images[generated], self.images[generated + 1]
	end

	function META:GetReadySemaphores()
		local generated = self.slot * 2 + 1
		return self.ready_semaphores[generated], self.ready_semaphores[generated + 1]
	end

	-- the frame's graphics submit on queue must signal the ready semaphores of the images in the mask before this runs
	function META:Queue(queue, present_generated)
		local s = self.state
		vulkan.assert(
			vulkan.lib.vkQueueSubmit(queue.ptr[0], 0, nil, self.frame_fences[self.slot + 1].ptr[0]),
			"frame pacer: fence submit failed"
		)
		local job = s.write_count % JOBS
		s.job_slots[job] = self.slot
		s.job_masks[job] = present_generated and 3 or 2
		s.write_count = s.write_count + 1
	end

	function META:Remove()
		local s = self.state
		s.quit = 1
		self.thread:join()
		self.device.present_thread = nil
		self.device:WaitIdle()

		for i = 1, PRESENTS do
			self.images[i]:Remove()
			self.acquire_semaphores[i]:Remove()
			self.ready_semaphores[i]:Remove()
			self.copy_fences[i]:Remove()
		end

		for _, fence in ipairs(self.frame_fences) do
			fence:Remove()
		end

		for _, semaphore in ipairs(self.done_semaphores) do
			semaphore:Remove()
		end

		self.command_pool:Remove()
	end
end

return frame_pacer
