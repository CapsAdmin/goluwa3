local ffi = require("ffi")
local render = require("graphics.render")
local Texture = require("graphics.texture")
local Fence = require("graphics.vulkan.internal.fence")
local Matrix = require("structs.matrix")
local Vec3 = require("structs.vec3")
local ShadowMap = {}
ShadowMap.__index = ShadowMap
-- Default shadow map settings
local DEFAULT_SIZE = 2048
local DEFAULT_FORMAT = "D32_SFLOAT"
-- Push constants for shadow pass (just need MVP matrix)
local ShadowVertexConstants = ffi.typeof([[
	struct {
		float light_space_matrix[16];
	}
]])

function ShadowMap.New(config)
	config = config or {}
	local self = setmetatable({}, ShadowMap)
	self.size = config.size or DEFAULT_SIZE
	self.format = config.format or DEFAULT_FORMAT
	self.near_plane = config.near_plane or 0.1
	self.far_plane = config.far_plane or 100.0
	self.ortho_size = config.ortho_size or 50.0 -- Half-size of orthographic projection
	-- Create depth texture for shadow map
	self.depth_texture = Texture.New(
		{
			width = self.size,
			height = self.size,
			format = self.format,
			image = {
				usage = {"depth_stencil_attachment", "sampled"},
				properties = "device_local",
			},
			view = {
				aspect = "depth",
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_border",
				wrap_t = "clamp_to_border",
				border_color = "float_opaque_white",
				compare_enable = true,
				compare_op = "less_or_equal",
			},
		}
	)
	-- Create depth-only pipeline for shadow pass
	self.pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			depth_format = self.format,
			shader_stages = {
				{
					type = "vertex",
					code = [[
					#version 450
					#extension GL_EXT_scalar_block_layout : require

					layout(location = 0) in vec3 in_position;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;
					layout(location = 3) in vec4 in_tangent;

					layout(push_constant, scalar) uniform Constants {
						mat4 light_space_matrix;
					} pc;

					void main() {
						gl_Position = pc.light_space_matrix * vec4(in_position, 1.0);
					}
				]],
					bindings = {
						{
							binding = 0,
							stride = ffi.sizeof("float") * 12, -- Match render3d vertex format
							input_rate = "vertex",
						},
					},
					attributes = {
						{
							binding = 0,
							location = 0,
							format = "R32G32B32_SFLOAT",
							offset = 0,
						},
						{
							binding = 0,
							location = 1,
							format = "R32G32B32_SFLOAT",
							offset = ffi.sizeof("float") * 3,
						},
						{
							binding = 0,
							location = 2,
							format = "R32G32_SFLOAT",
							offset = ffi.sizeof("float") * 6,
						},
						{
							binding = 0,
							location = 3,
							format = "R32G32B32A32_SFLOAT",
							offset = ffi.sizeof("float") * 8,
						},
					},
					input_assembly = {
						topology = "triangle_list",
						primitive_restart = false,
					},
					push_constants = {
						size = ffi.sizeof(ShadowVertexConstants),
						offset = 0,
					},
				},
				{
					type = "fragment",
					code = [[
					#version 450
					void main() {
						// Depth is written automatically
					}
				]],
				},
			},
			rasterizer = {
				depth_clamp = true, -- Clamp depth to avoid shadow acne at edges
				discard = false,
				polygon_mode = "fill",
				line_width = 1.0,
				cull_mode = "front", -- Front-face culling reduces shadow acne
				front_face = "counter_clockwise",
				depth_bias = 1, -- Enable depth bias
				depth_bias_constant_factor = 1.25,
				depth_bias_slope_factor = 1.75,
			},
			color_blend = {
				logic_op_enabled = false,
				logic_op = "copy",
				constants = {0.0, 0.0, 0.0, 0.0},
				attachments = {}, -- No color attachments
			},
			multisampling = {
				sample_shading = false,
				rasterization_samples = "1",
			},
			depth_stencil = {
				depth_test = true,
				depth_write = true,
				depth_compare_op = "less_or_equal",
				depth_bounds_test = false,
				stencil_test = false,
			},
		}
	)
	-- Light space matrix
	self.light_view_matrix = Matrix()
	self.light_projection_matrix = Matrix()
	self.light_space_matrix = Matrix()
	-- Command buffer for shadow pass
	self.command_pool = render.GetCommandPool()
	self.cmd = self.command_pool:AllocateCommandBuffer()
	self.fence = Fence.New(render.GetDevice())
	return self
