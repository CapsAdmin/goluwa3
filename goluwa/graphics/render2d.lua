local ffi = require("ffi")
local utility = require("utility")
local Colorf = require("structs.color").Colorf
local Vec3f = require("structs.vec3").Vec3f
local Vec2f = require("structs.vec2").Vec2f
local Rect = require("structs.rect")
local Matrix44f = require("structs.matrix").Matrix44f
local render = require("graphics.render")
local window = require("graphics.window")
local event = require("event")
local VertexBuffer = require("graphics.vertex_buffer")
local IndexBuffer = require("graphics.index_buffer")
local Texture = require("graphics.texture")
-- Vertex shader push constants (64 bytes)
local VertexConstants = ffi.typeof([[
	struct {
		$ projection_view_world;
	}
]], Matrix44f -- projection_view_world
)
-- Fragment shader push constants (64 bytes - fits in remaining 64 byte budget)
local FragmentConstants = ffi.typeof(
	[[
	struct {
        $ global_color;           // 16 bytes
        $ color_override;         // 16 bytes
        $ hsv_mult;               // 12 bytes
        //float alpha_multiplier;   // 4 bytes
        $ world_scale;            // 8 bytes
        float alpha_test_ref;     // 4 bytes
        float border_radius;      // 4 bytes
        int texture_index;        // 4 bytes - for bindless texture selection
	}
]],
	Colorf, -- global_color
	Colorf, -- color_override
	Vec3f, -- hsv_mult
	Vec2f -- world_scale
-- Total: 68 bytes (offset 64-131)
)
local vertex_constants = VertexConstants()
local fragment_constants = FragmentConstants()
local render2d = {}
-- Bindless texture management
render2d.texture_registry = {} -- texture_object -> index mapping
render2d.texture_array = {} -- array of {view, sampler} for descriptor set
render2d.next_texture_index = 0
render2d.max_textures = 1024
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
	-- Set default blend mode
	render2d.current_blend_mode = "alpha"
	-- Check if dynamic blend is supported
	local device = render.GetDevice()
	render2d.has_dynamic_blend = device.has_dynamic_blend or false
	-- Update dynamic states based on support
	local dynamic_states = {"viewport", "scissor", "blend_constants"}

	if render2d.has_dynamic_blend then
		table.insert(dynamic_states, "color_blend_enable_ext")
		table.insert(dynamic_states, "color_blend_equation_ext")
	end

	render2d.pipeline_data.dynamic_states = dynamic_states
	render2d.pipeline = render.CreateGraphicsPipeline(render2d.pipeline_data)
	local mesh_data = {
		{pos = Vec3f(0, 1, 0), uv = Vec2f(0, 0), color = Colorf(1, 1, 1, 1)},
		{pos = Vec3f(0, 0, 0), uv = Vec2f(0, 1), color = Colorf(1, 1, 1, 1)},
		{pos = Vec3f(1, 1, 0), uv = Vec2f(1, 0), color = Colorf(1, 1, 1, 1)},
		{pos = Vec3f(1, 0, 0), uv = Vec2f(1, 1), color = Colorf(1, 1, 1, 1)},
		{pos = Vec3f(1, 1, 0), uv = Vec2f(1, 0), color = Colorf(1, 1, 1, 1)},
		{pos = Vec3f(0, 0, 0), uv = Vec2f(0, 1), color = Colorf(1, 1, 1, 1)},
	}
	local indices = {}

	for i = 1, #mesh_data do
		indices[i] = i - 1
	end

	render2d.rectangle_indices = IndexBuffer.New(indices)
	render2d.rectangle = render2d.CreateMesh(mesh_data)

	do
		local buffer = ffi.new("uint8_t[4]", {255, 255, 255, 255})
		render2d.white_texture = Texture.New(
			{
				width = 1,
				height = 1,
				buffer = buffer,
				format = "R8G8B8A8_UNORM",
			}
		)
	end

	render2d.SetTexture()
	render2d.SetHSV(1, 1, 1)
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetColorOverride(0, 0, 0, 0)
	render2d.SetAlphaMultiplier(1)
	render2d.SetAlphaTestReference(0)
	render2d.SetBorderRadius(0)
	render2d.UpdateScreenSize(window:GetSize())
	-- Register white texture as index 0 for bindless
	render2d.RegisterTexture(render2d.white_texture)
	render2d.ready = true
