local ffi = require("ffi")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local Texture = require("graphics.texture")
local Fence = require("graphics.vulkan.internal.fence")
local Matrix44 = require("structs.matrix").Matrix44
local Vec3 = require("structs.vec3")
local Vec2 = require("structs.vec2")
local Ang3 = require("structs.ang3")
local ShadowMap = {}
ShadowMap.__index = ShadowMap
-- Default shadow map settings
local DEFAULT_SIZE = Vec2() + 2048 --Vec2(800, 600) --Vec2() + 2048 -- Shadow map resolution
local DEFAULT_FORMAT = "d32_sfloat"
local DEFAULT_CASCADE_COUNT = 3 -- Default number of cascades for CSM
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
	-- Cascaded shadow map settings
	self.cascade_count = config.cascade_count or DEFAULT_CASCADE_COUNT
	self.cascade_split_lambda = config.cascade_split_lambda or 0.75 -- Blend between linear and logarithmic split
	self.max_shadow_distance = config.max_shadow_distance or 500.0 -- Maximum shadow distance (clamps view far plane)
	self.cascade_splits = {} -- Will store the split distances
	self.cascade = {} -- Per-cascade data
	-- Initialize cascades
	for i = 1, self.cascade_count do
		self.cascade[i] = {
			position = Vec3(0, 0, 0),
			light_space_matrix = Matrix44(),
		}
		-- Create depth texture for each cascade
		self.cascade[i].depth_texture = Texture.New(
			{
				width = self.size.w,
				height = self.size.h,
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
	end

	-- Create depth-only pipeline for shadow pass
	self.pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			-- Even with dynamic states, must provide initial viewport/scissor matching what we'll use
			viewport = {x = 0, y = 0, w = self.size.w, h = self.size.h, min_depth = 0, max_depth = 1},
			scissor = {x = 0, y = 0, w = self.size.w, h = self.size.h},
			color_format = false, -- No color attachment for shadow pass
			depth_format = self.format,
			samples = "1", -- Shadow map uses single sample
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
							format = "r32g32b32_sfloat",
							offset = 0,
						},
						{
							binding = 0,
							location = 1,
							format = "r32g32b32_sfloat",
							offset = ffi.sizeof("float") * 3,
						},
						{
							binding = 0,
							location = 2,
							format = "r32g32_sfloat",
							offset = ffi.sizeof("float") * 6,
						},
						{
							binding = 0,
							location = 3,
							format = "r32g32b32a32_sfloat",
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
	-- Command buffer for shadow pass
	self.command_pool = render.GetCommandPool()
	self.cmd = self.command_pool:AllocateCommandBuffer()
	self.fence = Fence.New(render.GetDevice())
	-- Current cascade being rendered (for Begin/End API)
	self.current_cascade = 1
	return self
end

-- Calculate cascade split distances using practical split scheme
-- Blends between logarithmic and linear split based on lambda parameter
function ShadowMap:CalculateCascadeSplits(view_near, view_far)
	local lambda = self.cascade_split_lambda
	self.cascade_splits = {}
	local n = self.cascade_count

	for i = 1, n do
		local p = i / n
		-- Logarithmic split
		local log_split = view_near * math.pow(view_far / view_near, p)
		-- Linear split
		local linear_split = view_near + (view_far - view_near) * p
		-- Blend between the two
		self.cascade_splits[i] = lambda * log_split + (1 - lambda) * linear_split
	end
end

-- Update all cascade light matrices for cascaded shadow mapping
-- view_camera: the main view camera to calculate frustum splits from
-- light_direction: normalized direction of the directional light
function ShadowMap:UpdateCascadeLightMatrices(light_direction)
	self:CalculateCascadeSplits(render3d.camera:GetNearZ(), render3d.camera:GetFarZ())

	for cascade_idx = 1, self.cascade_count do
		-- Each cascade covers a larger area
		-- Use ortho_size scaled by cascade index for simple, predictable cascades
		local cascade_scale = cascade_idx / self.cascade_count
		local cascade_ortho_size = self.ortho_size * (0.5 + cascade_scale * 1.5)
		-- Calculate where the shadow map should be centered
		-- Start at camera position, then offset toward where they're looking
		local shadow_center = render3d.camera:GetPosition()

		if false then
			-- Offset the shadow center forward based on camera yaw
			-- Bias more forward for closer cascades
			local forward_offset = cascade_ortho_size * (0.5 + (1 - cascade_scale) * 0.4)
			local yaw = render3d.camera:GetAngles().y
			local forward_x = math.cos(yaw) * forward_offset
			local forward_y = math.sin(yaw) * forward_offset
			shadow_center = shadow_center + Vec3(forward_x, forward_y, 0)
		end

		-- The shadow camera is positioned "behind" the shadow center
		local shadow_cam_pos = shadow_center + light_direction * -cascade_ortho_size
		local angles = light_direction:GetAngles()
		-- Build the view matrix
		-- ORIENTATION / TRANSFORMATION: Using rotation helpers from orientation module
		local view = Matrix44()
		view:RotateRoll(angles.z)
		view:RotateYaw(angles.y)
		view:RotatePitch(-angles.x)
		view:SetTranslation(-shadow_cam_pos.x, shadow_cam_pos.y, -shadow_cam_pos.z)
		-- Build orthographic projection (same approach as working UpdateLightMatrix)
		local projection = Matrix44()
		local size = cascade_ortho_size * 2
		projection:Ortho(-size, size, -size, size, -self.far_plane * 2, self.far_plane * 0.1)
		-- Store all cascade data
		self.cascade[cascade_idx].light_space_matrix = projection * view
	end
end

-- Begin shadow pass for a specific cascade (or all cascades if cascade_index is nil)
function ShadowMap:Begin(cascade_index)
	cascade_index = cascade_index or 1
	self.current_cascade = cascade_index
	local depth_texture = self.cascade[cascade_index].depth_texture
	self.cmd:Reset()
	self.cmd:Begin()
	-- Transition depth texture to depth attachment optimal
	self.cmd:PipelineBarrier(
		{
			srcStage = "fragment",
			dstStage = "early_fragment_tests",
			imageBarriers = {
				{
					image = depth_texture:GetImage(),
					srcAccessMask = "shader_read",
					dstAccessMask = "depth_stencil_attachment_write",
					oldLayout = "undefined",
					newLayout = "depth_attachment_optimal",
					aspect = "depth",
				},
			},
		}
	)
	-- Use integer values from the depth texture to ensure consistency
	local w = depth_texture:GetWidth()
	local h = depth_texture:GetHeight()
	-- Begin rendering (depth-only)
	self.cmd:BeginRendering(
		{
			depth_image_view = depth_texture:GetView(),
			depth_store = true, -- We need to store the depth for sampling later
			depth_layout = "depth_attachment_optimal",
			w = w,
			h = h,
			clear_depth = 1.0,
		}
	)
	-- Bind shadow pipeline
	self.pipeline:Bind(self.cmd)
	-- Set viewport and scissor (dynamic states)
	self.cmd:SetViewport(0.0, 0.0, w, h, 0.0, 1.0)
	self.cmd:SetScissor(0, 0, w, h)
	-- NOTE: Pipeline barriers are not allowed inside dynamic rendering!
	-- Synchronization between shadow map and main pass happens via fence/submit
	return self.cmd
end

-- Begin rendering all cascades (helper for cascaded shadow mapping)
-- Returns a table of command buffers, one per cascade
function ShadowMap:BeginAllCascades()
	local cmds = {}

	for i = 1, self.cascade_count do
		cmds[i] = self:Begin(i)
	end

	return cmds
end

-- Upload shadow pass constants (light space matrix * world matrix)
function ShadowMap:UploadConstants(world_matrix, cascade_index)
	cascade_index = cascade_index or self.current_cascade
	local constants = ShadowVertexConstants()
	local mvp = self.cascade[cascade_index].light_space_matrix * world_matrix
	constants.light_space_matrix = mvp:GetFloatCopy()
	self.pipeline:PushConstants(self.cmd, "vertex", 0, constants)
end

-- End shadow pass for current cascade
function ShadowMap:End(cascade_index)
	cascade_index = cascade_index or self.current_cascade
	local depth_texture = self.cascade[cascade_index].depth_texture
	self.cmd:EndRendering()
	-- Transition depth texture to shader read optimal for sampling
	self.cmd:PipelineBarrier(
		{
			srcStage = "late_fragment_tests",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = depth_texture:GetImage(),
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
function ShadowMap:GetDepthTexture(cascade_index)
	return self.cascade[cascade_index].depth_texture
end

-- Get all cascade depth textures
function ShadowMap:GetCascadeDepthTextures()
	local textures = {}

	for i = 1, self.cascade_count do
		textures[i] = self.cascade[i].depth_texture
	end

	return textures
end

-- Get the light space matrix for transforming in main pass
function ShadowMap:GetLightSpaceMatrix(cascade_index)
	return self.cascade[cascade_index].light_space_matrix
end

-- Get cascade split distances (view-space depth values)
function ShadowMap:GetCascadeSplits()
	return self.cascade_splits
end

-- Get number of cascades
function ShadowMap:GetCascadeCount()
	return self.cascade_count
end

-- Get shadow map size
function ShadowMap:GetSize()
	return self.size
end

return ShadowMap
