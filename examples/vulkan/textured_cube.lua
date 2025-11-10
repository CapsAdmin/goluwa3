local ffi = require("ffi")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
local shaderc = require("shaderc")
local wnd = cocoa.window()
local png = require("helpers.png")
local Buffer = require("helpers.buffer")
local Matrix44f = require("helpers.structs.matrix").Matrix44f
local Vec3 = require("helpers.structs.Vec3")
local Vec2 = require("helpers.structs.Vec2")
local Ang3 = require("helpers.structs.Ang3")
local calc_movement = require("helpers.3d_movement")
local get_time = require("time")
local input = require("helpers.input")
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
local file = io.open("examples/vulkan/capsadmin.png", "rb")
local file_data = file:read("*a")
file:close()
local file_buffer = Buffer.New(file_data, #file_data)
local img = png.decode(file_buffer)
local texture_image = renderer.device:CreateImage(
	img.width,
	img.height,
	"R8G8B8A8_UNORM",
	{"sampled", "transfer_dst", "transfer_src"},
	"device_local"
)
renderer:UploadToImage(
	texture_image,
	img.buffer:GetBuffer(),
	texture_image:GetWidth(),
	texture_image:GetHeight()
)
local texture_view = texture_image:CreateView()
local texture_sampler = renderer.device:CreateSampler(
	{
		min_filter = "nearest",
		mag_filter = "nearest",
		wrap_s = "repeat",
		wrap_t = "repeat",
	}
)

-- Programmatically generate cube geometry
local function generate_cube(size)
	size = size or 1.0
	local half = size / 2
	-- Define the 6 faces of a cube with their properties
	-- Each face: {normal, positions for 4 corners, UVs for 4 corners}
	local faces = {
		-- Front face (+Z)
		{
			normal = {0, 0, 1},
			positions = {
				{-half, -half, half},
				{half, -half, half},
				{half, half, half},
				{-half, half, half},
			},
		},
		-- Back face (-Z)
		{
			normal = {0, 0, -1},
			positions = {
				{half, -half, -half},
				{-half, -half, -half},
				{-half, half, -half},
				{half, half, -half},
			},
		},
		-- Right face (+X)
		{
			normal = {1, 0, 0},
			positions = {
				{half, -half, half},
				{half, -half, -half},
				{half, half, -half},
				{half, half, half},
			},
		},
		-- Left face (-X)
		{
			normal = {-1, 0, 0},
			positions = {
				{-half, -half, -half},
				{-half, -half, half},
				{-half, half, half},
				{-half, half, -half},
			},
		},
		-- Top face (+Y)
		{
			normal = {0, 1, 0},
			positions = {
				{-half, half, half},
				{half, half, half},
				{half, half, -half},
				{-half, half, -half},
			},
		},
		-- Bottom face (-Y)
		{
			normal = {0, -1, 0},
			positions = {
				{-half, -half, -half},
				{half, -half, -half},
				{half, -half, half},
				{-half, -half, half},
			},
		},
	}
	local uvs = {{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	local vertices = {}
	local indices = {}
	local vertex_count = 0

	for face_idx, face in ipairs(faces) do
		-- Add 4 vertices for this face
		for i = 1, 4 do
			local pos = face.positions[i]
			local normal = face.normal
			local uv = uvs[i]
			-- Position (vec3)
			table.insert(vertices, pos[1])
			table.insert(vertices, pos[2])
			table.insert(vertices, pos[3])
			-- Normal (vec3)
			table.insert(vertices, normal[1])
			table.insert(vertices, normal[2])
			table.insert(vertices, normal[3])
			-- UV (vec2)
			table.insert(vertices, uv[1])
			table.insert(vertices, uv[2])
		end

		-- Add 6 indices for this face (2 triangles) - counter-clockwise winding
		table.insert(indices, vertex_count + 0)
		table.insert(indices, vertex_count + 1)
		table.insert(indices, vertex_count + 2)
		table.insert(indices, vertex_count + 0)
		table.insert(indices, vertex_count + 2)
		table.insert(indices, vertex_count + 3)
		vertex_count = vertex_count + 4
	end

	return vertices, indices
end

local cube_vertices, cube_indices = generate_cube(2.0) -- Make it MUCH bigger
local vertex_buffer = renderer:CreateBuffer(
	{
		buffer_usage = "vertex_buffer",
		data_type = "float",
		data = cube_vertices,
	}
)
local index_buffer = renderer:CreateBuffer(
	{
		buffer_usage = "index_buffer",
		data_type = "uint32_t",
		data = cube_indices,
	}
)
-- Create uniform buffer for MVP matrix
local PushConstants = ffi.typeof([[
	struct {
		float mvp[16];
	}
]])
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

					layout(location = 0) in vec3 in_position;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;

					layout(push_constant) uniform PushConstants {
						mat4 mvp;
					} pc;

					layout(location = 0) out vec3 out_normal;
					layout(location = 1) out vec2 out_uv;

					void main() {
						gl_Position = pc.mvp * vec4(in_position, 1.0);
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
					size = ffi.sizeof(PushConstants),
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
						args = {texture_view, texture_sampler},
					},
				},
			},
		},
		rasterizer = {
			depth_clamp = false,
			discard = false,
			polygon_mode = "fill",
			line_width = 1.0,
			cull_mode = "none", -- Disable culling for debugging
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
wnd:Initialize()
wnd:OpenWindow()
local time = get_time()
local frame_count = 0
local next_show_fps = time
local mouse_sensitivity = 0.002 -- Adjust for desired sensitivity
local dt = 0
local last_time = get_time()
local key_trigger = input.SetupInputEvent("Key")
local mouse_trigger = input.SetupInputEvent("Mouse")
local cam_pos = Vec3(0, 0, -5)
local cam_ang = Ang3(0, 0, 0)
local cam_fov = math.rad(60)
local mouse_pos = Vec2(0, 0)
local mouse_delta = Vec2(0, 0)

while true do
	local events = wnd:ReadEvents()
	local time = get_time()
	dt = time - last_time
	last_time = time

	for _, event in ipairs(events) do
		if event.type == "window_close" then
			renderer:WaitForIdle()
			os.exit()
		elseif event.type == "key_press" then
			if event.key == "escape" then
				renderer:WaitForIdle()
				os.exit()
			end

			key_trigger(event.key, true)

			if event.key == "escape" and wnd:IsMouseCaptured() then
				wnd:ReleaseMouse()
			end
		elseif event.type == "key_release" then
			key_trigger(event.key, false)
		elseif event.type == "mouse_move" then
			mouse_pos = Vec2(event.x, event.y)
			mouse_delta = Vec2(event.delta_x, event.delta_y)
		elseif event.type == "mouse_button" then
			mouse_trigger(event.button, event.action == "pressed")

			if
				event.button == "left" and
				event.action == "pressed" and
				not wnd:IsMouseCaptured()
			then
				wnd:CaptureMouse()
			end
		end

		if event.type == "window_resize" then window_target:RecreateSwapchain() end
	end

	local forward
	forward, cam_ang, cam_fov = calc_movement(dt, Ang3(0, 0, 0), cam_fov, wnd:IsMouseCaptured(), mouse_pos, mouse_delta)
	cam_pos = cam_pos + forward
	print(cam_ang)

	if window_target:BeginFrame() then
		local extent = window_target:GetExtent()
		local aspect = extent.width / extent.height
		local proj = Matrix44f():Perspective(cam_fov, 1, 100, aspect)
		local view = Matrix44f()
		--view = view:Rotate(-cam_ang.y, 0, 1, 0):Rotate(-cam_ang.x, 1, 0, 0)
		print(cam_pos)
		view = view:SetTranslation(cam_pos.y, cam_pos.y, cam_pos.z)
		local world = Matrix44f():Rotate(time, 0, 0, 1):Rotate(time, 1, 0, 0):Translate(0, 0, 0)
		local pc_data = PushConstants()
		pc_data.mvp = ffi.cast(pc_data.mvp, proj * view * world)
		local cmd = window_target:GetCommandBuffer()
		cmd:BeginRenderPass(
			window_target:GetRenderPass(),
			window_target:GetFramebuffer(),
			window_target:GetExtent(),
			ffi.new("float[4]", 0.2, 0.2, 0.2, 1.0)
		)
		graphics_pipeline:Bind(cmd)
		graphics_pipeline:PushConstants(cmd, "vertex", 0, pc_data)
		cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
		cmd:SetScissor(0, 0, extent.width, extent.height)
		cmd:BindVertexBuffer(vertex_buffer, 0)
		cmd:BindIndexBuffer(index_buffer, 0)
		cmd:DrawIndexed(36, 1, 0, 0, 0)
		cmd:EndRenderPass()
		window_target:EndFrame()
	end

	if next_show_fps < time then
		wnd:SetTitle("Textured Cube - FPS: " .. frame_count)
		frame_count = 0
		next_show_fps = time + 1
	end

	frame_count = frame_count + 1
	dt = time - last_time
	last_time = time
end
