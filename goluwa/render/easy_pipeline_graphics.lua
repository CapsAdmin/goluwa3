local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local render = import("goluwa/render/render.lua")
local upload_probe = import("goluwa/render/upload_probe.lua")
local GraphicsPipeline = import("goluwa/render/vulkan/graphics_pipeline.lua")
local UniformBuffer = import("goluwa/render/uniform_buffer.lua")
local system = import("goluwa/system.lua")
local glsl_meta = import("goluwa/render/glsl_metadata.lua")
local base = import("goluwa/render/easy_pipeline_base.lua")
local EasyPipeline = base.EasyPipeline
local resolve_constant_placement = base.resolve_constant_placement
local get_constant_stage_config = base.get_constant_stage_config
local resolve_draw_frame_index = base.resolve_draw_frame_index
local resolve_draw_framebuffer = base.resolve_draw_framebuffer
local assign_auto_binding = base.assign_auto_binding
local upload_block = base.upload_block
local upload_ubo = base.upload_ubo
local get_compute_sampled_descriptor = base.get_compute_sampled_descriptor
local EasyPipelineGraphics = objects.CreateTemplate("render_easy_pipeline_graphics")

do
	EasyPipelineGraphics.Base = EasyPipeline

	function EasyPipelineGraphics:UploadConstants()
		local cmd = render.GetCommandBuffer()
		local pipeline_key = self.pipeline
		local probe_enabled = upload_probe.IsEnabled()

		-- Per-stage push constant uploads
		for _, stage_name in ipairs(self.active_stages) do
			local stage_blocks = self._per_stage_push_blocks[stage_name]

			if stage_blocks then
				local stages_to_push = {}

				for _, name in ipairs(self.push_constant_block_order) do
					if stage_blocks[name] then
						local block = self.push_constant_blocks[name]
						local struct_name = name:sub(1, 1):upper() .. name:sub(2) .. "Constants"
						local constants = self.constant_structs[struct_name]
						local offset = self.push_constant_block_offsets[name]
						local constants_size = ffi.sizeof(constants)
						upload_block(self, block, constants, name)

						if
							self:ShouldPushConstants(cmd, pipeline_key, stage_name, offset, constants, constants_size)
						then
							if probe_enabled then
								upload_probe.RecordUpload(block.debug_name, block.field_descriptors, constants, constants_size, true)
							end

							stages_to_push[#stages_to_push + 1] = {
								block = block,
								offset = offset,
								data = constants,
								size = constants_size,
							}
						end
					end
				end

				-- Push all blocks for this stage in one call
				for _, entry in ipairs(stages_to_push) do
					self.pipeline:PushConstants(cmd, {stage_name}, entry.offset, entry.data, entry.size)
				end
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
				self._BytesEqual
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
						local struct_name, ctype = EasyPipeline.BuildPushConstantBlock(block.name, block)
						push_constant_types[struct_name] = ctype
						push_constant_block_offsets[block.name] = 0 -- placeholder
						push_constant_blocks[block.name] = block
						table.insert(push_constant_block_order, block.name)
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
		-- Map each stage to the push constant blocks it uses
		self._per_stage_push_blocks = {}

		for _, stage_name in ipairs(possible_stages) do
			local stage_config = get_constant_stage_config(config, stage_name)

			if stage_config and stage_config.push_constants then
				self._per_stage_push_blocks[stage_name] = {}

				for _, block in ipairs(stage_config.push_constants) do
					self._per_stage_push_blocks[stage_name][block.name] = true
				end
			end
		end

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

	EasyPipelineGraphics:Register()
end

return EasyPipelineGraphics