end

-- Update light space matrix based on light direction
function ShadowMap:UpdateLightMatrix(light_direction, scene_center, scene_radius)
	scene_center = scene_center or Vec3(0, 0, 0)
	scene_radius = scene_radius or self.ortho_size
	-- Normalize light direction
	local dir = light_direction:GetNormalized()
	-- Calculate light position (far from scene in opposite direction of light)
	local light_pos = scene_center - dir * (scene_radius * 2)
	-- Create view matrix (look at scene center from light position)
	self.light_view_matrix:Identity()
	self.light_view_matrix:LookAt(light_pos, scene_center, Vec3(0, 1, 0))
	-- Create orthographic projection matrix
	self.light_projection_matrix:Identity()
	self.light_projection_matrix:Ortho(
		-scene_radius,
		scene_radius,
		-scene_radius,
		scene_radius,
		self.near_plane,
		self.far_plane + scene_radius * 2
	)
	-- Combine into light space matrix
	self.light_space_matrix = self.light_projection_matrix * self.light_view_matrix
end

-- Begin shadow pass
function ShadowMap:Begin()
	self.cmd:Reset()
	self.cmd:Begin()
	-- Transition depth texture to depth attachment optimal
	self.cmd:PipelineBarrier(
		{
			srcStage = "fragment",
			dstStage = "early_fragment_tests",
			imageBarriers = {
				{
					image = self.depth_texture:GetImage(),
					srcAccessMask = "shader_read",
					dstAccessMask = "depth_stencil_attachment_write",
					oldLayout = "undefined",
					newLayout = "depth_attachment_optimal",
					aspect = "depth",
				},
			},
		}
	)
	-- Begin rendering (depth-only)
	self.cmd:BeginRendering(
		{
			depthImageView = self.depth_texture:GetView(),
			extent = {width = self.size, height = self.size},
			clearDepth = 1.0,
		}
	)
	self.cmd:SetViewport(0.0, 0.0, self.size, self.size, 0.0, 1.0)
	self.cmd:SetScissor(0, 0, self.size, self.size)
	-- Bind shadow pipeline
	self.pipeline:Bind(self.cmd)
	return self.cmd
end

-- Upload shadow pass constants (light space matrix * world matrix)
function ShadowMap:UploadConstants(world_matrix)
	local constants = ShadowVertexConstants()
	local mvp = self.light_space_matrix * world_matrix
	constants.light_space_matrix = mvp:GetFloatCopy()
	self.pipeline:PushConstants(self.cmd, "vertex", 0, constants)
end

-- End shadow pass
function ShadowMap:End()
	self.cmd:EndRendering()
	-- Transition depth texture to shader read optimal for sampling
	self.cmd:PipelineBarrier(
		{
			srcStage = "late_fragment_tests",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = self.depth_texture:GetImage(),
					srcAccessMask = "depth_stencil_attachment_write",
					dstAccessMask = "shader_read",
					oldLayout = "depth_attachment_optimal",
					newLayout = "shader_read_only_optimal",
					aspect = "depth",
				},
			},
		}
	)
	self.cmd:End()
	-- Submit and wait
	local device = render.GetDevice()
	local queue = render.GetQueue()
	queue:SubmitAndWait(device, self.cmd, self.fence)
end

-- Get the depth texture for sampling in main pass
function ShadowMap:GetDepthTexture()
	return self.depth_texture
end

-- Get the light space matrix for transforming in main pass
function ShadowMap:GetLightSpaceMatrix()
	return self.light_space_matrix
end

-- Get shadow map size
function ShadowMap:GetSize()
	return self.size
end

return ShadowMap
