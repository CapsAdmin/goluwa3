local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local render3d = nil
local Texture = import("goluwa/render/texture.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local Material = import("goluwa/render3d/material.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Quat = import("goluwa/structs/quat.lua")
local system = import("goluwa/system.lua")
local prototype = import("goluwa/prototype.lua")
local UniformBuffer = import("goluwa/render/uniform_buffer.lua")
local ShadowMap = prototype.CreateTemplate("render3d_shadow_map")
-- Default shadow map settings
local DEFAULT_SIZE = Vec2() + 2048 --Vec2(800, 600) --Vec2() + 2048 -- Shadow map resolution
local DEFAULT_FORMAT = "d32_sfloat"
local DEFAULT_CASCADE_COUNT = 3 -- Default number of cascades for CSM
local TEMP_IDENTITY_CASCADE_OVERRIDE = false
local TEMP_REUSE_FIRST_CASCADE_OVERRIDE = false

local function supports_tessellation()
	local device = render.GetDevice and render.GetDevice()

	if
		not device or
		not device.physical_device or
		not device.physical_device.GetFeatures
	then
		return false
	end

	local features = device.physical_device:GetFeatures()
	return features and features.tessellationShader == 1 or false
end

local function use_tessellated_shadow(material)
	return supports_tessellation() and
		material and
		material:GetHeightTexture() and
		material:GetHeightScale() > 0 and
		material:GetTessellationFactor() > 1.0
end

-- Push constants for shadow pass (MVP matrix + texture index for alpha testing)
local ShadowVertexConstants = ffi.typeof([[
	struct {
		float light_space_matrix[16];
		int albedo_texture_index;
		int height_texture_index;
		int flags;
		float color_multiplier_a;
		float alpha_cutoff;
		float height_scale;
		float height_center;
		float tessellation_factor;
	}
]])
local ShadowTransformUniformDecl = [[
	struct {
		float world[16];
	}
]]
local SHADOW_PUSH_CONSTANT_GLSL = [[
	layout(push_constant, scalar) uniform Constants {
		mat4 light_space_matrix;
		int albedo_texture_index;
		int height_texture_index;
		int flags;
		float color_multiplier_a;
		float alpha_cutoff;
		float height_scale;
		float height_center;
		float tessellation_factor;
	} pc;
]]

local function get_shadow_stage_push_constants()
	return {
		size = ffi.sizeof(ShadowVertexConstants),
		offset = 0,
	}
end

local function get_shadow_texture_descriptor_sets(bindless_texture_capacity)
	return {
		{
			type = "combined_image_sampler",
			binding_index = 0,
			count = bindless_texture_capacity,
		},
	}
end

local function get_shadow_geometry_descriptor_sets(self, bindless_texture_capacity)
	local descriptor_sets = get_shadow_texture_descriptor_sets(bindless_texture_capacity)
	descriptor_sets[2] = {
		type = "uniform_buffer_dynamic",
		binding_index = 1,
		args = {self.vertex_animation_buffer.buffer, self.vertex_animation_buffer.aligned_size},
	}
	descriptor_sets[3] = {
		type = "uniform_buffer_dynamic",
		binding_index = 2,
		args = {self.shadow_transform_buffer.buffer, self.shadow_transform_buffer.aligned_size},
	}
	return descriptor_sets
end

local function build_shadow_fragment_shader(bindless_texture_capacity)
	local prelude = (
		[[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					#extension GL_EXT_scalar_block_layout : require

					layout(binding = 0) uniform sampler2D textures[%d];

					%s
					layout(location = 0) in vec2 in_uv;

					#define FLAGS pc.flags
				]]
	):format(bindless_texture_capacity, SHADOW_PUSH_CONSTANT_GLSL)
	return prelude .. Material.BuildGlslFlags("pc.flags") .. model_pipeline.BuildBindlessAlphaSamplingGlsl("pc.albedo_texture_index", "pc.color_multiplier_a") .. model_pipeline.BuildAlphaDiscardGlsl("pc.alpha_cutoff") .. [[
					void main() {
						float alpha = get_alpha();
						compute_translucency_and_discard(alpha);
					}
				]]
end

local function build_shadow_projected_main(
	local_pos_expr,
	local_normal_expr,
	local_tangent_expr,
	uv_expr,
	texture_blend_expr,
	vertex_color_expr
)
	return (
		[[
					void main() {
						vec3 local_pos = %s;
						vec3 local_normal = normalize(%s);
						vec3 local_tangent = normalize(%s);
						vec2 uv = %s;
						float texture_blend = %s;
						vec4 vertex_color = %s;
						vec3 world_pos = (shadow_transform.world * vec4(local_pos, 1.0)).xyz;
						mat3 world_matrix3 = mat3(shadow_transform.world);
						mat3 inv_world_matrix3 = inverse(world_matrix3);
						vec3 world_normal = normalize(transpose(inv_world_matrix3) * local_normal);
						vec3 world_tangent = normalize(world_matrix3 * local_tangent);

						apply_shadow_geometry_deformation(
							local_pos,
							world_pos,
							world_normal,
							world_tangent,
							uv,
							texture_blend,
							vertex_color,
							inv_world_matrix3
						);

						gl_Position = pc.light_space_matrix * vec4(local_pos, 1.0);
						out_uv = uv;
					}
				]]
	):format(
		local_pos_expr,
		local_normal_expr,
		local_tangent_expr,
		uv_expr,
		texture_blend_expr,
		vertex_color_expr
	)
end

local function build_shadow_vertex_stage(self, bindless_texture_capacity)
	return {
		type = "vertex",
		code = [[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					#extension GL_EXT_scalar_block_layout : require

					layout(binding = 0) uniform sampler2D textures[];

					layout(location = 0) in vec3 in_position;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;
					layout(location = 3) in vec4 in_tangent;
					layout(location = 4) in float in_texture_blend;
					layout(location = 5) in vec4 in_vertex_color;

					]] .. SHADOW_PUSH_CONSTANT_GLSL .. [[
				]] .. model_pipeline.BuildVertexAnimationUniformDeclaration("vertex_animation", 1) .. [[
					layout(scalar, binding = 2) uniform ShadowTransform_t {
						mat4 world;
					} shadow_transform;

					layout(location = 0) out vec2 out_uv;

				]] .. model_pipeline.BuildShadowGeometryDeformationGlsl("vertex_animation") .. build_shadow_projected_main(
				"in_position",
				"in_normal",
				"in_tangent.xyz",
				"in_uv",
				"in_texture_blend",
				"in_vertex_color"
			),
		bindings = {model_pipeline.GetVertexBufferBinding(0)},
		attributes = model_pipeline.GetVertexAttributeLayout(0),
		descriptor_sets = get_shadow_geometry_descriptor_sets(self, bindless_texture_capacity),
		push_constants = get_shadow_stage_push_constants(),
	}
end

local function build_shadow_tess_vertex_stage()
	return {
		type = "vertex",
		code = [[
					#version 450

					layout(location = 0) in vec3 in_position;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;
					layout(location = 3) in vec4 in_tangent;
					layout(location = 4) in float in_texture_blend;
					layout(location = 5) in vec4 in_vertex_color;

					layout(location = 0) out vec3 out_position;
					layout(location = 1) out vec3 out_normal;
					layout(location = 2) out vec4 out_tangent;
					layout(location = 3) out vec2 out_uv;
					layout(location = 4) out float out_texture_blend;
					layout(location = 5) out vec4 out_vertex_color;

					void main() {
						out_position = in_position;
						out_normal = in_normal;
						out_tangent = in_tangent;
						out_uv = in_uv;
						out_texture_blend = in_texture_blend;
						out_vertex_color = in_vertex_color;
						gl_Position = vec4(in_position, 1.0);
					}
				]],
		bindings = {model_pipeline.GetVertexBufferBinding(0)},
		attributes = model_pipeline.GetVertexAttributeLayout(0),
	}
end

local function build_shadow_tess_control_stage()
	return {
		type = "tessellation_control",
		code = [[
					#version 450
					#extension GL_EXT_scalar_block_layout : require

					layout(location = 0) in vec3 in_position[];
					layout(location = 1) in vec3 in_normal[];
					layout(location = 2) in vec4 in_tangent[];
					layout(location = 3) in vec2 in_uv[];
					layout(location = 4) in float in_texture_blend[];
					layout(location = 5) in vec4 in_vertex_color[];

					layout(location = 0) out vec3 out_position[];
					layout(location = 1) out vec3 out_normal[];
					layout(location = 2) out vec4 out_tangent[];
					layout(location = 3) out vec2 out_uv[];
					layout(location = 4) out float out_texture_blend[];
					layout(location = 5) out vec4 out_vertex_color[];

					]] .. SHADOW_PUSH_CONSTANT_GLSL .. [[

					layout(vertices = 3) out;

					void main() {
						out_position[gl_InvocationID] = in_position[gl_InvocationID];
						out_normal[gl_InvocationID] = in_normal[gl_InvocationID];
						out_tangent[gl_InvocationID] = in_tangent[gl_InvocationID];
						out_uv[gl_InvocationID] = in_uv[gl_InvocationID];
						out_texture_blend[gl_InvocationID] = in_texture_blend[gl_InvocationID];
						out_vertex_color[gl_InvocationID] = in_vertex_color[gl_InvocationID];
						gl_out[gl_InvocationID].gl_Position = gl_in[gl_InvocationID].gl_Position;

						if (gl_InvocationID == 0) {
							float tess = clamp(pc.tessellation_factor, 1.0, 64.0);
							gl_TessLevelOuter[0] = tess;
							gl_TessLevelOuter[1] = tess;
							gl_TessLevelOuter[2] = tess;
							gl_TessLevelInner[0] = tess;
						}
					}
				]],
		push_constants = get_shadow_stage_push_constants(),
	}
end

local function build_shadow_tess_evaluation_stage(self, bindless_texture_capacity)
	return {
		type = "tessellation_evaluation",
		code = [[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					#extension GL_EXT_scalar_block_layout : require

					layout(binding = 0) uniform sampler2D textures[];

					layout(location = 0) in vec3 in_position[];
					layout(location = 1) in vec3 in_normal[];
					layout(location = 2) in vec4 in_tangent[];
					layout(location = 3) in vec2 in_uv[];
					layout(location = 4) in float in_texture_blend[];
					layout(location = 5) in vec4 in_vertex_color[];

					]] .. SHADOW_PUSH_CONSTANT_GLSL .. [[

				]] .. model_pipeline.BuildVertexAnimationUniformDeclaration("vertex_animation", 1) .. [[
					layout(scalar, binding = 2) uniform ShadowTransform_t {
						mat4 world;
					} shadow_transform;

					layout(triangles, equal_spacing, cw) in;
					layout(location = 0) out vec2 out_uv;

				]] .. model_pipeline.BuildShadowGeometryDeformationGlsl("vertex_animation") .. model_pipeline.BuildTriangleInterpolationGlsl() .. build_shadow_projected_main(
				"interpolate_vec3(in_position[0], in_position[1], in_position[2])",
				"interpolate_vec3(in_normal[0], in_normal[1], in_normal[2])",
				"interpolate_vec3(in_tangent[0].xyz, in_tangent[1].xyz, in_tangent[2].xyz)",
				"interpolate_vec2(in_uv[0], in_uv[1], in_uv[2])",
				"interpolate_float(in_texture_blend[0], in_texture_blend[1], in_texture_blend[2])",
				"interpolate_vec4(in_vertex_color[0], in_vertex_color[1], in_vertex_color[2])"
			),
		descriptor_sets = get_shadow_geometry_descriptor_sets(self, bindless_texture_capacity),
		push_constants = get_shadow_stage_push_constants(),
	}
end

local function build_shadow_fragment_stage(bindless_texture_capacity)
	return {
		type = "fragment",
		code = build_shadow_fragment_shader(bindless_texture_capacity),
		push_constants = get_shadow_stage_push_constants(),
		descriptor_sets = get_shadow_texture_descriptor_sets(bindless_texture_capacity),
	}
end

local function build_shadow_pipeline_config(
	format,
	max_shadow_width,
	max_shadow_height,
	shader_stages,
	topology,
	patch_control_points
)
	local config = {
		ViewportX = 0,
		ViewportY = 0,
		ViewportWidth = max_shadow_width,
		ViewportHeight = max_shadow_height,
		ViewportMinDepth = 0,
		ViewportMaxDepth = 1,
		ScissorX = 0,
		ScissorY = 0,
		ScissorWidth = max_shadow_width,
		ScissorHeight = max_shadow_height,
		ColorFormat = false,
		DepthFormat = format,
		RasterizationSamples = "1",
		DescriptorSetCount = 1,
		Topology = topology,
		PrimitiveRestart = false,
		shader_stages = shader_stages,
		DepthClamp = true,
		Discard = false,
		PolygonMode = "fill",
		LineWidth = 1.0,
		CullMode = "none",
		FrontFace = orientation.FRONT_FACE,
		DepthBias = true,
		DepthBiasConstantFactor = 0.5,
		DepthBiasSlopeFactor = 1.25,
		LogicOpEnabled = false,
		LogicOp = "copy",
		BlendConstants = {0.0, 0.0, 0.0, 0.0},
		DepthTest = true,
		DepthWrite = true,
		DepthCompareOp = "less",
		DepthBoundsTest = false,
		StencilTest = false,
	}

	if patch_control_points then
		config.PatchControlPoints = patch_control_points
	end

	return config
end

function ShadowMap.New(config)
	config = config or {}
	local self = ShadowMap:CreateObject()
	local bindless_texture_capacity = render.GetBindlessDescriptorCapacities().textures
	self.size = config.size or DEFAULT_SIZE
	self.format = config.format or DEFAULT_FORMAT
	self.near_plane = config.near_plane or 0.1
	self.far_plane = config.far_plane or 100.0
	self.ortho_size = config.ortho_size or 50.0 -- Half-size of orthographic projection
	-- Cascaded shadow map settings
	self.cascade_count = config.cascade_count or DEFAULT_CASCADE_COUNT
	assert(self.cascade_count <= 4, "shadow maps currently support up to 4 cascades")
	self.cascade_split_lambda = config.cascade_split_lambda or 0.75 -- Blend between linear and logarithmic split
	self.max_shadow_distance = config.max_shadow_distance or 500.0 -- Maximum shadow distance (clamps view far plane)
	self.cascade_zoom_factors = config.cascade_zoom_factors or {}
	self.cascade_splits = {} -- Will store the split distances
	self.cascade = {} -- Per-cascade data
	self.vertex_animation_buffer = UniformBuffer.New(model_pipeline.GetVertexAnimationUniformBufferDecl())
	self.shadow_transform_buffer = UniformBuffer.New(ShadowTransformUniformDecl)
	local cascade_sizes = config.cascade_sizes or {}
	local max_shadow_width = self.size.w
	local max_shadow_height = self.size.h

	-- Initialize cascades
	for i = 1, self.cascade_count do
		local cascade_size = cascade_sizes[i] or self.size

		if cascade_size.w > max_shadow_width then max_shadow_width = cascade_size.w end

		if cascade_size.h > max_shadow_height then max_shadow_height = cascade_size.h end

		self.cascade[i] = {
			position = Vec3(0, 0, 0),
			size = cascade_size,
			view_matrix = Matrix44(),
			cull_aabb = AABB(-1, -1, -1, 1, 1, 1),
			light_space_matrix = Matrix44(),
			is_sampleable = false,
		}
		-- Create depth texture for each cascade
		self.cascade[i].depth_texture = Texture.New{
			width = cascade_size.w,
			height = cascade_size.h,
			format = self.format,
			image = {
				usage = {"depth_stencil_attachment", "sampled"},
				properties = "device_local",
			},
			view = {
				aspect = "depth",
			},
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "clamp_to_border",
				wrap_t = "clamp_to_border",
				border_color = "float_opaque_white",
			-- No compare_enable - we do manual PCF in the shader
			},
		}
	end

	self.pipeline = render.CreateGraphicsPipeline(
		build_shadow_pipeline_config(
			self.format,
			max_shadow_width,
			max_shadow_height,
			{
				build_shadow_vertex_stage(self, bindless_texture_capacity),
				build_shadow_fragment_stage(bindless_texture_capacity),
			},
			"triangle_list"
		)
	)

	if supports_tessellation() then
		self.tess_pipeline = render.CreateGraphicsPipeline(
			build_shadow_pipeline_config(
				self.format,
				max_shadow_width,
				max_shadow_height,
				{
					build_shadow_tess_vertex_stage(),
					build_shadow_tess_control_stage(),
					build_shadow_tess_evaluation_stage(self, bindless_texture_capacity),
					build_shadow_fragment_stage(bindless_texture_capacity),
				},
				"patch_list",
				3
			)
		)
	end

	-- Command buffer for shadow pass
	self.command_pool = render.GetCommandPool()
	self.cmd = self.command_pool:AllocateCommandBuffer()
	self.fence = Fence.New(render.GetDevice())
	self.is_recording_cascades = false
	-- Current cascade being rendered (for Begin/End API)
	self.current_cascade = 1
	return self
