local ffi = require("ffi")
local cocoa = require("cocoa")
local threads = require("threads")
local Renderer = require("helpers.renderer")
-- Create window
local wnd = cocoa.window()
-- Initialize renderer
local renderer = Renderer.New(
	{
		surface_handle = assert(wnd:GetMetalLayer()),
		present_mode = "fifo",
		image_count = nil,
		surface_format_index = 1,
		composite_alpha = "opaque",
	}
)
-- Create window render target for explicit rendering to the window
local window_target = renderer:CreateWindowRenderTarget()

-- Game of Life configuration
local WORKGROUP_SIZE = 16
local GAME_WIDTH, GAME_HEIGHT -- Will be set based on window size
local UniformData = ffi.typeof("struct { float time; float colorShift; float brightness; float contrast; }")
local COMPUTE_SHADER = [[
#version 450

layout (local_size_x = 16, local_size_y = 16) in;

layout (binding = 0, rgba8) uniform readonly image2D inputImage;
layout (binding = 1, rgba8) uniform writeonly image2D outputImage;

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(inputImage);

	if (pos.x >= size.x || pos.y >= size.y) {
		return;
	}

	// Count alive neighbors (wrapping at edges)
	int count = 0;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			if (dx == 0 && dy == 0) continue; 

			ivec2 neighbor = ivec2(
				(pos.x + dx + size.x) % size.x, 
				(pos.y + dy + size.y) % size.y
			);

			vec4 cell = imageLoad(inputImage, neighbor);
			if (cell.r > 0.5) {
				count++;
			}
		}
	}

	// Current cell state
	vec4 current = imageLoad(inputImage, pos);
	bool alive = current.r > 0.5;

	// Conway's Game of Life rules
	bool newState = false;
	if (alive) {
		newState = (count == 2 || count == 3);
	} else {
		newState = (count == 3);
	}

	// Write result
	vec4 color = newState ? vec4(1.0, 1.0, 1.0, 1.0) : vec4(0.0, 0.0, 0.0, 1.0);
	imageStore(outputImage, pos, color);
}
]]
-- Fullscreen vertex shader
local VERTEX_SHADER = [[
#version 450

layout(location = 0) out vec2 fragTexCoord;

vec2 positions[6] = vec2[](
	vec2(-1.0, -1.0),
	vec2( 1.0, -1.0),
	vec2( 1.0,  1.0),
	vec2(-1.0, -1.0),
	vec2( 1.0,  1.0),
	vec2(-1.0,  1.0)
);

vec2 texCoords[6] = vec2[](
	vec2(0.0, 0.0),
	vec2(1.0, 0.0),
	vec2(1.0, 1.0),
	vec2(0.0, 0.0),
	vec2(1.0, 1.0),
	vec2(0.0, 1.0)
);

void main() {
	gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
	fragTexCoord = texCoords[gl_VertexIndex];
}
]]
-- Fragment shader with post-processing effects
local FRAGMENT_SHADER = [[
#version 450

layout(binding = 0, rgba8) uniform readonly image2D gameImage;
layout(binding = 1) uniform UniformBuffer {
	float time;
	float colorShift;
	float brightness;
	float contrast;
} ubo;

layout(location = 0) in vec2 fragTexCoord;
layout(location = 0) out vec4 outColor;

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
	ivec2 size = imageSize(gameImage);
	ivec2 texCoord = ivec2(fragTexCoord * vec2(size));

	vec4 cell = imageLoad(gameImage, texCoord);

	// Base color
	vec3 color = cell.rgb;

	// Add color based on alive cells with hue shift over time
	if (cell.r > 0.5) {
		float hue = fract(ubo.colorShift + fragTexCoord.x * 0.1 + fragTexCoord.y * 0.1);
		vec3 hsvColor = hsv2rgb(vec3(hue, 0.8, 1.0));
		color = hsvColor;
	}

	// Apply brightness and contrast
	color = (color - 0.5) * ubo.contrast + 0.5 + ubo.brightness;

	// Vignette effect
	vec2 uv = fragTexCoord * 2.0 - 1.0;
	float vignette = 1.0 - dot(uv, uv) * 0.2;
	color *= vignette;

	outColor = vec4(color, 1.0);
}
]]
-- Storage images for ping-pong compute (Game of Life needs 2 images to read from one and write to the other)
local storage_images = {}
local storage_image_views = {}

local function create_storage_images()
	local extent = renderer:GetExtent()
	local pixel_count = extent.width * extent.height
	-- Generate random initial state
	local data = ffi.new("uint8_t[?]", pixel_count * 4)
	math.randomseed(os.time())

	for i = 0, pixel_count - 1 do
		local alive = math.random() < 0.3
		local value = alive and 255 or 0
		data[i * 4 + 0] = value
		data[i * 4 + 1] = value
		data[i * 4 + 2] = value
		data[i * 4 + 3] = 255
	end

	-- Create 2 storage images for ping-pong
	storage_images = {}
	storage_image_views = {}

	for i = 1, 2 do
		local image = renderer.device:CreateImage(
			extent.width,
			extent.height,
			"R8G8B8A8_UNORM",
			{"storage", "transfer_dst", "transfer_src"},
			"device_local"
		)
		renderer:UploadToImage(image, data, extent.width, extent.height)
		storage_images[i] = image
		storage_image_views[i] = image:CreateView()
	end
