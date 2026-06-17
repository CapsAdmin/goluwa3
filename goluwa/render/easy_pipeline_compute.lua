local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local render = import("goluwa/render/render.lua")
local GraphicsPipeline = import("goluwa/render/vulkan/graphics_pipeline.lua")
local UniformBuffer = import("goluwa/render/uniform_buffer.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local glsl_meta = import("goluwa/render/glsl_metadata.lua")
local base = import("goluwa/render/easy_pipeline_base.lua")
local EasyPipeline = base.EasyPipeline
local resolve_draw_frame_index = base.resolve_draw_frame_index
local resolve_draw_framebuffer = base.resolve_draw_framebuffer
local get_compute_sampled_descriptor = base.get_compute_sampled_descriptor

local EasyPipelineCompute = prototype.CreateTemplate("render_easy_pipeline_compute")

do
	EasyPipelineCompute.Base = EasyPipeline

	function EasyPipelineCompute:UploadConstants()
		self.dynamic_offsets = nil

		if self.uniform_buffer_order[1] then
			local offsets = {}
			local frame_index = render.GetCurrentFrame() or 1

			for i, name in ipairs(self.uniform_buffer_order) do
				local info = self.uniform_buffer_types[name]
				local data = info.ubo:GetData()
				base.upload_block(self, info.block, data, name)
				offsets[i] = info.ubo:Upload(frame_index)
			end

			self.dynamic_offsets = offsets
		end

		self:UploadPushConstants()
	end

	function EasyPipelineCompute:Dispatch(cmd, group_count_x, group_count_y, group_count_z, frame_index, dynamic_offsets)
		if not self.pipeline or not self.pipeline.Dispatch then
			error("EasyPipeline:Dispatch is only available for compute pipelines", 2)
		end

		cmd = cmd or render.GetCommandBuffer()
		render.PushCommandBuffer(cmd)

		if self.on_draw then
			self:on_draw(cmd)
		else
			self:UploadConstants()
			self.pipeline:Dispatch(
				cmd,
				group_count_x or 1,
				group_count_y or 1,
				group_count_z or 1,
				frame_index,
				dynamic_offsets or self.dynamic_offsets
			)
		end

		render.PopCommandBuffer()
	end

	function EasyPipelineCompute:DispatchForSize(cmd, width, height, depth, frame_index, dynamic_offsets)
		if not self.pipeline or not self.pipeline.DispatchForSize then
			error("EasyPipeline:DispatchForSize is only available for compute pipelines", 2)
		end

		cmd = cmd or render.GetCommandBuffer()
		render.PushCommandBuffer(cmd)

		if self.on_draw then
			self:on_draw(cmd)
		else
			self:UploadConstants()
			self.pipeline:DispatchForSize(
				cmd,
				width,
				height,
				depth,
				frame_index,
				dynamic_offsets or self.dynamic_offsets
			)
		end

		render.PopCommandBuffer()
	end

	-- Compute constructor
	function EasyPipelineCompute.Compute(config)
		local write = config.write
		local source = config.source

		if type(config.block) == "table" then
			write = write or config.block.write
			source = source or config.block.source
		end

		local self = EasyPipelineCompute:CreateObject()
		self.on_draw = config.on_draw or nil
		self.config = config
		local block = config.block or {}
		local uniform_buffers = {}
		local uniform_buffer_types = {}
		local uniform_buffer_order = {}

		-- Process push constant block using shared builder
		local push_constant_size = 0
		if #block > 0 then
			block.name = "_u_compute"
			block._is_unnamed = true
			-- Transfer write/source from config level to block level
			if block.write == nil and write then block.write = write end
			if block.source == nil and source then block.source = source end
			local struct_name, ctype = EasyPipeline.BuildPushConstantBlock(block.name, block)
			push_constant_size = ffi.sizeof(ctype)
			self.push_constant_structs = {[struct_name] = ctype()}
			self.push_constant_blocks = {[block.name] = block}
			self.push_constant_block_order = {block.name}
			self.push_constant_block_offsets = {[block.name] = 0}
			self.push_constant_size = push_constant_size
			self.push_constant_source = source
			self.push_constant_write = write
		else
			self.push_constant_structs = {}
			self.push_constant_blocks = {}
			self.push_constant_block_order = {}
			self.push_constant_block_offsets = {}
			self.push_constant_size = 0
			self.push_constant_source = nil
			self.push_constant_write = nil
		end

		self.uniform_buffer_order = uniform_buffer_order
		self.uniform_buffer_types = uniform_buffer_types
		self.uniform_buffers = uniform_buffers
		self.push_constant_cache_by_cmd = setmetatable({}, {__mode = "k"})
		self._push_constant_stages = {"compute"}
		local bindless_descriptor_capacities = render.GetBindlessDescriptorCapacities()
		local bindless_texture_capacity = bindless_descriptor_capacities.textures
		local bindless_cubemap_capacity = bindless_descriptor_capacities.cubemaps
		local shader_header = glsl_meta.build_shader_header(bindless_texture_capacity, bindless_cubemap_capacity)
		local push_constant_glsl = ""

		if #block > 0 then
			push_constant_glsl = "layout(push_constant, scalar) uniform ComputeConstants {\n" .. glsl_meta.build_glsl_fields(block.block) .. "} compute;\n\n"
		end

		local descriptor_sets = glsl_meta.build_base_descriptor_sets(bindless_texture_capacity, bindless_cubemap_capacity)

		for _, ds in ipairs(config.descriptor_sets or {}) do
			descriptor_sets[#descriptor_sets + 1] = ds
		end

		for _, block_info in ipairs(config.uniform_buffers or {}) do
			if block_info.name == nil then
				error("EasyPipeline.Compute: uniform buffer is missing a name", 2)
			end

			local info = {}

			for key, value in pairs(block_info) do
				info[key] = value
			end

			if info.binding_index == nil then
				error(
					"EasyPipeline.Compute: uniform buffer " .. tostring(info.name) .. " is missing binding_index",
					2
				)
			end

			glsl_meta.hoist_inline_block_metadata(info)
			info.block = glsl_meta.flatten_fields(info.block)

			if not info.block[1] then
				error(
					"EasyPipeline.Compute: uniform buffer " .. tostring(info.name) .. " has no fields",
					2
				)
			end

			local ffi_code = glsl_meta.build_ffi_struct("scalar", info.block)
			local glsl_fields, glsl_structs = glsl_meta.build_glsl_fields(info.block)
			local ubo = UniformBuffer.New(ffi_code)
			info.source = glsl_meta.normalize_block_source(
				info,
				ffi.sizeof(ubo.struct),
				glsl_meta.get_scalar_block_alignment(info.block),
				"uniform buffer block"
			)
			local block_type_name = glsl_meta.normalize_block_type_name(info.name)
			uniform_buffer_order[#uniform_buffer_order + 1] = info.name
			uniform_buffer_types[info.name] = {
				ubo = ubo,
				block = info,
				debug_name = (config.name or "pipeline") .. ".ubo." .. info.name,
				field_descriptors = glsl_meta.build_field_descriptors(ubo.struct, info.block),
				glsl = string.format(
					"%slayout(scalar, set = %d, binding = %d) uniform %s {\n%s} %s;",
					glsl_structs,
					info.set_index or 0,
					info.binding_index,
					block_type_name,
					glsl_fields,
					info.name
				),
			}
			uniform_buffers[info.name] = ubo
			descriptor_sets[#descriptor_sets + 1] = {
				type = "uniform_buffer_dynamic",
				binding_index = info.binding_index,
				set_index = info.set_index or 0,
				args = {ubo.buffer, ubo.aligned_size},
			}
		end

		local local_size = config.LocalSize or config.local_size or config.workgroup_size
		local local_size_glsl = ""
		local uniform_buffer_glsl = ""

		if local_size then
			if type(local_size) == "number" then
				local_size = {x = local_size, y = local_size, z = 1}
			else
				local_size = {
					x = local_size.x or local_size[1] or 8,
					y = local_size.y or local_size[2] or 8,
					z = local_size.z or local_size[3] or 1,
				}
			end

			local_size_glsl = string.format(
				"layout(local_size_x = %d, local_size_y = %d, local_size_z = %d) in;\n\n",
				local_size.x,
				local_size.y,
				local_size.z
			)
		end

		for _, name in ipairs(uniform_buffer_order) do
			uniform_buffer_glsl = uniform_buffer_glsl .. uniform_buffer_types[name].glsl .. "\n\n"
		end

		self.pipeline = render.CreateComputePipeline{
			DescriptorSetCount = config.DescriptorSetCount or
				(
					config.descriptor_set_count
				)
				or
				(
					render.target:IsValid() and
					render.target.image_count
				)
				or
				1,
			LocalSize = local_size,
			shader_stages = {
				{
					type = "compute",
					code = shader_header .. (
							config.custom_declarations or
							""
						) .. local_size_glsl .. push_constant_glsl .. uniform_buffer_glsl .. (
							config.shader or
							""
						),
					descriptor_sets = descriptor_sets,
					push_constants = push_constant_size > 0 and
						{
							offset = 0,
							size = push_constant_size,
						} or
						nil,
				},
			},
		}
		return self
	end

	-- Build descriptor sets for ComputePass from storage/sampled image bindings
	local function build_compute_pass_descriptor_sets(config)
		local descriptor_sets = {}

		for _, ds in ipairs(config.descriptor_sets or {}) do
			table.insert(descriptor_sets, ds)
		end

		for _, info in ipairs(config.storage_images or config.StorageImages or {}) do
			table.insert(
				descriptor_sets,
				{
					type = "storage_image",
					binding_index = info.binding_index,
					stageFlags = info.stageFlags or "compute",
					set_index = info.set_index or 0,
				}
			)
		end

		for _, info in ipairs(config.sampled_images or config.SampledImages or {}) do
			table.insert(
				descriptor_sets,
				{
					type = "combined_image_sampler",
					binding_index = info.binding_index,
					stageFlags = info.stageFlags or "compute",
					set_index = info.set_index or 0,
				}
			)
		end

		return descriptor_sets
	end

	-- ComputePass: special compute pipeline with framebuffer + image transition handling
	function EasyPipelineCompute.ComputePass(config)
		local compute_config = table.copy(config)
		local storage_images = {}
		local sampled_images = {}
		local output_bindings = config.storage_images or config.StorageImages or {}
		local sampled_bindings = config.sampled_images or config.SampledImages or {}
		local declared_descriptor_sets = build_compute_pass_descriptor_sets(config)
		local user_on_draw = config.on_draw or nil

		for _, info in ipairs(output_bindings) do
			storage_images[#storage_images + 1] = {
				binding_index = info.binding_index,
				set_index = info.set_index or 0,
				attachment = info.attachment,
				get_texture = info.get_texture,
				dst_stage = info.dst_stage,
			}
		end

		for _, info in ipairs(sampled_bindings) do
			sampled_images[#sampled_images + 1] = {
				binding_index = info.binding_index,
				set_index = info.set_index or 0,
				get_texture = info.get_texture,
				get_descriptor = info.get_descriptor,
			}
		end

		compute_config.descriptor_sets = declared_descriptor_sets
		compute_config.on_draw = nil
		local compute_pass_frame_span = math.max(render.GetSwapchainImageCount() or 1, 1)
		local compute_pass_slots_per_frame = config.DescriptorSetsPerFrame or config.descriptor_sets_per_frame or 16

		if
			compute_config.DescriptorSetCount == nil and
			compute_config.descriptor_set_count == nil
		then
			compute_config.DescriptorSetCount = math.max(
				compute_pass_frame_span * compute_pass_slots_per_frame,
				config.framebuffer_count or 1,
				compute_pass_frame_span
			)
		end

		local self = EasyPipelineCompute.Compute(compute_config)
		self.config = config
		self.actual_color_formats, self.debug_views = glsl_meta.get_color_formats(config)
		self.on_pre_draw = config.on_pre_draw or nil
		self.on_draw = user_on_draw
		self.storage_images = storage_images
		self.sampled_images = sampled_images
		self.compute_pass_frame_span = compute_pass_frame_span
		self.compute_pass_slots_per_frame = compute_pass_slots_per_frame

		if
			not config.dont_create_framebuffers and
			(
				#self.actual_color_formats > 0 or
				config.DepthFormat
			)
		then
			self:RecreateFramebuffers()

			if not self.config.FramebufferSize then
				self:AddGlobalEvent("WindowFramebufferResized")
			end
		end

		return self
	end

	function EasyPipelineCompute:RecreateFramebuffers()
		self:CreateOwnedFramebuffers({color_image_usage = {"storage"}})
	end

	function EasyPipelineCompute:Draw(cmd, framebuffer, frame_index)
		cmd = cmd or render.GetCommandBuffer()
		local resolved_frame_index = resolve_draw_frame_index(self, frame_index)
		local descriptor_count = self:GetDescriptorSetCount()
		local fb = resolve_draw_framebuffer(self, framebuffer, resolved_frame_index)

		if not fb then
			error(
				"EasyPipeline.ComputePass: Draw requires an owned framebuffer or explicit framebuffer",
				2
			)
		end

		render.PushCommandBuffer(cmd)
		local current_frame_index = render.GetCurrentFrame() or frame_index or 1

		if current_frame_index < 1 then current_frame_index = 1 end

		if current_frame_index > self.compute_pass_frame_span then
			current_frame_index = ((current_frame_index - 1) % self.compute_pass_frame_span) + 1
		end

		if self._compute_pass_descriptor_cmd ~= cmd then
			self._compute_pass_descriptor_cmd = cmd
			self._compute_pass_descriptor_slot = 0
		end

		local descriptor_slot = (self._compute_pass_descriptor_slot or 0) + 1
		local descriptor_frame_index = ((current_frame_index - 1) * self.compute_pass_slots_per_frame) + descriptor_slot

		if
			descriptor_count and
			descriptor_count > 0 and
			descriptor_frame_index > descriptor_count
		then
			error(
				string.format(
					"EasyPipeline.ComputePass: descriptor set ring exhausted for frame %d (%d > %d)",
					current_frame_index,
					descriptor_frame_index,
					descriptor_count
				),
				2
			)
		end

		self._compute_pass_descriptor_slot = descriptor_slot
		local transitioned = {}

		if self.on_pre_draw then
			self.on_pre_draw(self, cmd, resolved_frame_index, descriptor_frame_index)
		end

		for _, info in ipairs(self.storage_images) do
			local texture = info.get_texture and
				info.get_texture(self, fb, resolved_frame_index) or
				fb:GetAttachment(info.attachment or 1)
			assert(
				texture,
				self.name .. " is missing compute output texture for binding " .. tostring(info.binding_index)
			)
			render.TransitionResourceToComputeStorage(texture, {cmd = cmd})
			self:UpdateDescriptorSet(
				"storage_image",
				descriptor_frame_index,
				info.binding_index,
				info.set_index,
				texture:GetView()
			)
			transitioned[#transitioned + 1] = {
				texture = texture,
				dst_stage = info.dst_stage,
			}
		end

		for _, info in ipairs(self.sampled_images) do
			local view
			local sampler

			if info.get_descriptor then
				local descriptor = info.get_descriptor(self, fb, resolved_frame_index)

				if type(descriptor) == "table" then
					view = descriptor[1]
					sampler = descriptor[2]
				end
			elseif info.get_texture then
				view, sampler = get_compute_sampled_descriptor(info.get_texture(self, fb, resolved_frame_index))
			else
				view, sampler = get_compute_sampled_descriptor(nil)
			end

			if not view or not sampler then
				view, sampler = get_compute_sampled_descriptor(nil)
			end

			self:UpdateDescriptorSet(
				"combined_image_sampler",
				descriptor_frame_index,
				info.binding_index,
				info.set_index,
				view,
				sampler
			)
		end

		if self.on_draw then
			self:on_draw(cmd, fb, resolved_frame_index, descriptor_frame_index)
		else
			self:UploadConstants()
			self.pipeline:DispatchForSize(
				cmd,
				fb.width,
				fb.height,
				1,
				descriptor_frame_index,
				self.dynamic_offsets
			)
		end

		for _, info in ipairs(transitioned) do
			render.TransitionResourceFrom(
				info.texture,
				"shader_read_only_optimal",
				{
					cmd = cmd,
					srcStage = "compute",
					srcAccess = "shader_write",
					dstStage = info.dst_stage or "fragment",
					dstAccess = "shader_read",
				}
			)
		end

		render.PopCommandBuffer()
	end

	EasyPipelineCompute:Register()
end

return EasyPipelineCompute
