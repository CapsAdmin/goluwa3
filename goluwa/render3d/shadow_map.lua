local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local render3d = nil
local ShadowMapLispsm = import("goluwa/render3d/shadow_map_lispsm.lua")
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
local DEFAULT_SIZE = Vec2() + 512 --Vec2(800, 600) --Vec2() + 2048 -- Shadow map resolution
local DEFAULT_FORMAT = "d32_sfloat"
local DEFAULT_POINT_COLOR_FORMAT = "r32_sfloat"
local DEFAULT_CASCADE_COUNT = 3 -- Default number of cascades for CSM
local DEFAULT_DIRECTIONAL_PROJECTION_MODE = ShadowMapLispsm.DEFAULT_DIRECTIONAL_PROJECTION_MODE
local FRUSTUM_PLANE_COMPONENT_COUNT = 24
local TEMP_IDENTITY_CASCADE_OVERRIDE = false
local TEMP_REUSE_FIRST_CASCADE_OVERRIDE = false
local POINT_SHADOW_FACE_ANGLES = {
	Deg3(0, -90 + 180, 0),
	Deg3(0, 90 + 180, 0),
	Deg3(90, 0 + 180, 0),
	Deg3(-90, 0 + 180, 0),
	Deg3(0, 0 + 180, 0),
	Deg3(0, 180 + 180, 0),
}

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

local function get_shadow_material_texture_cache(self)
	self.shadow_material_texture_cache = self.shadow_material_texture_cache or setmetatable({}, {__mode = "k"})
	return self.shadow_material_texture_cache
end

local function cache_shadow_material_texture_indices(self, material, pipeline)
	if not material or not pipeline then return nil end

	local cache = get_shadow_material_texture_cache(self)
	local material_cache = cache[material]

	if not material_cache then
		material_cache = setmetatable({}, {__mode = "k"})
		cache[material] = material_cache
	end

	local entry = material_cache[pipeline] or {}
	local albedo_texture = material:GetAlbedoTexture()
	local opacity_texture = material:GetOpacityTexture()
	local height_texture = material:GetHeightTexture()
	local albedo_view = albedo_texture and albedo_texture:GetView() or nil
	local opacity_view = opacity_texture and opacity_texture:GetView() or nil
	local height_view = height_texture and height_texture:GetView() or nil

	if
		entry.albedo_texture ~= albedo_texture or
		entry.albedo_view ~= albedo_view or
		entry.opacity_texture ~= opacity_texture or
		entry.opacity_view ~= opacity_view or
		entry.height_texture ~= height_texture or
		entry.height_view ~= height_view
	then
		entry.albedo_texture = albedo_texture
		entry.albedo_view = albedo_view
		entry.opacity_texture = opacity_texture
		entry.opacity_view = opacity_view
		entry.height_texture = height_texture
		entry.height_view = height_view
		entry.albedo_texture_index = pipeline:GetTextureIndex(albedo_texture)
		entry.opacity_texture_index = pipeline:GetTextureIndex(opacity_texture)
		entry.height_texture_index = pipeline:GetTextureIndex(height_texture)
		material_cache[pipeline] = entry
	end

	return entry
end

local function get_cached_shadow_material_texture_indices(self, material, pipeline)
	local cache = self.shadow_material_texture_cache
	local material_cache = cache and cache[material] or nil
	local entry = material_cache and material_cache[pipeline] or nil

	if entry then return entry end

	return nil
end

-- Push constants for shadow pass (MVP matrix + texture index for alpha testing)
local ShadowDrawPushConstants = ffi.typeof([[
	struct {
		float world[16];
	}
]])
local ShadowStateUniformDecl = [[
	struct {
		float light_space_matrix[16];
		float light_position[3];
		float light_far_plane;
		int albedo_texture_index;
		int opacity_texture_index;
		int height_texture_index;
		int flags;
		float color_multiplier_a;
		float alpha_cutoff;
		float height_scale;
		float height_center;
		float tessellation_factor;
	}
]]
local SHADOW_PUSH_CONSTANT_GLSL = [[
	layout(push_constant, scalar) uniform Constants {
		mat4 world;
	} pc;
]]
local SHADOW_STATE_UNIFORM_GLSL = [[
	layout(scalar, binding = 2) uniform ShadowState_t {
		mat4 light_space_matrix;
		vec3 light_position;
		float light_far_plane;
		int albedo_texture_index;
		int opacity_texture_index;
		int height_texture_index;
		int flags;
		float color_multiplier_a;
		float alpha_cutoff;
		float height_scale;
		float height_center;
		float tessellation_factor;
	} shadow_state;
]]
local NO_SHADOW_STATE_MATERIAL = {}

local function get_shadow_stage_push_constants()
	return {
		size = ffi.sizeof(ShadowDrawPushConstants),
		offset = 0,
	}
end

local function get_shadow_texture_descriptor_sets(self, bindless_texture_capacity)
	return {
		{
			type = "combined_image_sampler",
			binding_index = 0,
			count = bindless_texture_capacity,
		},
		{
			type = "uniform_buffer_dynamic",
			binding_index = 2,
			args = {self.shadow_state_buffer.buffer, self.shadow_state_buffer.aligned_size},
		},
	}
end