end

local compute_pipeline = renderer:CreateComputePipeline(
	{
		shader = COMPUTE_SHADER,
		workgroup_size = WORKGROUP_SIZE,
		descriptor_set_count = 2, -- 2 sets for ping-pong
		descriptor_layout = {
			{binding_index = 0, type = "storage_image", stageFlags = "compute", count = 1}, -- input
			{binding_index = 1, type = "storage_image", stageFlags = "compute", count = 1}, -- output
		},
		descriptor_pool = {
			{type = "storage_image", count = 4}, -- 2 bindings * 2 sets
		},
	}
)
create_storage_images()
local graphics_pipeline = renderer:CreatePipeline(
	{
		render_pass = window_target:GetRenderPass(),
		dynamic_states = {"viewport", "scissor"},
		shader_stages = {
			{type = "vertex", code = VERTEX_SHADER},
			{
				type = "fragment",
				code = FRAGMENT_SHADER,
				descriptor_sets = {
					{
						type = "storage_image",
						binding_index = 0,
						args = {
							storage_image_views[1],
						},
					},
					{
						type = "uniform_buffer",
						binding_index = 1,
						args = {
							renderer:CreateBuffer(
								{
									byte_size = ffi.sizeof(UniformData),
									buffer_usage = "uniform_buffer",
									data = UniformData({0.0, 0.0, 0.0, 1.0}),
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
			front_face = "counter_clockwise",
			depth_bias = 0,
		},
		color_blend = {
			logic_op_enabled = false,
			logic_op = "copy",
			constants = {0.0, 0.0, 0.0, 0.0},
			attachments = {{blend = false, color_write_mask = {"r", "g", "b", "a"}}},
		},
		multisampling = {sample_shading = false, rasterization_samples = "1"},
		depth_stencil = {
			depth_test = false,
			depth_write = false,
			depth_compare_op = "less",
			depth_bounds_test = false,
			stencil_test = false,
		},
	}
)

local function update_descriptor_sets()
	-- Update compute pipeline descriptor sets
	compute_pipeline:UpdateDescriptorSet("storage_image", 1, 0, storage_image_views[1])
	compute_pipeline:UpdateDescriptorSet("storage_image", 1, 1, storage_image_views[2])
	compute_pipeline:UpdateDescriptorSet("storage_image", 2, 0, storage_image_views[2])
	compute_pipeline:UpdateDescriptorSet("storage_image", 2, 1, storage_image_views[1])
	-- Update graphics pipeline
	graphics_pipeline:UpdateDescriptorSet("storage_image", 1, 0, storage_image_views[1])
end

update_descriptor_sets()
wnd:Initialize()
wnd:OpenWindow()
-- Simulation state
local paused = false
local time = 0.0
print("Game of Life - Vulkan Compute Shader")
print("Controls:")
print("  Space: Pause/Resume")
print("  R: Reset with random state")
print("  ESC: Exit")

-- Main loop
while true do
	local events = wnd:ReadEvents()

	for _, event in ipairs(events) do
		if
			event.type == "window_close" or
			(
				event.type == "key_press" and
				event.key == "escape"
			)
		then
			renderer:WaitForIdle()
			os.exit()
		end

		if event.type == "window_resize" then
			window_target:RecreateSwapchain()
			create_storage_images()
			update_descriptor_sets()
		end

		-- Handle keyboard input
		if event.type == "key_press" then
			if event.key == "space" then
				paused = not paused
				print(paused and "Paused" or "Resumed")
			elseif event.key == "r" then
				create_storage_images()
				update_descriptor_sets()
				print("Reset to random state")
			end
		end
	end

	if window_target:BeginFrame() then
		local cmd = window_target:GetCommandBuffer()

		-- Run compute shader (only if not paused)
		if not paused then
			compute_pipeline:Dispatch(cmd)
			-- Barrier: compute write -> fragment read
			local output_image_idx = (compute_pipeline.current_image_index % 2) + 1
			cmd:PipelineBarrier(
				{
					srcStage = "compute",
					dstStage = "fragment",
					imageBarriers = {
						{
							image = storage_images[output_image_idx],
							srcAccessMask = "shader_write",
							dstAccessMask = "shader_read",
							oldLayout = "general",
							newLayout = "general",
						},
					},
				}
			)
			-- Swap descriptor sets for next frame
			compute_pipeline:SwapImages()
		end

		-- Update uniform buffer
		time = time + 0.016
		graphics_pipeline:GetUniformBuffer(1):CopyData(UniformData({
			time,
			(
				time * 0.1
			) % 1.0,
			0.0,
			1.2,
		}))
		-- Render fullscreen quad
		cmd:BeginRenderPass(
			window_target:GetRenderPass(),
			window_target:GetFramebuffer(),
			window_target:GetExtent(),
			ffi.new("float[4]", {0.0, 0.0, 0.0, 1.0})
		)
		graphics_pipeline:Bind(cmd)
		local extent = window_target:GetExtent()
		cmd:SetViewport(0.0, 0.0, extent.width, extent.height, 0.0, 1.0)
		cmd:SetScissor(0, 0, extent.width, extent.height)
		cmd:Draw(6, 1, 0, 0)
		cmd:EndRenderPass()
		window_target:EndFrame()
	end

	threads.sleep(16)
end
