local ffi = require("ffi")
local render = require("graphics.render")
local Texture = require("graphics.texture")
local Fence = require("graphics.vulkan.internal.fence")
local Matrix = require("structs.matrix").Matrix44
local Vec3 = require("structs.vec3")
local camera = require("graphics.camera")
local ShadowMap = {}
ShadowMap.__index = ShadowMap
-- Default shadow map settings
local DEFAULT_SIZE = 800 -- Using 800 to match working viewport
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
	-- Create a camera for the light
	self.camera = camera.CreateCamera()
	self.camera:Set3D(true)
	self.camera:SetOrtho(true)
	self.camera:SetViewport(require("structs.rect")(0, 0, self.size, self.size))
	self.camera:SetNearZ(self.near_plane)
	self.camera:SetFarZ(self.far_plane)
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
			-- No compare_enable - we do manual PCF in the shader
			},
		}
	)
	-- Create depth-only pipeline for shadow pass
	self.pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			color_format = false, -- No color attachment for shadow pass
			depth_format = self.format,
			descriptor_set_count = 1, -- Shadow pass doesn't need per-frame descriptor sets
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
				depth_clamp = false,
				discard = false,
				polygon_mode = "fill",
				line_width = 1.0,
				cull_mode = "none", -- Disabled - was causing device lost
				front_face = "counter_clockwise",
				depth_bias = 0, -- Disabled - was causing device lost with some primitives
				depth_bias_constant_factor = 0.0,
				depth_bias_slope_factor = 0.0,
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
	local distance = scene_radius * 4
	local light_pos = scene_center - dir * distance

	-- Debug: print light setup once
	if not self._debug_light then
		print("=== Shadow Light Setup ===")
		print(string.format("Light dir: (%.2f, %.2f, %.2f)", dir.x, dir.y, dir.z))
		print(string.format("Light pos: (%.2f, %.2f, %.2f)", light_pos.x, light_pos.y, light_pos.z))
		print(
			string.format(
				"Scene center: (%.2f, %.2f, %.2f)",
				scene_center.x,
				scene_center.y,
				scene_center.z
			)
		)
		print(string.format("Scene radius: %.2f", scene_radius))
		self._debug_light = true
	end

	-- Build view matrix (LookAt from light_pos toward scene_center)
	local forward = dir
	local world_up = Vec3(0, 0, 1)

	if math.abs(forward.z) > 0.99 then world_up = Vec3(0, 1, 0) end

	local right = world_up:GetCross(forward):GetNormalized()
	local up = forward:GetCross(right):GetNormalized()
	local view = Matrix()
	view:Identity()
	view.m00 = right.x
	view.m10 = right.y
	view.m20 = right.z
	view.m01 = up.x
	view.m11 = up.y
	view.m21 = up.z
	view.m02 = -forward.x
	view.m12 = -forward.y
	view.m22 = -forward.z
	view.m30 = -right:GetDot(light_pos)
	view.m31 = -up:GetDot(light_pos)
	view.m32 = forward:GetDot(light_pos)
	-- Build orthographic projection matrix for Vulkan (depth [0,1])
	local near = self.near_plane
	local far = self.far_plane + distance
	local projection = Matrix()
	projection:Identity()
	projection.m00 = 2 / (2 * scene_radius) -- 1/scene_radius
	projection.m11 = 2 / (2 * scene_radius) -- 1/scene_radius
	projection.m22 = 1 / (near - far)
	projection.m32 = near / (near - far)
	-- Combine: projection * view
	self.light_space_matrix = projection * view

	-- Debug: print matrices once
	if not self._debug_matrices then
		print("=== Shadow Matrices ===")
		local m = self.light_space_matrix
		print(
			string.format(
				"Light space matrix:\n[%.3f, %.3f, %.3f, %.3f]\n[%.3f, %.3f, %.3f, %.3f]\n[%.3f, %.3f, %.3f, %.3f]\n[%.3f, %.3f, %.3f, %.3f]",
				m.m00,
				m.m10,
				m.m20,
				m.m30,
				m.m01,
				m.m11,
				m.m21,
				m.m31,
				m.m02,
				m.m12,
				m.m22,
				m.m32,
				m.m03,
				m.m13,
				m.m23,
				m.m33
			)
		)
		self._debug_matrices = true
	end
end

-- Begin shadow pass
function ShadowMap:Begin()
	self.cmd:Reset()
	self.cmd:Begin()
	-- Transition depth texture to depth attachment optimal
	self.cmd:PipelineBarrier(
		{
			srcStage = "all_commands",
			dstStage = "all_commands",
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
			depthStore = true, -- We need to store the depth for sampling later
			depthLayout = "VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL",
			extent = {width = 800, height = 600}, -- Match viewport for now
			clearDepth = 1.0,
		}
	)
	-- Bind shadow pipeline
	self.pipeline:Bind(self.cmd)
	-- Set viewport and scissor (dynamic states) - use 800x600 for now
	self.cmd:SetViewport(0.0, 0.0, 800, 600, 0.0, 1.0)
	self.cmd:SetScissor(0, 0, 800, 600)
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
			srcStage = "all_commands",
			dstStage = "all_commands",
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