end

function render2d.IsReady()
	return render2d.ready == true
end

do -- shader
	render2d.pipeline_data = {
		dynamic_states = {"viewport", "scissor"}, -- Will be updated in Initialize() based on support
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
						format = "R32G32B32_SFLOAT", -- vec3
						offset = 0,
						lua_type = Vec3f,
						lua_name = "pos",
					},
					{
						binding = 0,
						location = 1, -- in_uv
						format = "R32G32_SFLOAT", -- vec2
						offset = ffi.sizeof(Vec3f),
						lua_type = Vec2f,
						lua_name = "uv",
					},
					{
						binding = 0,
						location = 2, -- in_color
						format = "R32G32B32A32_SFLOAT", -- vec4
						offset = ffi.sizeof(Vec3f) + ffi.sizeof(Vec2f),
						lua_type = Colorf,
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

			layout(push_constant, scalar) uniform FragmentConstants {
				layout(offset = 64) vec4 global_color;
				vec4 color_override;
				vec3 hsv_mult;
				//float alpha_multiplier;
				vec2 world_scale;
				float alpha_test_ref;
				float border_radius;
				int texture_index;
			} pc;                    vec3 rgb2hsv(vec3 c)
                    {
                        vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
                        vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
                        vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

                        float d = q.x - min(q.w, q.y);
                        float e = 1.0e-10;
                        return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
                    }

                    vec3 hsv2rgb(vec3 c)
                    {
                        vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
                        vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
                        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
                    }

				void main() {
					
					vec4 tex_color = texture(textures[nonuniformEXT(pc.texture_index)], in_uv);
					float alpha_test = pc.alpha_test_ref;
					if (alpha_test > 0.0) {
						if (tex_color.a < alpha_test) {
							discard;
						}
					}

					vec4 override = pc.color_override;                        if (override.r > 0) tex_color.r = override.r;
                        if (override.g > 0) tex_color.g = override.g;
                        if (override.b > 0) tex_color.b = override.b;
                        if (override.a > 0) tex_color.a = override.a;

                        out_color = tex_color * in_color * pc.global_color;
                        out_color.a = out_color.a;// * pc.alpha_multiplier;

                        vec3 hsv_mult = pc.hsv_mult;
                        if (hsv_mult != vec3(1,1,1)) {
                            out_color.rgb = hsv2rgb(rgb2hsv(out_color.rgb) * hsv_mult);
                        }

                        // Calculate screen size from gl_FragCoord instead of push constant
                        vec2 screen_size = vec2(1.0 / fwidth(gl_FragCoord.x), 1.0 / fwidth(gl_FragCoord.y));
                        
                        vec2 ratio = vec2(1, 1);

                        if (screen_size.y > screen_size.x) {
                            ratio = vec2(1, screen_size.y / screen_size.x);
                        } else {
                            ratio = vec2(1, screen_size.y / screen_size.x);
                        }

                        float radius = pc.border_radius;
                        if (radius > 0) {
                            float softness = 50;
                            vec2 scale = pc.world_scale;
                            vec2 ratio2 = vec2(scale.y / scale.x, 1);
                            vec2 size = scale;
                            radius = min(radius, scale.x/2);
                            radius = min(radius, scale.y/2);

                            if (in_uv.x > 1.0 - radius/scale.x && in_uv.y > 1.0 - radius/scale.y) {
                                float distance = 0;
                                distance += length((in_uv - vec2(1, 1) + vec2(radius/scale.x, radius/scale.y)) * scale) * 1/radius;
                                out_color.a *= -pow(distance, softness)+1;
                            }

                            if (in_uv.x < radius/scale.x && in_uv.y > 1.0 - radius/scale.y) {
                                float distance = 0;
                                distance += length((in_uv - vec2(0, 1) + vec2(-radius/scale.x, radius/scale.y)) * scale) * 1/radius;
                                out_color.a *= -pow(distance, softness)+1;
                            }

                            if (in_uv.x > 1.0 - radius/scale.x && in_uv.y < radius/scale.y) {
                                float distance = 0;
                                distance += length((in_uv - vec2(1, 0) + vec2(radius/scale.x, -radius/scale.y)) * scale) * 1/radius;
                                out_color.a *= -pow(distance, softness)+1;
                            }

                            if (in_uv.x < radius/scale.x && in_uv.y < radius/scale.y) {
                                float distance = 0;
                                distance += length((in_uv - vec2(0, 0) + vec2(-radius/scale.x, -radius/scale.y)) * scale) * 1/radius;
                                out_color.a *= -pow(distance, softness)+1;
                            }
                        }


					}
				]],
				descriptor_sets = {
					{
						type = "combined_image_sampler",
						binding_index = 0,
						count = 1024, -- Array of 1024 textures for bindless
					},
				},
				push_constants = {
					size = ffi.sizeof(FragmentConstants),
					offset = 64, -- Must not overlap with vertex push constants (0-63)
				},
			},
		},
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = "front",
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
	render2d.pipeline = render2d.pipeline or NULL

	function render2d.CreateMesh(vertices)
		return VertexBuffer.New(vertices, render2d.pipeline:GetVertexAttributes())
	end

	function render2d.SetHSV(h, s, v)
		fragment_constants.hsv_mult.x = h
		fragment_constants.hsv_mult.y = s
		fragment_constants.hsv_mult.z = v
	end

	function render2d.GetHSV()
		return fragment_constants.hsv_mult:Unpack()
	end

	utility.MakePushPopFunction(render2d, "HSV")

	function render2d.SetColor(r, g, b, a)
		fragment_constants.global_color.r = r
		fragment_constants.global_color.g = g
		fragment_constants.global_color.b = b
		fragment_constants.global_color.a = a or fragment_constants.global_color.a
	end

	function render2d.GetColor()
		return fragment_constants.global_color:Unpack()
	end

	utility.MakePushPopFunction(render2d, "Color")

	function render2d.SetColorOverride(r, g, b, a)
		fragment_constants.color_override.r = r
		fragment_constants.color_override.g = g
		fragment_constants.color_override.b = b
		fragment_constants.color_override.a = a or fragment_constants.color_override.a
	end

	function render2d.GetColorOverride()
		return fragment_constants.color_override:Unpack()
	end

	utility.MakePushPopFunction(render2d, "ColorOverride")

	function render2d.SetAlpha(a)
		fragment_constants.global_color.a = a
	end

	function render2d.GetAlpha()
		return fragment_constants.global_color.a
	end

	utility.MakePushPopFunction(render2d, "Alpha")

	function render2d.SetAlphaMultiplier(a) --fragment_constants.alpha_multiplier = a or fragment_constants.alpha_multiplier
	end

	function render2d.GetAlphaMultiplier() --return fragment_constants.alpha_multiplier
	end

	utility.MakePushPopFunction(render2d, "AlphaMultiplier")

	-- Bindless texture registration
	function render2d.RegisterTexture(tex)
		-- Check if texture is already registered
		if render2d.texture_registry[tex] then
			return render2d.texture_registry[tex]
		end

		-- Check if we have space
		if render2d.next_texture_index >= render2d.max_textures then
			error("Texture registry full! Max textures: " .. render2d.max_textures)
		end

		-- Register the texture
		local index = render2d.next_texture_index
		render2d.texture_registry[tex] = index
		render2d.texture_array[index + 1] = {view = tex.view, sampler = tex.sampler}
		render2d.next_texture_index = render2d.next_texture_index + 1

		-- Update all descriptor sets with the new texture array
		for frame_i = 1, render.GetSwapchainImageCount() do
			render2d.pipeline:UpdateDescriptorSetArray(frame_i, 0, render2d.texture_array)
		end

		return index
	end

	function render2d.SetTexture(tex)
		tex = tex or render2d.white_texture
		render2d.current_texture = tex

		-- Register texture if not already registered (bindless)
		if not render2d.texture_registry[tex] then render2d.RegisterTexture(tex) end
	end

	function render2d.GetTexture()
		return render2d.current_texture
	end

	utility.MakePushPopFunction(render2d, "Texture")

	function render2d.SetAlphaTestReference(num)
		if not num then num = 0 end

		fragment_constants.alpha_test_ref = num
	end

	function render2d.GetAlphaTestReference()
		return fragment_constants.alpha_test_ref
	end

	utility.MakePushPopFunction(render2d, "AlphaTestReference")

	function render2d.SetBorderRadius(num)
		if not num then num = 0 end

		fragment_constants.border_radius = num
	end

	function render2d.GetBorderRadius()
		return fragment_constants.border_radius
	end

	utility.MakePushPopFunction(render2d, "BorderRadius")

	function render2d.SetBlendMode(mode_name)
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

		-- Apply blend mode
		if render2d.has_dynamic_blend then
			-- Use dynamic state if supported
			local blend_mode = render2d.blend_modes[mode_name]

			if render2d.cmd then
				render2d.cmd:SetColorBlendEnable(0, blend_mode.blend)

				if blend_mode.blend then
					render2d.cmd:SetColorBlendEquation(0, blend_mode)
				end
			end
		else
			-- Rebuild pipeline with new blend mode if dynamic state not supported
			local blend_mode = render2d.blend_modes[mode_name]
			render2d.pipeline:RebuildPipeline("color_blend", blend_mode)

			-- Rebind the pipeline if we're in the middle of rendering
			if render2d.cmd then
				local frame_index = render.GetCurrentFrame()
				render2d.pipeline:Bind(render2d.cmd, frame_index)
			end
		end
	end

	function render2d.GetBlendMode()
		return render2d.current_blend_mode
	end

	utility.MakePushPopFunction(render2d, "BlendMode")

	function render2d.GetPipelineVariantInfo()
		if render2d.pipeline and render2d.pipeline.GetVariantInfo then
			return render2d.pipeline:GetVariantInfo()
		end

		return {count = 0, keys = {}, current = nil}
	end

	function render2d.SetBlendConstants(r, g, b, a)
		if render2d.cmd then render2d.cmd:SetBlendConstants(r, g, b, a) end
	end

	function render2d.UploadConstants(cmd)
		-- With bindless textures, we don't need to rebind descriptor sets
		-- Just update the texture index in push constants
		render2d.last_texture = render2d.current_texture
		-- Update vertex constants
		vertex_constants.projection_view_world = render2d.camera:GetMatrices().projection_view_world
		render2d.pipeline:PushConstants(cmd, "vertex", 0, vertex_constants)
		-- Update fragment constants (including texture index)
		local world_matrix = render2d.camera:GetMatrices().world
		fragment_constants.world_scale = Vec2f(world_matrix.m00, world_matrix.m11)
		fragment_constants.texture_index = render2d.texture_registry[render2d.current_texture] or 0
		render2d.pipeline:PushConstants(cmd, "fragment", 64, fragment_constants)
	end

	function render2d.UpdateScreenSize(size)
		render2d.camera:SetViewport(Rect(0, 0, size.x, size.y))
	-- screen_size is now calculated in the shader from gl_FragCoord
	end
