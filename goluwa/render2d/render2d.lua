local ffi = require("ffi")
local utility = require("utility")
local Color = require("structs.color")
local Vec3 = require("structs.vec3")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Matrix44 = require("structs.matrix44")
local render = require("render.render")
local event = require("event")
local VertexBuffer = require("render.vertex_buffer")
local Mesh = require("render.mesh")
local Texture = require("render.texture")
local Matrix44 = require("structs.matrix44")
local surface_format = "r16g16b16a16_sfloat"
-- Vertex shader push constants (64 bytes)
local VertexConstants = ffi.typeof([[
	struct {
		float projection_view_world[16];
	}
]])
local FragmentConstants = ffi.typeof([[
	struct {
        float global_color[4];          
        float alpha_multiplier;  
        int texture_index;       
        float uv_offset[2];             
        float uv_scale[2];              
        int swizzle_mode;
        float edge_feather;
        int premultiply_output;
        int unpremultiply_input;
	}
]])
local vertex_constants = VertexConstants()
local fragment_constants = FragmentConstants()
local render2d = library()
-- Blend mode presets
render2d.blend_modes = {
	alpha = {
		blend = true,
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one_minus_src_alpha",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	additive = {
		blend = true,
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	multiply = {
		blend = true,
		src_color_blend_factor = "dst_color",
		dst_color_blend_factor = "zero",
		color_blend_op = "add",
		src_alpha_blend_factor = "dst_alpha",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	premultiplied = {
		blend = true,
		src_color_blend_factor = "one",
		dst_color_blend_factor = "one_minus_src_alpha",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one_minus_src_alpha",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	screen = {
		blend = true,
		src_color_blend_factor = "one",
		dst_color_blend_factor = "one_minus_src_color",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "one_minus_src_alpha",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
	none = {
		blend = false,
		src_color_blend_factor = "one",
		dst_color_blend_factor = "zero",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
		color_write_mask = {"r", "g", "b", "a"},
	},
}

function render2d.Initialize()
	if render2d.pipeline then return end

	local dynamic_states = {
		"viewport",
		"scissor",
		"blend_constants",
		"stencil_reference",
		"stencil_compare_mask",
		"stencil_write_mask",
	}
	local device = render.GetDevice()

	if device.has_extended_dynamic_state then
		table.insert(dynamic_states, "stencil_test_enable")
		table.insert(dynamic_states, "stencil_op")
	end

	if device.has_extended_dynamic_state3 then
		table.insert(dynamic_states, "color_blend_enable_ext")
		table.insert(dynamic_states, "color_blend_equation_ext")
	end

	render2d.pipeline_data.dynamic_states = dynamic_states
	render2d.pipeline_data.descriptor_set_count = render.target.image_count
	render2d.pipeline_cache = {}
	render2d.SetSamples(render.target.samples or "1", true)
	render2d.ResetState()
	render2d.rect_mesh = render2d.CreateMesh(
		{
			{pos = Vec3(0, 1, 0), uv = Vec2(0, 0), color = Color(1, 1, 1, 1)},
			{pos = Vec3(0, 0, 0), uv = Vec2(0, 1), color = Color(1, 1, 1, 1)},
			{pos = Vec3(1, 1, 0), uv = Vec2(1, 0), color = Color(1, 1, 1, 1)},
			{pos = Vec3(1, 0, 0), uv = Vec2(1, 1), color = Color(1, 1, 1, 1)},
		},
		{0, 1, 2, 2, 1, 3}
	)
	render2d.triangle_mesh = render2d.CreateMesh(
		{
			{pos = Vec3(-0.5, -0.5, 0), uv = Vec2(0, 0), color = Color(1, 1, 1, 1)},
			{pos = Vec3(0.5, 0.5, 0), uv = Vec2(1, 1), color = Color(1, 1, 1, 1)},
			{pos = Vec3(-0.5, 0.5, 0), uv = Vec2(0, 1), color = Color(1, 1, 1, 1)},
		}
	)
end

function render2d.ResetState()
	render2d.SetTexture()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(1)
	render2d.SetUV()
	render2d.SetSwizzleMode(0)
	render2d.SetEdgeFeather(0)
	render2d.SetPremultiplyOutput(false)
	render2d.UpdateScreenSize(render.GetRenderImageSize())
	render2d.SetBlendMode("alpha", true)
	render2d.SetColorFormat(render.target and render.target:GetColorFormat() or surface_format)

	if render2d.SetStencilMode then render2d.SetStencilMode("none") end
end

do
	render2d.pipeline_data = {
		shader_stages = {
			{
				type = "vertex",
				code = [[
					#version 450
					#extension GL_EXT_scalar_block_layout : require

					layout(location = 0) in vec3 in_pos;
					layout(location = 1) in vec2 in_uv;
					layout(location = 2) in vec4 in_color;

					layout(push_constant, scalar) uniform VertexConstants {
						mat4 projection_view_world;
					} pc;

					layout(location = 0) out vec2 out_uv;
					layout(location = 1) out vec4 out_color;

					void main() {
						gl_Position = pc.projection_view_world * vec4(in_pos, 1.0);
						out_uv = in_uv;
						out_color = in_color;
					}
				]],
				bindings = {
					{
						binding = 0,
						stride = ffi.sizeof("float") * 9, -- vec3 + vec2 + vec4
						input_rate = "vertex",
					},
				},
				attributes = {
					{
						binding = 0,
						location = 0, -- in_position
						format = "r32g32b32_sfloat", -- vec3
						offset = 0,
						lua_type = ffi.typeof("float[3]"),
						lua_name = "pos",
					},
					{
						binding = 0,
						location = 1, -- in_uv
						format = "r32g32_sfloat", -- vec2
						offset = ffi.sizeof("float[3]"),
						lua_type = ffi.typeof("float[2]"),
						lua_name = "uv",
					},
					{
						binding = 0,
						location = 2, -- in_color
						format = "r32g32b32a32_sfloat", -- vec4
						offset = ffi.sizeof("float[3]") + ffi.sizeof("float[2]"),
						lua_type = ffi.typeof("float[4]"),
						lua_name = "color",
					},
				},
				input_assembly = {
					topology = "triangle_list",
					primitive_restart = false,
				},
				push_constants = {
					size = ffi.sizeof(VertexConstants),
					offset = 0,
				},
			},
			{
				type = "fragment",
				code = [[
					#version 450
					#extension GL_EXT_scalar_block_layout : require
					#extension GL_EXT_nonuniform_qualifier : require

					layout(binding = 0) uniform sampler2D textures[1024]; // Bindless texture array
					layout(location = 0) in vec2 in_uv;
					layout(location = 1) in vec4 in_color;
					layout(location = 0) out vec4 out_color;

					layout(push_constant, scalar) 
					uniform FragmentConstants {
						layout(offset = ]] .. ffi.sizeof(VertexConstants) .. [[)
						vec4 global_color;
						float alpha_multiplier;
						int texture_index;
						vec2 uv_offset;
						vec2 uv_scale;
						int swizzle_mode;
						float edge_feather;
						int premultiply_output;
						int unpremultiply_input;
					} pc;                   
					
					void main() 
					{
						out_color = in_color * pc.global_color;
						
						if (pc.texture_index >= 0) {
							vec4 tex = texture(textures[nonuniformEXT(pc.texture_index)], in_uv * pc.uv_scale + pc.uv_offset);
							
							if (pc.unpremultiply_input != 0 && tex.a > 0.0) {
								tex.rgb /= tex.a;
							}

							if (pc.swizzle_mode == 1) tex = vec4(tex.rrr, 1.0);
							else if (pc.swizzle_mode == 2) tex = vec4(tex.ggg, 1.0);
							else if (pc.swizzle_mode == 3) tex = vec4(tex.bbb, 1.0);
							else if (pc.swizzle_mode == 4) tex = vec4(tex.aaa, 1.0);
							else if (pc.swizzle_mode == 5) tex = vec4(tex.rgb, 1.0);
							out_color *= tex;
						}

						if (pc.edge_feather > 0.0) {
							vec2 uv_dist = smoothstep(vec2(0.0), vec2(pc.edge_feather), in_uv) * 
							               smoothstep(vec2(1.0), vec2(1.0 - pc.edge_feather), in_uv);
							out_color.a *= uv_dist.x * uv_dist.y;
						}


						out_color.a = out_color.a * pc.alpha_multiplier;
						
						if (pc.premultiply_output != 0) {
							out_color.rgb *= out_color.a;
						}
					}
				]],
				descriptor_sets = {
					{
						type = "combined_image_sampler",
						binding_index = 0,
						count = 1024,
					},
				},
				push_constants = {
					size = ffi.sizeof(FragmentConstants),
					offset = ffi.sizeof(VertexConstants),
				},
			},
		},
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = "none",
			front_face = "counter_clockwise",
			depth_bias = 0,
		},
		color_blend = {
			logic_op_enabled = false,
			logic_op = "copy",
			constants = {0.0, 0.0, 0.0, 0.0},
			attachments = {
				{
					blend = true,
					src_color_blend_factor = "src_alpha",
					dst_color_blend_factor = "one_minus_src_alpha",
					color_blend_op = "add",
					src_alpha_blend_factor = "one",
					dst_alpha_blend_factor = "zero",
					alpha_blend_op = "add",
					color_write_mask = {"r", "g", "b", "a"},
				},
			},
		},
		multisampling = {
			sample_shading = false,
			rasterization_samples = "1",
		},
		depth_stencil = {
			depth_test = false,
			depth_write = true,
			depth_compare_op = "less",
			depth_bounds_test = false,
			stencil_test = false,
		},
	}

	do
		function render2d.SetColor(r, g, b, a)
			fragment_constants.global_color[0] = r
			fragment_constants.global_color[1] = g
			fragment_constants.global_color[2] = b

			if a then fragment_constants.global_color[3] = a end
		end

		function render2d.SetSwizzleMode(mode)
			if mode then fragment_constants.swizzle_mode = mode end
		end

		function render2d.GetSwizzleMode()
			return fragment_constants.swizzle_mode
		end

		function render2d.GetColor()
			return fragment_constants.global_color[0],
			fragment_constants.global_color[1],
			fragment_constants.global_color[2],
			fragment_constants.global_color[3]
		end

		utility.MakePushPopFunction(render2d, "Color")
		utility.MakePushPopFunction(render2d, "SwizzleMode")
	end

	do
		function render2d.SetEdgeFeather(feather)
			fragment_constants.edge_feather = feather or 0
		end

		function render2d.GetEdgeFeather()
			return fragment_constants.edge_feather
		end

		utility.MakePushPopFunction(render2d, "EdgeFeather")
	end

	do
		function render2d.SetUnpremultiplyInput(enabled)
			fragment_constants.unpremultiply_input = enabled and 1 or 0
		end

		function render2d.GetUnpremultiplyInput()
			return fragment_constants.unpremultiply_input ~= 0
		end

		utility.MakePushPopFunction(render2d, "UnpremultiplyInput")
	end

	do
		function render2d.SetPremultiplyOutput(enabled)
			fragment_constants.premultiply_output = enabled and 1 or 0
		end

		function render2d.GetPremultiplyOutput()
			return fragment_constants.premultiply_output ~= 0
		end

		utility.MakePushPopFunction(render2d, "PremultiplyOutput")
	end

	do
		function render2d.SetAlphaMultiplier(a)
			fragment_constants.alpha_multiplier = a
		end

		function render2d.GetAlphaMultiplier()
			return fragment_constants.alpha_multiplier
		end

		utility.MakePushPopFunction(render2d, "AlphaMultiplier")
	end

	do
		function render2d.SetTexture(tex)
			render2d.current_texture = tex
		end

		function render2d.GetTexture()
			return render2d.current_texture
		end

		utility.MakePushPopFunction(render2d, "Texture")
	end

	function render2d.SetBlendMode(mode_name, force)
		if render2d.current_blend_mode == mode_name and not force then return end

		if not render2d.blend_modes[mode_name] then
			local valid_modes = {}

			for k in pairs(render2d.blend_modes) do
				table.insert(valid_modes, k)
			end

			error(
				"Invalid blend mode: " .. tostring(mode_name) .. ". Valid modes: " .. table.concat(valid_modes, ", ")
			)
		end

		render2d.current_blend_mode = mode_name
		local blend_mode = render2d.blend_modes[mode_name]

		if render.GetDevice().has_extended_dynamic_state3 then
			if render2d.cmd then
				render2d.cmd:SetColorBlendEnable(0, blend_mode.blend)

				if blend_mode.blend then
					render2d.cmd:SetColorBlendEquation(0, blend_mode)
				end
			end
		else
			render2d.UpdatePipeline()

			if render2d.cmd then
				render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
			end
		end
	end

	function render2d.GetBlendMode()
		return render2d.current_blend_mode
	end

	utility.MakePushPopFunction(render2d, "BlendMode")

	function render2d.SetSamples(samples, force)
		if render2d.current_samples == samples and not force then return end

		render2d.current_samples = samples
		render2d.UpdatePipeline()

		if render2d.cmd then
			render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
		end
	end

	function render2d.GetSamples()
		return render2d.current_samples
	end

	utility.MakePushPopFunction(render2d, "Samples")

	function render2d.SetColorFormat(format, force)
		if render2d.current_color_format == format and not force then return end

		render2d.current_color_format = format
		render2d.UpdatePipeline()

		if render2d.cmd then
			render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
		end
	end

	function render2d.GetColorFormat()
		return render2d.current_color_format or
			(
				render.target and
				render.target:GetColorFormat()
			)
	end

	utility.MakePushPopFunction(render2d, "ColorFormat")
	render2d.stencil_modes = {
		none = {
			stencil_test = false,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "always",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		write = { -- Simply write the reference value everywhere
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "replace",
				depth_fail_op = "keep",
				compare_op = "always",
			},
			color_write_mask = {},
		},
		mask_write = { -- Increment level if it matches reference
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "increment_and_clamp",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {},
		},
		mask_test = { -- Pass if it matches reference
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		test = {
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "equal",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
		test_inverse = {
			stencil_test = true,
			front = {
				fail_op = "keep",
				pass_op = "keep",
				depth_fail_op = "keep",
				compare_op = "not_equal",
			},
			color_write_mask = {"r", "g", "b", "a"},
		},
	}

	do
		local current_mode = "none"
		local current_ref = 1
		render2d.stencil_level = 0

		function render2d.SetStencilMode(mode_name, ref)
			ref = ref or current_ref
			local mode = render2d.stencil_modes[mode_name]

			if not mode then error("Invalid stencil mode: " .. tostring(mode_name)) end

			current_mode = mode_name
			current_ref = ref
			local device = render.GetDevice()

			if device.has_extended_dynamic_state then
				if render2d.cmd then
					render2d.cmd:SetStencilTestEnable(mode.stencil_test)

					if mode.stencil_test then
						render2d.cmd:SetStencilOp(
							"front_and_back",
							mode.front.fail_op,
							mode.front.pass_op,
							mode.front.depth_fail_op,
							mode.front.compare_op
						)
						render2d.cmd:SetStencilReference("front_and_back", ref)
						render2d.cmd:SetStencilCompareMask("front_and_back", 0xFF)
						render2d.cmd:SetStencilWriteMask("front_and_back", 0xFF)
					end
				end
			end

			render2d.UpdatePipeline()

			if render2d.cmd then
				render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())

				if device.has_extended_dynamic_state then
					render2d.cmd:SetStencilTestEnable(mode.stencil_test)

					if mode.stencil_test then
						render2d.cmd:SetStencilOp(
							"front_and_back",
							mode.front.fail_op,
							mode.front.pass_op,
							mode.front.depth_fail_op,
							mode.front.compare_op
						)
						render2d.cmd:SetStencilReference("front_and_back", ref)
						render2d.cmd:SetStencilCompareMask("front_and_back", 0xFF)
						render2d.cmd:SetStencilWriteMask("front_and_back", 0xFF)
					end
				end
			end
		end

		function render2d.GetStencilMode()
			return current_mode, current_ref
		end

		function render2d.GetStencilReference()
			return current_ref
		end

		function render2d.ClearStencil(val)
			if render2d.cmd then
				local old_mode, old_ref = render2d.GetStencilMode()
				render2d.stencil_level = 0
				render2d.SetStencilMode("write", val or 0)
				local sw, sh = render2d.GetSize()
				render2d.PushMatrix()
				render2d.SetWorldMatrix(Matrix44())
				render2d.DrawRect(0, 0, sw or 800, sh or 600)
				render2d.PopMatrix()
				render2d.SetStencilMode(old_mode, old_ref)
			end
		end

		function render2d.PushStencilMask()
			render2d.PushStencilMode("mask_write", render2d.stencil_level)
			render2d.stencil_level = render2d.stencil_level + 1
		end

		function render2d.BeginStencilTest()
			render2d.SetStencilMode("mask_test", render2d.stencil_level)
		end

		function render2d.PopStencilMask()
			render2d.PopStencilMode()
			render2d.stencil_level = render2d.stencil_level - 1
		end

		utility.MakePushPopFunction(render2d, "StencilMode")
	end

	function render2d.UpdatePipeline()
		local samples = render2d.current_samples or "1"
		local blend_mode_name = render2d.current_blend_mode or "alpha"
		local stencil_mode_name = render2d.GetStencilMode() or "none"
		local color_format = render2d.GetColorFormat() or surface_format
		-- If we have extended dynamic state, we don't need to bake the blend mode into the pipeline cache key
		local cache_key = samples .. "_" .. color_format
		local device = render.GetDevice()

		if not device.has_extended_dynamic_state3 then
			cache_key = cache_key .. "_" .. blend_mode_name
		end

		-- Always include stencil mode in cache key because color_write_mask is not yet handled as dynamic state
		cache_key = cache_key .. "_stencil_" .. stencil_mode_name

		if render2d.pipeline_cache[cache_key] then
			render2d.pipeline = render2d.pipeline_cache[cache_key]
			return
		end

		local data = table.copy(render2d.pipeline_data)
		data.samples = samples
		data.color_format = color_format
		local blend_mode = render2d.blend_modes[blend_mode_name]

		if blend_mode then
			data.color_blend.attachments[1] = {
				blend = blend_mode.blend,
				src_color_blend_factor = blend_mode.src_color_blend_factor,
				dst_color_blend_factor = blend_mode.dst_color_blend_factor,
				color_blend_op = blend_mode.color_blend_op,
				src_alpha_blend_factor = blend_mode.src_alpha_blend_factor,
				dst_alpha_blend_factor = blend_mode.dst_alpha_blend_factor,
				alpha_blend_op = blend_mode.alpha_blend_op,
				color_write_mask = blend_mode.color_write_mask,
			}
		end

		local stencil_mode = render2d.stencil_modes[stencil_mode_name]

		if stencil_mode then
			data.depth_stencil.stencil_test = stencil_mode.stencil_test and 1 or 0
			data.depth_stencil.front = stencil_mode.front
			data.depth_stencil.back = stencil_mode.front -- Same for both for 2D
			if stencil_mode.color_write_mask then
				data.color_blend.attachments[1].color_write_mask = stencil_mode.color_write_mask
			end
		end

		render2d.pipeline = render.CreateGraphicsPipeline(data)
		render2d.pipeline_cache[cache_key] = render2d.pipeline
	end

	function render2d.GetPipelineVariantInfo()
		if render2d.pipeline and render2d.pipeline.GetVariantInfo then
			return render2d.pipeline:GetVariantInfo()
		end

		return {count = 0, keys = {}, current = nil}
	end

	function render2d.SetBlendConstants(r, g, b, a)
		if render2d.cmd then render2d.cmd:SetBlendConstants(r, g, b, a) end
	end

	function render2d.SetScissor(x, y, w, h)
		if x < 0 then
			w = w + x
			x = 0
		end

		if y < 0 then
			h = h + y
			y = 0
		end

		w = math.max(w, 0)
		h = math.max(h, 0)

		if render2d.cmd then render2d.cmd:SetScissor(x, y, w, h) end
	end

	do
		local stack = {}

		function render2d.PushScissor(x, y, w, h)
			local current = stack[#stack]

			if current then
				local x2 = math.max(x, current.x)
				local y2 = math.max(y, current.y)
				local w2 = math.min(x + w, current.x + current.w) - x2
				local h2 = math.min(y + h, current.y + current.h) - y2
				x, y, w, h = x2, y2, math.max(0, w2), math.max(0, h2)
			end

			local data = {x = x, y = y, w = w, h = h}
			table.insert(stack, data)
			render2d.SetScissor(x, y, w, h)
		end

		function render2d.PopScissor()
			table.remove(stack)
			local current = stack[#stack]

			if current then
				render2d.SetScissor(current.x, current.y, current.w, current.h)
			else
				local sw, sh = render2d.GetSize()
				render2d.SetScissor(0, 0, sw or 0, sh or 0)
			end
		end
	end

	function render2d.UploadConstants(cmd)
		do
			vertex_constants.projection_view_world = render2d.GetMatrix():GetFloatCopy()
			render2d.pipeline:PushConstants(cmd, "vertex", 0, vertex_constants)
		end

		do
			fragment_constants.texture_index = render2d.current_texture and
				render2d.pipeline:GetTextureIndex(render2d.current_texture) or
				-1
			render2d.pipeline:PushConstants(cmd, "fragment", ffi.sizeof(vertex_constants), fragment_constants)
		end
	end
end

do -- mesh
	function render2d.CreateMesh(vertices, indices)
		return Mesh.New(render2d.pipeline:GetVertexAttributes(), vertices, indices)
	end

	render2d.last_bound_mesh = nil
	local last_cmd = nil

	function render2d.BindMesh(mesh)
		if last_cmd ~= render2d.cmd or render2d.last_bound_mesh ~= mesh then
			mesh:Bind(render2d.cmd, 0)
			render2d.last_bound_mesh = mesh
			last_cmd = render2d.cmd
		end
	end

	function render2d.DrawIndexedMesh(index_count, instance_count, first_index, vertex_offset, first_instance)
		render2d.cmd:DrawIndexed(
			index_count or index_buffer:GetIndexCount(),
			instance_count or 1,
			first_index or 0,
			vertex_offset or 0,
			first_instance or 0
		)
	end

	function render2d.DrawMesh(vertex_count, instance_count, first_vertex, first_instance)
		render2d.cmd:Draw(
			vertex_count or vertex_buffer:GetVertexCount(),
			instance_count or 1,
			first_vertex or 0,
			first_instance or 0
		)
	end
end

do -- uv
	local X, Y, W, H, SX, SY

	function render2d.SetUV(x, y, w, h, sx, sy)
		if not x then
			-- Reset to default (no transformation)
			fragment_constants.uv_offset[0] = 0
			fragment_constants.uv_offset[1] = 0
			fragment_constants.uv_scale[0] = 1
			fragment_constants.uv_scale[1] = 1
		else
			sx = sx or 1
			sy = sy or 1
			local y = -y - h
			-- Set UV offset and scale
			fragment_constants.uv_offset[0] = x / sx
			fragment_constants.uv_offset[1] = y / sy
			fragment_constants.uv_scale[0] = w / sx
			fragment_constants.uv_scale[1] = h / sy
		end

		X = x
		Y = y
		W = w
		H = h
		SX = sx
		SY = sy
	end

	function render2d.GetUV()
		return X, Y, W, H, SX, SY
	end

	function render2d.SetUV2(u1, v1, u2, v2)
		-- Calculate offset and scale from UV coordinates
		fragment_constants.uv_offset[0] = u1
		fragment_constants.uv_offset[1] = v1
		fragment_constants.uv_scale[0] = u2 - u1
		fragment_constants.uv_scale[1] = v2 - v1
	end

	utility.MakePushPopFunction(render2d, "UV")
end

do -- camera
	local proj = Matrix44()
	local view = Matrix44()
	local world = Matrix44()
	local viewport = Rect(0, 0, 512, 512)
	local view_pos = Vec2(0, 0)
	local view_zoom = Vec2(1, 1)
	local view_angle = 0
	local world_matrix_stack = {Matrix44()}
	local world_matrix_stack_pos = 1
	local proj_view = Matrix44()

	local function update_proj_view()
		proj_view = view * proj
	end

	local function update_projection()
		proj:Identity()
		proj:Ortho(viewport.x, viewport.w, viewport.y, viewport.h, -16000, 16000)
		update_proj_view()
	end

	local function update_view()
		view:Identity()
		local x, y = viewport.w / 2, viewport.h / 2
		view:Translate(x, y, 0)
		view:Rotate(view_angle, 0, 0, 1)
		view:Translate(-x, -y, 0)
		view:Translate(view_pos.x, view_pos.y, 0)
		view:Translate(x, y, 0)
		view:Scale(view_zoom.x, view_zoom.y, 1)
		view:Translate(-x, -y, 0)
		update_proj_view()
	end

	function render2d.UpdateScreenSize(size)
		viewport.w = size.w
		viewport.h = size.h
		update_projection()
		update_view()
	end

	function render2d.GetMatrix()
		return world_matrix_stack[world_matrix_stack_pos] * proj_view
	end

	function render2d.GetSize()
		return viewport.w, viewport.h
	end

	do
		local ceil = math.ceil

		function render2d.Translate(x, y, z)
			world_matrix_stack[world_matrix_stack_pos]:Translate(ceil(x), ceil(y), z or 0)
		end
	end

	function render2d.Translatef(x, y, z)
		world_matrix_stack[world_matrix_stack_pos]:Translate(x, y, z or 0)
	end

	function render2d.Rotate(a)
		world_matrix_stack[world_matrix_stack_pos]:Rotate(a, 0, 0, 1)
	end

	function render2d.Scale(w, h, z)
		world_matrix_stack[world_matrix_stack_pos]:Scale(w, h or w, z or 1)
	end

	function render2d.Shear(x, y)
		world_matrix_stack[world_matrix_stack_pos]:Shear(x, y, 0)
	end

	function render2d.LoadIdentity()
		world_matrix_stack[world_matrix_stack_pos]:Identity()
	end

	function render2d.PushMatrix(x, y, w, h, a, dont_multiply)
		world_matrix_stack_pos = world_matrix_stack_pos + 1

		if dont_multiply then
			world_matrix_stack[world_matrix_stack_pos] = Matrix44()
		else
			world_matrix_stack[world_matrix_stack_pos] = world_matrix_stack[world_matrix_stack_pos - 1]:Copy()
		end

		if x and y then render2d.Translate(x, y) end

		if w and h then render2d.Scale(w, h) end

		if a then render2d.Rotate(a) end
	end

	function render2d.PopMatrix()
		if world_matrix_stack_pos > 1 then
			world_matrix_stack_pos = world_matrix_stack_pos - 1
		else
			error("Matrix stack underflow")
		end
	end

	function render2d.SetWorldMatrix(mat)
		world_matrix_stack[world_matrix_stack_pos] = mat:Copy()
	end

	function render2d.GetWorldMatrix()
		return world_matrix_stack[world_matrix_stack_pos]
	end
end

do
	function render2d.DrawRect(x, y, w, h, a, ox, oy)
		render2d.BindMesh(render2d.rect_mesh)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if ox then render2d.Translate(-ox, -oy) end

		if w and h then render2d.Scale(w, h) end

		render2d.UploadConstants(render2d.cmd)
		render2d.rect_mesh:DrawIndexed(render2d.cmd, 6)
		render2d.PopMatrix()
	end
end

do
	function render2d.DrawTriangle(x, y, w, h, a)
		render2d.BindMesh(render2d.triangle_mesh)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if w and h then render2d.Scale(w, h) end

		render2d.UploadConstants(render2d.cmd)
		render2d.triangle_mesh:Draw(render2d.cmd, 3)
		render2d.PopMatrix()
	end
end

function render2d.BindPipeline()
	render2d.cmd = render.GetCommandBuffer()

	if render2d.cmd then
		render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
		render2d.SetBlendMode(render2d.current_blend_mode, true)
	end

	-- Reset mesh binding cache since command buffer state was reset
	render2d.last_bound_mesh = nil
end

render2d.SetColor(1, 1, 1, 1)
render2d.SetAlphaMultiplier(1)
render2d.SetSwizzleMode(0)
render2d.current_blend_mode = "alpha"
render2d.current_samples = "1"
render2d.current_color_format = render.target and render.target:GetColorFormat() or surface_format

event.AddListener("PostDraw", "draw_2d", function(cmd, dt)
	if not render2d.pipeline then return end -- not 2d initialized
	render2d.BindPipeline()
	event.Call("Draw2D", dt)
	render2d.cmd = nil
end)

event.AddListener("WindowFramebufferResized", "render2d", function(wnd, size)
	if render.target and render.target.config.offscreen then return end

	render2d.UpdateScreenSize(size)
end)

return render2d
