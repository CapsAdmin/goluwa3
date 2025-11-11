local ffi = require("ffi")
local Renderer = require("graphics.renderer")
local system = require("system")
local Matrix44f = require("structs.matrix").Matrix44f
local Vec3 = require("structs.Vec3")
local Vec2 = require("structs.Vec2")
local Ang3 = require("structs.Ang3")
local event = require("event")
local window = require("window")
local file_formats = require("file_formats")
local Transform = require("transform")
local wnd = window.Open()
local renderer = Renderer.New(
	{
		surface_handle = assert(wnd:GetSurfaceHandle()),
		present_mode = "fifo",
		image_count = nil, -- Use default (minImageCount + 1)
		surface_format_index = 1,
		composite_alpha = "opaque",
	}
)
local window_target = renderer:CreateWindowRenderTarget()
local MatrixConstants = ffi.typeof([[
	struct {
		$ projection_view;
		$ world;
	}
]], Matrix44f, Matrix44f)
local graphics_pipeline = renderer:CreatePipeline(
	{
		render_pass = window_target:GetRenderPass(),
		dynamic_states = {"viewport", "scissor"},
		shader_stages = {
			{
				type = "vertex",
				code = [[
					#version 450

					layout(location = 0) in vec3 in_position;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;

					layout(push_constant) uniform MatrixConstants {
						mat4 projection_view;
						mat4 world;
					} pc;

					layout(location = 0) out vec3 out_normal;
					layout(location = 1) out vec2 out_uv;

					void main() {
						gl_Position = pc.projection_view * pc.world * vec4(in_position, 1.0);
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
					size = ffi.sizeof(MatrixConstants),
					offset = 0,
				},
			},
			{
				type = "fragment",
				code = [[
					#version 450

					layout(binding = 0) uniform sampler2D tex_sampler;

					// from vertex shader
					layout(location = 0) in vec3 frag_normal;
					layout(location = 1) in vec2 frag_uv;

					// output color
					layout(location = 0) out vec4 out_color;

					void main() {
						// Simple directional light
						vec3 light_dir = normalize(vec3(0.5, -1.0, 0.3));
						vec3 normal = normalize(frag_normal);
						float diffuse = max(dot(normal, -light_dir), 0.0);
						
						// Ambient + diffuse lighting
						float ambient = 0.3;
						float lighting = ambient + diffuse * 0.7;
						
						vec4 tex_color = texture(tex_sampler, frag_uv);
						out_color.rgb = tex_color.rgb * lighting;
						out_color.a = tex_color.a;
					}
				]],
				descriptor_sets = {
					{
						type = "combined_image_sampler",
						binding_index = 0,
					},
				},
			},
		},
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = "back",
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
			depth_test = true, -- Disable for debugging
			depth_write = true,
			depth_compare_op = "less",
			depth_bounds_test = false,
			stencil_test = false,
		},
	}
)

event.AddListener("KeyInput", "test", function(key, press)
	if key == "escape" and press then system.ShutDown() end
end)

event.AddListener("FramebufferResized", "test", function(size)
	window_target:RecreateSwapchain()
end)

local camera = require("graphics.camera").CreateCamera()
wnd:SetMouseTrapped(true)
local calc_movement = require("graphics.3d_movement")

event.AddListener("Update", "rendering", function(dt)
	local cam_pos = camera:GetPosition()
	local cam_ang = camera:GetAngles()
	local cam_fov = camera:GetFOV()
	local dir, ang, fov = calc_movement(dt, cam_ang, cam_fov)
	cam_pos = cam_pos + dir
	camera:SetPosition(cam_pos)
	camera:SetAngles(ang)
	camera:SetFOV(fov)

	if not window_target:BeginFrame() then return end

	local cmd = window_target:GetCommandBuffer()
	camera:SetWorld(renderer.world_matrix)
	graphics_pipeline:PushConstants(
		cmd,
		"vertex",
		0,
		MatrixConstants(
			{
				projection_view = camera:GetMatrices().projection_view,
				world = camera:GetMatrices().world,
			}
		)
	)
	cmd:BeginRenderPass(
		window_target:GetRenderPass(),
		window_target:GetFramebuffer(),
		window_target:GetExtent(),
		ffi.new("float[4]", 0.2, 0.2, 0.2, 1.0)
	)
	graphics_pipeline:Bind(cmd)
	local extent = window_target:GetExtent()
	local aspect = extent.width / extent.height
	cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
	cmd:SetScissor(0, 0, extent.width, extent.height)
	event.Call("Draw3D", cmd, camera, dt)
	cmd:EndRenderPass()
	window_target:EndFrame()

	if wait(1) then
		wnd:SetTitle("FPS: " .. math.round(1 / system.GetFrameTime()))
	end
end)

event.AddListener("Shutdown", "test", function()
	renderer:WaitForIdle()
	system.ShutDown()
end)

function renderer.SetWorldMatrix(world)
	renderer.world_matrix = world
end

function renderer.UpdateDescriptorSet(type, index, binding_index, ...)
	graphics_pipeline:UpdateDescriptorSet(type, index, binding_index, ...)
end

return renderer
