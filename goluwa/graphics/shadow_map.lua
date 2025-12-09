local ffi = require("ffi")
local render = require("graphics.render")
local Texture = require("graphics.texture")
local Fence = require("graphics.vulkan.internal.fence")
local Matrix = require("structs.matrix").Matrix44
local Vec3 = require("structs.vec3")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local camera = require("graphics.camera")
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
	self.cascade_cameras = {} -- Camera per cascade
	self.cascade_depth_textures = {} -- Depth texture per cascade
	self.cascade_light_space_matrices = {} -- Light space matrix per cascade
	-- Initialize cascades
	for i = 1, self.cascade_count do
		-- Create a camera for each cascade
		local cam = camera.CreateCamera()
		cam:Set3D(true)
		cam:SetOrtho(true)
		cam:SetViewport(Rect(0, 0, self.size.w, self.size.h))
		cam:SetNearZ(self.near_plane)
		cam:SetFarZ(self.far_plane)
		self.cascade_cameras[i] = cam
		-- Create depth texture for each cascade
		self.cascade_depth_textures[i] = Texture.New(
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
		-- Initialize light space matrix
		self.cascade_light_space_matrices[i] = Matrix()
	end

	-- Legacy single-cascade support (for backwards compatibility)
	self.camera = self.cascade_cameras[1]
	self.depth_texture = self.cascade_depth_textures[1]
	self.light_space_matrix = self.cascade_light_space_matrices[1]
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
	local n = self.cascade_count
	local lambda = self.cascade_split_lambda
	self.cascade_splits = {}

	for i = 1, n do
		local p = i / n
		-- Logarithmic split
		local log_split = view_near * math.pow(view_far / view_near, p)
		-- Linear split
		local linear_split = view_near + (view_far - view_near) * p
		-- Blend between the two
		self.cascade_splits[i] = lambda * log_split + (1 - lambda) * linear_split
	end

	return self.cascade_splits
end

-- Get frustum corners in world space for a given near/far range
function ShadowMap:GetFrustumCornersWorldSpace(view_camera, split_near, split_far)
	local inv_view_proj = view_camera:GetProjectionViewMatrix():GetInverse()
	-- NDC corners (Vulkan: z goes from 0 to 1)
	local ndc_corners = {
		-- Near plane (z = 0 in Vulkan NDC)
		{-1, -1, 0},
		{1, -1, 0},
		{1, 1, 0},
		{-1, 1, 0},
		-- Far plane (z = 1 in Vulkan NDC)
		{-1, -1, 1},
		{1, -1, 1},
		{1, 1, 1},
		{-1, 1, 1},
	}
	-- Get the full frustum corners in world space
	-- Manual 4x4 matrix * vec4 multiplication since TransformVector4 doesn't exist
	local frustum_corners = {}

	for i, ndc in ipairs(ndc_corners) do
		local nx, ny, nz = ndc[1], ndc[2], ndc[3]
		local m = inv_view_proj
		-- Multiply matrix by vec4(nx, ny, nz, 1.0)
		local x = m.m00 * nx + m.m10 * ny + m.m20 * nz + m.m30
		local y = m.m01 * nx + m.m11 * ny + m.m21 * nz + m.m31
		local z = m.m02 * nx + m.m12 * ny + m.m22 * nz + m.m32
		local w = m.m03 * nx + m.m13 * ny + m.m23 * nz + m.m33
		frustum_corners[i] = Vec3(x / w, y / w, z / w)
	end

	-- Now interpolate to get the cascade-specific frustum
	-- Near corners are indices 1-4, far corners are indices 5-8
	local view_near = view_camera:GetNearZ()
	local view_far = view_camera:GetFarZ()
	local near_t = (split_near - view_near) / (view_far - view_near)
	local far_t = (split_far - view_near) / (view_far - view_near)
	local cascade_corners = {}

	for i = 1, 4 do
		local near_corner = frustum_corners[i]
		local far_corner = frustum_corners[i + 4]
		-- Interpolate to get cascade near corner
		cascade_corners[i] = near_corner + (far_corner - near_corner) * near_t
		-- Interpolate to get cascade far corner
		cascade_corners[i + 4] = near_corner + (far_corner - near_corner) * far_t
	end

	return cascade_corners
end

-- Update light space matrix for directional/sun light
-- For sun shadows, we center the shadow map on the camera position and orient by light direction
-- camera_angles is used to bias the shadow map center toward where the player is looking
function ShadowMap:UpdateLightMatrix(light_direction, camera_position, camera_angles)
	-- Calculate where the shadow map should be centered
	-- Start at camera position, then offset toward where they're looking
	local shadow_center = camera_position

	if camera_angles then
		-- Offset the shadow center forward based on camera yaw
		-- This biases coverage toward where the player is looking
		local forward_offset = self.ortho_size * 0.89
		local yaw = camera_angles.y
		-- In source-engine style: x is forward/back, y is left/right
		local forward_x = math.cos(yaw) * forward_offset
		local forward_y = math.sin(yaw) * forward_offset
		shadow_center = shadow_center + Vec3(forward_x, forward_y, 0)
	end

	-- The shadow camera is positioned "behind" the shadow center
	-- (offset in the opposite direction of the light)
	local shadow_cam_pos = shadow_center + light_direction * -self.ortho_size
	-- Set the shadow camera position
	self.camera:SetPosition(shadow_cam_pos)
	-- Set angles from light direction
	self.camera:SetAngles(light_direction:GetAngles())
	-- Clear any custom view matrix so camera builds it from position/angles
	self.camera:SetView(nil)
	-- Build the projection matrix (orthographic for directional lights)
	local projection = Matrix()
	local size = self.ortho_size * 2
	projection:Ortho(-size, size, -size, size, -self.far_plane * 2, self.far_plane * 0.1)
	self.camera:SetProjection(projection)
	-- Rebuild the camera to update all matrices
	self.camera:Rebuild()
	-- Get the combined projection_view matrix from camera
	self.light_space_matrix = self.camera:GetProjectionViewMatrix()
	-- Also update first cascade for backwards compatibility
	self.cascade_light_space_matrices[1] = self.light_space_matrix
end

-- Update all cascade light matrices for cascaded shadow mapping
-- view_camera: the main view camera to calculate frustum splits from
-- light_direction: normalized direction of the directional light
function ShadowMap:UpdateCascadeLightMatrices(light_direction, view_camera)
	local view_near = view_camera:GetNearZ()
	local view_far = math.min(view_camera:GetFarZ(), self.max_shadow_distance)
	local camera_position = view_camera:GetPosition()
	local camera_angles = view_camera:GetAngles()
	-- Calculate cascade splits with clamped far plane
	self:CalculateCascadeSplits(view_near, view_far)

	for cascade_idx = 1, self.cascade_count do
		-- Each cascade covers a larger area
		-- Use ortho_size scaled by cascade index for simple, predictable cascades
		local cascade_scale = cascade_idx / self.cascade_count
		local cascade_ortho_size = self.ortho_size * (0.5 + cascade_scale * 1.5)
		-- Calculate where the shadow map should be centered
		-- Start at camera position, then offset toward where they're looking
		local shadow_center = camera_position

		if camera_angles then
			-- Offset the shadow center forward based on camera yaw
			-- Bias more forward for closer cascades
			local forward_offset = cascade_ortho_size * (0.5 + (1 - cascade_scale) * 0.4)
			local yaw = camera_angles.y
			local forward_x = math.cos(yaw) * forward_offset
			local forward_y = math.sin(yaw) * forward_offset
			shadow_center = shadow_center + Vec3(forward_x, forward_y, 0)
		end

		-- The shadow camera is positioned "behind" the shadow center
		local shadow_cam_pos = shadow_center + light_direction * -cascade_ortho_size
		local cam = self.cascade_cameras[cascade_idx]
		cam:SetPosition(shadow_cam_pos)
		cam:SetAngles(light_direction:GetAngles())
		cam:SetView(nil)
		-- Build orthographic projection (same approach as working UpdateLightMatrix)
		local projection = Matrix()
		local size = cascade_ortho_size * 2
		projection:Ortho(-size, size, -size, size, -self.far_plane * 2, self.far_plane * 0.1)
		cam:SetProjection(projection)
		-- Rebuild camera
		cam:Rebuild()
		-- Store the light space matrix
		self.cascade_light_space_matrices[cascade_idx] = cam:GetProjectionViewMatrix()
	end

	-- Update legacy single matrix for backwards compatibility
	self.light_space_matrix = self.cascade_light_space_matrices[1]
end

-- Begin shadow pass for a specific cascade (or all cascades if cascade_index is nil)
function ShadowMap:Begin(cascade_index)
	cascade_index = cascade_index or 1
	self.current_cascade = cascade_index
	local depth_texture = self.cascade_depth_textures[cascade_index]
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
	local mvp = self.cascade_light_space_matrices[cascade_index] * world_matrix
	constants.light_space_matrix = mvp:GetFloatCopy()
	self.pipeline:PushConstants(self.cmd, "vertex", 0, constants)
end

-- End shadow pass for current cascade
function ShadowMap:End(cascade_index)
	cascade_index = cascade_index or self.current_cascade
	local depth_texture = self.cascade_depth_textures[cascade_index]
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
	if cascade_index then return self.cascade_depth_textures[cascade_index] end

	return self.depth_texture
end

-- Get all cascade depth textures
function ShadowMap:GetCascadeDepthTextures()
	return self.cascade_depth_textures
end

-- Get the light space matrix for transforming in main pass
function ShadowMap:GetLightSpaceMatrix(cascade_index)
	if cascade_index then
		return self.cascade_light_space_matrices[cascade_index]
	end

	return self.light_space_matrix
end

-- Get all cascade light space matrices
function ShadowMap:GetCascadeLightSpaceMatrices()
	return self.cascade_light_space_matrices
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
