local ffi = require("ffi")
local vulkan = require("bindings.vulkan")
local Renderer = {}
Renderer.__index = Renderer
-- Default configuration
local default_config = {
	-- Swapchain settings
	present_mode = "fifo", -- FIFO (vsync), IMMEDIATE (no vsync), MAILBOX (triple buffer)
	image_count = nil, -- nil = minImageCount + 1 (usually triple buffer)
	surface_format_index = 1, -- Which format from available formats to use
	composite_alpha = "opaque", -- OPAQUE, PRE_MULTIPLIED, POST_MULTIPLIED, INHERIT
	clipped = true, -- Clip pixels obscured by other windows
	image_usage = nil, -- nil = COLOR_ATTACHMENT | TRANSFER_DST, or provide custom flags
	-- Image acquisition
	acquire_timeout = ffi.cast("uint64_t", -1), -- Infinite timeout by default
	-- Presentation
	pre_transform = nil, -- nil = use currentTransform
}

function Renderer.New(config)
	config = config or {}

	for k, v in pairs(default_config) do
		if config[k] == nil then config[k] = v end
	end

	local self = setmetatable({}, Renderer)
	self.config = config
	self:Initialize(assert(self.config.surface_handle))
	return self
end

function Renderer:Initialize(metal_surface)
	local layers = {}
	local extensions = {"VK_KHR_surface", "VK_EXT_metal_surface"}

	if os.getenv("VULKAN_SDK") then
		table.insert(layers, "VK_LAYER_KHRONOS_validation")
		table.insert(extensions, "VK_KHR_portability_enumeration")
	end

	-- Vulkan initialization
	self.instance = vulkan.CreateInstance(extensions, layers)
	self.surface = self.instance:CreateMetalSurface(metal_surface)
	self.physical_device = self.instance:GetPhysicalDevices()[1]
	self.graphics_queue_family = self.physical_device:FindGraphicsQueueFamily(self.surface)
	self.device = self.physical_device:CreateDevice({"VK_KHR_swapchain"}, self.graphics_queue_family)
	self.command_pool = self.device:CreateCommandPool(self.graphics_queue_family)
	-- Get queue
	self.queue = self.device:GetQueue(self.graphics_queue_family)
	-- Create swapchain
	self:RecreateSwapchain()
	return self
end

function Renderer:RecreateSwapchain()
	-- Wait for device to be idle (skip on initial creation)
	if self.swapchain then self:WaitForIdle() end

	-- Query surface capabilities and formats
	self.surface_capabilities = self.physical_device:GetSurfaceCapabilities(self.surface)
	local new_surface_formats = self.physical_device:GetSurfaceFormats(self.surface)

	-- Validate format index
	if self.config.surface_format_index > #new_surface_formats then
		error(
			"Invalid surface_format_index: " .. self.config.surface_format_index .. " (max: " .. (
					#new_surface_formats
				) .. ")"
		)
	end

	local selected_format = new_surface_formats[self.config.surface_format_index]

	if selected_format.format == "undefined" then
		error("selected surface format is undefined!")
	end

	self.surface_formats = new_surface_formats
	-- Build swapchain config
	local swapchain_config = {
		present_mode = self.config.present_mode,
		image_count = self.config.image_count or (self.surface_capabilities[0].minImageCount + 1),
		composite_alpha = self.config.composite_alpha,
		clipped = self.config.clipped,
		image_usage = self.config.image_usage,
		pre_transform = self.config.pre_transform,
	}
	-- Create new swapchain (pass old swapchain if it exists)
	self.swapchain = self.device:CreateSwapchain(
		self.surface,
		self.surface_formats[self.config.surface_format_index],
		self.surface_capabilities,
		swapchain_config,
		self.swapchain -- old swapchain for efficient recreation (nil on initial creation)
	)
	self.swapchain_images = self.swapchain:GetImages()
end

