local event = require("event")
local ffi = require("ffi")
local orientation = require("orientation")
local Matrix44 = require("structs.matrix").Matrix44
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local skybox = {}

function skybox.Initialize()
	if skybox.pipeline then return end

	skybox.pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			shader_stages = {
				{
					type = "vertex",
					code = [[
					#version 450
					
					layout(location = 0) out vec3 out_direction;
					
					layout(push_constant) uniform Constants {
						mat4 inv_projection_view;
					} pc;
					
					vec2 positions[3] = vec2[](
						vec2(-1.0, -1.0),
						vec2( 3.0, -1.0),
						vec2(-1.0,  3.0)
					);
					
					void main() {
						vec2 pos = positions[gl_VertexIndex];
						gl_Position = vec4(pos, 1.0, 1.0);
						
						// Convert NDC to world direction
						vec4 world_pos = pc.inv_projection_view * vec4(pos, 1.0, 1.0);
						out_direction = world_pos.xyz / world_pos.w;
					}
				]],
					push_constants = {
						size = ffi.sizeof("float") * 16,
						offset = 0,
					},
				},
				{
					type = "fragment",
					code = [[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					
					layout(binding = 0) uniform sampler2D textures[1024];
					
					layout(location = 0) in vec3 in_direction;
					layout(location = 0) out vec4 out_color;
					
					layout(push_constant) uniform Constants {
						layout(offset = 64)
						int environment_texture_index;
					} pc;
					
					const float PI = 3.14159265359;
					
					void main() {
						if (pc.environment_texture_index < 0) {
							out_color = vec4(0.2, 0.2, 0.2, 1.0);
							return;
						}
						
						vec3 dir = normalize(in_direction);
						float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
						float v = asin(dir.y) / PI + 0.5;
						vec3 color = texture(textures[nonuniformEXT(pc.environment_texture_index)], vec2(u, -v)).rgb;
						
						// Tonemapping + gamma
						color = color / (color + vec3(1.0));
						color = pow(color, vec3(1.0/2.2));
						
						out_color = vec4(color, 1.0);
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
						size = ffi.sizeof("int"),
						offset = ffi.sizeof("float") * 16,
					},
				},
			},
			rasterizer = {
				depth_clamp = false,
				discard = false,
				polygon_mode = "fill",
				line_width = 1.0,
				cull_mode = {"front"},
				front_face = orientation.FRONT_FACE,
				depth_bias = 0,
			},
			color_blend = {
				logic_op_enabled = false,
				logic_op = "copy",
				constants = {0.0, 0.0, 0.0, 0.0},
				attachments = {
					{
						blend = false,
						src_color_blend_factor = "one",
						dst_color_blend_factor = "zero",
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
				depth_write = false,
				depth_compare_op = "less_or_equal",
				depth_bounds_test = false,
				stencil_test = false,
			},
		}
	)
end

event.AddListener("Render3DInitialized", "skybox", function()
	skybox.Initialize()
end)

if render3d.pipeline then skybox.Initialize() end

local inv_proj_view = Matrix44()
local SkyboxConstants = ffi.typeof([[
		struct {
			float inv_projection_view[16];
			int texture_index;
		}
	]])
local skybox_constants = SkyboxConstants()

function skybox.Draw()
	local cmd = render.GetCommandBuffer()

	if not skybox.texture or not skybox.pipeline then return end

	render3d.SetEnvironmentTexture(skybox.GetTexture())
	local frame_index = render.GetCurrentFrame()
	skybox.pipeline:Bind(cmd, frame_index)
	-- Calculate inverse projection-view matrix (without camera translation for skybox)
	local proj = render3d.camera:BuildProjectionMatrix()
	local view = render3d.camera:BuildViewMatrix():Copy()
	-- Remove translation from view matrix for skybox
	view.m30 = 0
	view.m31 = 0
	view.m32 = 0
	local proj_view = view * proj
	proj_view:GetInverse(inv_proj_view)
	-- Upload constants
	local matrix_copy = inv_proj_view:GetFloatCopy()
	ffi.copy(skybox_constants.inv_projection_view, matrix_copy, ffi.sizeof("float") * 16)
	skybox_constants.texture_index = skybox.pipeline:RegisterTexture(skybox.texture)
	skybox.pipeline:PushConstants(cmd, "vertex", 0, skybox_constants)
	-- Draw fullscreen triangle
	cmd:Draw(3, 1, 0, 0)
end

event.AddListener("DrawSkybox", "skybox", skybox.Draw)

function skybox.SetTexture(texture)
	skybox.texture = texture
end

function skybox.GetTexture()
	return skybox.texture
end

return skybox
