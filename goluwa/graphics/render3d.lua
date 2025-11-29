local ffi = require("ffi")
local render = require("graphics.render")
local event = require("event")
local window = require("graphics.window")
local camera = require("graphics.camera")
local cam = camera.CreateCamera()
local VertexConstants = ffi.typeof([[
	struct {
		float projection_view_world[16];
	}
]])
local FragmentConstants = ffi.typeof([[
	struct {
		int texture_index;
	}
]])
local render3d = {}
render3d.cam = cam
render3d.current_texture = nil

function render3d.Initialize()
	render3d.pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			shader_stages = {
				{
					type = "vertex",
					code = [[
					#version 450
					#extension GL_EXT_scalar_block_layout : require

					layout(location = 0) in vec3 in_position;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;

					layout(push_constant, scalar) uniform Constants {
						mat4 projection_view_world;
					} pc;

					layout(location = 0) out vec3 out_normal;
					layout(location = 1) out vec2 out_uv;

					void main() {
						gl_Position = pc.projection_view_world * vec4(in_position, 1.0);
						out_normal = in_normal;
						out_uv = in_uv;
					}
				]],
					bindings = {
						{
							binding = 0,
							stride = ffi.sizeof("float") * 8, -- vec3 + vec3 + vec2
							input_rate = "vertex",
						},
					},
					attributes = {
						{
							binding = 0,
							location = 0, -- in_position
							format = "R32G32B32_SFLOAT", -- vec3
							offset = 0,
						},
						{
							binding = 0,
							location = 1, -- in_normal
							format = "R32G32B32_SFLOAT", -- vec3
							offset = ffi.sizeof("float") * 3,
						},
						{
							binding = 0,
							location = 2, -- in_uv
							format = "R32G32_SFLOAT", -- vec2
							offset = ffi.sizeof("float") * 6,
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
					#extension GL_EXT_nonuniform_qualifier : require

					layout(binding = 0) uniform sampler2D textures[1024]; // Bindless texture array

					// from vertex shader
					layout(location = 0) in vec3 in_normal;
					layout(location = 1) in vec2 in_uv;

					// output color
					layout(location = 0) out vec4 out_color;

					layout(push_constant) uniform Constants {
						layout(offset = ]] .. ffi.sizeof(VertexConstants) .. [[)
						int texture_index;
					} pc;

					void main() {
						// Simple directional light
						vec3 light_dir = normalize(vec3(0.5, -1.0, 0.3));
						vec3 normal = normalize(in_normal);
						float diffuse = max(dot(normal, -light_dir), 0.0);
						
						// Ambient + diffuse lighting
						float ambient = 0.3;
						float lighting = ambient + diffuse * 0.7;
						
						vec4 tex_color = texture(textures[nonuniformEXT(pc.texture_index)], in_uv);
						out_color.rgb = tex_color.rgb * lighting;
						out_color.a = tex_color.a;
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
				cull_mode = "none", -- Disable culling for double-sided materials
				front_face = "counter_clockwise",
				depth_bias = 0,
			},
			color_blend = {
				logic_op_enabled = false,
				logic_op = "copy",
				constants = {0.0, 0.0, 0.0, 0.0},
				attachments = {
					{
						blend = false,
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
				depth_test = true,
				depth_write = true,
				depth_compare_op = "less",
				depth_bounds_test = false,
				stencil_test = false,
			},
		}
	)

	event.AddListener("Draw", "draw_3d", function(cmd, dt)
		local frame_index = render.GetCurrentFrame()
		render3d.pipeline:Bind(cmd, frame_index)
		event.Call("Draw3D", cmd, dt)
	end)
end

function render3d.SetWorldMatrix(world)
	cam:SetWorld(world)
end

function render3d.UploadConstants(cmd)
	local matrices = cam:GetMatrices()

	do
		local vertex_constants = VertexConstants()
		vertex_constants.projection_view_world = matrices.projection_view_world:GetFloatCopy()
		render3d.pipeline:PushConstants(cmd, "vertex", 0, vertex_constants)
	end

	do
		local fragment_constants = FragmentConstants()
		fragment_constants.texture_index = render3d.pipeline:GetTextureIndex(render3d.current_texture)
		render3d.pipeline:PushConstants(cmd, "fragment", ffi.sizeof(VertexConstants), fragment_constants)
	end
end

function render3d.SetTexture(tex)
	render3d.current_texture = tex
	render3d.pipeline:RegisterTexture(tex)
end

return render3d