end

do -- rectangle
	function render2d.DrawRect(x, y, w, h, a, ox, oy)
		render2d.PushMatrix()

		if x and y then render2d.Translate(x, y) end

		if a then render2d.Rotate(a) end

		if ox then render2d.Translate(-ox, -oy) end

		if w and h then render2d.Scale(w, h) end

		render2d.UploadConstants(render2d.cmd)
		render2d.cmd:DrawIndexed(6, 1, 0, 0, 0)
		render2d.PopMatrix()
	end

	do
		--[[{
		{pos = {0, 0}, uv = {xbl, ybl}, color = color_bottom_left},
		{pos = {0, 1}, uv = {xtl, ytl}, color = color_top_left},
		{pos = {1, 1}, uv = {xtr, ytr}, color = color_top_right},

		{pos = {1, 1}, uv = {xtr, ytr}, color = color_top_right},
		{pos = {1, 0}, uv = {xbr, ybr}, color = mesh_data[1].color},
		{pos = {0, 0}, uv = {xbl, ybl}, color = color_bottom_left},
	})]]
		-- sdasdasd
		local last_xtl = 0
		local last_ytl = 0
		local last_xtr = 1
		local last_ytr = 0
		local last_xbl = 0
		local last_ybl = 1
		local last_xbr = 1
		local last_ybr = 1
		local last_color_bottom_left = Colorf(1, 1, 1, 1)
		local last_color_top_left = Colorf(1, 1, 1, 1)
		local last_color_top_right = Colorf(1, 1, 1, 1)
		local last_color_bottom_right = Colorf(1, 1, 1, 1)

		local function update_vbo()
			local vertices = render2d.rectangle:GetData()

			if
				last_xtl ~= vertices[1].uv.x or
				last_ytl ~= vertices[1].uv.y or
				last_xtr ~= vertices[5].uv.x or
				last_ytr ~= vertices[5].uv.y or
				last_xbl ~= vertices[2].uv.x or
				last_ybl ~= vertices[1].uv.y or
				last_xbr ~= vertices[4].uv.x or
				last_ybr ~= vertices[4].uv.y or
				last_color_bottom_left ~= vertices[2].color or
				last_color_top_left ~= vertices[1].color or
				last_color_top_right ~= vertices[3].color or
				last_color_bottom_right ~= vertices[4].color
			then
				render2d.rectangle:Upload()
				last_xtl = vertices[1].uv.x
				last_ytl = vertices[1].uv.y
				last_xtr = vertices[5].uv.x
				last_ytr = vertices[5].uv.y
				last_xbl = vertices[2].uv.x
				last_ybl = vertices[1].uv.y
				last_xbr = vertices[4].uv.x
				last_ybr = vertices[4].uv.y
				last_color_bottom_left = vertices[2].color
				last_color_top_left = vertices[1].color
				last_color_top_right = vertices[3].color
				last_color_bottom_right = vertices[4].color
			end
		end

		do
			local X, Y, W, H, SX, SY

			function render2d.SetRectUV(x, y, w, h, sx, sy)
				local vertices = render2d.rectangle:GetData()

				if not x then
					vertices[2].uv.x = 0
					vertices[1].uv.y = 0
					vertices[2].uv.y = 1
					vertices[3].uv.x = 1
				else
					sx = sx or 1
					sy = sy or 1
					local y = -y - h
					vertices[2].uv.x = x / sx
					vertices[1].uv.y = y / sy
					vertices[2].uv.y = (y + h) / sy
					vertices[3].uv.x = (x + w) / sx
				end

				vertices[1].uv.x = vertices[2].uv.x
				vertices[3].uv.y = vertices[1].uv.y
				vertices[5].uv.x = vertices[3].uv.x
				vertices[5].uv.y = vertices[1].uv.y
				vertices[4].uv.x = vertices[3].uv.x
				vertices[4].uv.y = vertices[2].uv.y
				vertices[6].uv.x = vertices[2].uv.x
				vertices[6].uv.y = vertices[2].uv.y
				update_vbo()
				X = x
				Y = y
				W = w
				H = h
				SX = sx
				SY = sy
			end

			function render2d.GetRectUV()
				return X, Y, W, H, SX, SY
			end

			function render2d.SetRectUV2(u1, v1, u2, v2)
				local vertices = render2d.rectangle:GetData()
				vertices[2].uv.x = u1
				vertices[1].uv.y = v1
				vertices[2].uv.y = u2
				vertices[3].uv.x = v2
				vertices[1].uv.x = vertices[2].uv.x
				vertices[3].uv.y = vertices[1].uv.y
				vertices[5].uv.x = vertices[3].uv.x
				vertices[5].uv.y = vertices[1].uv.y
				vertices[4].uv.x = vertices[3].uv.x
				vertices[4].uv.y = vertices[2].uv.y
				vertices[6].uv.x = vertices[2].uv.x
				vertices[6].uv.y = vertices[2].uv.y
				update_vbo()
			end
		end

		function render2d.SetRectColors(cbl, ctl, ctr, cbr)
			local vertices = render2d.rectangle:GetData()

			if not cbl then
				for i = 1, 6 do
					local r, g, b, a = 1, 1, 1, 1
					vertices[i].color.r = r
					vertices[i].color.g = g
					vertices[i].color.b = b
					vertices[i].color.a = a
				end
			else
				local r, g, b, a = cbl:Unpack()
				vertices[2].color.r = r
				vertices[2].color.g = g
				vertices[2].color.b = b
				vertices[2].color.a = a
				r, g, b, a = ctl:Unpack()
				vertices[1].color.r = r
				vertices[1].color.g = g
				vertices[1].color.b = b
				vertices[1].color.a = a
				r, g, b, a = ctr:Unpack()
				vertices[3].color.r = r
				vertices[3].color.g = g
				vertices[3].color.b = b
				vertices[3].color.a = a
				vertices[5].color.r = r
				vertices[5].color.g = g
				vertices[5].color.b = b
				vertices[5].color.a = a
				r, g, b, a = cbr:Unpack()
				vertices[4].color.r = r
				vertices[4].color.g = g
				vertices[4].color.b = b
				vertices[4].color.a = a
				vertices[6].color.r = vertices[1].color.r
				vertices[6].color.g = vertices[1].color.g
				vertices[6].color.b = vertices[1].color.b
				vertices[6].color.a = vertices[1].color.a
			end

			update_vbo()
		end
	end
