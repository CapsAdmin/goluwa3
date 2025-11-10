local ffi = require("ffi")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
local shaderc = require("shaderc")
local wnd = cocoa.window()
local Color = require("helpers.structs.color")
local PushConstants = ffi.typeof([[
	struct {
		struct {
			float r;
			float g;
			float b;
		} color;
		float alpha;
	}
]])
local renderer = Renderer.New(
	{
		surface_handle = assert(wnd:GetMetalLayer()),
		present_mode = "fifo",
		image_count = nil, -- Use default (minImageCount + 1)
		surface_format_index = 1,
		composite_alpha = "opaque",
	}
)
local window_target = renderer:CreateWindowRenderTarget()
local offscreen_target = renderer:CreateOffscreenRenderTarget(
	32,
	32,
	"R8G8B8A8_UNORM",
	{
		usage = {"color_attachment", "sampled"},
		final_layout = "color_attachment_optimal",
	}
)
local noise_pipeline = renderer:CreatePipeline(
	{
		render_pass = offscreen_target:GetRenderPass(),
		shader_stages = {
			{
				type = "vertex",
				code = [[
					#version 450

					// Full-screen triangle
					vec2 positions[3] = vec2[](
						vec2(-1.0, -1.0),
						vec2( 3.0, -1.0),
						vec2(-1.0,  3.0)
					);

					layout(location = 0) out vec2 frag_uv;

					void main() {
						vec2 pos = positions[gl_VertexIndex];
						gl_Position = vec4(pos, 0.0, 1.0);
						frag_uv = pos * 0.5 + 0.5;
					}
				]],
				input_assembly = {
					topology = "triangle_list",
					primitive_restart = false,
				},
			},
			{
				type = "fragment",
				code = [[
					#version 450

					layout(binding = 0) uniform NoiseParams {
						float seed;
					} params;

					layout(location = 0) in vec2 frag_uv;
					layout(location = 0) out vec4 out_color;

					// Simple hash function for noise
					float hash(vec2 p) {
						p = fract(p * vec2(123.34, 456.21));
						p += dot(p, p + 34.23);
						return fract(p.x * p.y);
					}

					void main() {
						vec2 uv = frag_uv * 1000 + params.seed;
						float noise = hash(floor(uv));
						out_color = vec4(vec3(noise), 1.0);
					}
				]],
				descriptor_sets = {
					{
						type = "uniform_buffer",
						binding_index = 0,
						args = {
							renderer:CreateBuffer(
								{
									byte_size = ffi.sizeof("float"),
									buffer_usage = "uniform_buffer",
									data = ffi.new("float[1]", math.random() * 1000.0),
								}
							),
						},
					},
				},
			},
		},
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = "none",
			front_face = "clockwise",
			depth_bias = 0,
		},
		color_blend = {
			logic_op_enabled = false,
			logic_op = "copy",
			constants = {0.0, 0.0, 0.0, 0.0},
			attachments = {
				{
					blend = false,
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
			depth_write = false,
			depth_compare_op = "less",
			depth_bounds_test = false,
			stencil_test = false,
		},
	}
)

local function update_noise_texture()
	offscreen_target:BeginFrame()
	local cmd = offscreen_target:GetCommandBuffer()
	noise_pipeline:GetUniformBuffer(0):CopyData(ffi.new("float[1]", math.random() * 1000.0))
	cmd:BeginRenderPass(
		offscreen_target:GetRenderPass(),
		offscreen_target:GetFramebuffer(),
		offscreen_target:GetExtent(),
		ffi.new("float[4]", 0.0, 0.0, 0.0, 1.0)
	)
	noise_pipeline:Bind(cmd)
	local extent = offscreen_target:GetExtent()
	cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
	cmd:SetScissor(0, 0, extent.width, extent.height)
	cmd:Draw(3, 1, 0, 0)
	cmd:EndRenderPass()
	offscreen_target:ReadMode(cmd)
	offscreen_target:EndFrame()
end

update_noise_texture()
local texture_sampler = renderer.device:CreateSampler(
	{
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	}
)
local vertex_buffer = renderer:CreateBuffer(
	{
		buffer_usage = "vertex_buffer",
		data_type = "float",
		data = {
			-- top-left (red) + UV (0, 0)
			-0.5, -- x
			-0.5, -- y
			1.0, -- r
			0.0, -- g
			0.0, -- b
			0.0, -- u
			0.0, -- v
			-- top-right (green) + UV (1, 0)
			0.5,
			-0.5,
			0.0,
			1.0,
			0.0,
			1.0,
			0.0,
			-- bottom-right (blue) + UV (1, 1)
			0.5,
			0.5,
			0.0,
			0.0,
			1.0,
			1.0,
			1.0,
			-- bottom-left (yellow) + UV (0, 1)
			-0.5,
			0.5,
			1.0,
			1.0,
			0.0,
			0.0,
			1.0,
		},
	}
)
local index_buffer = renderer:CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = {
			0,
			1,
			2, -- first triangle (top-left, top-right, bottom-right)
			2,
			3,
			0, -- second triangle (bottom-right, bottom-left, top-left)
		},
	}
)
-- Create pipeline once at startup with dynamic viewport/scissor
local graphics_pipeline = renderer:CreatePipeline(
	{
		render_pass = window_target:GetRenderPass(),
		dynamic_states = {"viewport", "scissor"},
		shader_stages = {
			{
				type = "vertex",
				code = [[
					#version 450

					layout(location = 0) in vec2 in_position;
					layout(location = 1) in vec3 in_color;
					layout(location = 2) in vec2 in_uv;

					layout(location = 0) out vec3 frag_color;
					layout(location = 1) out vec2 frag_uv;

					void main() {
						gl_Position = vec4(in_position, 0.0, 1.0);
						frag_color = in_color;
						frag_uv = in_uv;
					}
				]],
				bindings = {
					{
						binding = 0,
						stride = ffi.sizeof("float") * 7, -- vec2 + vec3 + vec2
						input_rate = "vertex",
					},
				},
				attributes = {
					{
						binding = 0,
						location = 0, -- in_position
						format = "R32G32_SFLOAT", -- vec2
						offset = 0,
					},
					{
						binding = 0,
						location = 1, -- in_color
						format = "R32G32B32_SFLOAT", -- vec3
						offset = ffi.sizeof("float") * 2,
					},
					{
						binding = 0,
						location = 2, -- in_uv
						format = "R32G32_SFLOAT", -- vec2
						offset = ffi.sizeof("float") * 5,
					},
				},
				input_assembly = {
					topology = "triangle_list",
					primitive_restart = false,
				},
			},
			{
				type = "fragment",
				code = [[
					#version 450

					layout(binding = 0) uniform ColorUniform1 {
						vec3 color_multiplier;
					} ubo1;

					layout(push_constant) uniform PushConstants {
						vec3 color_multiplier;
						float alpha;
					} pc;

					layout(binding = 1) uniform sampler2D tex_sampler;

					// from vertex shader
					layout(location = 0) in vec3 frag_color;
					layout(location = 1) in vec2 frag_uv;

					// output color
					layout(location = 0) out vec4 out_color;

					void main() {
						vec4 tex_color = texture(tex_sampler, frag_uv);
						out_color.rgb = frag_color * pc.color_multiplier * ubo1.color_multiplier * tex_color.rgb;
						out_color.a = pc.alpha * tex_color.a;
					}
				]],
				descriptor_sets = {
					{
						type = "uniform_buffer",
						binding_index = 0,
						args = {
							renderer:CreateBuffer(
								{
									byte_size = Color().ByteSize,
									buffer_usage = "uniform_buffer",
									data = Color(1.0, 1.0, 1.0),
								}
							),
						},
					},
					{
						type = "combined_image_sampler",
						binding_index = 1,
						args = {offscreen_target:GetImageView(), texture_sampler},
					},
				},
				push_constants = {
					size = ffi.sizeof(PushConstants),
					offset = 0,
				},
			},
		},
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = "back",
			front_face = "clockwise",
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
			depth_write = false,
			depth_compare_op = "less",
			depth_bounds_test = false,
			stencil_test = false,
		},
	}
)
wnd:Initialize()
wnd:OpenWindow()
local frame_count = 0