do
	local OffscreenRenderTarget = {}
	OffscreenRenderTarget.__index = OffscreenRenderTarget

	function OffscreenRenderTarget.New(renderer, width, height, format, config)
		config = config or {}
		local usage = config.usage or {"color_attachment", "sampled"}
		local samples = config.samples or "1"
		local final_layout = config.final_layout or "color_attachment_optimal"
		local self = setmetatable({}, OffscreenRenderTarget)
		self.renderer = renderer
		self.width = width
		self.height = height
		self.format = format
		self.final_layout = final_layout
		-- Create the image
		self.image = renderer.device:CreateImage(width, height, format, usage, "device_local", samples)
		-- Create image view
		self.image_view = self.image:CreateView()
		-- Create render pass for this format (with offscreen-appropriate final layout)
		self.render_pass = renderer.device:CreateRenderPass({format = format, color_space = "srgb_nonlinear"}, samples, final_layout)
		-- Create framebuffer
		self.framebuffer = renderer.device:CreateFramebuffer(self.render_pass, self.image_view.ptr[0], width, height, nil)
		-- Create command pool and buffer for offscreen rendering
		self.command_pool = renderer.device:CreateCommandPool(renderer.graphics_queue_family)
		self.command_buffer = self.command_pool:CreateCommandBuffer()
		return self
	end

	function OffscreenRenderTarget:GetImageView()
		return self.image_view
	end

	function OffscreenRenderTarget:GetRenderPass()
		return self.render_pass
	end

	function OffscreenRenderTarget:WriteMode(cmd)
		cmd:PipelineBarrier(
			{
				srcStage = "fragment",
				dstStage = "all_commands",
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "shader_read",
						dstAccessMask = "color_attachment_write",
						oldLayout = "shader_read_only_optimal",
						newLayout = "color_attachment_optimal",
					},
				},
			}
		)
	end

	function OffscreenRenderTarget:ReadMode(cmd)
		cmd:PipelineBarrier(
			{
				srcStage = "all_commands",
				dstStage = "fragment",
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "color_attachment_write",
						dstAccessMask = "shader_read",
						oldLayout = "color_attachment_optimal",
						newLayout = "shader_read_only_optimal",
					},
				},
			}
		)
	end

	function OffscreenRenderTarget:BeginFrame()
		self.command_buffer:Reset()
		self.command_buffer:Begin()
		return true
	end

	function OffscreenRenderTarget:EndFrame()
		self.command_buffer:End()
		local fence = self.renderer.device:CreateFence()
		self.renderer.queue:SubmitAndWait(self.renderer.device, self.command_buffer, fence)
	end

	function OffscreenRenderTarget:GetCommandBuffer()
		return self.command_buffer
	end

	function OffscreenRenderTarget:GetFramebuffer()
		return self.framebuffer
	end

	function OffscreenRenderTarget:GetExtent()
		return {width = self.width, height = self.height}
	end

	function Renderer:CreateOffscreenRenderTarget(width, height, format, config)
		return OffscreenRenderTarget.New(self, width, height, format, config)
	end
end

function Renderer:TransitionImageLayout(image, old_layout, new_layout, src_stage, dst_stage)
	local cmd = self:GetCommandBuffer()
	src_stage = src_stage or "all_commands"
	dst_stage = dst_stage or "all_commands"
	local src_access = "none"
	local dst_access = "none"

	-- Determine access masks based on layouts
	if old_layout == "color_attachment_optimal" then
		src_access = "color_attachment_write"
	elseif old_layout == "shader_read_only_optimal" then
		src_access = "shader_read"
	end

	if new_layout == "color_attachment_optimal" then
		dst_access = "color_attachment_write"
	elseif new_layout == "shader_read_only_optimal" then
		dst_access = "shader_read"
	end

	cmd:PipelineBarrier(
		{
			srcStage = src_stage,
			dstStage = dst_stage,
			imageBarriers = {
				{
					image = image,
					srcAccessMask = src_access,
					dstAccessMask = dst_access,
					oldLayout = old_layout,
					newLayout = new_layout,
				},
			},
		}
	)