end

-- Calculate cascade split distances using practical split scheme
-- Blends between logarithmic and linear split based on lambda parameter
function ShadowMap:CalculateCascadeSplits()
	render3d = render3d or import("goluwa/render3d/render3d.lua")
	local cam = render3d.GetCamera()
	local view_near = cam:GetNearZ()
	local view_far = math.min(cam:GetFarZ(), self.max_shadow_distance)
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

local function get_frustum_slice_corners(cam, split_near, split_far)
	local viewport = cam:GetViewport()
	local aspect = viewport.w / viewport.h
	local tan_half_fov = math.tan(cam:GetFOV() * 0.5)
	local near_height = split_near * tan_half_fov
	local near_width = near_height * aspect
	local far_height = split_far * tan_half_fov
	local far_width = far_height * aspect
	local position = cam:GetPosition()
	local rotation = cam:GetRotation()
	local forward = rotation:GetForward()
	local right = rotation:GetRight()
	local up = rotation:GetUp()
	local near_center = position + forward * split_near
	local far_center = position + forward * split_far
	local near_right = right * near_width
	local near_up = up * near_height
	local far_right = right * far_width
	local far_up = up * far_height
	return {
		near_center - near_right - near_up,
		near_center + near_right - near_up,
		near_center + near_right + near_up,
		near_center - near_right + near_up,
		far_center - far_right - far_up,
		far_center + far_right - far_up,
		far_center + far_right + far_up,
		far_center - far_right + far_up,
	}
