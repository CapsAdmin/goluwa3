local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local render = import("goluwa/render/render.lua")
local upload_probe = import("goluwa/render/upload_probe.lua")
local GraphicsPipeline = import("goluwa/render/vulkan/graphics_pipeline.lua")
local UniformBuffer = import("goluwa/render/uniform_buffer.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local system = import("goluwa/system.lua")
local timer = import("goluwa/timer.lua")
local glsl_meta = import("goluwa/render/glsl_metadata.lua")

local function get_compute_sampled_descriptor(texture)
	texture = texture or render.GetErrorTexture()
	assert(texture, "missing texture for compute sampled descriptor")
	return texture:GetView(),
	texture.sampler or render.CreateSampler(texture:GetSamplerConfig())
end

local function get_constant_stage_config(config, stage_name)
	return config[stage_name] or
		(
			stage_name == "mesh_ext" and
			config.mesh
		)
		or
		(
			stage_name == "task_ext" and
			config.task
		)
end

local function resolve_draw_frame_index(self, frame_index)
	if frame_index then return frame_index end

	if self.framebuffers and self.framebuffers[2] then
		return system.GetFrameNumber() % #self.framebuffers + 1
	end

	return render.GetCurrentFrame()
end

local function resolve_draw_framebuffer(self, framebuffer, frame_index)
	local fb = framebuffer

	if not fb then
		local resolved_frame_index = resolve_draw_frame_index(self, frame_index)

		if resolved_frame_index then
			fb = self:GetFramebuffer(resolved_frame_index)
		elseif self.framebuffers then
			fb = self:GetFramebuffer(system.GetFrameNumber() % #self.framebuffers + 1)
		end
	end

	return fb
end



local function assign_auto_binding(block, next_auto_binding, uniform_buffer_types)
	if block.binding_index == nil then
		local existing = uniform_buffer_types[block.name]

		if existing then
			block.binding_index = existing.block.binding_index
		else
			block.binding_index = next_auto_binding
			next_auto_binding = next_auto_binding + 1
		end
	end

	return next_auto_binding
end

local function upload_block(self, block, data, name)
	if block.source then
		local source_data = block.source.get(self, block)

		if source_data == nil then
			error("block source returned nil for " .. tostring(name), 2)
		end

		ffi.copy(data, ffi.cast("uint8_t *", source_data) + block.source.offset, ffi.sizeof(data))
	end

	if block.write then block.write(self, data, block) end
end

-- Resolve constant placement (push vs uniform buffer) based on budget and preferences
-- Upload and cache a uniform buffer block, returning the dynamic offset
-- This is a hot code path - no closures inside
local function upload_ubo(
	self,
	info,
	frame_index,
	frame_number,
	probe_enabled,
	probe_record_upload,
	probe_record_cache_access,
	persistent_bytes_equal
)
	local offset = nil
	local cache_key = nil
	local cache_hit = false
	local persistent_entry = nil
	local persistent_entries = nil
	local upload_scope = info.block.upload_scope

	if upload_scope == "frame" then
		cache_key = true
	elseif
		(
			upload_scope == "frame_keyed" or
			upload_scope == "persistent_keyed"
		)
		and
		info.block.upload_key
	then
		cache_key = info.block.upload_key(self, info.block)
	end

	if cache_key ~= nil then
		local cache = info.offsets

		if upload_scope == "frame" then
			if cache.frame_number == frame_number and cache.key == cache_key then
				offset = cache.offset
			end

			cache_hit = offset ~= nil
		elseif upload_scope == "frame_keyed" then
			if cache.frame_number ~= frame_number then
				cache.frame_number = frame_number
				cache.strong_entries = {}
				cache.weak_entries = setmetatable({}, {__mode = "k"})
			end

			local key_type = type(cache_key)
			local entries = (
					key_type == "table" or
					key_type == "userdata"
				)
				and
				cache.weak_entries or
				cache.strong_entries
			offset = entries[cache_key]
			cache_hit = offset ~= nil
		elseif upload_scope == "persistent_keyed" then
			cache.strong_entries = cache.strong_entries or {}
			cache.weak_entries = cache.weak_entries or setmetatable({}, {__mode = "k"})
			local key_type = type(cache_key)
			persistent_entries = (
					key_type == "table" or
					key_type == "userdata"
				)
				and
				cache.weak_entries or
				cache.strong_entries
			persistent_entry = persistent_entries[cache_key]

			if persistent_entry then
				offset = info.ubo:GetOffset(frame_index, persistent_entry.slot)
			end
		end
	end

	if upload_scope == "persistent_keyed" and cache_key ~= nil then
		local ubo_data = info.ubo:GetData()

		if info.block.source then
			local source_data = info.block.source.get(self, info.block)

			if source_data == nil then
				error("uniform buffer block source returned nil for " .. tostring(info.block.name), 2)
			end

			ffi.copy(
				ubo_data,
				ffi.cast("uint8_t *", source_data) + info.block.source.offset,
				ffi.sizeof(ubo_data)
			)
		end

		if info.block.write then info.block.write(self, ubo_data, info.block) end

		local src = ffi.cast("uint8_t *", ubo_data)

		if
			persistent_entry and
			persistent_entry.snapshot and
			persistent_bytes_equal(persistent_entry.snapshot, src, info.ubo.size)
		then
			cache_hit = true
			offset = info.ubo:GetOffset(frame_index, persistent_entry.slot)
		else
			cache_hit = false

			if probe_enabled then
				probe_record_upload(info.debug_name, info.field_descriptors, ubo_data, info.ubo.size, cache_key)
			end

			if persistent_entry == nil then
				persistent_entry = {
					slot = info.ubo:AllocatePersistentSlot(),
					snapshot = ffi.new("uint8_t[?]", info.ubo.size),
				}
				persistent_entries[cache_key] = persistent_entry
			end

			info.ubo:UploadPersistent(persistent_entry.slot)
			ffi.copy(persistent_entry.snapshot, src, info.ubo.size)
			offset = info.ubo:GetOffset(frame_index, persistent_entry.slot)
		end
	elseif offset == nil then
		local ubo_data = info.ubo:GetData()

		if info.block.source then
			local source_data = info.block.source.get(self, info.block)

			if source_data == nil then
				error("uniform buffer block source returned nil for " .. tostring(info.block.name), 2)
			end

			ffi.copy(
				ubo_data,
				ffi.cast("uint8_t *", source_data) + info.block.source.offset,
				ffi.sizeof(ubo_data)
			)
		end

		if info.block.write then info.block.write(self, ubo_data, info.block) end

		if probe_enabled then
			probe_record_upload(info.debug_name, info.field_descriptors, ubo_data, info.ubo.size, cache_key)
		end

		offset = info.ubo:Upload(frame_index)

		if upload_scope == "frame" then
			local cache = info.offsets
			cache.frame_number = frame_number
			cache.key = true
			cache.offset = offset
		elseif upload_scope == "frame_keyed" and cache_key ~= nil then
			local cache = info.offsets

			if cache.frame_number ~= frame_number then
				cache.frame_number = frame_number
				cache.strong_entries = {}
				cache.weak_entries = setmetatable({}, {__mode = "k"})
			end

			local key_type = type(cache_key)
			local entries = (
					key_type == "table" or
					key_type == "userdata"
				)
				and
				cache.weak_entries or
				cache.strong_entries
			entries[cache_key] = offset
		end
	end

	if probe_enabled then
		probe_record_cache_access(info.debug_name, cache_key, cache_hit)
	end

	return offset
end

local function resolve_constant_placement(config, possible_stages)
	local placement = config.ConstantPlacement or {}
	local push_budget = placement.push_budget

	if push_budget == nil or push_budget == "device" then
		push_budget = render.GetDevice().physical_device:GetProperties().limits.maxPushConstantsSize
	end

	push_budget = assert(
		tonumber(push_budget),
		"EasyPipeline.New: ConstantPlacement.push_budget must be a number or 'device'"
	)
	push_budget = push_budget - math.max(0, tonumber(placement.reserve_push_bytes) or 0)

	if push_budget < 0 then push_budget = 0 end

	local fallback_storage = placement.fallback or "uniform_buffer"
	local default_mode = placement.mode or "auto"
	local constant_blocks = {}
	local auto_blocks = {}
	local explicit_push_span = 0
	local hard_push_size = 0
	local constant_order = 0
	local seen_explicit_push_blocks = {}

	-- First pass: measure explicit push constant blocks
	for _, stage_name in ipairs(possible_stages) do
		local stage_config = get_constant_stage_config(config, stage_name)

		if type(stage_config) == "table" and stage_config.push_constants then
			for _, block in ipairs(stage_config.push_constants) do
				if block.name == nil then
					block.name = "_u_" .. stage_name
					block._is_unnamed = true
				end

				if not seen_explicit_push_blocks[block.name] then
					seen_explicit_push_blocks[block.name] = true
					local flat_block = glsl_meta.flatten_fields(block.block)
					local alignment = glsl_meta.get_scalar_block_alignment(flat_block)
					local ctype = ffi.typeof(glsl_meta.build_ffi_struct("scalar", flat_block))
					explicit_push_span = glsl_meta.align_offset(explicit_push_span, alignment) + ffi.sizeof(ctype)
				end
			end
		end
	end

	-- Second pass: process constant blocks
	for _, stage_name in ipairs(possible_stages) do
		local stage_config = get_constant_stage_config(config, stage_name)

		if type(stage_config) == "table" and stage_config.constants then
			for _, block in ipairs(stage_config.constants) do
				if block.name == nil then
					block.name = "_c_" .. stage_name
					block._is_unnamed = true
				end

				local resolved = constant_blocks[block.name]

				if not resolved then
					constant_order = constant_order + 1
					resolved = glsl_meta.clone_constant_block(block)
					resolved.block = glsl_meta.flatten_fields(resolved.block)
					resolved._constant_order = constant_order
					resolved._requested_storage = resolved.storage or default_mode
					resolved._preferred_storage = resolved.prefer or "push"
					resolved._priority = tonumber(resolved.priority) or 0
					local struct_name = resolved.name:sub(1, 1):upper() .. resolved.name:sub(2) .. "Constants"
					local ctype = ffi.typeof(glsl_meta.build_ffi_struct("scalar", resolved.block))
					glsl_meta.verify_layout("scalar", struct_name, resolved.block, ctype)
					resolved._size = ffi.sizeof(ctype)
					resolved._alignment = glsl_meta.get_scalar_block_alignment(resolved.block)
					resolved.source = glsl_meta.normalize_block_source(resolved, resolved._size, resolved._alignment, "constant block")
					constant_blocks[resolved.name] = resolved

					if resolved._requested_storage == "push" then
						resolved._resolved_storage = "push"
						hard_push_size = hard_push_size + resolved._size
					elseif resolved._requested_storage == "uniform_buffer" then
						resolved._resolved_storage = "uniform_buffer"
					elseif resolved._requested_storage == "auto" then
						table.insert(auto_blocks, resolved)
					else
						error(
							"EasyPipeline.New: invalid constants storage '" .. tostring(resolved._requested_storage) .. "'",
							3
						)
					end
				end
			end
		end
	end

	-- Validate budget
	if explicit_push_span + hard_push_size > push_budget then
		error(
			string.format(
				"EasyPipeline.New: explicit and forced push constant blocks require %d bytes but the configured budget is %d",
				explicit_push_span + hard_push_size,
				push_budget
			),
			3
		)
	end

	-- Sort auto blocks by preference (push first), priority, size (smaller first), then order
	table.sort(auto_blocks, function(a, b)
		local a_push = a._preferred_storage == "push" and 1 or 0
		local b_push = b._preferred_storage == "push" and 1 or 0

		if a_push ~= b_push then return a_push > b_push end

		if a._priority ~= b._priority then return a._priority > b._priority end

		if a._size ~= b._size then return a._size < b._size end

		return a._constant_order < b._constant_order
	end)

	-- Assign storage based on budget
	local remaining_push_budget = push_budget - explicit_push_span - hard_push_size

	for _, block in ipairs(auto_blocks) do
		if block._size <= remaining_push_budget then
			block._resolved_storage = "push"
			remaining_push_budget = remaining_push_budget - block._size
		elseif fallback_storage == "uniform_buffer" then
			block._resolved_storage = "uniform_buffer"
		else
			error(
				string.format(
					"EasyPipeline.New: constant block '%s' (%d bytes) does not fit in the remaining push constant budget (%d bytes)",
					block.name,
					block._size,
					remaining_push_budget
				),
				3
			)
		end
	end

	-- Reassign blocks to push_constants or uniform_buffers based on resolved storage
	for _, stage_name in ipairs(possible_stages) do
		local stage_config = get_constant_stage_config(config, stage_name)

		if type(stage_config) == "table" and stage_config.constants then
			for _, block in ipairs(stage_config.constants) do
				local resolved = assert(constant_blocks[block.name], "missing resolved constant block")
				local target_key = resolved._resolved_storage == "push" and "push_constants" or "uniform_buffers"
				stage_config[target_key] = stage_config[target_key] or {}
				table.insert(stage_config[target_key], resolved)
			end
		end
	end

	return {
		push_budget = push_budget,
		fallback = fallback_storage,
		blocks = constant_blocks,
	}
end

local EasyPipeline = prototype.CreateTemplate("render_easy_pipeline")

do
	-- Static methods (shared across all variants)
	EasyPipeline.BuildFFIType = glsl_meta.build_ffi_type

	-- Delegate storable variable methods from GraphicsPipeline
	for _, info in ipairs(prototype.GetStorableVariables(GraphicsPipeline)) do
		EasyPipeline[info.set_name] = function(self, ...)
			return self.pipeline[info.set_name](self.pipeline, ...)
		end
		EasyPipeline[info.get_name] = function(self, ...)
			return self.pipeline[info.get_name](self.pipeline, ...)
		end
	end

	-- Shared instance methods (available on all pipeline variants)
	function EasyPipeline:OnRemove()
		if self.framebuffers then
			for _, fb in ipairs(self.framebuffers) do
				if fb then fb:Remove() end
			end

			self.framebuffers = nil
		end

		if self.pipeline then
			self.pipeline:Remove()
			self.pipeline = nil
		end

		if self.uniform_buffers then
			for _, ubo in pairs(self.uniform_buffers) do
				if ubo then ubo:Remove() end
			end

			self.uniform_buffers = nil
		end
	end

	function EasyPipeline:Bind(cmd, frame_index, dynamic_offsets)
		cmd = cmd or render.GetCommandBuffer()
		frame_index = frame_index or render.GetCurrentFrame()
		self.pipeline:Bind(cmd, frame_index, dynamic_offsets or self.dynamic_offsets)
	end

	function EasyPipeline:ApplyProperties(...)
		return self.pipeline:ApplyProperties(...)
	end

	function EasyPipeline:UpdateDescriptorSetArray(...)
		return self.pipeline:UpdateDescriptorSetArray(...)
	end

	function EasyPipeline:UpdateDescriptorSet(...)
		return self.pipeline:UpdateDescriptorSet(...)
	end

	function EasyPipeline:ResetToBase(...)
		return self.pipeline:ResetToBase(...)
	end

	function EasyPipeline:GetUniformBuffer(...)
		return self.pipeline:GetUniformBuffer(...)
	end

	function EasyPipeline:GetColorFormat(...)
		return self.pipeline:GetColorFormat(...)
	end

	function EasyPipeline:GetDepthFormat(...)
		return self.pipeline:GetDepthFormat(...)
	end

	function EasyPipeline:GetRasterizationSamples(...)
		return self.pipeline:GetRasterizationSamples(...)
	end

	function EasyPipeline:GetDescriptorSetCount(...)
		return self.pipeline:GetDescriptorSetCount(...)
	end

	function EasyPipeline:GetDebugViews()
		return self.debug_views
	end

	function EasyPipeline:GetVertexAttributes()
		return self.vertex_attributes
	end

	function EasyPipeline:SetTextureSamplerConfigResolver(resolver)
		self.texture_sampler_config_resolver = resolver
	end

	function EasyPipeline:GetTextureSamplerConfig(texture)
		if self.texture_sampler_config_resolver then
			return self.texture_sampler_config_resolver(texture)
		end

		return nil
	end

	function EasyPipeline:GetTextureIndex(texture)
		return self.pipeline:GetTextureIndex(texture, 1, self:GetTextureSamplerConfig(texture))
	end

	function EasyPipeline:SetSamplerConfig(config)
		self.sampler_config = config
		return config
	end

	function EasyPipeline:GetSamplerConfig()
		return self.sampler_config
	end

	function EasyPipeline:SetSamplerConfigValue(key, value)
		self.sampler_config = self.sampler_config or {}
		self.sampler_config[key] = value
		return value
	end

	function EasyPipeline:GetPushConstantBlockOffset(name)
		local offset = self.push_constant_block_offsets and self.push_constant_block_offsets[name]

		if offset == nil then
			error("Invalid push constant block: " .. tostring(name), 2)
		end

		return offset
	end

	function EasyPipeline:GetPushConstantBlockType(name)
		if not (self.push_constant_blocks and self.push_constant_blocks[name]) then
			error("Invalid push constant block: " .. tostring(name), 2)
		end

		local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
		local ctype = self.push_constant_types and self.push_constant_types[struct_name]

		if not ctype then error("Missing push constant type: " .. tostring(name), 2) end

		return ctype
	end

	function EasyPipeline:GetPushConstantBlockSize(name)
		return ffi.sizeof(self:GetPushConstantBlockType(name))
	end

	function EasyPipeline:GetConstantBlockInfo(name)
		local block = self.constant_blocks and self.constant_blocks[name]

		if not block then error("Invalid constant block: " .. tostring(name), 2) end

		return {
			name = block.name,
			storage = block._resolved_storage,
			size = block._size,
			binding_index = block.binding_index,
			offset = block._resolved_storage == "push" and
				self:GetPushConstantBlockOffset(name) or
				nil,
		}
	end

	function EasyPipeline:GetConstantBlockStorage(name)
		return self:GetConstantBlockInfo(name).storage
	end

	function EasyPipeline:BuildConstantBlockData(name)
		local info = self:GetConstantBlockInfo(name)
		local block = assert(
			self.constant_blocks and self.constant_blocks[name],
			"Invalid constant block: " .. tostring(name)
		)
		local data

		if info.storage == "push" then
			data = self:GetPushConstantBlockType(name)()
		else
			local ubo_data = assert(
				self.uniform_buffers and self.uniform_buffers[name],
				"Missing uniform buffer for constant block: " .. tostring(name)
			):GetData()
			data = ffi.typeof(ubo_data)()
		end

		upload_block(self, block, data, name)
		return data
	end

	function EasyPipeline:GetFramebuffer(index)
		return self.framebuffers and (self.framebuffers[index] or self.framebuffers[1])
	end

	function EasyPipeline:RecreateFramebuffers()
		self:CreateOwnedFramebuffers()
	end

	do
		local function resolve_framebuffer_size(config)
			local size = config.FramebufferSize or render.GetRenderImageSize()
			local scale = config.scale or config.Scale

			if type(size) == "function" then size = size() end

			if type(scale) == "function" then scale = scale() end

			local width = tonumber(size.x or size.width or size.w or 0) or 0
			local height = tonumber(size.y or size.height or size.h or 0) or 0

			if scale ~= nil then
				width = math.max(1, math.floor(width * scale + 0.5))
				height = math.max(1, math.floor(height * scale + 0.5))
			end

			return {x = width, y = height}
		end

		function EasyPipeline:CreateOwnedFramebuffers(extra_config)
			local framebuffer_count = self.config.framebuffer_count or 1
			local size = resolve_framebuffer_size(self.config)

			if self.framebuffers then
				for _, fb in ipairs(self.framebuffers) do
					fb:Remove()
				end

				self.framebuffers = nil
			end

			local function build_framebuffer_config()
				local config = {
					width = size.x,
					height = size.y,
					formats = #self.actual_color_formats > 0 and self.actual_color_formats or nil,
					depth = self.config.DepthFormat ~= nil,
					depth_format = self.config.DepthFormat,
					mip_map_levels = self.config.mip_map_levels,
					color_image_usage = self.config.color_image_usage,
				}

				if extra_config then
					for key, value in pairs(extra_config) do
						config[key] = value
					end
				end

				return config
			end

			self.framebuffers = {}

			for i = 1, framebuffer_count do
				self.framebuffers[i] = Framebuffer.New(build_framebuffer_config())
			end
		end
	end

	function EasyPipeline:OnWindowFramebufferResized()
		if render.target:IsValid() and render.target.config.offscreen then return end

		timer.Delay(
			0.01,
			function()
				self:RecreateFramebuffers()
				-- Update descriptor sets if they reference framebuffer textures
				local textures = {}
				local fb = self.framebuffers[1]

				if fb then
					for _, tex in ipairs(fb.color_textures or {}) do
						table.insert(textures, tex)
					end

					if fb.depth_texture then table.insert(textures, fb.depth_texture) end

					if #textures > 0 and self.pipeline.UpdateDescriptorSetArray then
						for i = 1, #self.pipeline.descriptor_sets do
							self.pipeline:UpdateDescriptorSetArray(i, 0, 1, textures)
						end
					end
				end
			end,
			self
		)
	end
end

local EasyPipelineGraphics = prototype.CreateTemplate("render_easy_pipeline_graphics")

do
	EasyPipelineGraphics.Base = EasyPipeline

	function EasyPipelineGraphics:UploadConstants()
		local cmd = render.GetCommandBuffer()
		local pipeline_key = self.pipeline
		local probe_enabled = upload_probe.IsEnabled()

		for _, name in ipairs(self.push_constant_block_order) do
			local block = self.push_constant_blocks[name]
			local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
			local constants = self.constant_structs[struct_name]
			local offset = self.push_constant_block_offsets[name]
			local constants_size = ffi.sizeof(constants)
			upload_block(self, block, constants, name)

			if
				self:ShouldPushConstants(cmd, pipeline_key, self.active_stage_key, offset, constants, constants_size)
			then
				if probe_enabled then
					upload_probe.RecordUpload(block.debug_name, block.field_descriptors, constants, constants_size, true)
				end

				self.pipeline:PushConstants(cmd, self.active_stages, offset, constants)
			end
		end

		local offsets = {}
		local frame_index = render.GetCurrentFrame()
		local frame_number = system.GetFrameNumber and system.GetFrameNumber() or 0

		for i, name in ipairs(self.uniform_buffer_order) do
			local info = self.uniform_buffer_types[name]
			offsets[i] = upload_ubo(
				self,
				info,
				frame_index,
				frame_number,
				probe_enabled,
				upload_probe.RecordUpload,
				upload_probe.RecordCacheAccess,
				self.BytesEqual
			)
		end

		self.dynamic_offsets = #offsets > 0 and offsets or nil

		if self.dynamic_offsets then
			self.pipeline:Bind(cmd, frame_index, self.dynamic_offsets)
		end
	end

	-- Begin drawing to this pipeline's framebuffer
	-- framebuffer: optional custom framebuffer to use (defaults to pipeline's framebuffer)
	-- frame_index: optional frame index for ping-pong buffers (defaults to auto-calculated)
	function EasyPipelineGraphics:BeginDraw(cmd, framebuffer, frame_index)
		cmd = cmd or render.GetCommandBuffer()
		local fb = resolve_draw_framebuffer(self, framebuffer, frame_index)

		if fb then fb:Begin(cmd) end

		-- If drawing directly to the main target, reset viewport/scissor to full size
		if not fb then
			local size = render.GetRenderImageSize()

			if size and size.x > 0 and size.y > 0 then
				cmd:SetViewport(0, 0, size.x, size.y, 0, 1)
				cmd:SetScissor(0, 0, size.x, size.y)
			end
		end

		self:Bind(cmd, frame_index)
		return fb
	end

	-- End drawing (must be paired with BeginDraw)
	function EasyPipelineGraphics:EndDraw(cmd, framebuffer)
		cmd = cmd or render.GetCommandBuffer()

		if framebuffer then framebuffer:End(cmd) end
	end

	-- Complete draw call with automatic framebuffer handling
	-- framebuffer: optional custom framebuffer to use
	-- frame_index: optional frame index for ping-pong buffers
	-- vertex_count: optional vertex count (defaults to 3 for fullscreen quad)
	function EasyPipelineGraphics:Draw(cmd, framebuffer, frame_index, vertex_count)
		cmd = cmd or render.GetCommandBuffer()
		vertex_count = vertex_count or 3
		local resolved_frame_index = resolve_draw_frame_index(self, frame_index)
		local fb = resolve_draw_framebuffer(self, framebuffer, resolved_frame_index)
		render.PushCommandBuffer(cmd)

		if self.on_pre_draw then self.on_pre_draw(self, cmd, resolved_frame_index) end

		if fb then fb:Begin(cmd) end

		-- Reset viewport/scissor when drawing directly to the main target
		if not fb then
			local size = render.GetRenderImageSize()

			if size and size.x > 0 and size.y > 0 then
				cmd:SetViewport(0, 0, size.x, size.y, 0, 1)
				cmd:SetScissor(0, 0, size.x, size.y)
			end
		end

		self:Bind(cmd, resolved_frame_index)

		if self.on_draw then
			self:on_draw(cmd)
		else
			self:UploadConstants()
			cmd:Draw(vertex_count, 1, 0, 0)
		end

		if fb then fb:End(cmd) end

		render.PopCommandBuffer()
	end

	function EasyPipelineGraphics:DrawMeshTasks(gx, gy, gz, cmd, framebuffer, frame_index)
		cmd = cmd or render.GetCommandBuffer()
		local resolved_frame_index = resolve_draw_frame_index(self, frame_index)
		local fb = resolve_draw_framebuffer(self, framebuffer, resolved_frame_index)
		render.PushCommandBuffer(cmd)
		local ok, err = xpcall(
			function()
				if fb then fb:Begin(cmd) end

				if not fb then
					local size = render.GetRenderImageSize()

					if size and size.x > 0 and size.y > 0 then
						cmd:SetViewport(0, 0, size.x, size.y, 0, 1)
						cmd:SetScissor(0, 0, size.x, size.y)
					end
				end

				self:Bind(cmd, resolved_frame_index)

				if self.on_draw then
					self:on_draw(cmd)
				else
					self:UploadConstants()
					cmd:DrawMeshTasks(gx, gy, gz)
				end
			end,
			debug.traceback
		)

		if fb then fb:End(cmd) end

		render.PopCommandBuffer()

		if not ok then error(err, 0) end
	end

	function EasyPipelineGraphics:PushConstants(...)
		return self.pipeline:PushConstants(...)
	end

	local function get_glsl_push_constants(config, push_constant_block_offsets, stage, header)
		local stage_config = get_constant_stage_config(config, stage)

		if not stage_config or not stage_config.push_constants then return "" end

		local blocks = stage_config.push_constants
		local str = ""

		for _, block in ipairs(blocks) do
			local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
			local glsl_fields, glsl_structs = glsl_meta.build_glsl_fields(block.block)
			str = str .. glsl_structs .. "struct " .. struct_name .. " {\n" .. glsl_fields .. "};\n\n"
		end

		str = str .. "layout(push_constant, scalar) uniform Constants {\n"

		for _, block in ipairs(blocks) do
			local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
			local offset = push_constant_block_offsets[block.name]
			str = str .. "    layout(offset = " .. offset .. ") " .. struct_name .. " " .. block.name .. ";\n"
		end

		str = str .. "} pc;\n\n"

		-- Emit shortcut #defines: named block -> #define name pc.name
		-- unnamed block -> #define U pc._u
		for _, block in ipairs(blocks) do
			if block._is_unnamed then
				str = str .. "#define U pc." .. block.name .. "\n"
			else
				str = str .. "#define " .. block.name .. " pc." .. block.name .. "\n"
			end
		end

		str = str .. "\n"
		return str
	end

	local function get_glsl_uniform_buffers(config, uniform_buffer_types, stage)
		local stage_config = config[stage]

		if not stage_config or not stage_config.uniform_buffers then return "" end

		local glsl = ""

		for _, block in ipairs(stage_config.uniform_buffers) do
			glsl = glsl .. uniform_buffer_types[block.name].glsl .. "\n\n"

			-- Emit #define U for unnamed UBOs
			if block._is_unnamed then
				glsl = glsl .. "#define U " .. block.name .. "\n\n"
			end
		end

		return glsl
	end

	-- Build a shader stage table from config
	local function build_shader_stage(
		config,
		type_name,
		input,
		output,
		custom_declarations,
		shader,
		extra,
		header,
		ds,
		pc_info,
		pcbo,
		uniform_buffer_types
	)
		local stage_config = get_constant_stage_config(config, type_name)

		if
			not stage_config or
			not stage_config.shader and
			type_name ~= "vertex" or
			not shader
		then
			-- For vertex, shader may be nil if using passthrough
			if type_name == "vertex" and (not stage_config or not stage_config.shader) then
				return
			end

			return
		end

		local code = header .. (input or "") .. (output or "")
		code = code .. get_glsl_push_constants(config, pcbo, type_name, header)
		code = code .. get_glsl_uniform_buffers(config, uniform_buffer_types, type_name)
		code = code .. (custom_declarations or "")
		code = code .. (shader or "")
		return {
			type = type_name,
			code = code,
			descriptor_sets = ds,
			push_constants = stage_config.push_constants and pc_info or nil,
		}
	end

	-- Build task/mesh shader stage with pragma injection
	local function build_task_mesh_stage(config, type_name, pragma, header, ds, pc_info, pcbo)
		local stage_config = get_constant_stage_config(config, type_name)

		if not stage_config or not stage_config.shader then return end

		local code = header:gsub("#version 450", "#version 450\n#pragma shader_stage(" .. pragma .. ")")
		code = code .. (stage_config.custom_declarations or "")
		code = code .. get_glsl_push_constants(config, pcbo, type_name, header)
		code = code .. get_glsl_uniform_buffers(config, uniform_buffer_types, type_name)
		code = code .. (stage_config.shader or "")
		return {
			type = type_name,
			code = code,
			descriptor_sets = ds,
			push_constants = stage_config.push_constants and pc_info or nil,
		}
	end

	-- Graphics constructor
	function EasyPipelineGraphics.New(config)
		if config.ComputePass or config.compute_pass then
			return EasyPipelineCompute.ComputePass(config)
		end

		local self = EasyPipelineGraphics:CreateObject()
		self.on_pre_draw = config.on_pre_draw or nil
		self.on_draw = config.on_draw or nil
		local color_format = config.ColorFormat
		local depth_format = config.DepthFormat
		local rasterization_samples = config.RasterizationSamples
		local descriptor_set_count = config.DescriptorSetCount

		-- Resolve format functions if they exist
		if type(color_format) == "function" then color_format = color_format() end

		if type(depth_format) == "function" then depth_format = depth_format() end

		if type(rasterization_samples) == "function" then
			rasterization_samples = rasterization_samples()
		end

		config.ColorFormat = color_format
		config.DepthFormat = depth_format
		config.RasterizationSamples = rasterization_samples
		config.DescriptorSetCount = descriptor_set_count

		if not config.vertex then
			config.vertex = {
				shader = [[
				layout(location = 0) out vec2 out_uv;
				void main() {
					vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
					gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
					out_uv = uv;
				}
			]],
			}
			assert(config.fragment)
			config.fragment.custom_declarations = (config.fragment.custom_declarations or "") .. [[
			layout(location = 0) in vec2 in_uv;
		]]
		end

		-- Resolve color format functions
		if type(color_format) == "table" then
			for i, format in ipairs(color_format) do
				if type(format) == "table" then
					-- Resolve first element if it's a function
					if type(format[1]) == "function" then format[1] = format[1]() end
				end
			end
		end

		local push_constant_types = {}
		local possible_stages = {
			"task_ext",
			"mesh_ext",
			"vertex",
			"tessellation_control",
			"tessellation_evaluation",
			"fragment",
			"compute",
		}
		local push_constant_blocks = {}
		local push_constant_block_order = {}
		local push_constant_block_offsets = {}
		local uniform_buffer_types = {}
		local uniform_buffers = {}
		local actual_color_formats = {}
		local fragment_outputs = ""
		local debug_views = {}
		local color_formats = color_format

		if color_formats then
			if type(color_formats) == "string" then color_formats = {color_formats} end

			for i, format in ipairs(color_formats) do
				if type(format) == "table" then
					local actual_format = format[1]
					table.insert(actual_color_formats, actual_format)
					local max_component = 0
					local component_map = {r = 1, g = 2, b = 3, a = 4, x = 1, y = 2, z = 3, w = 4}

					for j = 2, #format do
						local swizzle = format[j][2]

						for char in swizzle:gmatch(".") do
							max_component = math.max(max_component, component_map[char] or 0)
						end
					end

					max_component = math.max(max_component, 1)
					local output_type = "float"

					if max_component == 2 then
						output_type = "vec2"
					elseif max_component == 3 then
						output_type = "vec3"
					elseif max_component == 4 then
						output_type = "vec4"
					end

					fragment_outputs = fragment_outputs .. string.format("layout(location = %d) out %s out_%d;\n", i - 1, output_type, i - 1)

					for j = 2, #format do
						local mapping = format[j]
						local name = mapping[1]
						local swizzle = mapping[2]
						local glsl_type = "float"

						if #swizzle == 2 then
							glsl_type = "vec2"
						elseif #swizzle == 3 then
							glsl_type = "vec3"
						elseif #swizzle == 4 then
							glsl_type = "vec4"
						end

						if output_type == "float" then
							fragment_outputs = fragment_outputs .. string.format("void set_%s(%s val) { out_%d = val; }\n", name, glsl_type, i - 1)
						else
							fragment_outputs = fragment_outputs .. string.format("void set_%s(%s val) { out_%d.%s = val; }\n", name, glsl_type, i - 1, swizzle)
						end

						table.insert(
							debug_views,
							{
								name = name,
								attachment_index = i,
								swizzle = swizzle,
							}
						)
					end
				else
					table.insert(actual_color_formats, format)
					local out_name = "out_" .. (i - 1)
					fragment_outputs = fragment_outputs .. string.format("layout(location = %d) out vec4 %s;\n", i - 1, out_name)

					if i == 1 then
						fragment_outputs = fragment_outputs .. "#define out_color " .. out_name .. "\n"
					end

					table.insert(
						debug_views,
						{
							name = "Target " .. i,
							attachment_index = i,
							swizzle = "rgba",
						}
					)
				end
			end
		end

		local constant_resolution = resolve_constant_placement(config, possible_stages)

		-- Process push constants and uniform buffers
		-- First pass: Collect all unique push constant blocks across all stages to assign shared offsets
		for _, stage_name in ipairs(possible_stages) do
			local stage_config = get_constant_stage_config(config, stage_name)

			if type(stage_config) == "table" and stage_config.push_constants then
				for _, block in ipairs(stage_config.push_constants) do
					-- Auto-assign a stable internal name for unnamed blocks (stage-specific to avoid collision)
					if block.name == nil then
						block.name = "_u_" .. stage_name
						block._is_unnamed = true
					end

					if not push_constant_blocks[block.name] then
						glsl_meta.hoist_inline_block_metadata(block)
						block.block = glsl_meta.flatten_fields(block.block)
						push_constant_blocks[block.name] = block
						table.insert(push_constant_block_order, block.name)
						local struct_name = block.name:sub(1, 1):upper() .. block.name:sub(2) .. "Constants"
						local ffi_code = glsl_meta.build_ffi_struct("scalar", block.block)
						local ctype = ffi.typeof(ffi_code)
						glsl_meta.verify_layout("scalar", struct_name, block.block, ctype)
						block.debug_name = (config.name or "pipeline") .. ".pc." .. block.name
						block.field_descriptors = glsl_meta.build_field_descriptors(ctype, block.block)
						block.source = glsl_meta.normalize_block_source(
							block,
							ffi.sizeof(ctype),
							glsl_meta.get_scalar_block_alignment(block.block),
							"push constant block"
						)
						push_constant_types[struct_name] = ctype
						push_constant_block_offsets[block.name] = 0 -- placeholder
					end
				end
			end
		end

		-- Assign offsets sequentially based on order of appearance in possible_stages
		local current_push_offset = 0

		for _, name in ipairs(push_constant_block_order) do
			current_push_offset = glsl_meta.align_offset(
				current_push_offset,
				glsl_meta.get_scalar_block_alignment(push_constant_blocks[name].block)
			)
			push_constant_block_offsets[name] = current_push_offset
			local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
			current_push_offset = current_push_offset + ffi.sizeof(push_constant_types[struct_name])
		end

		if current_push_offset > constant_resolution.push_budget then
			error(
				string.format(
					"EasyPipeline.New: resolved push constant layout requires %d bytes but the configured budget is %d",
					current_push_offset,
					constant_resolution.push_budget
				),
				2
			)
		end

		-- Auto binding index counter starts at 2 (0=textures, 1=cubemaps are reserved)
		local next_auto_binding = 2

		-- Pre-scan all explicit binding indices so auto-assignment skips them
		for _, sc in pairs(config) do
			if type(sc) == "table" and sc.uniform_buffers then
				for _, b in ipairs(sc.uniform_buffers) do
					if b.binding_index and b.binding_index >= next_auto_binding then
						next_auto_binding = b.binding_index + 1
					end
				end
			end
		end

		local uniform_buffer_order = {}

		for _, stage_name in ipairs(possible_stages) do
			local stage_config = config[stage_name]

			if type(stage_config) ~= "table" then goto continue end

			-- Process uniform buffers
			if stage_config.uniform_buffers then
				for _, block in ipairs(stage_config.uniform_buffers) do
					-- Auto-assign a stable internal name for unnamed blocks (stage-specific to avoid collision)
					if block.name == nil then
						block.name = "_u_" .. stage_name
						block._is_unnamed = true
					end

					-- Auto-assign binding index if not specified
					next_auto_binding = assign_auto_binding(block, next_auto_binding, uniform_buffer_types)
					glsl_meta.hoist_inline_block_metadata(block)
					block.block = glsl_meta.flatten_fields(block.block)

					if not block.block[1] then
						error("Uniform buffer " .. block.name .. " has no fields!")
					end

					local existing = uniform_buffer_types[block.name]

					if existing then
						if existing.block.binding_index ~= block.binding_index then
							error(
								"Uniform buffer " .. block.name .. " is declared with conflicting binding indices: " .. tostring(existing.block.binding_index) .. " and " .. tostring(block.binding_index)
							)
						end

						goto continue_uniform_buffer
					end

					local ffi_code = glsl_meta.build_ffi_struct("scalar", block.block)
					local glsl_fields, glsl_structs = glsl_meta.build_glsl_fields(block.block)
					local ubo = UniformBuffer.New(ffi_code)
					glsl_meta.verify_layout("scalar", block.name, block.block, ubo.struct)
					block.source = glsl_meta.normalize_block_source(
						block,
						ffi.sizeof(ubo.struct),
						glsl_meta.get_scalar_block_alignment(block.block),
						"uniform buffer block"
					)
					local block_type_name = glsl_meta.normalize_block_type_name(block.name)
					local glsl_declaration = string.format(
						"%slayout(scalar, binding = %d) uniform %s {\n%s} %s;",
						glsl_structs,
						block.binding_index,
						block_type_name,
						glsl_fields,
						block.name
					)
					table.insert(uniform_buffer_order, block.name)
					uniform_buffer_types[block.name] = {
						ubo = ubo,
						block = block,
						glsl = glsl_declaration,
						debug_name = (config.name or "pipeline") .. ".ubo." .. block.name,
						field_descriptors = glsl_meta.build_field_descriptors(ubo.struct, block.block),
						offsets = {}, -- Tracks offsets used in the current frame
					}
					uniform_buffers[block.name] = ubo

					::continue_uniform_buffer::
				end
			end

			::continue::
		end

		table.sort(uniform_buffer_order, function(a, b)
			local a_block = uniform_buffer_types[a].block
			local b_block = uniform_buffer_types[b].block
			local a_set = a_block.set_index or 0
			local b_set = b_block.set_index or 0

			if a_set ~= b_set then return a_set < b_set end

			if a_block.binding_index ~= b_block.binding_index then
				return a_block.binding_index < b_block.binding_index
			end

			return a < b
		end)

		-- Build constants upload function
		local constant_structs = {}

		for struct_name, ctype in pairs(push_constant_types) do
			constant_structs[struct_name] = ctype()
		end

		local active_stages = {}

		for _, s in ipairs(possible_stages) do
			local stage_config = get_constant_stage_config(config, s)

			if stage_config then
				-- Only consider it an active shader stage if it has a shader or if it's vertex/fragment (which might have default shaders in some systems, but here we check for .shader)
				-- Actually, for vertex we only add it if .shader is present now.
				if stage_config.shader then table.insert(active_stages, s) end
			end
		end

		local active_stage_key = table.concat(active_stages, "|")
		self.constant_structs = constant_structs
		self.active_stages = active_stages
		self.active_stage_key = active_stage_key
		self.push_constant_blocks = push_constant_blocks
		self.push_constant_block_offsets = push_constant_block_offsets
		self.push_constant_block_order = push_constant_block_order
		self.push_constant_types = push_constant_types
		self.constant_blocks = constant_resolution.blocks
		self.constant_push_budget = constant_resolution.push_budget
		self.uniform_buffer_order = uniform_buffer_order
		self.uniform_buffer_types = uniform_buffer_types
		self.uniform_buffers = uniform_buffers
		self.push_constant_cache_by_cmd = setmetatable({}, {__mode = "k"})
		-- Build vertex attributes
		local attributes = {}
		local logical_attributes = {}
		local bindings = {}
		local shader_inputs = {}
		local shader_outputs = {}
		local resolved_vertex_shader = config.vertex and config.vertex.shader or nil
		local resolved_fragment_shader = config.fragment and config.fragment.shader or nil

		if config.vertex then
			shader_outputs = config.vertex.outputs or config.vertex.attributes or {}
			local vertex_bindings = config.vertex.bindings

			if not vertex_bindings and config.vertex.attributes then
				vertex_bindings = {
					{
						binding = config.vertex.binding_index or 0,
						input_rate = config.vertex.input_rate or "vertex",
						attributes = config.vertex.attributes,
					},
				}
			end

			if vertex_bindings then
				local location = 0

				for binding_index, binding in ipairs(vertex_bindings) do
					local binding_attributes = binding.attributes or {}
					local stride = 0
					local resolved_binding = binding.binding

					if resolved_binding == nil then resolved_binding = binding.binding_index end

					if resolved_binding == nil then resolved_binding = binding_index - 1 end

					for _, attribute in ipairs(binding_attributes) do
						local attribute_name = attribute[1]
						local attribute_type = attribute[2]
						local attribute_format = attribute[3]
						local attribute_lua_type = glsl_meta.GLSL_TO_LUA_TYPE[attribute_type]
						local location_count = glsl_meta.get_vertex_attribute_location_count(attribute_type)
						local attribute_size = location_count * render.GetVulkanFormatSize(attribute_type == "mat4" and "r32g32b32a32_sfloat" or attribute_format)
						local attribute_offset = attribute[4]

						if attribute_offset == nil then attribute_offset = stride end

						logical_attributes[#logical_attributes + 1] = {
							binding = resolved_binding,
							offset = attribute_offset,
							lua_name = attribute_name,
							lua_type = attribute_lua_type,
							format = attribute_format,
						}

						for location_offset = 0, location_count - 1 do
							local physical_name = attribute_name
							local physical_type = attribute_type
							local physical_format = attribute_format
							local physical_offset = attribute_offset

							if attribute_type == "mat4" then
								physical_name = string.format("%s_row_%d", attribute_name, location_offset)
								physical_type = "vec4"
								physical_format = "r32g32b32a32_sfloat"
								physical_offset = attribute_offset + location_offset * render.GetVulkanFormatSize(physical_format)
							end

							table.insert(
								attributes,
								{
									binding = resolved_binding,
									location = location + location_offset,
									format = physical_format,
									offset = physical_offset,
									lua_name = attribute_name,
									lua_type = attribute_lua_type,
								}
							)
						end

						glsl_meta.append_vertex_shader_input(shader_inputs, attribute)
						stride = math.max(stride, attribute_offset + attribute_size)
						location = location + location_count
					end

					if #binding_attributes > 0 then
						table.insert(
							bindings,
							{
								binding = resolved_binding,
								stride = binding.stride or stride,
								input_rate = binding.input_rate or "vertex",
							}
						)
					end
				end
			end
		end

		local bindless_descriptor_capacities = render.GetBindlessDescriptorCapacities()
		local bindless_texture_capacity = bindless_descriptor_capacities.textures
		local bindless_cubemap_capacity = bindless_descriptor_capacities.cubemaps
		local tess_control_outputs = (config.tessellation_control and config.tessellation_control.outputs) or shader_outputs
		local tess_eval_outputs = (
				config.tessellation_evaluation and
				config.tessellation_evaluation.outputs
			)
			or
			tess_control_outputs
		local final_fragment_inputs = config.tessellation_evaluation and tess_eval_outputs or shader_outputs
		-- Build shader header and I/O
		local mesh_ext = config.mesh or config.mesh_ext or config.task or config.task_ext
		local shader_header = glsl_meta.build_shader_header(
			bindless_texture_capacity,
			bindless_cubemap_capacity,
			mesh_ext and {"#extension GL_EXT_mesh_shader : require"} or nil
		)
		local vertex_input = ""
		local vertex_output = ""
		local tess_control_input = ""
		local tess_control_output = ""
		local tess_eval_input = ""
		local tess_eval_output = ""
		local fragment_input = ""

		for i, attr in ipairs(shader_inputs) do
			vertex_input = vertex_input .. string.format("layout(location = %d) in %s in_%s;\n", i - 1, attr[2], attr[1])
		end

		for i, attr in ipairs(shader_outputs) do
			vertex_output = vertex_output .. string.format("layout(location = %d) out %s out_%s;\n", i - 1, attr[2], attr[1])
			tess_control_input = tess_control_input .. string.format("layout(location = %d) in %s in_%s[];\n", i - 1, attr[2], attr[1])
		end

		for i, attr in ipairs(tess_control_outputs) do
			tess_control_output = tess_control_output .. string.format("layout(location = %d) out %s out_%s[];\n", i - 1, attr[2], attr[1])
			tess_eval_input = tess_eval_input .. string.format("layout(location = %d) in %s in_%s[];\n", i - 1, attr[2], attr[1])
		end

		for i, attr in ipairs(tess_eval_outputs) do
			tess_eval_output = tess_eval_output .. string.format("layout(location = %d) out %s out_%s;\n", i - 1, attr[2], attr[1])
		end

		for i, attr in ipairs(final_fragment_inputs) do
			fragment_input = fragment_input .. string.format("layout(location = %d) in %s in_%s;\n", i - 1, attr[2], attr[1])
		end

		if config.vertex and not resolved_vertex_shader and config.vertex.passthrough then
			resolved_vertex_shader = glsl_meta.build_passthrough_vertex_shader(config.vertex, shader_outputs, shader_inputs)
		end

		if config.fragment then
			resolved_fragment_shader = glsl_meta.build_fragment_shader(config.fragment)
		end

		-- Build descriptor sets
		local descriptor_sets = glsl_meta.build_base_descriptor_sets(bindless_texture_capacity, bindless_cubemap_capacity)
		-- Add uniform buffers from and descriptors from all stages
		local uniform_buffer_order_desc = {}

		for _, stage_name in ipairs(possible_stages) do
			local stage_config = config[stage_name]

			if type(stage_config) == "table" then
				if stage_config.descriptor_sets then
					for _, desc in ipairs(stage_config.descriptor_sets) do
						if type(desc.args) == "function" then desc.args = desc.args() end

						table.insert(descriptor_sets, desc)
					end
				end

				if stage_config.uniform_buffers then
					for _, block in ipairs(stage_config.uniform_buffers) do
						local ubo = uniform_buffers[block.name]
						table.insert(uniform_buffer_order_desc, block.name)
						table.insert(
							descriptor_sets,
							{
								type = "uniform_buffer_dynamic",
								binding_index = block.binding_index,
								args = {ubo.buffer, ubo.aligned_size},
							}
						)
					end
				end
			end
		end

		-- Build shader stages
		local shader_stages = {}
		local push_constant_info = nil

		if #push_constant_block_order > 0 then
			push_constant_info = {
				offset = 0,
				size = current_push_offset,
			}
		end

		-- Task stage
		local task_stage = build_task_mesh_stage(
			config,
			"task_ext",
			"task",
			shader_header,
			descriptor_sets,
			push_constant_info,
			push_constant_block_offsets,
			uniform_buffer_types
		)

		if task_stage then table.insert(shader_stages, task_stage) end

		-- Mesh stage
		local mesh_stage = build_task_mesh_stage(
			config,
			"mesh_ext",
			"mesh",
			shader_header,
			descriptor_sets,
			push_constant_info,
			push_constant_block_offsets,
			uniform_buffer_types
		)

		if mesh_stage then table.insert(shader_stages, mesh_stage) end

		-- Vertex stage
		if config.vertex and resolved_vertex_shader then
			local vertex_stage = build_shader_stage(
				config,
				"vertex",
				vertex_input,
				vertex_output,
				config.vertex.custom_declarations,
				resolved_vertex_shader,
				nil,
				shader_header,
				descriptor_sets,
				push_constant_info,
				push_constant_block_offsets,
				uniform_buffer_types
			)

			if vertex_stage then
				vertex_stage.bindings = bindings
				vertex_stage.attributes = attributes
				table.insert(shader_stages, vertex_stage)
			end
		end

		-- Tessellation control stage
		local tess_control_stage = build_shader_stage(
			config,
			"tessellation_control",
			tess_control_input,
			tess_control_output,
			config.tessellation_control and config.tessellation_control.custom_declarations,
			config.tessellation_control and config.tessellation_control.shader,
			nil,
			shader_header,
			descriptor_sets,
			push_constant_info,
			push_constant_block_offsets,
			uniform_buffer_types
		)

		if tess_control_stage then table.insert(shader_stages, tess_control_stage) end

		-- Tessellation evaluation stage
		local tess_eval_stage = build_shader_stage(
			config,
			"tessellation_evaluation",
			tess_eval_input,
			tess_eval_output,
			config.tessellation_evaluation and
				config.tessellation_evaluation.custom_declarations,
			config.tessellation_evaluation and config.tessellation_evaluation.shader,
			nil,
			shader_header,
			descriptor_sets,
			push_constant_info,
			push_constant_block_offsets,
			uniform_buffer_types
		)

		if tess_eval_stage then table.insert(shader_stages, tess_eval_stage) end

		-- Fragment stage
		local fragment_stage = build_shader_stage(
			config,
			"fragment",
			fragment_input,
			fragment_outputs,
			config.fragment and config.fragment.custom_declarations,
			resolved_fragment_shader,
			nil,
			shader_header,
			descriptor_sets,
			push_constant_info,
			push_constant_block_offsets,
			uniform_buffer_types
		)

		if fragment_stage then table.insert(shader_stages, fragment_stage) end

		-- Create pipeline
		local color_blend = config.color_blend or {}
		local sanitized_color_blend = glsl_meta.sanitize_color_blend_attachments(color_blend.attachments)
		local pipeline_config = {
			ColorFormat = #actual_color_formats > 0 and actual_color_formats or color_format,
			DepthFormat = depth_format,
			RasterizationSamples = rasterization_samples or "1",
			DescriptorSetCount = descriptor_set_count or
				(
					render.target:IsValid() and
					render.target.image_count
				)
				or
				1,
			shader_stages = shader_stages,
			Topology = config.Topology or "triangle_list",
			PatchControlPoints = config.PatchControlPoints or 3,
			PolygonMode = config.PolygonMode or "fill",
			CullMode = config.CullMode or "back",
			FrontFace = config.FrontFace or "counter_clockwise",
			DepthBias = config.DepthBias or false,
			DepthBiasConstantFactor = config.DepthBiasConstantFactor or 0,
			DepthBiasClamp = config.DepthBiasClamp or 0,
			DepthBiasSlopeFactor = config.DepthBiasSlopeFactor or 0,
			LineWidth = config.LineWidth or 1.0,
			DepthClamp = config.DepthClamp or false,
			Discard = config.Discard or false,
			PrimitiveRestart = config.PrimitiveRestart or false,
			Blend = config.Blend or false,
			SrcColorBlendFactor = config.SrcColorBlendFactor or "src_alpha",
			DstColorBlendFactor = config.DstColorBlendFactor or "one_minus_src_alpha",
			ColorBlendOp = config.ColorBlendOp or "add",
			SrcAlphaBlendFactor = config.SrcAlphaBlendFactor or "one",
			DstAlphaBlendFactor = config.DstAlphaBlendFactor or "zero",
			AlphaBlendOp = config.AlphaBlendOp or "add",
			ColorWriteMask = config.ColorWriteMask or {"r", "g", "b", "a"},
			LogicOpEnabled = config.LogicOpEnabled or false,
			LogicOp = config.LogicOp or "copy",
			BlendConstants = config.BlendConstants or {0.0, 0.0, 0.0, 0.0},
			SampleShading = config.SampleShading or false,
			MinSampleShading = config.MinSampleShading or 0,
			Sampler = config.Sampler or config.sampler,
			color_blend = sanitized_color_blend,
			DepthTest = config.DepthTest,
			DepthWrite = config.DepthWrite,
			DepthCompareOp = config.DepthCompareOp,
			DepthBoundsTest = config.DepthBoundsTest,
			StencilTest = config.StencilTest,
			FrontStencilFailOp = config.FrontStencilFailOp,
			FrontStencilPassOp = config.FrontStencilPassOp,
			FrontStencilDepthFailOp = config.FrontStencilDepthFailOp,
			FrontStencilCompareOp = config.FrontStencilCompareOp,
			FrontStencilReference = config.FrontStencilReference,
			FrontStencilCompareMask = config.FrontStencilCompareMask,
			FrontStencilWriteMask = config.FrontStencilWriteMask,
			BackStencilFailOp = config.BackStencilFailOp,
			BackStencilPassOp = config.BackStencilPassOp,
			BackStencilDepthFailOp = config.BackStencilDepthFailOp,
			BackStencilCompareOp = config.BackStencilCompareOp,
			BackStencilReference = config.BackStencilReference,
			BackStencilCompareMask = config.BackStencilCompareMask,
			BackStencilWriteMask = config.BackStencilWriteMask,
		}

		if pipeline_config.DepthCompareOp == nil then
			pipeline_config.DepthCompareOp = "less"
		end

		if pipeline_config.DepthBoundsTest == nil then
			pipeline_config.DepthBoundsTest = false
		end

		if pipeline_config.StencilTest == nil then
			pipeline_config.StencilTest = false
		end

		if pipeline_config.DepthTest == nil then pipeline_config.DepthTest = true end

		if pipeline_config.DepthWrite == nil then pipeline_config.DepthWrite = true end

		self.pipeline = render.CreateGraphicsPipeline(pipeline_config)
		self.vertex_attributes = logical_attributes
		self.physical_vertex_attributes = attributes
		self.debug_views = debug_views
		self.config = config
		self.actual_color_formats = actual_color_formats

		-- Create framebuffer(s) if this pipeline has color or depth outputs
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

	do
		local function bytes_equal(lhs, rhs, size)
			for i = 0, size - 1 do
				if lhs[i] ~= rhs[i] then return false end
			end

			return true
		end

		EasyPipelineGraphics.BytesEqual = bytes_equal

		local function ranges_overlap(lhs_offset, lhs_size, rhs_offset, rhs_size)
			return lhs_offset < rhs_offset + rhs_size and rhs_offset < lhs_offset + rhs_size
		end

		function EasyPipelineGraphics:ShouldPushConstants(cmd, pipeline_key, stage_key, offset, data, size)
			local cache = self.push_constant_cache_by_cmd[cmd]
			local serial = cmd and cmd.recording_serial or 0

			if not cache or cache.serial ~= serial then
				cache = {serial = serial, entries = {}}
				self.push_constant_cache_by_cmd[cmd] = cache
			end

			local entries = cache.entries
			local src = ffi.cast("uint8_t *", data)

			-- Remove overlapping entries from previous pushes in this frame
			for i = #entries, 1, -1 do
				local entry = entries[i]

				if
					entry.pipeline_key == pipeline_key and
					entry.stage_key == stage_key and
					ranges_overlap(entry.offset, entry.size, offset, size)
				then
					table.remove(entries, i)
				end
			end

			-- Check if this push differs from a previous one
			for _, entry in ipairs(entries) do
				if
					entry.pipeline_key == pipeline_key and
					entry.stage_key == stage_key and
					entry.offset == offset and
					entry.size == size
				then
					return not bytes_equal(entry.snapshot, src, size)
				end
			end

			-- Record this push
			entries[#entries + 1] = {
				pipeline_key = pipeline_key,
				stage_key = stage_key,
				offset = offset,
				size = size,
				snapshot = ffi.new("uint8_t[?]", size),
			}
			ffi.copy(entries[#entries].snapshot, src, size)
			return true
		end
	end

	EasyPipelineGraphics:Register()
end

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
				upload_block(self, info.block, data, name)
				offsets[i] = info.ubo:Upload(frame_index)
			end

			self.dynamic_offsets = offsets
		end

		if not self.push_constant_data then return end

		if self.push_constant_source then
			local source_data = self.push_constant_source.get(self, self.push_constant_source)

			if source_data == nil then
				error("compute push constant source returned nil", 2)
			end

			ffi.copy(
				self.push_constant_data,
				ffi.cast("uint8_t *", source_data) + (self.push_constant_source.offset or 0),
				self.push_constant_size
			)
		end

		if self.push_constant_write then
			self.push_constant_write(self, self.push_constant_data)
		end

		self.pipeline:PushConstants(
			render.GetCommandBuffer(),
			{"compute"},
			0,
			self.push_constant_data,
			self.push_constant_size
		)
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
		local flat_push_constant_block = #block > 0 and glsl_meta.flatten_fields(block) or block
		local push_constant_type
		local push_constant_size = 0
		local push_constant_field_descriptors
		local uniform_buffers = {}
		local uniform_buffer_types = {}
		local uniform_buffer_order = {}

		if #block > 0 then
			push_constant_type = EasyPipeline.BuildFFIType("scalar", "ComputeConstants", flat_push_constant_block)
			push_constant_size = ffi.sizeof(push_constant_type)
			push_constant_field_descriptors = glsl_meta.build_field_descriptors(push_constant_type, flat_push_constant_block)
		end

		self.push_constant_data = push_constant_type and push_constant_type() or nil
		self.push_constant_size = push_constant_size
		self.push_constant_source = source
		self.push_constant_write = write
		self.uniform_buffer_order = uniform_buffer_order
		self.uniform_buffer_types = uniform_buffer_types
		self.uniform_buffers = uniform_buffers
		local bindless_descriptor_capacities = render.GetBindlessDescriptorCapacities()
		local bindless_texture_capacity = bindless_descriptor_capacities.textures
		local bindless_cubemap_capacity = bindless_descriptor_capacities.cubemaps
		local shader_header = glsl_meta.build_shader_header(bindless_texture_capacity, bindless_cubemap_capacity)
		local push_constant_glsl = ""

		if #block > 0 then
			push_constant_glsl = "layout(push_constant, scalar) uniform ComputeConstants {\n" .. glsl_meta.build_glsl_fields(flat_push_constant_block) .. "} compute;\n\n"
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

function EasyPipeline.New(config)
	if config.ComputePass or config.compute_pass then
		return EasyPipelineCompute.ComputePass(config)
	end

	return EasyPipelineGraphics.New(config)
end

EasyPipeline.Compute = EasyPipelineCompute.Compute
EasyPipeline.ComputePass = EasyPipelineCompute.ComputePass
return EasyPipeline:Register()