end

function Renderer:GetExtent()
	return self.surface_capabilities[0].currentExtent
end

function Renderer:WaitForIdle()
	self.device:WaitIdle()
end

do
	local Pipeline = {}
	Pipeline.__index = Pipeline

	function Pipeline.New(renderer, config)
		local self = setmetatable({}, Pipeline)
		local uniform_buffers = {}
		local shader_modules = {}
		local layout = {}
		local pool_sizes = {}
		local push_constant_ranges = {}

		for i, stage in ipairs(config.shader_stages) do
			shader_modules[i] = {
				type = stage.type,
				module = renderer.device:CreateShaderModule(stage.code, stage.type),
			}

			if stage.descriptor_sets then
				local counts = {}

				for i, ds in ipairs(stage.descriptor_sets) do
					layout[i] = {
						binding_index = ds.binding_index,
						type = ds.type,
						stageFlags = stage.type,
						count = 1,
					}
					counts[ds.type] = (counts[ds.type] or 0) + 1

					if ds.type == "uniform_buffer" then
						uniform_buffers[ds.binding_index] = ds.args[1]
					end
				end

				for type, count in pairs(counts) do
					table.insert(pool_sizes, {type = type, count = count})
				end
			end

			if stage.push_constants then
				table.insert(
					push_constant_ranges,
					{
						stage = stage.type,
						offset = stage.push_constants.offset or 0,
						size = stage.push_constants.size,
					}
				)
			end
		end

		local descriptorSetLayout = renderer.device:CreateDescriptorSetLayout(layout)
		local pipelineLayout = renderer.device:CreatePipelineLayout({descriptorSetLayout}, push_constant_ranges)
		local descriptorPool = renderer.device:CreateDescriptorPool(pool_sizes, 1)
		local descriptorSet = descriptorPool:AllocateDescriptorSet(descriptorSetLayout)
		local vertex_bindings
		local vertex_attributes

		-- Update descriptor sets
		for i, stage in ipairs(config.shader_stages) do
			if stage.descriptor_sets then
				for i, ds in ipairs(stage.descriptor_sets) do
					renderer.device:UpdateDescriptorSet(ds.type, descriptorSet, ds.binding_index, unpack(ds.args))
				end
			end

			if stage.type == "vertex" then
				vertex_bindings = stage.bindings
				vertex_attributes = stage.attributes
			end
		end

		pipeline = renderer.device:CreateGraphicsPipeline(
			{
				shaderModules = shader_modules,
				extent = config.extent,
				vertexBindings = vertex_bindings,
				vertexAttributes = vertex_attributes,
				input_assembly = config.input_assembly,
				rasterizer = config.rasterizer,
				viewport = config.viewport,
				scissor = config.scissor,
				multisampling = config.multisampling,
				color_blend = config.color_blend,
				dynamic_states = config.dynamic_states,
				depth_stencil = config.depth_stencil,
			},
			{config.render_pass},
			pipelineLayout
		)
		self.pipeline = pipeline
		self.descriptor_sets = {descriptorSet}
		self.pipeline_layout = pipelineLayout
		self.renderer = renderer
		self.config = config
		self.uniform_buffers = uniform_buffers
		self.descriptorSetLayout = descriptorSetLayout
		self.descriptorPool = descriptorPool
		return self
	end

	function Pipeline:UpdateDescriptorSet(type, index, binding_index, ...)
		self.renderer.device:UpdateDescriptorSet(type, self.descriptor_sets[index], binding_index, ...)
	end

	function Pipeline:PushConstants(cmd, stage, binding_index, data, data_size)
		cmd:PushConstants(self.pipeline_layout, stage, binding_index, data_size or ffi.sizeof(data), data)
	end

	function Pipeline:GetUniformBuffer(binding_index)
		local ub = self.uniform_buffers[binding_index]

		if not ub then
			error("Invalid uniform buffer binding index: " .. binding_index)
		end

		return ub
	end

	function Renderer:CreatePipeline(...)
		return Pipeline.New(self, ...)
	end

	function Pipeline:Bind(cmd)
		cmd:BindPipeline(self.pipeline, "graphics")
		cmd:BindDescriptorSets("graphics", self.pipeline_layout, self.descriptor_sets, 0)
	end