local function get_shadow_geometry_descriptor_sets(self, bindless_texture_capacity)
	local descriptor_sets = {
		{
			type = "combined_image_sampler",
			binding_index = 0,
			count = bindless_texture_capacity,
		},
		{
			type = "uniform_buffer_dynamic",
			binding_index = 1,
			args = {self.vertex_animation_buffer.buffer, self.vertex_animation_buffer.aligned_size},
		},
		{
			type = "uniform_buffer_dynamic",
			binding_index = 2,
			args = {self.shadow_state_buffer.buffer, self.shadow_state_buffer.aligned_size},
		},
	}
	return descriptor_sets
end

local function get_shadow_tess_control_descriptor_sets(self, bindless_texture_capacity)
	return {
		{
			type = "combined_image_sampler",
			binding_index = 0,
			count = bindless_texture_capacity,
		},
		{
			type = "uniform_buffer_dynamic",
			binding_index = 1,
			args = {self.vertex_animation_buffer.buffer, self.vertex_animation_buffer.aligned_size},
		},
		{
			type = "uniform_buffer_dynamic",
			binding_index = 2,
			args = {self.shadow_state_buffer.buffer, self.shadow_state_buffer.aligned_size},
		},
	}
end

local function build_shadow_fragment_shader(bindless_texture_capacity, linear_depth_output)
	local prelude = (
		[[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					#extension GL_EXT_scalar_block_layout : require

					layout(binding = 0) uniform sampler2D textures[%d];

					%s
					%s
					layout(location = 0) in vec2 in_uv;
					%s
					%s

					#define FLAGS shadow_state.flags
				]]
	):format(
		bindless_texture_capacity,
		SHADOW_PUSH_CONSTANT_GLSL,
		SHADOW_STATE_UNIFORM_GLSL,
		linear_depth_output and "layout(location = 1) in vec3 in_world_pos;" or "",
		linear_depth_output and "layout(location = 0) out float out_distance;" or ""
	)
	return prelude .. Material.BuildGlslFlags("shadow_state.flags") .. model_pipeline.BuildBindlessAlphaSamplingGlsl(
			"shadow_state.albedo_texture_index",
			"shadow_state.color_multiplier_a",
			"shadow_state.opacity_texture_index"
		) .. model_pipeline.BuildAlphaDiscardGlsl("shadow_state.alpha_cutoff") .. (
			linear_depth_output and
			[[
					void main() {
						float alpha = get_alpha();
						compute_translucency_and_discard(alpha);
						float light_distance = length(in_world_pos - shadow_state.light_position);
						out_distance = clamp(light_distance / max(shadow_state.light_far_plane, 0.0001), 0.0, 1.0);
					}
				]] or
			[[
					void main() {
						float alpha = get_alpha();
						compute_translucency_and_discard(alpha);
					}
				]]
		)
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
						vec3 world_pos = (pc.world * vec4(local_pos, 1.0)).xyz;
						mat3 world_matrix3 = mat3(pc.world);
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

						gl_Position = shadow_state.light_space_matrix * vec4(world_pos, 1.0);
						out_uv = uv;
						out_world_pos = world_pos;
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
				]] .. SHADOW_STATE_UNIFORM_GLSL .. [[
				]] .. model_pipeline.BuildVertexAnimationUniformDeclaration("vertex_animation", 1) .. [[
					layout(location = 0) out vec2 out_uv;
					layout(location = 1) out vec3 out_world_pos;

				]] .. model_pipeline.BuildShadowGeometryDeformationGlsl("vertex_animation", "shadow_state") .. build_shadow_projected_main(
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

local function build_shadow_tess_control_stage(self, bindless_texture_capacity)
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

					]] .. SHADOW_STATE_UNIFORM_GLSL .. [[

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
							float tess = clamp(shadow_state.tessellation_factor, 1.0, 64.0);
							gl_TessLevelOuter[0] = tess;
							gl_TessLevelOuter[1] = tess;
							gl_TessLevelOuter[2] = tess;
							gl_TessLevelInner[0] = tess;
						}
					}
				]],
		descriptor_sets = get_shadow_tess_control_descriptor_sets(self, bindless_texture_capacity),
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
				]] .. SHADOW_STATE_UNIFORM_GLSL .. [[

				]] .. model_pipeline.BuildVertexAnimationUniformDeclaration("vertex_animation", 1) .. [[
					layout(triangles, equal_spacing, cw) in;
					layout(location = 0) out vec2 out_uv;
					layout(location = 1) out vec3 out_world_pos;

				]] .. model_pipeline.BuildShadowGeometryDeformationGlsl("vertex_animation", "shadow_state") .. model_pipeline.BuildTriangleInterpolationGlsl() .. build_shadow_projected_main(
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

local function build_shadow_fragment_stage(self, bindless_texture_capacity, linear_depth_output)
	return {
		type = "fragment",
		code = build_shadow_fragment_shader(bindless_texture_capacity, linear_depth_output),
		descriptor_sets = get_shadow_texture_descriptor_sets(self, bindless_texture_capacity),
	}
end

local function get_shadow_state_upload_cache(self, frame_index)
	local cache = self.shadow_state_upload_cache

	if not cache or cache.frame_index ~= frame_index then
		cache = {frame_index = frame_index, pipelines = {}}
		self.shadow_state_upload_cache = cache
	end

	return cache.pipelines
end

local function get_shadow_state_offset(self, frame_index, pipeline, material, cascade_index, texture_entry)
	local pipelines = get_shadow_state_upload_cache(self, frame_index)
	local pipeline_cache = pipelines[pipeline]

	if not pipeline_cache then
		pipeline_cache = {}
		pipelines[pipeline] = pipeline_cache
	end

	local material_key = material or NO_SHADOW_STATE_MATERIAL
	local material_cache = pipeline_cache[material_key]

	if not material_cache then
		material_cache = {}
		pipeline_cache[material_key] = material_cache
	end

	local cached_offset = material_cache[cascade_index]

	if cached_offset then return cached_offset end

	local data = self.shadow_state_buffer:GetData()
	data.light_space_matrix = self.cascade[cascade_index].light_space_matrix:GetFloatCopy()
	data.light_position[0] = self.point_light_position.x
	data.light_position[1] = self.point_light_position.y
	data.light_position[2] = self.point_light_position.z
	data.light_far_plane = self.far_plane

	if material then
		data.albedo_texture_index = texture_entry and texture_entry.albedo_texture_index or 0
		data.opacity_texture_index = texture_entry and texture_entry.opacity_texture_index or -1
		data.height_texture_index = texture_entry and texture_entry.height_texture_index or -1
		data.flags = material:GetFillFlags()
		data.color_multiplier_a = material:GetColorMultiplier().a
		data.alpha_cutoff = material:GetAlphaCutoff()
		data.height_scale = material:GetHeightScale()
		data.height_center = material:GetHeightCenter()
		data.tessellation_factor = material:GetTessellationFactor()
	else
		data.albedo_texture_index = 0
		data.opacity_texture_index = -1
		data.height_texture_index = -1
		data.flags = 0
		data.color_multiplier_a = 1.0
		data.alpha_cutoff = 0.5
		data.height_scale = 0.0
		data.height_center = 0.5
		data.tessellation_factor = 1.0
	end

	local offset = self.shadow_state_buffer:Upload(frame_index)
	material_cache[cascade_index] = offset
	return offset
end

local function build_shadow_pipeline_config(
	format,
	max_shadow_width,
	max_shadow_height,
	shader_stages,
	topology,
	patch_control_points,
	color_format
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
		ColorFormat = color_format or false,
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
		DepthBiasClamp = 0.01,
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

local function normalize_shadow_size(size)
	if not size then return DEFAULT_SIZE:Copy() end

	if type(size) == "number" then return Vec2(size, size) end

	if size.Copy then return size:Copy() end

	return Vec2(size.w or size.x, size.h or size.y)
end

local function get_cascade_depth_format(cascade_formats, cascade_index, default_format)
	if not cascade_formats then return default_format end

	return cascade_formats[cascade_index] or default_format
end

local function create_shadow_pipeline_variant(
	self,
	depth_format,
	max_shadow_width,
	max_shadow_height,
	bindless_texture_capacity,
	linear_depth_output,
	color_format
)
	local pipeline = render.CreateGraphicsPipeline(
		build_shadow_pipeline_config(
			depth_format,
			max_shadow_width,
			max_shadow_height,
			{
				build_shadow_vertex_stage(self, bindless_texture_capacity),
				build_shadow_fragment_stage(self, bindless_texture_capacity, linear_depth_output),
			},
			"triangle_list",
			nil,
			color_format
		)
	)
	local tess_pipeline = nil

	if supports_tessellation() then
		tess_pipeline = render.CreateGraphicsPipeline(
			build_shadow_pipeline_config(
				depth_format,
				max_shadow_width,
				max_shadow_height,
				{
					build_shadow_tess_vertex_stage(),
					build_shadow_tess_control_stage(self, bindless_texture_capacity),
					build_shadow_tess_evaluation_stage(self, bindless_texture_capacity),
					build_shadow_fragment_stage(self, bindless_texture_capacity, linear_depth_output),
				},
				"patch_list",
				3,
				color_format
			)
		)
	end

	return pipeline, tess_pipeline
end

local function get_pipeline_for_cascade(self, material, cascade_index)
	local uses_tessellation = use_tessellated_shadow(material)

	if self.mode == "point" then
		return uses_tessellation and self.tess_pipeline or self.pipeline,
		uses_tessellation
	end

	local cascade = self.cascade[cascade_index]
	local depth_format = cascade and cascade.format or self.format
	return uses_tessellation and
		self.tess_pipeline_variants[depth_format] or
		self.pipeline_variants[depth_format],
	uses_tessellation
end

local function extract_frustum_planes(proj_view_matrix, out_planes)
	local m = proj_view_matrix
	out_planes[0] = m.m03 + m.m00
	out_planes[1] = m.m13 + m.m10
	out_planes[2] = m.m23 + m.m20
	out_planes[3] = m.m33 + m.m30
	out_planes[4] = m.m03 - m.m00
	out_planes[5] = m.m13 - m.m10
	out_planes[6] = m.m23 - m.m20
	out_planes[7] = m.m33 - m.m30
	out_planes[8] = m.m03 + m.m01
	out_planes[9] = m.m13 + m.m11
	out_planes[10] = m.m23 + m.m21
	out_planes[11] = m.m33 + m.m31
	out_planes[12] = m.m03 - m.m01
	out_planes[13] = m.m13 - m.m11
	out_planes[14] = m.m23 - m.m21
	out_planes[15] = m.m33 - m.m31
	out_planes[16] = m.m02
	out_planes[17] = m.m12
	out_planes[18] = m.m22
	out_planes[19] = m.m32
	out_planes[20] = m.m03 - m.m02
	out_planes[21] = m.m13 - m.m12
	out_planes[22] = m.m23 - m.m22
	out_planes[23] = m.m33 - m.m32

	for i = 0, 20, 4 do
		local a, b, c = out_planes[i], out_planes[i + 1], out_planes[i + 2]
		local len = math.sqrt(a * a + b * b + c * c)

		if len > 0 then
			local inv_len = 1.0 / len
			out_planes[i] = a * inv_len
			out_planes[i + 1] = b * inv_len
			out_planes[i + 2] = c * inv_len
			out_planes[i + 3] = out_planes[i + 3] * inv_len
		end
	end
end

local function is_aabb_visible_frustum(aabb, frustum_planes)
	for i = 0, 20, 4 do
		local a, b, c, d = frustum_planes[i], frustum_planes[i + 1], frustum_planes[i + 2], frustum_planes[i + 3]
		local px = a > 0 and aabb.max_x or aabb.min_x
		local py = b > 0 and aabb.max_y or aabb.min_y
		local pz = c > 0 and aabb.max_z or aabb.min_z

		if a * px + b * py + c * pz + d < 0 then return false end
	end

	return true
end

local function update_cascade_frustum_planes(cascade)
	if not cascade or not cascade.light_space_matrix or not cascade.frustum_planes then
		return
	end

	extract_frustum_planes(cascade.light_space_matrix, cascade.frustum_planes)
end

local function get_shadow_texel_coverage(self, cascade_index, world_aabb)
	if self.mode == "point" or not world_aabb then return math.huge, math.huge end

	local cascade = self.cascade[cascade_index]

	if not cascade then return math.huge, math.huge end

	local texel_world_size = cascade.texel_world_size or 0

	if texel_world_size <= 0 then return math.huge, math.huge end

	local local_aabb = AABB.BuildLocalAABBFromWorldAABB(world_aabb, cascade.view_matrix)
	local width_texels = (local_aabb.max_x - local_aabb.min_x) / texel_world_size
	local height_texels = (local_aabb.max_y - local_aabb.min_y) / texel_world_size
	return width_texels, height_texels
end

local function build_world_aabb_from_local_aabb(local_aabb, local_to_world)
	if not local_aabb then return nil end

	if not local_to_world then return local_aabb end

	local corners = {
		Vec3(local_aabb.min_x, local_aabb.min_y, local_aabb.min_z),
		Vec3(local_aabb.min_x, local_aabb.min_y, local_aabb.max_z),
		Vec3(local_aabb.min_x, local_aabb.max_y, local_aabb.min_z),
		Vec3(local_aabb.min_x, local_aabb.max_y, local_aabb.max_z),
		Vec3(local_aabb.max_x, local_aabb.min_y, local_aabb.min_z),
		Vec3(local_aabb.max_x, local_aabb.min_y, local_aabb.max_z),
		Vec3(local_aabb.max_x, local_aabb.max_y, local_aabb.min_z),
		Vec3(local_aabb.max_x, local_aabb.max_y, local_aabb.max_z),
	}
	local world_aabb = AABB(math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge)

	for i = 1, #corners do
		local point = local_to_world:TransformVector(corners[i])
		world_aabb:ExpandVec3(point)
	end

	return world_aabb
end

local function create_point_face_views(cubemap)
	local face_views = {}

	for face = 0, 5 do
		face_views[face + 1] = cubemap:GetImage():CreateView{
			view_type = "2d",
			base_array_layer = face,
			layer_count = 1,
			base_mip_level = 0,
			level_count = 1,
		}
	end

	return face_views
end

local get_frustum_slice_corners

local function set_directional_cascade_state(
	self,
	cascade,
	light_position,
	view,
	light_space_matrix,
	texel_world_size,
	cull_aabb,
	range
)
	cascade.position = light_position:Copy()
	cascade.view_matrix = view
	cascade.light_space_matrix = light_space_matrix
	cascade.texel_world_size = texel_world_size
	cascade.cull_aabb = cull_aabb
	update_cascade_frustum_planes(cascade)
	self.cascade_splits[1] = range
end

local function update_local_directional_orthographic(self, light_position, light_rotation, range, ortho_size)
	range = range or self.far_plane
	ortho_size = ortho_size or self.ortho_size
	local half_depth = math.max(range * 0.5, 0.001)
	local view = Matrix44()
	view:Translate(-light_position.x, -light_position.y, -light_position.z)
	view:Multiply(light_rotation:GetConjugated():GetMatrix())
	local projection = Matrix44()
	projection:Ortho(-ortho_size, ortho_size, -ortho_size, ortho_size, -half_depth, half_depth, true)
	local cascade = self.cascade[1]
	set_directional_cascade_state(
		self,
		cascade,
		light_position,
		view,
		view * projection,
		(ortho_size * 2.0) / math.max(self.size.w, self.size.h),
		AABB(-ortho_size, -ortho_size, -half_depth, ortho_size, ortho_size, half_depth),
		range
	)
end

local function get_camera_shadow_corners(max_distance)
	render3d = render3d or import("goluwa/render3d/render3d.lua")
	local cam = render3d.GetCamera()

	if not cam then return nil end

	local split_near = cam:GetNearZ()
	local split_far = math.min(cam:GetFarZ(), max_distance or cam:GetFarZ())

	if split_far <= split_near then return nil end

	return cam,
	get_frustum_slice_corners(cam, split_near, split_far),
	split_near,
	split_far
end

local function depth_to_linear_distance(depth, near_plane, far_plane)
	if depth == nil or depth >= 1.0 or depth <= 0.0 then return nil end

	local denom = far_plane - depth * (far_plane - near_plane)

	if denom <= 1e-6 then return nil end

	return (near_plane * far_plane) / denom
end

local function get_depth_fit_percentile(sorted_values, percentile)
	if #sorted_values == 0 then return nil end

	local index = math.floor(math.clamp(percentile, 0, 1) * (#sorted_values - 1) + 1.5)
	index = math.clamp(index, 1, #sorted_values)
	return index
end

local function partition_depth_values(values, left, right, pivot_index)
	local pivot_value = values[pivot_index]
	values[pivot_index], values[right] = values[right], values[pivot_index]
	local store_index = left

	for i = left, right - 1 do
		if values[i] < pivot_value then
			values[store_index], values[i] = values[i], values[store_index]
			store_index = store_index + 1
		end
	end

	values[right], values[store_index] = values[store_index], values[right]
	return store_index
end

local function quickselect_depth_value(values, target_index)
	local left = 1
	local right = #values

	while left <= right do
		if left == right then return values[left] end

		local mid = math.floor((left + right) * 0.5)
		local a = values[left]
		local b = values[mid]
		local c = values[right]
		local pivot_index = mid

		if a > b then a, b = b, a end

		if b > c then b, c = c, b end

		if a > b then b = a end

		if b == values[left] then
			pivot_index = left
		elseif b == values[right] then
			pivot_index = right
		end

		pivot_index = partition_depth_values(values, left, right, pivot_index)

		if target_index == pivot_index then return values[target_index] end

		if target_index < pivot_index then
			right = pivot_index - 1
		else
			left = pivot_index + 1
		end
	end

	return nil
end

function ShadowMap.New(config)
	config = config or {}
	local self = ShadowMap:CreateObject()
	local bindless_texture_capacity = render.GetBindlessDescriptorCapacities().textures
	self.mode = config.mode or "directional"
	self.size = normalize_shadow_size(config.size)
	self.format = config.format or DEFAULT_FORMAT
	self.directional_projection_mode = ShadowMapLispsm.NormalizeDirectionalProjectionMode(config.directional_projection_mode or
		(
			self.mode == "directional" and
			DEFAULT_DIRECTIONAL_PROJECTION_MODE or
			"orthographic"
		))
	self.cascade_formats = config.cascade_formats
	self.near_plane = config.near_plane or 0.1
	self.far_plane = config.far_plane or 100.0
	self.ortho_size = config.ortho_size or 50.0 -- Half-size of orthographic projection
	self.point_color_format = config.point_color_format or DEFAULT_POINT_COLOR_FORMAT
	self.point_light_position = Vec3(0, 0, 0)
	-- Cascaded shadow map settings
	self.cascade_count = config.cascade_count or (self.mode == "point" and 6 or DEFAULT_CASCADE_COUNT)

	if self.mode ~= "point" then
		assert(self.cascade_count <= 4, "shadow maps currently support up to 4 cascades")
	end

	self.cascade_split_lambda = config.cascade_split_lambda or 0.75 -- Blend between linear and logarithmic split
	self.max_shadow_distance = config.max_shadow_distance or 500.0 -- Maximum shadow distance (clamps view far plane)
	self.min_caster_texel_size = config.min_caster_texel_size or 0
	self.sticky_cascade_index = config.sticky_cascade_index
	self.disable_vertex_animation_cascades = config.disable_vertex_animation_cascades or {}
	self.cascade_zoom_factors = config.cascade_zoom_factors or {}
	self.cascade_splits = {} -- Will store the split distances
	self.cascade = {} -- Per-cascade data
	self.vertex_animation_buffer = UniformBuffer.New(model_pipeline.GetVertexAnimationUniformBufferDecl())
	self.shadow_state_buffer = UniformBuffer.New(ShadowStateUniformDecl)
	local cascade_sizes = config.cascade_sizes or {}
	local max_shadow_width = self.size.w
	local max_shadow_height = self.size.h

	if self.mode == "point" then
		max_shadow_width = self.size.w
		max_shadow_height = self.size.h

		for i = 1, 6 do
			self.cascade[i] = {
				position = Vec3(0, 0, 0),
				size = self.size,
				texel_world_size = 0,
				view_matrix = Matrix44(),
				cull_aabb = AABB(-1, -1, -1, 1, 1, 1),
				light_space_matrix = Matrix44(),
				frustum_planes = ffi.new("float[?]", FRUSTUM_PLANE_COMPONENT_COUNT),
				last_shadow_volume_change_version = 0,
				last_camera_position = nil,
				last_rendered_frame = nil,
				is_sampleable = false,
			}
		end

		self.point_depth_cubemap = Texture.New{
			width = self.size.w,
			height = self.size.h,
			format = self.point_color_format,
			image = {
				array_layers = 6,
				flags = {"cube_compatible"},
				usage = {"color_attachment", "sampled"},
				properties = "device_local",
			},
			view = {
				view_type = "cube",
				layer_count = 6,
			},
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
				wrap_r = "clamp_to_edge",
			},
		}
		self.point_face_views = create_point_face_views(self.point_depth_cubemap)
		self.point_depth_buffer = Texture.New{
			width = self.size.w,
			height = self.size.h,
			format = self.format,
			image = {
				usage = {"depth_stencil_attachment"},
				properties = "device_local",
			},
			view = {
				aspect = "depth",
			},
		}
		self.point_depth_buffer_ready = false
		self.pipeline, self.tess_pipeline = create_shadow_pipeline_variant(
			self,
			self.format,
			max_shadow_width,
			max_shadow_height,
			bindless_texture_capacity,
			true,
			self.point_color_format
		)
	else
		local unique_formats = {}

		-- Initialize cascades
		for i = 1, self.cascade_count do
			local cascade_size = normalize_shadow_size(cascade_sizes[i] or self.size)
			local cascade_format = get_cascade_depth_format(self.cascade_formats, i, self.format)

			if cascade_size.w > max_shadow_width then max_shadow_width = cascade_size.w end

			if cascade_size.h > max_shadow_height then max_shadow_height = cascade_size.h end

			self.cascade[i] = {
				position = Vec3(0, 0, 0),
				size = cascade_size,
				format = cascade_format,
				texel_world_size = 0,
				view_matrix = Matrix44(),
				cull_aabb = AABB(-1, -1, -1, 1, 1, 1),
				light_space_matrix = Matrix44(),
				frustum_planes = ffi.new("float[?]", FRUSTUM_PLANE_COMPONENT_COUNT),
				is_sampleable = false,
			}
			self.cascade[i].depth_texture = Texture.New{
				width = cascade_size.w,
				height = cascade_size.h,
				format = cascade_format,
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
				},
			}
			unique_formats[cascade_format] = true
		end

		self.pipeline_variants = {}
		self.tess_pipeline_variants = {}

		for depth_format in pairs(unique_formats) do
			local pipeline, tess_pipeline = create_shadow_pipeline_variant(
				self,
				depth_format,
				max_shadow_width,
				max_shadow_height,
				bindless_texture_capacity,
				false,
				nil
			)
			self.pipeline_variants[depth_format] = pipeline
			self.tess_pipeline_variants[depth_format] = tess_pipeline
		end

		self.pipeline = self.pipeline_variants[self.format]
		self.tess_pipeline = self.tess_pipeline_variants[self.format]
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

function ShadowMap:UpdatePointLightMatrices(light_position)
	self.point_light_position = light_position:Copy()
	local projection = Matrix44()
	projection:Perspective(math.rad(90), self.near_plane, self.far_plane, 1)

	for face = 1, 6 do
		local rotation = Quat():SetAngles(POINT_SHADOW_FACE_ANGLES[face])
		local view = Matrix44()
		view:Translate(-light_position.x, -light_position.y, -light_position.z)
		view:Multiply(rotation:GetConjugated():GetMatrix())
		self.cascade[face].position = light_position:Copy()
		self.cascade[face].view_matrix = view
		self.cascade[face].light_space_matrix = view * projection
		self.cascade[face].texel_world_size = self.far_plane / math.max(self.size.w, self.size.h)
		self.cascade[face].cull_aabb = AABB(
			light_position.x - self.far_plane,
			light_position.y - self.far_plane,
			light_position.z - self.far_plane,
			light_position.x + self.far_plane,
			light_position.y + self.far_plane,
			light_position.z + self.far_plane
		)
		update_cascade_frustum_planes(self.cascade[face])
	end

	self.cascade_splits[1] = self.far_plane
end

function ShadowMap:UpdateLocalDirectionalLightMatrices(light_position, light_rotation, range, ortho_size)
	if
		self.directional_projection_mode ~= "orthographic" and
		ShadowMapLispsm.UpdateLocalDirectional(
			self,
			light_position,
			light_rotation,
			range,
			get_frustum_slice_corners,
			set_directional_cascade_state
		)
	then
		return
	end

	update_local_directional_orthographic(self, light_position, light_rotation, range, ortho_size)
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

function get_frustum_slice_corners(cam, split_near, split_far)
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
function ShadowMap:UpdateCascadeLightMatrices(light_rotation, cascade_update_mask)
	if self.mode == "point" then return end

	render3d = render3d or import("goluwa/render3d/render3d.lua")
	local cam = render3d.GetCamera()
	self:CalculateCascadeSplits()

	if TEMP_IDENTITY_CASCADE_OVERRIDE then
		for cascade_idx = 1, self.cascade_count do
			self.cascade[cascade_idx].position = Vec3(0, 0, 0)
			self.cascade[cascade_idx].view_matrix = Matrix44()
			self.cascade[cascade_idx].cull_aabb = AABB(-1000000, -1000000, -1000000, 1000000, 1000000, 1000000)
			self.cascade[cascade_idx].light_space_matrix = Matrix44()
			update_cascade_frustum_planes(self.cascade[cascade_idx])
		end

		return
	end

	local world_to_light = light_rotation:GetConjugated():GetMatrix()
	local light_to_world = light_rotation:GetMatrix()
	local previous_split = cam:GetNearZ()

	for cascade_idx = 1, self.cascade_count do
		local split_far = self.cascade_splits[cascade_idx]

		if cascade_update_mask and cascade_update_mask[cascade_idx] == false then
			previous_split = split_far

			goto continue
		end

		local corners = get_frustum_slice_corners(cam, previous_split, split_far)
		local center = Vec3(0, 0, 0)

		for i = 1, #corners do
			center = center + corners[i]
		end

		center = center / #corners
		local sphere_radius = 0

		for i = 1, #corners do
			local offset = corners[i] - center
			local distance = offset:GetLength()

			if distance > sphere_radius then sphere_radius = distance end
		end

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
		local radius = sphere_radius
		radius = radius / zoom_factor
		radius = math.max(radius * 1.05, 0.0001)
		local cascade_size = self.cascade[cascade_idx].size or self.size
		local texel_world_x = math.max((radius * 2.0) / cascade_size.w, 0.0001)
		local texel_world_y = math.max((radius * 2.0) / cascade_size.h, 0.0001)
		self.cascade[cascade_idx].texel_world_size = math.max(texel_world_x, texel_world_y)
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
		update_cascade_frustum_planes(self.cascade[cascade_idx])
		previous_split = split_far

		::continue::
	end

	if TEMP_REUSE_FIRST_CASCADE_OVERRIDE and self.cascade_count > 1 then
		local first = self.cascade[1]

		for cascade_idx = 2, self.cascade_count do
			self.cascade[cascade_idx].position = first.position:Copy()
			self.cascade[cascade_idx].view_matrix = first.view_matrix:Copy()
			self.cascade[cascade_idx].cull_aabb = first.cull_aabb:Copy()
			self.cascade[cascade_idx].light_space_matrix = first.light_space_matrix:Copy()
			update_cascade_frustum_planes(self.cascade[cascade_idx])
		end
	end
end

function ShadowMap:IsWorldAABBVisible(cascade_index, world_aabb)
	if not world_aabb then return true end

	local cascade = self.cascade[cascade_index]

	if not cascade then return true end

	if self.mode == "point" then
		return world_aabb:IsOverlappedSphereInside(self.point_light_position, self.far_plane) and
			is_aabb_visible_frustum(world_aabb, cascade.frustum_planes)
	end

	local local_aabb = AABB.BuildLocalAABBFromWorldAABB(world_aabb, cascade.view_matrix)

	if not cascade.cull_aabb:IsBoxIntersecting(local_aabb) then return false end

	return is_aabb_visible_frustum(world_aabb, cascade.frustum_planes)
end

function ShadowMap:IsWorldAABBTooSmall(cascade_index, world_aabb)
	local min_caster_texel_size = self.min_caster_texel_size or 0

	if min_caster_texel_size <= 0 then return false end

	local width_texels, height_texels = get_shadow_texel_coverage(self, cascade_index, world_aabb)
	return width_texels < min_caster_texel_size and height_texels < min_caster_texel_size
end

function ShadowMap:GetCascadeWorldAABB(cascade_index)
	local cascade = self.cascade[cascade_index]

	if not cascade or not cascade.cull_aabb or not cascade.view_matrix then
		return nil
	end

	return build_world_aabb_from_local_aabb(cascade.cull_aabb, cascade.view_matrix:GetInverse())
end

function ShadowMap:ShouldDisableVertexAnimation(cascade_index)
	return self.disable_vertex_animation_cascades[cascade_index] == true
end

function ShadowMap:MarkCascadeRendered(cascade_index, shadow_volume_change_version, camera_position)
	local cascade = self.cascade[cascade_index]

	if not cascade then return end

	cascade.last_shadow_volume_change_version = shadow_volume_change_version or cascade.last_shadow_volume_change_version or 0
	cascade.last_camera_position = camera_position and camera_position:Copy() or nil
	cascade.last_rendered_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
end

function ShadowMap:UsesTessellatedMaterial(material)
	return use_tessellated_shadow(material)
end

-- Begin shadow pass for a specific cascade (or all cascades if cascade_index is nil)
function ShadowMap:Begin(cascade_index, is_first_in_batch)
	cascade_index = cascade_index or 1
	is_first_in_batch = is_first_in_batch == nil and cascade_index == 1 or is_first_in_batch
	self.current_cascade = cascade_index

	if self.mode == "point" then
		if is_first_in_batch then
			local queue = render.GetQueue()

			if queue:HasPendingSubmission(self.fence) then
				self.fence:Wait(true)
				queue:RetireFence(self.fence)
			end

			self.cmd:Reset()
			self.cmd:Begin()
			self.is_recording_cascades = true
		end

		local color_view = self.point_face_views[cascade_index]
		local old_layout = self.cascade[cascade_index].is_sampleable and
			"shader_read_only_optimal" or
			"undefined"
		self.cmd:PipelineBarrier{
			srcStage = "fragment_shader",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = self.point_depth_cubemap:GetImage(),
					srcAccessMask = "shader_read",
					dstAccessMask = "color_attachment_write",
					oldLayout = old_layout,
					newLayout = "color_attachment_optimal",
					base_array_layer = cascade_index - 1,
					layer_count = 1,
					base_mip_level = 0,
					level_count = 1,
				},
			},
		}

		if not self.point_depth_buffer_ready then
			self.cmd:PipelineBarrier{
				srcStage = "top_of_pipe",
				dstStage = "early_fragment_tests",
				imageBarriers = {
					{
						image = self.point_depth_buffer:GetImage(),
						srcAccessMask = "none",
						dstAccessMask = "depth_stencil_attachment_write",
						oldLayout = "undefined",
						newLayout = "depth_attachment_optimal",
					},
				},
			}
			self.point_depth_buffer_ready = true
		end

		self.cmd:BeginRendering{
			color_attachments = {
				{
					color_image_view = color_view,
					clear_color = {1, 0, 0, 0},
					load_op = "clear",
					store_op = "store",
				},
			},
			depth_image_view = self.point_depth_buffer:GetView(),
			clear_depth = 1.0,
			depth_store = false,
			depth_layout = "depth_attachment_optimal",
			w = self.size.w,
			h = self.size.h,
		}
		self.cmd:SetViewport(0.0, 0.0, self.size.w, self.size.h, 0.0, 1.0)
		self.cmd:SetScissor(0, 0, self.size.w, self.size.h)
		return self.cmd
	end

	local depth_texture = self.cascade[cascade_index].depth_texture

	if is_first_in_batch then
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

-- Upload shadow pass constants (light-space matrix; world transform is applied in shader)
-- material: optional Material object for alpha testing (will use albedo texture)
function ShadowMap:UploadConstants(world_matrix, material, cascade_index)
	cascade_index = cascade_index or self.current_cascade
	local push_constants = ShadowDrawPushConstants()
	local pipeline, uses_tessellation = get_pipeline_for_cascade(self, material, cascade_index)
	local texture_entry = nil

	-- If material is provided, get its albedo texture index and flags for alpha testing
	if material then
		texture_entry = get_cached_shadow_material_texture_indices(self, material, pipeline)

		if not texture_entry then
			texture_entry = cache_shadow_material_texture_indices(self, material, pipeline)
		end
	end

	local vertex_animation_material = self:ShouldDisableVertexAnimation(cascade_index) and
		render3d.GetDefaultMaterial() or
		(
			material or
			render3d.GetDefaultMaterial()
		)
	model_pipeline.FillVertexAnimationData(self.vertex_animation_buffer:GetData(), vertex_animation_material)
	world_matrix:CopyToFloatPointer(push_constants.world)
	local frame_index = render.GetCurrentFrame()
	local vertex_animation_offset = self.vertex_animation_buffer:Upload(frame_index)
	local shadow_state_offset = get_shadow_state_offset(self, frame_index, pipeline, material, cascade_index, texture_entry)
	pipeline:Bind(self.cmd, frame_index, {vertex_animation_offset, shadow_state_offset})

	do
		local depth_texture = self.mode == "point" and
			self.point_depth_buffer or
			self.cascade[cascade_index].depth_texture
		local w = depth_texture:GetWidth()
		local h = depth_texture:GetHeight()
		self.cmd:SetViewport(0.0, 0.0, w, h, 0.0, 1.0)
		self.cmd:SetScissor(0, 0, w, h)
	end

	self.cmd:SetFrontFace(orientation.FRONT_FACE)
	self.cmd:SetCullMode("none")

	if uses_tessellation then
		pipeline:PushConstants(self.cmd, {"tessellation_evaluation"}, 0, push_constants)
	else
		pipeline:PushConstants(self.cmd, {"vertex"}, 0, push_constants)
	end
end

function ShadowMap:PrimeMaterial(material)
	if not material then return end

	if self.mode == "point" then
		cache_shadow_material_texture_indices(self, material, self.pipeline)

		if self.tess_pipeline then
			cache_shadow_material_texture_indices(self, material, self.tess_pipeline)
		end

		return
	end

	for _, pipeline in pairs(self.pipeline_variants or {}) do
		cache_shadow_material_texture_indices(self, material, pipeline)
	end

	for _, pipeline in pairs(self.tess_pipeline_variants or {}) do
		if pipeline then
			cache_shadow_material_texture_indices(self, material, pipeline)
		end
	end
end

-- End shadow pass for current cascade
function ShadowMap:End(cascade_index, is_last_in_batch)
	cascade_index = cascade_index or self.current_cascade
	is_last_in_batch = is_last_in_batch == nil and
		cascade_index == self.cascade_count or
		is_last_in_batch

	if self.mode == "point" then
		self.cmd:EndRendering()
		self.cmd:PipelineBarrier{
			srcStage = "color_attachment_output",
			dstStage = "fragment_shader",
			imageBarriers = {
				{
					image = self.point_depth_cubemap:GetImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "shader_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "shader_read_only_optimal",
					base_array_layer = cascade_index - 1,
					layer_count = 1,
					base_mip_level = 0,
					level_count = 1,
				},
			},
		}
		self.cascade[cascade_index].is_sampleable = true

		if is_last_in_batch then
			self.cmd:End()
			self.is_recording_cascades = false
			render.Submit(self.cmd, self.fence)
		end

		return
	end

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
	self.cascade[cascade_index].is_sampleable = true

	if is_last_in_batch then
		self.cmd:End()
		self.is_recording_cascades = false
		-- Submit once after all cascades are recorded and let the next frame fence-gate reuse.
		render.Submit(self.cmd, self.fence)
	end
end

-- Get the depth texture for sampling in main pass
function ShadowMap:GetDepthTexture(cascade_index)
	if self.mode == "point" then return self.point_depth_cubemap end

	return self.cascade[cascade_index].depth_texture
end

-- Get all cascade depth textures
function ShadowMap:GetCascadeDepthTextures()
	if self.mode == "point" then return {self.point_depth_cubemap} end

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

function ShadowMap:GetMode()
	return self.mode
end

function ShadowMap:GetLightPosition()
	return self.point_light_position
end

function ShadowMap:GetFarPlane()
	return self.far_plane
end

function ShadowMap:GetCascadeTexelWorldSize(cascade_index)
	return self.cascade[cascade_index].texel_world_size or 0
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