end

-- Update all cascade light matrices for cascaded shadow mapping
-- view_camera: the main view camera to calculate frustum splits from
-- light_rotation: quaternion rotation of the directional light
function ShadowMap:UpdateCascadeLightMatrices(light_rotation)
	render3d = render3d or import("goluwa/render3d/render3d.lua")
	local cam = render3d.GetCamera()
	self:CalculateCascadeSplits()

	if TEMP_IDENTITY_CASCADE_OVERRIDE then
		for cascade_idx = 1, self.cascade_count do
			self.cascade[cascade_idx].position = Vec3(0, 0, 0)
			self.cascade[cascade_idx].view_matrix = Matrix44()
			self.cascade[cascade_idx].cull_aabb = AABB(-1000000, -1000000, -1000000, 1000000, 1000000, 1000000)
			self.cascade[cascade_idx].light_space_matrix = Matrix44()
		end

		return
	end

	local world_to_light = light_rotation:GetConjugated():GetMatrix()
	local light_to_world = light_rotation:GetMatrix()
	local previous_split = cam:GetNearZ()

	for cascade_idx = 1, self.cascade_count do
		local split_far = self.cascade_splits[cascade_idx]
		local corners = get_frustum_slice_corners(cam, previous_split, split_far)
		local center = cam:GetPosition() + cam:GetRotation():GetForward() * (
				previous_split + (
					split_far - previous_split
				) * 0.35
			)
		local center_ls = world_to_light:TransformVector(center)
		local min_x, min_y, min_z = math.huge, math.huge, math.huge
		local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

		for i = 1, #corners do
			local corner = world_to_light:TransformVector(corners[i])

			if corner.x < min_x then min_x = corner.x end

			if corner.x > max_x then max_x = corner.x end

			if corner.y < min_y then min_y = corner.y end

			if corner.y > max_y then max_y = corner.y end

			if corner.z < min_z then min_z = corner.z end

			if corner.z > max_z then max_z = corner.z end
		end

		local zoom_factor = self.cascade_zoom_factors[cascade_idx] or 1
		local radius = math.max(
			max_x - center_ls.x,
			center_ls.x - min_x,
			max_y - center_ls.y,
			center_ls.y - min_y
		)
		radius = radius / zoom_factor
		radius = math.max(radius * 1.05, 0.0001)
		local cascade_size = self.cascade[cascade_idx].size or self.size
		local texel_world_x = math.max((radius * 2.0) / cascade_size.w, 0.0001)
		local texel_world_y = math.max((radius * 2.0) / cascade_size.h, 0.0001)
		center_ls.x = math.floor(center_ls.x / texel_world_x + 0.5) * texel_world_x
		center_ls.y = math.floor(center_ls.y / texel_world_y + 0.5) * texel_world_y
		local shadow_center = light_to_world:TransformVector(center_ls)
		local tr = Matrix44()
		tr:Translate(-shadow_center.x, -shadow_center.y, -shadow_center.z)
		tr:Multiply(light_rotation:GetConjugated():GetMatrix())
		local view = tr
		min_x, min_y, min_z = math.huge, math.huge, math.huge
		max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

		for i = 1, #corners do
			local corner = view:TransformVector(corners[i])

			if corner.x < min_x then min_x = corner.x end

			if corner.x > max_x then max_x = corner.x end

			if corner.y < min_y then min_y = corner.y end

			if corner.y > max_y then max_y = corner.y end

			if corner.z < min_z then min_z = corner.z end

			if corner.z > max_z then max_z = corner.z end
		end

		radius = math.max(math.abs(min_x), math.abs(max_x), math.abs(min_y), math.abs(max_y))
		radius = radius / zoom_factor
		radius = math.max(radius * 1.05, 0.0001)
		min_x = -radius
		max_x = radius
		min_y = -radius
		max_y = radius
		local receiver_depth_span = max_z - min_z
		local caster_depth_padding = math.max(receiver_depth_span * 4.0, split_far - previous_split, 100.0)
		local caster_min_z = min_z - caster_depth_padding
		local caster_max_z = max_z + caster_depth_padding
		local projection = Matrix44()
		projection:Ortho(min_x, max_x, min_y, max_y, caster_min_z, caster_max_z, true)
		self.cascade[cascade_idx].position = shadow_center
		self.cascade[cascade_idx].view_matrix = view
		self.cascade[cascade_idx].cull_aabb = AABB(min_x, min_y, caster_min_z, max_x, max_y, caster_max_z)
		self.cascade[cascade_idx].light_space_matrix = view * projection
		previous_split = split_far
	end

	if TEMP_REUSE_FIRST_CASCADE_OVERRIDE and self.cascade_count > 1 then
		local first = self.cascade[1]

		for cascade_idx = 2, self.cascade_count do
			self.cascade[cascade_idx].position = first.position:Copy()
			self.cascade[cascade_idx].view_matrix = first.view_matrix:Copy()
			self.cascade[cascade_idx].cull_aabb = first.cull_aabb:Copy()
			self.cascade[cascade_idx].light_space_matrix = first.light_space_matrix:Copy()
		end
	end