end

do -- camera
	local camera = require("graphics.camera")
	render2d.camera = camera.CreateCamera()
	render2d.camera:Set3D(false)
	render2d._camera = render2d.camera

	function render2d.SetCamera(cam)
		render2d.camera = cam or render2d._camera
	end

	function render2d.GetSize()
		return render2d.camera.Viewport.w, render2d.camera.Viewport.h
	end

	do
		local ceil = math.ceil

		function render2d.Translate(x, y, z)
			render2d.camera:TranslateWorld(ceil(x), ceil(y), z or 0)
		end
	end

	function render2d.Translatef(x, y, z)
		render2d.camera:TranslateWorld(x, y, z or 0)
	end

	function render2d.Rotate(a)
		render2d.camera:RotateWorld(a, 0, 0, 1)
	end

	function render2d.Scale(w, h, z)
		render2d.camera:ScaleWorld(w, h or w, z or 1)
	end

	function render2d.Shear(x, y)
		render2d.camera:ShearWorld(x, y, 0)
	end

	function render2d.LoadIdentity()
		render2d.camera:LoadIdentityWorld()
	end

	function render2d.PushMatrix(x, y, w, h, a, dont_multiply)
		render2d.camera:PushWorld(nil, dont_multiply)

		if x and y then render2d.Translate(x, y) end

		if w and h then render2d.Scale(w, h) end

		if a then render2d.Rotate(a) end
	end

	function render2d.PopMatrix()
		render2d.camera:PopWorld()
	end

	function render2d.SetWorldMatrix(mat)
		render2d.camera:SetWorld(mat)
	end

	function render2d.GetWorldMatrix()
		return render2d.camera:GetWorld()
	end

	function render2d.ScreenToWorld(x, y)
		return render2d.camera:ScreenToWorld(x, y)
	end

	function render2d.ScreenTo3DWorld(x, y)
		return render3d.camera:ScreenToWorld(x, y)
	end

	function render2d.Start3D2D(pos, ang, scale)
		render2d.camera:Start3D2DEx(pos, ang, scale)
	end

	function render2d.End3D2D()
		render2d.camera:End3D2D()
	end