end

function Renderer:CreateBuffer(config)
	local byte_size
	local data = config.data

	if data then
		if type(data) == "table" then
			data = ffi.new((config.data_type or "float") .. "[" .. (#data) .. "]", data)
			byte_size = ffi.sizeof(data)
		else
			byte_size = config.byte_size or ffi.sizeof(data)
		end
	end

	local buffer = self.device:CreateBuffer(byte_size, config.buffer_usage, config.memory_property)

	if data then buffer:CopyData(data, byte_size) end

	return buffer
end

function Renderer:UploadToImage(image, data, width, height)
	local pixel_count = width * height
	-- Create staging buffer
	local staging_buffer = self.device:CreateBuffer(pixel_count * 4, "transfer_src", {"host_visible", "host_coherent"})
	staging_buffer:CopyData(data, pixel_count * 4)
	-- Copy to image using command buffer
	local cmd_pool = self.device:CreateCommandPool(self.graphics_queue_family)
	local cmd = cmd_pool:CreateCommandBuffer()
	cmd:Begin()
	-- Transition image to transfer dst
	cmd:PipelineBarrier(
		{
			srcStage = "compute",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = image,
					srcAccessMask = "none",
					dstAccessMask = "transfer_write",
					oldLayout = "undefined",
					newLayout = "transfer_dst_optimal",
				},
			},
		}
	)
	-- Copy buffer to image
	cmd:CopyBufferToImage(staging_buffer, image, width, height)
	-- Determine final layout based on image usage
	local final_layout = "general"
	local dst_stage = "compute"

	if type(image.usage) == "table" then
		for _, usage in ipairs(image.usage) do
			if usage == "sampled" then
				final_layout = "shader_read_only_optimal"
				dst_stage = "fragment"

				break
			end
		end
	end

	-- Transition to final layout
	cmd:PipelineBarrier(
		{
			srcStage = "transfer",
			dstStage = dst_stage,
			imageBarriers = {
				{
					image = image,
					srcAccessMask = "transfer_write",
					dstAccessMask = "shader_read",
					oldLayout = "transfer_dst_optimal",
					newLayout = final_layout,
				},
			},
		}
	)
	cmd:End()
	-- Submit and wait
	local fence = self.device:CreateFence()
	self.queue:SubmitAndWait(self.device, cmd, fence)
end