end

function ShadowMap:IsWorldAABBVisible(cascade_index, world_aabb)
	if not world_aabb then return true end

	local cascade = self.cascade[cascade_index]

	if not cascade then return true end

	local local_aabb = AABB.BuildLocalAABBFromWorldAABB(world_aabb, cascade.view_matrix)
	return cascade.cull_aabb:IsBoxIntersecting(local_aabb)
end

-- Begin shadow pass for a specific cascade (or all cascades if cascade_index is nil)
function ShadowMap:Begin(cascade_index)
	cascade_index = cascade_index or 1
	self.current_cascade = cascade_index
	local depth_texture = self.cascade[cascade_index].depth_texture

	if cascade_index == 1 then
		local queue = render.GetQueue()

		if queue:HasPendingSubmission(self.fence) then
			self.fence:Wait(true)
			queue:RetireFence(self.fence)
		end

		self.cmd:Reset()
		self.cmd:Begin()
		self.is_recording_cascades = true
	end

	-- Transition depth texture to depth attachment optimal
	self.cmd:PipelineBarrier{
		srcStage = "fragment",
		dstStage = "early_fragment_tests",
		imageBarriers = {
			{
				image = depth_texture:GetImage(),
				srcAccessMask = "shader_read",
				dstAccessMask = "depth_stencil_attachment_write",
				oldLayout = self.cascade[cascade_index].is_sampleable and
					"shader_read_only_optimal" or
					"undefined",
				newLayout = "depth_attachment_optimal",
			-- aspect is automatically determined from image format by PipelineBarrier
			},
		},
	}
	-- Use integer values from the depth texture to ensure consistency
	local w = depth_texture:GetWidth()
	local h = depth_texture:GetHeight()
	-- Begin rendering (depth-only)
	self.cmd:BeginRendering{
		depth_image_view = depth_texture:GetView(),
		depth_store = true, -- We need to store the depth for sampling later
		depth_layout = "depth_attachment_optimal",
		w = w,
		h = h,
		clear_depth = 1.0,
	}
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
-- material: optional Material object for alpha testing (will use albedo texture)
function ShadowMap:UploadConstants(world_matrix, material, cascade_index)
	cascade_index = cascade_index or self.current_cascade
	local constants = ShadowVertexConstants()
	local mvp = world_matrix * self.cascade[cascade_index].light_space_matrix
	constants.light_space_matrix = mvp:GetFloatCopy()
	local pipeline = use_tessellated_shadow(material) and self.tess_pipeline or self.pipeline

	-- If material is provided, get its albedo texture index and flags for alpha testing
	if material then
		constants.albedo_texture_index = pipeline:GetTextureIndex(material:GetAlbedoTexture())
		constants.height_texture_index = pipeline:GetTextureIndex(material:GetHeightTexture())
		constants.flags = material:GetFillFlags()
		constants.color_multiplier_a = material:GetColorMultiplier().a
		constants.alpha_cutoff = material:GetAlphaCutoff()
		constants.height_scale = material:GetHeightScale()
		constants.height_center = material:GetHeightCenter()
		constants.tessellation_factor = material:GetTessellationFactor()
	else
		constants.albedo_texture_index = 0 -- No texture, no alpha test
		constants.height_texture_index = -1
		constants.flags = 0
		constants.color_multiplier_a = 1.0
		constants.alpha_cutoff = 0.5
		constants.height_scale = 0.0
		constants.height_center = 0.5
		constants.tessellation_factor = 1.0
	end

	model_pipeline.FillVertexAnimationData(self.vertex_animation_buffer:GetData(), material or render3d.GetDefaultMaterial())
	world_matrix:CopyToFloatPointer(self.shadow_transform_buffer:GetData().world)
	local frame_index = render.GetCurrentFrame()
	local vertex_animation_offset = self.vertex_animation_buffer:Upload(frame_index)
	local shadow_transform_offset = self.shadow_transform_buffer:Upload(frame_index)
	pipeline:Bind(self.cmd, frame_index, {vertex_animation_offset, shadow_transform_offset})

	do
		local depth_texture = self.cascade[cascade_index].depth_texture
		local w = depth_texture:GetWidth()
		local h = depth_texture:GetHeight()
		self.cmd:SetViewport(0.0, 0.0, w, h, 0.0, 1.0)
		self.cmd:SetScissor(0, 0, w, h)
	end

	self.cmd:SetFrontFace(orientation.FRONT_FACE)
	self.cmd:SetCullMode("none")

	if pipeline == self.tess_pipeline then
		pipeline:PushConstants(
			self.cmd,
			{"tessellation_control", "tessellation_evaluation", "fragment"},
			0,
			constants
		)
	else
		pipeline:PushConstants(self.cmd, {"vertex", "fragment"}, 0, constants)
	end
