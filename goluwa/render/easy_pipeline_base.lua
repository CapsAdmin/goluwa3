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
		) or
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

-- Build FFI type and metadata for a push constant block
-- Handles both wrapped blocks (block.block) and direct blocks (the block itself is the field list)
local function build_push_constant_block(name, block)
	glsl_meta.hoist_inline_block_metadata(block)

	-- Determine the actual field list: block.block if present, otherwise block itself
	local raw_block = block.block or block

	if type(raw_block) ~= "table" or #raw_block == 0 then
		return nil, nil
	end

	local flat_block = glsl_meta.flatten_fields(raw_block)

	if not flat_block[1] then
		error("Push constant block " .. tostring(name) .. " has no fields")
	end

	local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
	local ffi_code = glsl_meta.build_ffi_struct("scalar", flat_block)
	local ctype = ffi.typeof(ffi_code)
	glsl_meta.verify_layout("scalar", struct_name, flat_block, ctype)
	block.debug_name = "pipeline.pc." .. name
	block.field_descriptors = glsl_meta.build_field_descriptors(ctype, flat_block)
	block.source = glsl_meta.normalize_block_source(
		block,
		ffi.sizeof(ctype),
		glsl_meta.get_scalar_block_alignment(flat_block),
		"push constant block"
	)
	-- Store flattened block in block.block for consistency
	block.block = flat_block
	return struct_name, ctype
end

local EasyPipeline = prototype.CreateTemplate("render_easy_pipeline")

do
	-- Static methods (shared across all variants)
	EasyPipeline.BuildFFIType = glsl_meta.build_ffi_type

	-- Shared push constant block builder (used by both graphics and compute constructors)
	EasyPipeline.BuildPushConstantBlock = build_push_constant_block

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

	-- Push constant upload helpers (shared by graphics and compute)
	function EasyPipeline:_BytesEqual(lhs, rhs, size)
		if not size or size <= 0 then return false end
		for i = 0, size - 1 do
			if lhs[i] ~= rhs[i] then return false end
		end
		return true
	end

	function EasyPipeline:ShouldPushConstants(cmd, pipeline_key, stage_key, offset, data, size)
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
				entry.offset == offset and
				entry.size == size
			then
				if self:_BytesEqual(entry.snapshot, src, size) then
					return false
				end

				table.remove(entries, i)
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

	-- Default: upload all push constant blocks and push once
	-- Override in graphics pipeline for per-stage uploads
	function EasyPipeline:UploadPushConstants()
		if not self.push_constant_block_order or #self.push_constant_block_order == 0 then return end

		local cmd = render.GetCommandBuffer()
		local pipeline_key = self.pipeline
		local stages = self._push_constant_stages or {"compute"}

		for _, name in ipairs(self.push_constant_block_order) do
			local block = self.push_constant_blocks[name]
			local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
			local constants = self.push_constant_structs[struct_name]
			local offset = self.push_constant_block_offsets[name]
			local constants_size = ffi.sizeof(constants)
			upload_block(self, block, constants, name)

			if self:ShouldPushConstants(cmd, pipeline_key, name, offset, constants, constants_size) then
				self.pipeline:PushConstants(cmd, stages, offset, constants, constants_size)
			end
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

return {
	EasyPipeline = EasyPipeline,
	resolve_constant_placement = resolve_constant_placement,
	get_constant_stage_config = get_constant_stage_config,
	resolve_draw_frame_index = resolve_draw_frame_index,
	resolve_draw_framebuffer = resolve_draw_framebuffer,
	assign_auto_binding = assign_auto_binding,
	upload_block = upload_block,
	upload_ubo = upload_ubo,
	get_compute_sampled_descriptor = get_compute_sampled_descriptor,
}