while true do
	local events = wnd:ReadEvents()

	for _, event in ipairs(events) do
		if event.type == "window_close" then
			renderer:WaitForIdle()
			os.exit()
		end

		if event.type == "window_resize" then window_target:RecreateSwapchain() end
	end

	if window_target:BeginFrame() then
		local cmd = window_target:GetCommandBuffer()
		cmd:BeginRenderPass(
			window_target:GetRenderPass(),
			window_target:GetFramebuffer(),
			window_target:GetExtent(),
			ffi.new("float[4]", 0.2, 0.2, 0.2, 1.0)
		)
		graphics_pipeline:Bind(cmd)
		local extent = window_target:GetExtent()
		local pc_data = PushConstants()
		pc_data.color = Color.FromHSV((os.clock() % 10) / 10, 1.0, 1.0):Cast(pc_data.color)
		pc_data.alpha = math.abs(math.sin(os.clock() * 0.5))
		graphics_pipeline:PushConstants(cmd, "fragment", 0, pc_data)
		cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
		cmd:SetScissor(0, 0, extent.width, extent.height)
		cmd:BindVertexBuffer(vertex_buffer, 0)
		cmd:BindIndexBuffer(index_buffer, 0)
		cmd:DrawIndexed(6, 1, 0, 0, 0)
		cmd:EndRenderPass()
		window_target:EndFrame()
	end

	if frame_count % 30 == 0 then update_noise_texture() end

	threads.sleep(1)
	frame_count = frame_count + 1
end