end

do -- stencil
	do
		local X, Y, W, H = 0, 0

		function render2d.SetScissor(x, y, w, h)
			error("NYI", 2)
			X = x
			Y = y
			W = w or render.GetWidth()
			H = h or render.GetHeight()

			if not x then
				X = 0
				Y = 0
				render.SetScissor()
			else
				x, y = render2d.ScreenToWorld(-x, -y)
				render.SetScissor(-x, -y, w, h)
			end
		end

		function render2d.GetScissor()
			error("NYI", 2)
			return X, Y, W, H
		end

		utility.MakePushPopFunction(render2d, "Scissor")
	end

	do
		function render2d.PushStencilRect(x, y, w, h)
			error("NYI", 2)
			render.SetStencil(true)
			render.GetFrameBuffer():ClearStencil(0)
			render.StencilFunction("always", 1, 0xFFFFFFFF)
			render.StencilOperation("keep", "keep", "replace")
			render.SetColorMask(0, 0, 0, 0)
			render2d.PushTexture()
			render2d.DrawRect(x, y, w, h)
			render2d.PopTexture()
			render.SetColorMask(1, 1, 1, 1)
			render.StencilFunction("equal", 1)
		end

		function render2d.PopStencilRect()
			error("NYI", 2)
			render.SetStencil(false)
		end
	end

	do
		local X, Y, W, H

		function render2d.EnableClipRect(x, y, w, h, i)
			error("NYI", 2)
			i = i or 1
			render.SetStencil(true)
			render.GetFrameBuffer():ClearStencil(0) -- out = 0
			render.StencilOperation("keep", "replace", "replace")
			-- if true then stencil = 33 return true end
			render.StencilFunction("always", i)
			-- on fail, keep zero value
			-- on success replace it with 33
			-- write to the stencil buffer
			-- on fail is probably never reached
			render2d.PushTexture()
			render.SetColorMask(0, 0, 0, 0)
			render2d.DrawRect(x, y, w, h)
			render.SetColorMask(1, 1, 1, 1)
			render2d.PopTexture()
			-- if stencil == 33 then stencil = 33 return true else return false end
			render.StencilFunction("equal", i)
			X = x
			Y = y
			W = w
			H = h
		end

		function render2d.GetClipRect()
			error("NYI", 2)
			return X or 0, Y or 0, W or render.GetWidth(), H or render.GetHeight()
		end

		function render2d.DisableClipRect()
			error("NYI", 2)
			render.SetStencil(false)
		end
	end
end

render2d.Initialize()

event.AddListener("PostDraw", "draw_2d", function(cmd, dt)
	local frame_index = render.GetCurrentFrame()

	-- Ensure correct pipeline variant is active if not using dynamic blend
	if not render2d.has_dynamic_blend then
		local blend_mode = render2d.blend_modes[render2d.current_blend_mode]
		render2d.pipeline:RebuildPipeline("color_blend", blend_mode)
	end

	-- Bind pipeline and descriptor set (bindless - one set with all textures)
	render2d.pipeline:Bind(cmd, frame_index)
	cmd:BindVertexBuffer(render2d.rectangle:GetBuffer(), 0)
	cmd:BindIndexBuffer(render2d.rectangle_indices:GetBuffer(), 0, "uint16")
	render2d.cmd = cmd
	render2d.texture_changed = false

	-- Set initial blend mode for the frame (only if dynamic blend is supported)
	if render2d.has_dynamic_blend then
		render2d.SetBlendMode(render2d.current_blend_mode)
	end

	event.Call("Draw2D", dt)
end)

event.AddListener("FramebufferResized", "render2d", function(size)
	render2d.UpdateScreenSize(size)
end)

return render2d