end

function ShadowMap:PrimeMaterial(material)
	if not material then return end

	self.pipeline:GetTextureIndex(material:GetAlbedoTexture())
	self.pipeline:GetTextureIndex(material:GetHeightTexture())

	if self.tess_pipeline then
		self.tess_pipeline:GetTextureIndex(material:GetAlbedoTexture())
		self.tess_pipeline:GetTextureIndex(material:GetHeightTexture())
	end
end

-- End shadow pass for current cascade
function ShadowMap:End(cascade_index)
	cascade_index = cascade_index or self.current_cascade
	local depth_texture = self.cascade[cascade_index].depth_texture
	self.cmd:EndRendering()
	-- Transition depth texture to shader read optimal for sampling
	self.cmd:PipelineBarrier{
		srcStage = "late_fragment_tests",
		dstStage = "fragment",
		imageBarriers = {
			{
				image = depth_texture:GetImage(),
				srcAccessMask = "depth_stencil_attachment_write",
				dstAccessMask = "shader_read",
				oldLayout = "depth_attachment_optimal",
				newLayout = "shader_read_only_optimal",
			-- aspect is automatically determined from image format by PipelineBarrier
			},
		},
	}

	if cascade_index == self.cascade_count then
		self.cmd:End()
		self.is_recording_cascades = false

		for i = 1, self.cascade_count do
			self.cascade[i].is_sampleable = true
		end

		-- Submit once after all cascades are recorded and let the next frame fence-gate reuse.
		render.Submit(self.cmd, self.fence)
	end
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

return ShadowMap:Register()