do
	local WindowRenderTarget = {}
	WindowRenderTarget.__index = WindowRenderTarget

	function WindowRenderTarget.New(renderer)
		local self = setmetatable({}, WindowRenderTarget)
		self.renderer = renderer
		self.current_frame = 0
		-- Create depth buffer
		local extent = renderer.surface_capabilities[0].currentExtent
		local depth_format = "D32_SFLOAT"
		self.depth_image = renderer.device:CreateImage(
			extent.width,
			extent.height,
			depth_format,
			{"depth_stencil_attachment"},
			"device_local"
		)
		self.depth_image_view = renderer.device:CreateImageView(self.depth_image.ptr[0], {format = depth_format, aspect = "depth"})
		-- Create render pass for swapchain format with depth
		self.render_pass = renderer.device:CreateRenderPass(renderer.surface_formats[renderer.config.surface_format_index], nil, nil, depth_format)
		-- Create image views for swapchain images
		self.image_views = {}

		for _, swapchain_image in ipairs(renderer.swapchain_images) do
			table.insert(
				self.image_views,
				renderer.device:CreateImageView(
					swapchain_image,
					renderer.surface_formats[renderer.config.surface_format_index].format
				)
			)
		end

		-- Create framebuffers
		self.framebuffers = {}

		for i, imageView in ipairs(self.image_views) do
			table.insert(
				self.framebuffers,
				renderer.device:CreateFramebuffer(
					self.render_pass,
					imageView.ptr[0],
					extent.width,
					extent.height,
					nil,
					self.depth_image_view.ptr[0]
				)
			)
		end

		-- Initialize per-frame resources
		self.command_buffers = {}
		self.image_available_semaphores = {}
		self.render_finished_semaphores = {}
		self.in_flight_fences = {}

		for i = 1, #renderer.swapchain_images do
			self.command_buffers[i] = renderer.command_pool:CreateCommandBuffer()
			self.image_available_semaphores[i] = renderer.device:CreateSemaphore()
			self.render_finished_semaphores[i] = renderer.device:CreateSemaphore()
			self.in_flight_fences[i] = renderer.device:CreateFence()
		end

		return self
	end

	function WindowRenderTarget:GetSwapChainImage()
		return self.renderer.swapchain_images[self.image_index]
	end

	function WindowRenderTarget:GetRenderPass()
		return self.render_pass
	end

	function WindowRenderTarget:BeginFrame()
		-- Use round-robin frame index
		self.current_frame = (self.current_frame % #self.renderer.swapchain_images) + 1
		-- Wait for the fence for this frame FIRST
		self.in_flight_fences[self.current_frame]:Wait()
		-- Acquire next image
		local image_index = self.renderer.swapchain:GetNextImage(self.image_available_semaphores[self.current_frame])

		-- Check if swapchain needs recreation
		if image_index == nil then
			self:RecreateSwapchain()
			return nil
		end

		self.image_index = image_index + 1
		-- Reset and begin command buffer for this frame
		self.command_buffers[self.current_frame]:Reset()
		self.command_buffers[self.current_frame]:Begin()
		return true
	end

	function WindowRenderTarget:EndFrame()
		local command_buffer = self.command_buffers[self.current_frame]
		command_buffer:End()
		-- Submit command buffer with current frame's semaphores
		self.renderer.queue:Submit(
			command_buffer,
			self.image_available_semaphores[self.current_frame],
			self.render_finished_semaphores[self.current_frame],
			self.in_flight_fences[self.current_frame]
		)

		-- Present and recreate swapchain if needed
		if
			not self.renderer.swapchain:Present(
				self.render_finished_semaphores[self.current_frame],
				self.renderer.queue,
				ffi.new("uint32_t[1]", self.image_index - 1)
			)
		then
			self:RecreateSwapchain()
		end
	end

	function WindowRenderTarget:RecreateSwapchain()
		self.renderer:RecreateSwapchain()
		-- Recreate depth buffer with new extent
		local extent = self.renderer.surface_capabilities[0].currentExtent
		local depth_format = "D32_SFLOAT"
		self.depth_image = self.renderer.device:CreateImage(
			extent.width,
			extent.height,
			depth_format,
			{"depth_stencil_attachment"},
			"device_local"
		)
		self.depth_image_view = self.renderer.device:CreateImageView(self.depth_image.ptr[0], {format = depth_format, aspect = "depth"})
		-- Recreate image views
		self.image_views = {}

		for _, swapchain_image in ipairs(self.renderer.swapchain_images) do
			table.insert(
				self.image_views,
				self.renderer.device:CreateImageView(
					swapchain_image,
					self.renderer.surface_formats[self.renderer.config.surface_format_index].format
				)
			)
		end

		-- Recreate framebuffers
		self.framebuffers = {}

		for i, imageView in ipairs(self.image_views) do
			table.insert(
				self.framebuffers,
				self.renderer.device:CreateFramebuffer(
					self.render_pass,
					imageView.ptr[0],
					extent.width,
					extent.height,
					nil,
					self.depth_image_view.ptr[0]
				)
			)
		end

		-- Recreate per-frame resources if image count changed
		local new_count = #self.renderer.swapchain_images
		local old_count = #self.command_buffers

		if old_count ~= new_count then
			self.command_buffers = {}
			self.image_available_semaphores = {}
			self.render_finished_semaphores = {}
			self.in_flight_fences = {}

			for i = 1, new_count do
				self.command_buffers[i] = self.renderer.command_pool:CreateCommandBuffer()
				self.image_available_semaphores[i] = self.renderer.device:CreateSemaphore()
				self.render_finished_semaphores[i] = self.renderer.device:CreateSemaphore()
				self.in_flight_fences[i] = self.renderer.device:CreateFence()
			end

			self.current_frame = 0
		end
	end

	function WindowRenderTarget:GetCommandBuffer()
		return self.command_buffers[self.current_frame]
	end

	function WindowRenderTarget:GetFramebuffer()
		return self.framebuffers[self.image_index]
	end

	function WindowRenderTarget:GetExtent()
		return self.renderer:GetExtent()
	end

	function Renderer:CreateWindowRenderTarget()
		return WindowRenderTarget.New(self)
	end
end

do
	local ComputePipeline = {}
	ComputePipeline.__index = ComputePipeline

	function ComputePipeline.New(renderer, config)
		local self = setmetatable({}, ComputePipeline)
		self.renderer = renderer
		self.config = config
		self.current_image_index = 1
		-- Create shader module
		local shader = renderer.device:CreateShaderModule(config.shader, "compute")
		-- Create descriptor set layout
		local descriptor_set_layout = renderer.device:CreateDescriptorSetLayout(config.descriptor_layout)
		local pipeline_layout = renderer.device:CreatePipelineLayout({descriptor_set_layout})
		-- Create compute pipeline
		local pipeline = renderer.device:CreateComputePipeline(shader, pipeline_layout)
		-- Determine number of descriptor sets (for ping-pong or single set)
		local descriptor_set_count = config.descriptor_set_count or 1
		-- Create descriptor pool
		local descriptor_pool = renderer.device:CreateDescriptorPool(config.descriptor_pool, descriptor_set_count)
		-- Create descriptor sets
		local descriptor_sets = {}

		for i = 1, descriptor_set_count do
			descriptor_sets[i] = descriptor_pool:AllocateDescriptorSet(descriptor_set_layout)
		end

		self.shader = shader
		self.pipeline = pipeline
		self.pipeline_layout = pipeline_layout
		self.descriptor_set_layout = descriptor_set_layout
		self.descriptor_pool = descriptor_pool
		self.descriptor_sets = descriptor_sets
		self.workgroup_size = config.workgroup_size or 16
		return self
	end

	function ComputePipeline:UpdateDescriptorSet(type, index, binding_index, ...)
		self.renderer.device:UpdateDescriptorSet(type, self.descriptor_sets[index], binding_index, ...)
	end

	function ComputePipeline:Dispatch(cmd)
		-- Bind compute pipeline
		cmd:BindPipeline(self.pipeline, "compute")
		cmd:BindDescriptorSets(
			"compute",
			self.pipeline_layout,
			{self.descriptor_sets[self.current_image_index]},
			0
		)
		local extent = self.renderer:GetExtent()
		local w = tonumber(extent.width)
		local h = tonumber(extent.height)
		-- Dispatch compute shader
		local group_count_x = math.ceil(w / self.workgroup_size)
		local group_count_y = math.ceil(h / self.workgroup_size)
		cmd:Dispatch(group_count_x, group_count_y, 1)
	end

	function ComputePipeline:SwapImages()
		-- Swap images for next frame (useful for ping-pong patterns)
		self.current_image_index = (self.current_image_index % #self.descriptor_sets) + 1
	end

	function Renderer:CreateComputePipeline(...)
		return ComputePipeline.New(self, ...)
	end
end

return Renderer
