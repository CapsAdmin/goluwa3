local ffi = require("ffi")
local vk = import("goluwa/bindings/vk.lua")
local render = import("goluwa/render/render.lua")
local render3d = nil
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local Texture = import("goluwa/render/texture.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local Material = import("goluwa/render3d/material.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local system = import("goluwa/system.lua")
local objects = import("goluwa/objects/objects.lua")
local UniformBuffer = import("goluwa/render/uniform_buffer.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local render_stats = import("goluwa/render/stats.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local BatchTable = import("goluwa/render3d/batch_table.lua")
local InstanceBatcher = import("goluwa/render3d/instance_batcher.lua")
local ShadowMap = objects.CreateTemplate("render3d_shadow_map")
local DEFAULT_FORMAT = "d32_sfloat"
local DEFAULT_POINT_COLOR_FORMAT = "r32_sfloat"
local DEFAULT_CASCADE_COUNT = 3
local FRUSTUM_PLANE_COMPONENT_COUNT = 24
local TEMP_IDENTITY_CASCADE_OVERRIDE = false
local TEMP_REUSE_FIRST_CASCADE_OVERRIDE = false
local SUN_CASTER_REACH = 20000
local SHADOW_INSTANCE_STRIDE = ffi.sizeof("float[16]")
local SHADOW_INSTANCE_BINDINGS = {
	model_pipeline.GetVertexBufferBinding(0),
	{
		binding = 1,
		stride = SHADOW_INSTANCE_STRIDE,
		input_rate = "instance",
	},
}
local SHADOW_INSTANCE_VERTEX_ATTRIBUTES = table.copy(model_pipeline.GetVertexAttributeLayout(0))
SHADOW_INSTANCE_VERTEX_ATTRIBUTES[#SHADOW_INSTANCE_VERTEX_ATTRIBUTES + 1] = {
	binding = 1,
	location = 6,
	format = "r32g32b32a32_sfloat",
	offset = 0,
}
SHADOW_INSTANCE_VERTEX_ATTRIBUTES[#SHADOW_INSTANCE_VERTEX_ATTRIBUTES + 1] = {
	binding = 1,
	location = 7,
	format = "r32g32b32a32_sfloat",
	offset = 16,
}
SHADOW_INSTANCE_VERTEX_ATTRIBUTES[#SHADOW_INSTANCE_VERTEX_ATTRIBUTES + 1] = {
	binding = 1,
	location = 8,
	format = "r32g32b32a32_sfloat",
	offset = 32,
}
SHADOW_INSTANCE_VERTEX_ATTRIBUTES[#SHADOW_INSTANCE_VERTEX_ATTRIBUTES + 1] = {
	binding = 1,
	location = 9,
	format = "r32g32b32a32_sfloat",
	offset = 48,
}
local POINT_SHADOW_FACE_ANGLES = {
	Deg3(0, -90 + 180, 0),
	Deg3(0, 90 + 180, 0),
	Deg3(90, 0 + 180, 0),
	Deg3(-90, 0 + 180, 0),
	Deg3(0, 0 + 180, 0),
	Deg3(0, 180 + 180, 0),
}

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

	local entry = material_cache[pipeline]
	local albedo_texture = material:GetAlbedoTexture()
	local albedo_view = albedo_texture and albedo_texture:GetView() or nil

	if
		not entry or
		entry.albedo_texture ~= albedo_texture or
		entry.albedo_view ~= albedo_view
	then
		entry = entry or {}
		entry.albedo_texture = albedo_texture
		entry.albedo_view = albedo_view
		entry.albedo_texture_index = pipeline:GetTextureIndex(albedo_texture)
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
		int flags;
		float color_multiplier_a;
		float alpha_cutoff;
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
		int flags;
		float color_multiplier_a;
		float alpha_cutoff;
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
			set_index = 1,
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
			set_index = 1,
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

local function build_shadow_fragment_shader(bindless_texture_capacity, linear_depth_output)
	local prelude = (
		[[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					#extension GL_EXT_scalar_block_layout : require

					layout(set = 1, binding = 0) uniform sampler2D textures[%d];

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
	return prelude .. Material.BuildGlslFlags("shadow_state.flags") .. model_pipeline.BuildBindlessAlphaSamplingGlsl("shadow_state.albedo_texture_index", "shadow_state.color_multiplier_a") .. model_pipeline.BuildAlphaDiscardGlsl("shadow_state.alpha_cutoff", "alpha") .. (
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
	world_matrix_expr,
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
						mat4 world_matrix = %s;
						vec3 world_pos = (world_matrix * vec4(local_pos, 1.0)).xyz;
						mat3 world_matrix3 = mat3(world_matrix);
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
		vertex_color_expr,
		world_matrix_expr
	)
end

local function BuildShadowGeometryDeformationGlsl(world_matrix_expr)
	return model_pipeline.BuildVertexAnimationGlsl(world_matrix_expr) .. [[
			void apply_shadow_geometry_deformation(
				inout vec3 local_pos,
				inout vec3 world_pos,
				vec3 world_normal,
				vec3 world_tangent,
				vec2 uv,
				float texture_blend,
				vec4 vertex_color,
				mat3 inv_world_matrix3
			) {
				vec3 world_offset = get_vertex_animation_offset(world_pos, world_normal, vertex_color);

				if (dot(world_offset, world_offset) > 0.0) {
					local_pos += inv_world_matrix3 * world_offset;
					world_pos += world_offset;
				}
			}
		]]
end

local function build_shadow_vertex_stage(self, bindless_texture_capacity)
	return {
		type = "vertex",
		code = [[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					#extension GL_EXT_scalar_block_layout : require

					layout(set = 1, binding = 0) uniform sampler2D textures[];

					layout(location = 0) in vec3 in_position;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;
					layout(location = 3) in vec4 in_tangent;
					layout(location = 4) in float in_texture_blend;
					layout(location = 5) in vec4 in_vertex_color;

					]] .. SHADOW_PUSH_CONSTANT_GLSL .. [[
				]] .. SHADOW_STATE_UNIFORM_GLSL .. [[
				]] .. model_pipeline.BuildVertexAnimationUniformDeclaration(1) .. [[
					layout(location = 0) out vec2 out_uv;
					layout(location = 1) out vec3 out_world_pos;

				]] .. BuildShadowGeometryDeformationGlsl("pc.world") .. build_shadow_projected_main(
				"pc.world",
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

local function build_shadow_instanced_vertex_stage(self, bindless_texture_capacity)
	return {
		type = "vertex",
		code = [[
					#version 450
					#extension GL_EXT_nonuniform_qualifier : require
					#extension GL_EXT_scalar_block_layout : require

					layout(set = 1, binding = 0) uniform sampler2D textures[];

					layout(location = 0) in vec3 in_position;
					layout(location = 1) in vec3 in_normal;
					layout(location = 2) in vec2 in_uv;
					layout(location = 3) in vec4 in_tangent;
					layout(location = 4) in float in_texture_blend;
					layout(location = 5) in vec4 in_vertex_color;
					layout(location = 6) in vec4 in_instance_world_row_0;
					layout(location = 7) in vec4 in_instance_world_row_1;
					layout(location = 8) in vec4 in_instance_world_row_2;
					layout(location = 9) in vec4 in_instance_world_row_3;

				]] .. SHADOW_STATE_UNIFORM_GLSL .. [[
				]] .. model_pipeline.BuildVertexAnimationUniformDeclaration(1) .. [[
					layout(location = 0) out vec2 out_uv;
					layout(location = 1) out vec3 out_world_pos;

				]] .. BuildShadowGeometryDeformationGlsl(
				"mat4(in_instance_world_row_0, in_instance_world_row_1, in_instance_world_row_2, in_instance_world_row_3)"
			) .. build_shadow_projected_main(
				"mat4(in_instance_world_row_0, in_instance_world_row_1, in_instance_world_row_2, in_instance_world_row_3)",
				"in_position",
				"in_normal",
				"in_tangent.xyz",
				"in_uv",
				"in_texture_blend",
				"in_vertex_color"
			),
		bindings = SHADOW_INSTANCE_BINDINGS,
		attributes = SHADOW_INSTANCE_VERTEX_ATTRIBUTES,
		descriptor_sets = get_shadow_geometry_descriptor_sets(self, bindless_texture_capacity),
	}
end

local function build_shadow_fragment_stage(self, bindless_texture_capacity, linear_depth_output)
	return {
		type = "fragment",
		code = build_shadow_fragment_shader(bindless_texture_capacity, linear_depth_output),
		descriptor_sets = get_shadow_texture_descriptor_sets(self, bindless_texture_capacity),
	}
end

local function get_shadow_state_upload_cache(self)
	local cache = self.shadow_state_upload_cache
	local frame = system.GetFrameNumber()

	if not cache or cache.frame ~= frame then
		cache = {frame = frame, pipelines = {}}
		self.shadow_state_upload_cache = cache
	end

	return cache.pipelines
end

local function get_shadow_state_offset(self, frame_index, pipeline, material, cascade_index, texture_entry)
	local pipelines = get_shadow_state_upload_cache(self)
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
		data.flags = material:GetShadowFlags()
		data.color_multiplier_a = material:GetShadowOpacity()
		data.alpha_cutoff = material:GetAlphaCutoff()
	else
		data.albedo_texture_index = 0
		data.flags = 0
		data.color_multiplier_a = 1.0
		data.alpha_cutoff = 0.5
	end

	local offset = self.shadow_state_buffer:Upload(frame_index)
	material_cache[cascade_index] = offset
	return offset
end

local function get_vertex_animation_offset(self, vertex_animation_material, frame_index)
	if vertex_animation_material:HasVertexAnimation() then
		model_pipeline.FillVertexAnimationData(self.vertex_animation_buffer:GetData(), vertex_animation_material)
		return self.vertex_animation_buffer:Upload(frame_index)
	end

	local cache = self.vertex_animation_upload_cache
	local frame_number = system.GetFrameNumber()

	if not cache or cache.frame ~= frame_number then
		cache = {frame = frame_number}
		self.vertex_animation_upload_cache = cache
	end

	local offset = cache[vertex_animation_material]

	if not offset then
		model_pipeline.FillVertexAnimationData(self.vertex_animation_buffer:GetData(), vertex_animation_material)
		offset = self.vertex_animation_buffer:Upload(frame_index)
		cache[vertex_animation_material] = offset
	end

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
		DepthBiasClamp = 0,
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
	return pipeline
end

local function create_shadow_instanced_pipeline_variant(
	self,
	depth_format,
	max_shadow_width,
	max_shadow_height,
	bindless_texture_capacity,
	linear_depth_output,
	color_format
)
	return render.CreateGraphicsPipeline(
		build_shadow_pipeline_config(
			depth_format,
			max_shadow_width,
			max_shadow_height,
			{
				build_shadow_instanced_vertex_stage(self, bindless_texture_capacity),
				build_shadow_fragment_stage(self, bindless_texture_capacity, linear_depth_output),
			},
			"triangle_list",
			nil,
			color_format
		)
	)
end

local ShadowBatchRecord = ffi.typeof(
	[[struct {
		uint32_t addresses[4];
		uint32_t index_is_32;
		int32_t albedo_texture_index;
		int32_t flags;
		float color_multiplier_a;
		float alpha_cutoff;
		$ anim;
	}]],
	ffi.typeof(model_pipeline.GetVertexAnimationUniformBufferDecl())
)
local ShadowMultiDrawPushConstants = ffi.typeof([[
	struct {
		float light_space_matrix[16];
		float light_position[3];
		float light_far_plane;
		int32_t disable_vertex_animation;
		float time;
		float prev_time;
		int32_t pad;
		uint64_t batches;
		uint64_t instances;
	}
]])
local SHADOW_MULTI_DRAW_COMMON_GLSL
local SHADOW_VERTEX_FLOAT_COUNT = model_pipeline.GetVertexStride() / ffi.sizeof("float")

do
	local fields = {}

	for _, field in ipairs(model_pipeline.GetVertexAnimationBlock()) do
		fields[#fields + 1] = "\t\t" .. field[2] .. " " .. field[1] .. ";"
	end

	SHADOW_MULTI_DRAW_COMMON_GLSL = [[
	#version 460
	#extension GL_EXT_nonuniform_qualifier : require
	#extension GL_EXT_scalar_block_layout : require
	#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
	#extension GL_EXT_buffer_reference : require

	struct VertexAnimation_t {
]] .. table.concat(fields, "\n") .. [[

	};

	struct ShadowBatch {
		uvec4 addresses;
		uint index_is_32;
		int albedo_texture_index;
		int flags;
		float color_multiplier_a;
		float alpha_cutoff;
		VertexAnimation_t anim;
	};

	layout(buffer_reference, scalar) readonly buffer ShadowBatchData {
		ShadowBatch b[];
	};

	layout(push_constant, scalar) uniform Constants {
		mat4 light_space_matrix;
		vec3 light_position;
		float light_far_plane;
		int disable_vertex_animation;
		float time;
		float prev_time;
		int pad;
		uint64_t batches;
		uint64_t instances;
	} pc;

	#define SHADOW_BATCH ShadowBatchData(pc.batches).b
]]
end

local function build_shadow_multi_draw_vertex_stage(linear_depth_output)
	return {
		type = "vertex",
		code = SHADOW_MULTI_DRAW_COMMON_GLSL .. [[
			layout(buffer_reference, scalar) readonly buffer ShadowInstanceData {
				mat4 worlds[];
			};

			layout(buffer_reference, scalar) readonly buffer ShadowVertexData {
				float v[];
			};

			layout(buffer_reference, scalar) readonly buffer ShadowIndexData {
				uint i[];
			};

			layout(location = 0) out vec2 out_uv;
			layout(location = 1) flat out uint out_batch;
			]] .. (
				linear_depth_output and
				"layout(location = 2) out vec3 out_world_pos;" or
				""
			) .. [[

			mat4 shadow_world;
			VertexAnimation_t vertex_animation;

			]] .. model_pipeline.BuildVertexAnimationGlsl("shadow_world") .. [[

			#define SHADOW_VERTEX_FLOATS ]] .. SHADOW_VERTEX_FLOAT_COUNT .. [[u

			void main() {
				uint batch_index = uint(gl_DrawID);
				uvec4 addresses = SHADOW_BATCH[batch_index].addresses;

				if (addresses.x == 0u && addresses.y == 0u) {
					gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
					return;
				}

				uint index = uint(gl_VertexIndex);
				uint64_t index_address = packUint2x32(addresses.zw);

				if (index_address != 0ul) {
					ShadowIndexData indices = ShadowIndexData(index_address);

					if (SHADOW_BATCH[batch_index].index_is_32 != 0u) {
						index = indices.i[index];
					} else {
						uint word = indices.i[index >> 1];
						index = (index & 1u) != 0u ? word >> 16 : word & 0xFFFFu;
					}
				}

				ShadowVertexData data = ShadowVertexData(packUint2x32(addresses.xy));
				uint base = index * SHADOW_VERTEX_FLOATS;
				vec3 local_pos = vec3(data.v[base], data.v[base + 1u], data.v[base + 2u]);
				vec2 uv = vec2(data.v[base + 6u], data.v[base + 7u]);
				shadow_world = ShadowInstanceData(pc.instances).worlds[gl_InstanceIndex];
				vec3 world_pos = (shadow_world * vec4(local_pos, 1.0)).xyz;

				if (
					pc.disable_vertex_animation == 0 &&
					(
						SHADOW_BATCH[batch_index].anim.MainBending > 0.0 ||
						(SHADOW_BATCH[batch_index].anim.DetailBending != 0 && SHADOW_BATCH[batch_index].anim.BendSpeed > 0.0)
					)
				) {
					vertex_animation = SHADOW_BATCH[batch_index].anim;
					vertex_animation.Time = pc.time;
					vertex_animation.PrevTime = pc.prev_time;
					vec3 local_normal = normalize(vec3(data.v[base + 3u], data.v[base + 4u], data.v[base + 5u]));
					vec4 vertex_color = vec4(data.v[base + 13u], data.v[base + 14u], data.v[base + 15u], data.v[base + 16u]);
					mat3 world_matrix3 = mat3(shadow_world);
					vec3 world_normal = normalize(transpose(inverse(world_matrix3)) * local_normal);
					world_pos += get_vertex_animation_offset(world_pos, world_normal, vertex_color);
				}

				gl_Position = pc.light_space_matrix * vec4(world_pos, 1.0);
				out_uv = uv;
				out_batch = batch_index;
				]] .. (
				linear_depth_output and
				"out_world_pos = world_pos;" or
				""
			) .. [[
			}
		]],
		push_constants = {size = ffi.sizeof(ShadowMultiDrawPushConstants), offset = 0},
	}
end

local function build_shadow_multi_draw_fragment_stage(bindless_texture_capacity, linear_depth_output)
	return {
		type = "fragment",
		code = SHADOW_MULTI_DRAW_COMMON_GLSL .. [[
			layout(set = 1, binding = 0) uniform sampler2D textures[]] .. bindless_texture_capacity .. [[];
			layout(location = 0) in vec2 in_uv;
			layout(location = 1) flat in uint in_batch;
			]] .. (
				linear_depth_output and
				"layout(location = 2) in vec3 in_world_pos;\nlayout(location = 0) out float out_distance;" or
				""
			) .. "\n" .. Material.BuildGlslFlags("SHADOW_BATCH[in_batch].flags") .. model_pipeline.BuildBindlessAlphaSamplingGlsl(
				"SHADOW_BATCH[in_batch].albedo_texture_index",
				"SHADOW_BATCH[in_batch].color_multiplier_a"
			) .. model_pipeline.BuildAlphaDiscardGlsl("SHADOW_BATCH[in_batch].alpha_cutoff", "alpha") .. (
				linear_depth_output and
				[[
					void main() {
						float alpha = get_alpha();
						compute_translucency_and_discard(alpha);
						float light_distance = length(in_world_pos - pc.light_position);
						out_distance = clamp(light_distance / max(pc.light_far_plane, 0.0001), 0.0, 1.0);
					}
				]] or
				[[
					void main() {
						float alpha = get_alpha();
						compute_translucency_and_discard(alpha);
					}
				]]
			),
		descriptor_sets = {
			{
				type = "combined_image_sampler",
				binding_index = 0,
				count = bindless_texture_capacity,
				set_index = 1,
			},
		},
		push_constants = {size = ffi.sizeof(ShadowMultiDrawPushConstants), offset = 0},
	}
end

local function create_shadow_multi_draw_pipeline_variant(
	depth_format,
	max_shadow_width,
	max_shadow_height,
	bindless_texture_capacity,
	linear_depth_output,
	color_format
)
	return render.CreateGraphicsPipeline(
		build_shadow_pipeline_config(
			depth_format,
			max_shadow_width,
			max_shadow_height,
			{
				build_shadow_multi_draw_vertex_stage(linear_depth_output),
				build_shadow_multi_draw_fragment_stage(bindless_texture_capacity, linear_depth_output),
			},
			"triangle_list",
			nil,
			color_format
		)
	)
end

local function get_pipeline_for_cascade(self, cascade_index)
	if self.mode == "point" then return self.pipeline end

	local cascade = self.cascade[cascade_index]
	local depth_format = cascade and cascade.format or self.format
	return self.pipeline_variants[depth_format]
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
	cascade.world_cull_aabb = build_world_aabb_from_local_aabb(cull_aabb, view:GetInverse())
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

local function update_local_directional_perspective(self, light_position, light_rotation, range, fov)
	local near = math.max(self.near_plane, 0.001)
	local view = Matrix44()
	view:Translate(-light_position.x, -light_position.y, -light_position.z)
	view:Multiply(light_rotation:GetConjugated():GetMatrix())
	local projection = Matrix44()
	projection:Perspective(fov, near, range, 1)
	local half_span = math.tan(fov * 0.5) * range
	local texel_world_size = (math.tan(fov * 0.5) * range) / math.max(self.size.w, self.size.h)
	local cascade = self.cascade[1]
	set_directional_cascade_state(
		self,
		cascade,
		light_position,
		view,
		view * projection,
		texel_world_size,
		AABB(-half_span, -half_span, -range, half_span, half_span, -near),
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

local SOUP_TRIANGLE_BINDING = 2
local SOUP_OPACITY_BINDING = 3
local SOUP_UV_BINDING = 4
local SOUP_VERTEX_BODY = [[
		uint vid = uint(gl_VertexIndex);
		uint tri = vid / 3u;
		uint which = vid - tri * 3u;
		scene_bvh_triangle t = bvh_tri(tri);
		vec3 p = vec3(0.0);

		if (material_opacities[t.material] > 0.0) {
			p = t.v0;

			if (which == 1u) p += t.e1;
			else if (which == 2u) p += t.e2;
		}

		gl_Position = soup_light.light_space_matrix * vec4(p, 1.0);
]]
local soup_vertex_glsl = {}

local function get_soup_vertex_glsl(uvs)
	local code = soup_vertex_glsl[uvs]

	if code then return code end

	code = [[
		#version 450
		#extension GL_EXT_scalar_block_layout : require
		#extension GL_EXT_nonuniform_qualifier : require
	]] .. scene_bvh.GetTriangleDeclarationGLSL(SOUP_TRIANGLE_BINDING) .. [[
		layout(scalar, set = 0, binding = ]] .. SOUP_OPACITY_BINDING .. [[) readonly buffer SoupShadowOpacity {
			float material_opacities[];
		};
		layout(scalar, set = 0, binding = 0) uniform SoupLight_t {
			mat4 light_space_matrix;
		} soup_light;
	]]

	if uvs then
		code = code .. scene_bvh.GetUvDeclarationGLSL(SOUP_UV_BINDING) .. [[
		layout(location = 0) out vec2 out_uv;
		layout(location = 1) flat out uint out_material;

		void main() {
]] .. SOUP_VERTEX_BODY .. [[
			scene_bvh_uv tuv = bvh_uv(tri);
			out_uv = which == 0u ? tuv.uv0 : (which == 1u ? tuv.uv1 : tuv.uv2);
			out_material = t.material;
		}
	]]
	else
		code = code .. "void main() {\n" .. SOUP_VERTEX_BODY .. "}\n"
	end

	soup_vertex_glsl[uvs] = code
	return code
end

local SOUP_FRAGMENT_GLSL = [[
		#version 450

		void main() {}
	]]

local function get_soup_descriptor_sets(self, uvs)
	local sets = {
		{
			type = "uniform_buffer_dynamic",
			binding_index = 0,
			args = {self.soup_light_buffer.buffer, self.soup_light_buffer.aligned_size},
		},
		{
			type = "storage_buffer",
			binding_index = SOUP_TRIANGLE_BINDING,
			count = scene_bvh.SOUP_CHUNKS,
		},
		{type = "storage_buffer", binding_index = SOUP_OPACITY_BINDING},
	}

	if uvs then
		sets[4] = {
			type = "storage_buffer",
			binding_index = SOUP_UV_BINDING,
			count = scene_bvh.SOUP_CHUNKS,
		}
	end

	return sets
end

local function create_soup_pipeline_variant(self, depth_format, max_shadow_width, max_shadow_height)
	return render.CreateGraphicsPipeline(
		build_shadow_pipeline_config(
			depth_format,
			max_shadow_width,
			max_shadow_height,
			{
				{
					type = "vertex",
					code = get_soup_vertex_glsl(false),
					descriptor_sets = get_soup_descriptor_sets(self, false),
				},
				{type = "fragment", code = SOUP_FRAGMENT_GLSL},
			},
			"triangle_list",
			nil,
			nil
		)
	)
end

local SOUP_UV_FRAGMENT_GLSL = [[
		#version 450
		#extension GL_EXT_nonuniform_qualifier : require
		#extension GL_EXT_scalar_block_layout : require

		layout(set = 1, binding = 0) uniform sampler2D textures[%d];

		struct SoupShadowMaterial {
			float alpha;
			int albedo_texture;
			float cutoff;
			uint mode;
		};

		layout(scalar, set = 0, binding = 1) readonly buffer SoupShadowMaterials {
			SoupShadowMaterial materials[];
		};

		layout(location = 0) in vec2 in_uv;
		layout(location = 1) flat in uint in_material;

		void main() {
			SoupShadowMaterial material = materials[in_material];
			float alpha = material.alpha;

			if (material.albedo_texture != -1) {
				alpha *= textureLod(textures[nonuniformEXT(material.albedo_texture)], in_uv, 0.0).a;
			}

			if (material.mode == 1u) {
				if (alpha < material.cutoff) discard;
			} else if (material.mode == 2u) {
				if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > alpha) discard;
			}
		}
	]]
local SoupShadowMaterial = ffi.typeof([[struct {
	float alpha;
	int32_t albedo_texture;
	float cutoff;
	uint32_t mode;
}]])
local SoupShadowMaterialPtr = ffi.typeof("$ *", SoupShadowMaterial)
local SOUP_MATERIAL_BYTES = ffi.sizeof(SoupShadowMaterial)

local function create_soup_material_table(capacity)
	local buffer = render.CreateBuffer{
		byte_size = capacity * SOUP_MATERIAL_BYTES,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "shadow_map.soup_materials",
	}
	return {
		buffer = buffer,
		ptr = ffi.cast(SoupShadowMaterialPtr, buffer:Map()),
		capacity = capacity,
		filled = 0,
		full_generation = -1,
		stamp = 0,
	}
end

local function create_soup_uv_pipeline_variant(
	self,
	depth_format,
	max_shadow_width,
	max_shadow_height,
	bindless_texture_capacity,
	table_state
)
	return render.CreateGraphicsPipeline(
		build_shadow_pipeline_config(
			depth_format,
			max_shadow_width,
			max_shadow_height,
			{
				{
					type = "vertex",
					code = get_soup_vertex_glsl(true),
					descriptor_sets = get_soup_descriptor_sets(self, true),
				},
				{
					type = "fragment",
					code = SOUP_UV_FRAGMENT_GLSL:format(bindless_texture_capacity),
					descriptor_sets = {
						{
							type = "combined_image_sampler",
							binding_index = 0,
							count = bindless_texture_capacity,
							set_index = 1,
						},
						{
							type = "storage_buffer",
							binding_index = 1,
							set_index = 0,
							args = {table_state.buffer, table_state.buffer:GetSize()},
						},
					},
				},
			},
			"triangle_list",
			nil,
			nil
		)
	)
end

local function update_soup_material_table(pipeline, table_state)
	local materials = scene_bvh.materials
	local count = #materials
	local full = table_state.full_generation ~= Material.shadow_full_generation

	if count > table_state.capacity then
		local grown = create_soup_material_table(math.max(count, math.ceil(table_state.capacity * 1.5)))
		ffi.copy(grown.ptr, table_state.ptr, table_state.filled * SOUP_MATERIAL_BYTES)
		grown.filled = table_state.filled
		table_state.buffer:Remove()
		table_state.buffer = grown.buffer
		table_state.ptr = grown.ptr
		table_state.capacity = grown.capacity
	end

	local stamp = table_state.stamp
	local filled = table_state.filled

	for i = 0, count - 1 do
		local material = materials[i + 1]

		if full or i >= filled or (material.shadow_stamp or 0) > stamp then
			local entry = table_state.ptr[i]
			local texture = material:HasShadowTexture() and material:GetAlbedoTexture() or nil
			entry.alpha = material:GetShadowOpacity()
			entry.albedo_texture = texture and pipeline:GetTextureIndex(texture) or -1
			entry.cutoff = material:GetAlphaCutoff()
			entry.mode = material:GetAlphaTest() and
				1 or
				(
					bit.band(material:GetShadowFlags(), Material.FlagBits.Translucent) ~= 0 and
					2 or
					0
				)
		end
	end

	table_state.filled = count
	table_state.full_generation = Material.shadow_full_generation
	table_state.stamp = Material.shadow_stamp
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 1, 0, table_state.buffer, table_state.buffer:GetSize())
end

local MAX_SHADOW_PASSES_PER_FRAME = 4
local shadow_pass_budget_frame = -1
local shadow_passes_used = 0
local active_maps = {}

local function position_changed(a, b, epsilon)
	if not a or not b then return true end

	epsilon = epsilon or 0

	if epsilon <= 0 then return a.x ~= b.x or a.y ~= b.y or a.z ~= b.z end

	local dx = a.x - b.x
	local dy = a.y - b.y
	local dz = a.z - b.z
	return dx * dx + dy * dy + dz * dz > epsilon * epsilon
end

local function rotation_changed(a, b, epsilon)
	if not a or not b then return true end

	epsilon = epsilon or 0

	if epsilon <= 0 then
		return a.x ~= b.x or a.y ~= b.y or a.z ~= b.z or a.w ~= b.w
	end

	return 1 - math.abs(a:Dot(b)) > epsilon
end

local scene_bounds_cache = {version = nil, aabb = nil}

local function get_shadow_scene_world_aabb()
	local library = Visual.Library
	local version = library.shadow_change_version_counter or 0

	if scene_bounds_cache.version == version then return scene_bounds_cache.aabb end

	scene_bounds_cache.version = version
	scene_bounds_cache.aabb = library.GetShadowCasterWorldAABB()
	return scene_bounds_cache.aabb
end

local function get_shadow_volume_change_version(shadow_map, cascade_idx)
	local world_aabb = shadow_map:GetCascadeWorldAABB(cascade_idx)

	if not world_aabb then return nil end

	return Visual.Library.GetShadowVolumeChangeVersion(world_aabb)
end

local function build_shadow_cascade_update_mask(self)
	local policy = self.policy

	if self.mode == "point" then return nil end

	if policy.farthest_cascade_update_mode ~= "world_changed" then return nil end

	local farthest_cascade_idx = self:GetCascadeCount()

	if farthest_cascade_idx <= 1 then return nil end

	local mask = {}

	for i = 1, farthest_cascade_idx do
		mask[i] = true
	end

	local farthest_cascade = self.cascade[farthest_cascade_idx]

	if not farthest_cascade or not farthest_cascade.last_rendered_frame then
		return mask
	end

	local light_rotation = self.light and self.light.transform and self.light.transform:GetRotation() or nil

	if
		rotation_changed(light_rotation, self.last_rotation, policy.shadow_rotation_epsilon or 0)
	then
		return mask
	end

	local camera = render3d.GetCamera()
	local camera_position = camera:GetPosition()
	local camera_moved = position_changed(
		camera_position,
		farthest_cascade.last_camera_position,
		policy.farthest_cascade_camera_position_threshold or 0
	)
	local camera_forward = camera:GetRotation():GetForward()
	local camera_turned = not farthest_cascade.last_camera_forward or
		camera_forward:Dot(farthest_cascade.last_camera_forward) < math.cos(math.rad(policy.farthest_cascade_camera_rotation_threshold or 5))
	local shadow_volume_change_version = get_shadow_volume_change_version(self, farthest_cascade_idx)
	local world_changed = shadow_volume_change_version == nil or
		shadow_volume_change_version > (
			farthest_cascade.last_shadow_volume_change_version or
			0
		)

	if not camera_moved and not camera_turned and not world_changed then
		mask[farthest_cascade_idx] = false
	end

	return mask
end

local function render_shadow_map_pass(self, cascade_index, is_first_in_batch, is_last_in_batch)
	local shadow_cmd = self:Begin(cascade_index, is_first_in_batch)
	render.PushCommandBuffer(shadow_cmd)
	event.Call("DrawAllShadows", self, cascade_index)
	render.PopCommandBuffer()
	self:End(cascade_index, is_last_in_batch)
	local camera = render3d.GetCamera()
	self:MarkCascadeRendered(
		cascade_index,
		get_shadow_volume_change_version(self, cascade_index),
		camera and camera:GetPosition() or nil,
		camera and camera:GetRotation():GetForward() or nil
	)
end

local draw_shadow_single, draw_shadow_instanced

function ShadowMap.New(config)
	config = config or {}
	local self = ShadowMap:CreateObject()
	local bindless_texture_capacity = render.GetBindlessDescriptorCapacities().textures
	local features = render.GetPhysicalDevice():GetFeatures()

	if
		features.multiDrawIndirect ~= 1 or
		render.GetPhysicalDevice():GetVulkan11Features().shaderDrawParameters ~= 1
	then
		error("shadow maps need the multiDrawIndirect and shaderDrawParameters device features")
	end

	self.mode = config.mode or "directional"
	self.size = config.size:Copy()
	self.format = config.format or DEFAULT_FORMAT
	self.directional_projection_mode = config.directional_projection_mode or
		(
			self.mode == "directional" and
			"perspective" or
			"orthographic"
		)
	self.cascade_formats = config.cascade_formats
	self.near_plane = config.near_plane or 0.1
	self.far_plane = config.far_plane or 100.0
	self.ortho_size = config.ortho_size or 50.0
	self.point_color_format = DEFAULT_POINT_COLOR_FORMAT
	self.point_light_position = Vec3(0, 0, 0)
	self.cascade_count = config.cascade_count or
		(
			self.mode == "point" and
			6 or
			self.mode == "directional" and
			1 or
			DEFAULT_CASCADE_COUNT
		)

	if self.mode ~= "point" then
		assert(self.cascade_count <= 4, "shadow maps currently support up to 4 cascades")
	end

	self.cascade_split_lambda = config.cascade_split_lambda or 0.75
	self.max_shadow_distance = config.max_shadow_distance or 500.0
	self.scene_world_aabb = nil
	self.scene_bounds_margin = config.scene_bounds_margin or 16
	self.current_shadow_distance = self.max_shadow_distance
	self.min_caster_texel_size = config.min_caster_texel_size or 0
	self.disable_vertex_animation_cascades = config.disable_vertex_animation_cascades or {}
	self.cascade_zoom_factors = config.cascade_zoom_factors or {}
	self.cascade_splits = {}
	self.cascade = {}
	self.vertex_animation_buffer = UniformBuffer.New(model_pipeline.GetVertexAnimationUniformBufferDecl(), "shadow_map.vertex_animation")
	self.shadow_state_buffer = UniformBuffer.New(ShadowStateUniformDecl, "shadow_map.state")
	self.soup_state = {
		version = -1,
		shadow_generation = -1,
		albedo_generation = -1,
		vertex_count = 0,
	}
	self.light = config.light
	self.role = config.role or "cascades"
	self.policy = config.policy or {}
	self.directional_rotation_flip = config.directional_rotation_flip
	self.perspective_fov = config.perspective_fov
	self.enabled = true
	self.next_cascade = 1
	self.needs_completion = false
	self.last_update_frame = nil
	self.last_position = nil
	self.last_rotation = nil
	self.geometry_dirty = true
	active_maps[#active_maps + 1] = self
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
		self.pipeline = create_shadow_pipeline_variant(
			self,
			self.format,
			max_shadow_width,
			max_shadow_height,
			bindless_texture_capacity,
			true,
			self.point_color_format
		)
		self.instanced_pipeline = create_shadow_instanced_pipeline_variant(
			self,
			self.format,
			max_shadow_width,
			max_shadow_height,
			bindless_texture_capacity,
			true,
			self.point_color_format
		)
		self.multi_draw_pipeline = create_shadow_multi_draw_pipeline_variant(
			self.format,
			max_shadow_width,
			max_shadow_height,
			bindless_texture_capacity,
			true,
			self.point_color_format
		)
	else
		local unique_formats = {}

		for i = 1, self.cascade_count do
			local cascade_size = (cascade_sizes[i] or self.size):Copy()
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
					usage = {"depth_stencil_attachment", "sampled", "transfer_src"},
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
				},
			}
			unique_formats[cascade_format] = true
		end

		self.pipeline_variants = {}
		self.instanced_pipeline_variants = {}
		self.multi_draw_pipeline_variants = {}
		self.soup_cascade_from = config.soup_cascade_from or 2
		self.soup_light_buffer = UniformBuffer.New([[struct { float light_space_matrix[16]; }]], "shadow_map.soup_light")
		self.soup_pipeline_variants = {}
		self.soup_uv_pipeline_variants = {}
		self.soup_material_tables = {}

		for depth_format in pairs(unique_formats) do
			self.pipeline_variants[depth_format] = create_shadow_pipeline_variant(
				self,
				depth_format,
				max_shadow_width,
				max_shadow_height,
				bindless_texture_capacity,
				false,
				nil
			)
			self.instanced_pipeline_variants[depth_format] = create_shadow_instanced_pipeline_variant(
				self,
				depth_format,
				max_shadow_width,
				max_shadow_height,
				bindless_texture_capacity,
				false,
				nil
			)
			self.multi_draw_pipeline_variants[depth_format] = create_shadow_multi_draw_pipeline_variant(
				depth_format,
				max_shadow_width,
				max_shadow_height,
				bindless_texture_capacity,
				false,
				nil
			)
			self.soup_pipeline_variants[depth_format] = create_soup_pipeline_variant(self, depth_format, max_shadow_width, max_shadow_height)
			local table_state = create_soup_material_table(256)
			self.soup_material_tables[depth_format] = table_state
			self.soup_uv_pipeline_variants[depth_format] = create_soup_uv_pipeline_variant(
				self,
				depth_format,
				max_shadow_width,
				max_shadow_height,
				bindless_texture_capacity,
				table_state
			)
		end

		self.pipeline = self.pipeline_variants[self.format]
		self.instanced_pipeline = self.instanced_pipeline_variants[self.format]
		self.soup_pipeline = self.soup_pipeline_variants[self.format]
	end

	self.command_pool = render.GetCommandPool()
	self.cmd = self.command_pool:AllocateCommandBuffer()
	self.fence = Fence.New(render.GetDevice())
	self.is_recording_cascades = false
	self.batch_serial = 0
	self.shadow_batch_tables = {}
	self.instance_batcher = InstanceBatcher.New{
		label = "render3d shadow instances",
		draw_single = draw_shadow_single,
		draw_instanced = draw_shadow_instanced,
	}
	self.shadow_multi_draw_push_constants = ShadowMultiDrawPushConstants()
	self.current_cascade = 1
	return self
end

function ShadowMap:OnRemove()
	for _, batch_table in pairs(self.shadow_batch_tables) do
		batch_table:Remove()
	end

	self.instance_batcher:Remove()

	for _, table_state in pairs(self.soup_material_tables or {}) do
		table_state.buffer:Remove()
	end

	for i, map in ipairs(active_maps) do
		if map == self then
			table.remove(active_maps, i)

			break
		end
	end

	for _, cascade in ipairs(self.cascade or {}) do
		if cascade.gpu_cull_output then
			gpu_culling.RemoveShadowQueryOutput(cascade.gpu_cull_output)
			cascade.gpu_cull_output = nil
		end

		if cascade.gpu_draw_cull_output then
			gpu_culling.RemoveShadowQueryOutput(cascade.gpu_draw_cull_output)
			cascade.gpu_draw_cull_output = nil
			cascade.gpu_draw_cull_result = nil
		end
	end
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
		local cull_aabb = AABB(
			light_position.x - self.far_plane,
			light_position.y - self.far_plane,
			light_position.z - self.far_plane,
			light_position.x + self.far_plane,
			light_position.y + self.far_plane,
			light_position.z + self.far_plane
		)
		self.cascade[face].cull_aabb = cull_aabb
		self.cascade[face].world_cull_aabb = cull_aabb
		update_cascade_frustum_planes(self.cascade[face])
	end

	self.cascade_splits[1] = self.far_plane
end

function ShadowMap:UpdateLocalDirectionalLightMatrices(light_position, light_rotation, range, ortho_size)
	if self.directional_projection_mode == "orthographic" then
		update_local_directional_orthographic(self, light_position, light_rotation, range, ortho_size)
	else
		update_local_directional_perspective(
			self,
			light_position,
			light_rotation,
			range,
			self.perspective_fov or math.rad(90)
		)
	end
end

function ShadowMap:CalculateCascadeSplits()
	render3d = render3d or import("goluwa/render3d/render3d.lua")
	local cam = render3d.GetCamera()
	local view_near = cam:GetNearZ()
	local view_far = math.min(cam:GetFarZ(), self.max_shadow_distance)
	local scene_aabb = self.scene_world_aabb

	if scene_aabb then
		local pos = cam:GetPosition()
		local dx = scene_aabb.max_x - pos.x
		local d = scene_aabb.min_x - pos.x

		if math.abs(d) > math.abs(dx) then dx = d end

		local dy = scene_aabb.max_y - pos.y
		d = scene_aabb.min_y - pos.y

		if math.abs(d) > math.abs(dy) then dy = d end

		local dz = scene_aabb.max_z - pos.z
		d = scene_aabb.min_z - pos.z

		if math.abs(d) > math.abs(dz) then dz = d end

		view_far = math.min(view_far, math.sqrt(dx * dx + dy * dy + dz * dz) + self.scene_bounds_margin)
	end

	self.current_shadow_distance = view_far
	local lambda = self.cascade_split_lambda
	self.cascade_splits = {}
	local n = self.cascade_count

	for i = 1, n do
		local p = i / n
		local log_split = view_near * math.pow(view_far / view_near, p)
		local linear_split = view_near + (view_far - view_near) * p
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

function ShadowMap:UpdateCascadeLightMatrices(light_rotation, cascade_update_mask)
	if self.mode == "point" then return end

	render3d = render3d or import("goluwa/render3d/render3d.lua")
	local cam = render3d.GetCamera()
	self:CalculateCascadeSplits()

	if TEMP_IDENTITY_CASCADE_OVERRIDE then
		local identity_cull_aabb = AABB(-1000000, -1000000, -1000000, 1000000, 1000000, 1000000)
		local identity = Matrix44()

		for cascade_idx = 1, self.cascade_count do
			self.cascade[cascade_idx].position = Vec3(0, 0, 0)
			self.cascade[cascade_idx].view_matrix = identity
			self.cascade[cascade_idx].cull_aabb = identity_cull_aabb
			self.cascade[cascade_idx].world_cull_aabb = identity_cull_aabb
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
		local texel_world_size = self.cascade[cascade_idx].texel_world_size
		local far_margin = receiver_depth_span * 0.05 + texel_world_size * 4
		local near_margin = math.max(receiver_depth_span * 0.5, self.current_shadow_distance * 0.5)
		local cull_near_margin = self.mode == "sun" and
			SUN_CASTER_REACH or
			math.max(receiver_depth_span * 4.0, self.current_shadow_distance * 2)
		local caster_min_z = min_z - far_margin
		local caster_max_z = max_z + near_margin
		local projection = Matrix44()
		projection:Ortho(min_x, max_x, min_y, max_y, -caster_max_z, -caster_min_z, true)
		local cull_projection = Matrix44()
		cull_projection:Ortho(min_x, max_x, min_y, max_y, -(max_z + cull_near_margin), -caster_min_z, true)
		self.cascade[cascade_idx].position = shadow_center
		self.cascade[cascade_idx].view_matrix = view
		local cull_aabb = AABB(min_x, min_y, caster_min_z, max_x, max_y, max_z + cull_near_margin)
		self.cascade[cascade_idx].cull_aabb = cull_aabb
		self.cascade[cascade_idx].world_cull_aabb = build_world_aabb_from_local_aabb(cull_aabb, view:GetInverse())
		self.cascade[cascade_idx].projection_aabb = AABB(min_x, min_y, caster_min_z, max_x, max_y, caster_max_z)
		self.cascade[cascade_idx].light_space_matrix = view * projection
		extract_frustum_planes(view * cull_projection, self.cascade[cascade_idx].frustum_planes)
		previous_split = split_far

		::continue::
	end

	if TEMP_REUSE_FIRST_CASCADE_OVERRIDE and self.cascade_count > 1 then
		local first = self.cascade[1]

		for cascade_idx = 2, self.cascade_count do
			self.cascade[cascade_idx].position = first.position:Copy()
			self.cascade[cascade_idx].view_matrix = first.view_matrix:Copy()
			self.cascade[cascade_idx].cull_aabb = first.cull_aabb:Copy()
			self.cascade[cascade_idx].world_cull_aabb = first.world_cull_aabb and first.world_cull_aabb:Copy()
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
		return AABB.IsOverlappedSphereInside(world_aabb, self.point_light_position, self.far_plane) and
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

	if not cascade.world_cull_aabb then
		cascade.world_cull_aabb = build_world_aabb_from_local_aabb(cascade.cull_aabb, cascade.view_matrix:GetInverse())
	end

	return cascade.world_cull_aabb
end

function ShadowMap:ShouldDisableVertexAnimation(cascade_index)
	return self.disable_vertex_animation_cascades[cascade_index] == true
end

function ShadowMap:MarkCascadeRendered(cascade_index, shadow_volume_change_version, camera_position, camera_forward)
	local cascade = self.cascade[cascade_index]

	if not cascade then return end

	cascade.last_shadow_volume_change_version = shadow_volume_change_version or cascade.last_shadow_volume_change_version or 0
	cascade.last_camera_position = camera_position and camera_position:Copy() or nil
	cascade.last_camera_forward = camera_forward and camera_forward:Copy() or nil
	cascade.last_rendered_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
end

local function get_shadow_cull_output_requirements()
	local dataset_buffers = gpu_culling.GetDatasetBuffers and gpu_culling.GetDatasetBuffers() or nil
	local layout = dataset_buffers and dataset_buffers.layout or nil
	return math.max(layout and layout.shadow_entry_capacity or 0, 1),
	math.max(layout and layout.shadow_instanced_batch_capacity or 0, 1),
	math.max(layout and layout.shadow_instance_capacity or 0, 1)
end

local function ensure_shadow_cull_output(self, cascade_index, key)
	local cascade = self.cascade and self.cascade[cascade_index] or nil

	if not cascade then return nil end

	local shadow_entry_capacity, shadow_instanced_batch_count, shadow_instance_capacity = get_shadow_cull_output_requirements()
	local output = cascade[key]

	if
		output and
		output.shadow_entry_capacity == shadow_entry_capacity and
		output.shadow_instanced_batch_count == shadow_instanced_batch_count and
		output.shadow_instance_capacity == shadow_instance_capacity
	then
		return output
	end

	local descriptor_slot = output and output.descriptor_slot or nil

	if output then gpu_culling.RemoveShadowQueryOutput(output) end

	output = gpu_culling.CreateShadowQueryOutput(
		string.format("shadow_%s_%d", key, cascade_index),
		shadow_entry_capacity,
		shadow_instanced_batch_count,
		shadow_instance_capacity,
		descriptor_slot
	)
	cascade[key] = output
	return output
end

function ShadowMap:GetShadowCullOutput(cascade_index)
	return ensure_shadow_cull_output(self, cascade_index or self.current_cascade, "gpu_cull_output")
end

function ShadowMap:GetGPUCullOptions(cascade_index)
	if self.mode == "point" then return nil end

	local cascade = self.cascade[cascade_index]
	local min_caster_texel_size = self.min_caster_texel_size or 0
	local texel_world_size = cascade.texel_world_size or 0

	if min_caster_texel_size <= 0 or texel_world_size <= 0 or not cascade.view_matrix then
		return nil
	end

	local options = cascade.gpu_cull_options or {}
	options.light_view = cascade.view_matrix
	options.min_caster_extent = min_caster_texel_size * texel_world_size
	cascade.gpu_cull_options = options
	return options
end

local function record_shadow_draw_cull(self, cascade_index)
	local cascade = self.cascade[cascade_index]
	cascade.gpu_draw_cull_result = nil

	if self:UsesSoup(cascade_index) and scene_bvh.IsReady() then return end

	if not gpu_culling.IsEnabled() or not gpu_culling.GetSceneDataset() then
		return
	end

	local query_aabb = self:GetCascadeWorldAABB(cascade_index)

	if not query_aabb then return end

	cascade.gpu_draw_cull_result = gpu_culling.RecordShadowViewAABBCulling(
		self.cmd,
		query_aabb,
		ensure_shadow_cull_output(self, cascade_index, "gpu_draw_cull_output"),
		self:GetGPUCullOptions(cascade_index)
	)
end

function ShadowMap:GetGPUDrawCullResult(cascade_index)
	local cull_result = self.cascade[cascade_index].gpu_draw_cull_result

	if cull_result and gpu_culling.IsCullResultCurrent(cull_result) then
		return cull_result
	end

	return nil
end

function ShadowMap:GetTimingName(cascade_index)
	local names = self.timing_names

	if not names then
		names = {}
		self.timing_names = names
	end

	local name = names[cascade_index]

	if not name then
		name = self.mode == "point" and
			"shadow_point_" .. cascade_index or
			"shadow_" .. self.role .. "_" .. cascade_index
		names[cascade_index] = name
	end

	return name
end

function ShadowMap:Begin(cascade_index, is_first_in_batch)
	cascade_index = cascade_index or 1
	is_first_in_batch = is_first_in_batch == nil and cascade_index == 1 or is_first_in_batch
	self.current_cascade = cascade_index

	if self.mode == "point" then
		if is_first_in_batch then
			local queue = render.GetQueue()

			if queue:HasPendingSubmission(self.fence) then
				self.fence:Wait()
				queue:RetireFence(self.fence)
			end

			self.cmd:Reset()
			self.cmd:Begin()
			gpu_timing.BeginCommandBuffer(self.cmd)
			self.is_recording_cascades = true
			self.batch_serial = self.batch_serial + 1
		end

		gpu_timing.BeginScope(self.cmd, self:GetTimingName(cascade_index))
		record_shadow_draw_cull(self, cascade_index)
		local color_view = self.point_face_views[cascade_index]
		render.TransitionResourceTo(
			self.point_depth_cubemap,
			"color_attachment_optimal",
			{
				cmd = self.cmd,
				srcStage = "fragment_shader",
				srcAccess = "shader_read",
				dstStage = "color_attachment_output",
				dstAccess = "color_attachment_write",
				base_array_layer = cascade_index - 1,
				layer_count = 1,
				base_mip_level = 0,
				level_count = 1,
			}
		)
		render.TransitionResourceTo(
			self.point_depth_buffer,
			"depth_attachment_optimal",
			{
				cmd = self.cmd,
				srcStage = "top_of_pipe",
				srcAccess = "none",
				dstStage = "early_fragment_tests",
				dstAccess = "depth_stencil_attachment_write",
			}
		)
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
			self.fence:Wait()
			queue:RetireFence(self.fence)
		end

		self.cmd:Reset()
		self.cmd:Begin()
		gpu_timing.BeginCommandBuffer(self.cmd)
		self.is_recording_cascades = true
		self.batch_serial = self.batch_serial + 1
		local state = self.soup_state

		if
			self.mode ~= "point" and
			self.soup_cascade_from <= self.cascade_count and
			(
				state.version ~= scene_bvh.soup_version or
				state.shadow_generation ~= Material.shadow_generation or
				state.albedo_generation ~= Material.albedo_generation
			)
		then
			local materials_changed = state.shadow_generation ~= Material.shadow_generation or
				state.albedo_generation ~= Material.albedo_generation
			state.version = scene_bvh.soup_version
			state.shadow_generation = Material.shadow_generation
			state.albedo_generation = Material.albedo_generation

			for format, table_state in pairs(self.soup_material_tables) do
				update_soup_material_table(self.soup_uv_pipeline_variants[format], table_state)
			end

			local opacities = scene_bvh.UpdateShadowMaterials()
			state.vertex_count = scene_bvh.IsReady() and scene_bvh.soup_triangle_count * 3 or 0

			if state.vertex_count > 0 then
				if materials_changed then scene_bvh.RefreshShadowClasses() end

				if
					state.triangle_buffer ~= scene_bvh.triangle_buffer or
					state.uv_buffer ~= scene_bvh.uv_buffer or
					state.opacity_buffer ~= opacities
				then
					state.triangle_buffer = scene_bvh.triangle_buffer
					state.uv_buffer = scene_bvh.uv_buffer
					state.opacity_buffer = opacities

					for _, pipeline in pairs(self.soup_pipeline_variants) do
						scene_bvh.BindTriangleBuffer(pipeline, 1, SOUP_TRIANGLE_BINDING, scene_bvh.triangle_buffer)
						pipeline:UpdateDescriptorSet("storage_buffer", 1, SOUP_OPACITY_BINDING, 0, opacities, opacities:GetSize())
					end

					for _, pipeline in pairs(self.soup_uv_pipeline_variants) do
						scene_bvh.BindTriangleBuffer(pipeline, 1, SOUP_TRIANGLE_BINDING, scene_bvh.triangle_buffer)
						pipeline:UpdateDescriptorSet("storage_buffer", 1, SOUP_OPACITY_BINDING, 0, opacities, opacities:GetSize())
						scene_bvh.BindTriangleBuffer(pipeline, 1, SOUP_UV_BINDING, scene_bvh.uv_buffer, scene_bvh.UV_CHUNK_BYTES)
					end
				end
			end
		end
	end

	gpu_timing.BeginScope(self.cmd, self:GetTimingName(cascade_index))
	record_shadow_draw_cull(self, cascade_index)
	render.TransitionResourceTo(
		depth_texture,
		"depth_attachment_optimal",
		{
			cmd = self.cmd,
			srcStage = "fragment",
			srcAccess = "shader_read",
			dstStage = "early_fragment_tests",
			dstAccess = "depth_stencil_attachment_write",
		}
	)
	local w = depth_texture:GetWidth()
	local h = depth_texture:GetHeight()
	self.cmd:BeginRendering{
		depth_image_view = depth_texture:GetView(),
		depth_store = true,
		depth_layout = "depth_attachment_optimal",
		w = w,
		h = h,
		clear_depth = 1.0,
	}
	self.cmd:SetViewport(0.0, 0.0, w, h, 0.0, 1.0)
	self.cmd:SetScissor(0, 0, w, h)
	return self.cmd
end

function ShadowMap:BeginAllCascades()
	local cmds = {}

	for i = 1, self.cascade_count do
		cmds[i] = self:Begin(i)
	end

	return cmds
end

function ShadowMap:UploadConstants(world_matrix, material, cascade_index)
	cascade_index = cascade_index or self.current_cascade
	local push_constants = ShadowDrawPushConstants()
	local pipeline = get_pipeline_for_cascade(self, cascade_index)
	local texture_entry = nil

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
	world_matrix:CopyToFloatPointer(push_constants.world)
	local frame_index = render.GetCurrentFrame()
	local vertex_animation_offset = get_vertex_animation_offset(self, vertex_animation_material, frame_index)
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
	pipeline:PushConstants(self.cmd, {"vertex"}, 0, push_constants)
end

local function get_instanced_pipeline_for_cascade(self, cascade_index)
	if self.mode == "point" then return self.instanced_pipeline end

	local cascade = self.cascade[cascade_index]
	local depth_format = cascade and cascade.format or self.format
	return self.instanced_pipeline_variants and
		self.instanced_pipeline_variants[depth_format] or
		self.instanced_pipeline
end

local function shadow_material_has_vertex_animation(material)
	return material and material:HasVertexAnimation()
end

local function get_shadow_draw_submission_context(self, track_component_stats)
	local context = self.shadow_draw_submission_context

	if not context then
		context = {
			submission_stats = {
				submitted_entry_count = 0,
				missing_world_matrix_count = 0,
			},
			submitted_by_component = setmetatable({}, {__mode = "k"}),
			missing_world_matrix_components = setmetatable({}, {__mode = "k"}),
		}
		self.shadow_draw_submission_context = context
	end

	context.submission_stats.submitted_entry_count = 0
	context.submission_stats.missing_world_matrix_count = 0

	if track_component_stats then
		table.clear(context.submitted_by_component)
		table.clear(context.missing_world_matrix_components)
	end

	return context.submission_stats,
	track_component_stats and context.submitted_by_component or nil,
	track_component_stats and context.missing_world_matrix_components or nil
end

local function get_shadow_draw_result(self)
	local result = self.shadow_draw_result

	if not result then
		result = {}
		self.shadow_draw_result = result
	end

	return result
end

local function bind_instanced_shadow_constants(self, material, cascade_index)
	local pipeline = get_instanced_pipeline_for_cascade(self, cascade_index)
	local texture_entry = nil

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
	local frame_index = render.GetCurrentFrame()
	local vertex_animation_offset = get_vertex_animation_offset(self, vertex_animation_material, frame_index)
	local shadow_state_offset = get_shadow_state_offset(self, frame_index, pipeline, material, cascade_index, texture_entry)
	pipeline:Bind(self.cmd, frame_index, {vertex_animation_offset, shadow_state_offset})
	local depth_texture = self.mode == "point" and
		self.point_depth_buffer or
		self.cascade[cascade_index].depth_texture
	local w = depth_texture:GetWidth()
	local h = depth_texture:GetHeight()
	self.cmd:SetViewport(0.0, 0.0, w, h, 0.0, 1.0)
	self.cmd:SetScissor(0, 0, w, h)
	self.cmd:SetFrontFace(orientation.FRONT_FACE)
	self.cmd:SetCullMode("none")
	return pipeline
end

local function collect_shadow_visible_entry(
	self,
	component,
	entry,
	cascade_index,
	submission_stats,
	submitted_by_component,
	missing_world_matrix_components
)
	local transform = entry and entry.transform or nil
	local world_matrix = transform and transform:GetWorldMatrix() or component:GetWorldMatrix()

	if not world_matrix then
		submission_stats.missing_world_matrix_count = submission_stats.missing_world_matrix_count + 1

		if missing_world_matrix_components then
			missing_world_matrix_components[component] = true
		end

		return
	end

	local material = component:GetResolvedMaterial(entry)
	local uses_vertex_animation = not self:ShouldDisableVertexAnimation(cascade_index) and
		shadow_material_has_vertex_animation(material)

	if not uses_vertex_animation then
		self.instance_batcher:Queue(entry.polygon3d, entry.polygon3d:GetMesh(), material, world_matrix)
	else
		render3d.SetWorldMatrix(world_matrix)
		render3d.SetCurrentPolygon3D(entry.polygon3d)
		self:UploadConstants(world_matrix, material, cascade_index)
		entry.polygon3d:Draw()
	end

	submission_stats.submitted_entry_count = submission_stats.submitted_entry_count + 1

	if submitted_by_component then
		submitted_by_component[component] = (submitted_by_component[component] or 0) + 1
	end
end

function draw_shadow_single(self, batch)
	local world_matrix = batch.world_matrices[1]
	render3d.SetWorldMatrix(world_matrix)
	render3d.SetCurrentPolygon3D(batch.polygon3d)
	self:UploadConstants(world_matrix, batch.material, self.flush_cascade_index)
	batch.polygon3d:Draw()
end

function draw_shadow_instanced(self, batch, instance_buffers, first_instance)
	render3d.SetWorldMatrix(batch.world_matrices[1])
	render3d.SetCurrentPolygon3D(batch.polygon3d)
	bind_instanced_shadow_constants(self, batch.material, self.flush_cascade_index)
	batch.mesh:DrawInstanced(self.cmd, batch.count, instance_buffers, nil, 0, 0, first_instance)
end

local function flush_shadow_instance_batches(self, cascade_index)
	self.flush_cascade_index = cascade_index
	return self.instance_batcher:Flush(self, self.batch_serial)
end

local function write_shadow_batch_record(self, pipeline, record, batch)
	local material = batch.material
	record.albedo_texture_index = cache_shadow_material_texture_indices(self, material, pipeline).albedo_texture_index
	record.flags = material:GetShadowFlags()
	record.color_multiplier_a = material:GetShadowOpacity()
	record.alpha_cutoff = material:GetAlphaCutoff()
	render3d.SetCurrentPolygon3D(batch.first_polygon3d)
	model_pipeline.FillVertexAnimationData(record.anim, material)
end

function ShadowMap:DrawGPUCulled(cull_result, cascade_index, track_component_stats)
	local submission_stats, submitted_by_component, missing_world_matrix_components = get_shadow_draw_submission_context(self, track_component_stats)
	local dataset = gpu_culling.GetSceneDataset()
	local output = cull_result.shadow_output
	local batches = dataset.shadow_instanced_batches
	local indirect_draws = 0

	if batches[1] then
		local pipeline = self.mode == "point" and
			self.multi_draw_pipeline or
			self.multi_draw_pipeline_variants[self.cascade[cascade_index].format]
		local batch_table = self.shadow_batch_tables[pipeline]

		if not batch_table then
			batch_table = BatchTable.New{
				label = "render3d_shadow_batches",
				record_type = ShadowBatchRecord,
				write_record = write_shadow_batch_record,
			}
			self.shadow_batch_tables[pipeline] = batch_table
		end

		local depth_texture = self.mode == "point" and
			self.point_depth_buffer or
			self.cascade[cascade_index].depth_texture
		local push_constants = self.shadow_multi_draw_push_constants
		self.cascade[cascade_index].light_space_matrix:CopyToFloatPointer(push_constants.light_space_matrix)
		push_constants.light_position[0] = self.point_light_position.x
		push_constants.light_position[1] = self.point_light_position.y
		push_constants.light_position[2] = self.point_light_position.z
		push_constants.light_far_plane = self.far_plane
		push_constants.disable_vertex_animation = self:ShouldDisableVertexAnimation(cascade_index) and 1 or 0
		push_constants.time = system.GetElapsedTime()
		push_constants.prev_time = render3d.GetPreviousElapsedTime()
		push_constants.batches = batch_table:Update(pipeline, batches, dataset.shadow.batch_serial, self.batch_serial, self)
		push_constants.instances = output.shadow_visible_instance_vertex_buffer.buffer:GetDeviceAddress()
		pipeline:Bind(self.cmd, render.GetCurrentFrame())
		self.cmd:SetViewport(0.0, 0.0, depth_texture:GetWidth(), depth_texture:GetHeight(), 0.0, 1.0)
		self.cmd:SetScissor(0, 0, depth_texture:GetWidth(), depth_texture:GetHeight())
		self.cmd:SetFrontFace(orientation.FRONT_FACE)
		self.cmd:SetCullMode("none")
		pipeline:PushConstants(self.cmd, {"vertex", "fragment"}, 0, push_constants)
		self.cmd:DrawIndirect(
			output.shadow_visible_batch_indirect_command_buffer,
			0,
			#batches,
			gpu_culling.BATCH_DRAW_COMMAND_SIZE
		)
		indirect_draws = 1
	end

	for _, entry in ipairs(dataset.shadow_fallback_entries) do
		local component = entry.component
		local world_aabb = not entry.skip_shadow_aabb_cull and component:GetWorldAABB() or nil

		if
			component:IsWithinCullDistance() and
			(
				not world_aabb or
				(
					self:IsWorldAABBVisible(cascade_index, world_aabb) and
					not self:IsWorldAABBTooSmall(cascade_index, world_aabb)
				)
			)
		then
			collect_shadow_visible_entry(
				self,
				component,
				entry.source_entry,
				cascade_index,
				submission_stats,
				submitted_by_component,
				missing_world_matrix_components
			)
		end
	end

	local instanced_draws, fallback_draws = flush_shadow_instance_batches(self, cascade_index)
	local result = get_shadow_draw_result(self)
	result.submitted_entry_count = submission_stats.submitted_entry_count
	result.missing_world_matrix_count = submission_stats.missing_world_matrix_count
	result.submitted_by_component = submitted_by_component
	result.missing_world_matrix_components = missing_world_matrix_components
	result.gpu_instanced_entry_count = 0
	result.gpu_instanced_draw_calls = indirect_draws
	result.gpu_active_batch_count = #batches
	result.gpu_total_batch_count = #batches
	result.instanced_draws = instanced_draws
	result.fallback_draws = fallback_draws
	return result
end

function ShadowMap:DrawVisibleComponents(visible_components, cascade_index, track_component_stats)
	cascade_index = cascade_index or self.current_cascade
	local submission_stats, submitted_by_component, missing_world_matrix_components = get_shadow_draw_submission_context(self, track_component_stats)

	for _, component in ipairs(visible_components or {}) do
		for _, entry in ipairs(component:GetRenderEntries() or {}) do
			collect_shadow_visible_entry(
				self,
				component,
				entry,
				cascade_index,
				submission_stats,
				submitted_by_component,
				missing_world_matrix_components
			)
		end
	end

	local instanced_draws, fallback_draws = flush_shadow_instance_batches(self, cascade_index)
	local result = get_shadow_draw_result(self)
	result.submitted_entry_count = submission_stats.submitted_entry_count
	result.missing_world_matrix_count = submission_stats.missing_world_matrix_count
	result.submitted_by_component = submitted_by_component
	result.missing_world_matrix_components = missing_world_matrix_components
	result.gpu_instanced_entry_count = 0
	result.gpu_instanced_draw_calls = 0
	result.gpu_active_batch_count = 0
	result.gpu_total_batch_count = 0
	result.instanced_draws = instanced_draws
	result.fallback_draws = fallback_draws
	return result
end

function ShadowMap:UsesSoup(cascade_index)
	return self.mode ~= "point" and cascade_index >= self.soup_cascade_from
end

do
	local dither_runs = {}

	function ShadowMap:DrawSoup(cascade_index)
		cascade_index = cascade_index or self.current_cascade
		local cascade = self.cascade[cascade_index]

		if not cascade then return end

		local frame_index = render.GetCurrentFrame()
		local data = self.soup_light_buffer:GetData()
		data.light_space_matrix = cascade.light_space_matrix:GetFloatCopy()
		local offset = self.soup_light_buffer:Upload(frame_index)
		local depth_texture = cascade.depth_texture
		local w = depth_texture:GetWidth()
		local h = depth_texture:GetHeight()
		self.cmd:SetViewport(0.0, 0.0, w, h, 0.0, 1.0)
		self.cmd:SetScissor(0, 0, w, h)
		self.cmd:SetCullMode("none")
		local planes = cascade.frustum_planes
		local ranges = scene_bvh.raster_ranges

		if not (ranges and planes) then return end

		local pipeline = self.soup_pipeline_variants[cascade.format] or self.soup_pipeline
		pipeline:Bind(self.cmd, frame_index, {offset})
		local first, stop = 0, 0
		local dither_count = 0
		local dither_first, dither_stop = 0, 0
		local limit = self.soup_state.vertex_count
		scene_bvh.MarkVisibleBlocks(planes)
		local visible = scene_bvh.raster_visible
		local dithered = scene_bvh.raster_dithered

		for i = 0, #scene_bvh.blocks - 1 do
			if visible[i] ~= 0 then
				visible[i] = 0

				if ranges[i * 2 + 1] <= limit then
					local block_first = ranges[i * 2]

					if dithered[i] ~= 0 then
						if block_first ~= dither_stop then
							if dither_stop > dither_first then
								dither_runs[dither_count + 1] = dither_first
								dither_runs[dither_count + 2] = dither_stop
								dither_count = dither_count + 2
							end

							dither_first = block_first
						end

						dither_stop = ranges[i * 2 + 1]
					else
						if block_first ~= stop then
							if stop > first then self.cmd:Draw(stop - first, 1, first, 0) end

							first = block_first
						end

						stop = ranges[i * 2 + 1]
					end
				end
			end
		end

		if stop > first then self.cmd:Draw(stop - first, 1, first, 0) end

		if dither_stop > dither_first then
			dither_runs[dither_count + 1] = dither_first
			dither_runs[dither_count + 2] = dither_stop
			dither_count = dither_count + 2
		end

		if dither_count == 0 then return end

		self.soup_uv_pipeline_variants[cascade.format]:Bind(self.cmd, frame_index, {offset})

		for i = 1, dither_count, 2 do
			self.cmd:Draw(dither_runs[i + 1] - dither_runs[i], 1, dither_runs[i], 0)
		end
	end
end

function ShadowMap:PrimeMaterial(material)
	if not material then return end

	if self.mode == "point" then
		cache_shadow_material_texture_indices(self, material, self.pipeline)
		cache_shadow_material_texture_indices(self, material, self.instanced_pipeline)
		return
	end

	for _, pipeline in pairs(self.pipeline_variants or {}) do
		cache_shadow_material_texture_indices(self, material, pipeline)
	end

	for _, pipeline in pairs(self.instanced_pipeline_variants or {}) do
		if pipeline then
			cache_shadow_material_texture_indices(self, material, pipeline)
		end
	end
end

function ShadowMap:End(cascade_index, is_last_in_batch)
	cascade_index = cascade_index or self.current_cascade
	is_last_in_batch = is_last_in_batch == nil and
		cascade_index == self.cascade_count or
		is_last_in_batch

	if self.mode == "point" then
		self.cmd:EndRendering()
		render.TransitionResourceFrom(
			self.point_depth_cubemap,
			"shader_read_only_optimal",
			{
				cmd = self.cmd,
				srcStage = "color_attachment_output",
				srcAccess = "color_attachment_write",
				dstStage = "fragment_shader",
				dstAccess = "shader_read",
				base_array_layer = cascade_index - 1,
				layer_count = 1,
				base_mip_level = 0,
				level_count = 1,
			}
		)
		self.cascade[cascade_index].is_sampleable = true
		gpu_timing.EndScope(self.cmd, self:GetTimingName(cascade_index))

		if is_last_in_batch then self:CloseBatch() end

		return
	end

	local depth_texture = self.cascade[cascade_index].depth_texture
	self.cmd:EndRendering()
	render.TransitionResourceFrom(
		depth_texture,
		"shader_read_only_optimal",
		{
			cmd = self.cmd,
			srcStage = "late_fragment_tests",
			srcAccess = "depth_stencil_attachment_write",
			dstStage = "fragment",
			dstAccess = "shader_read",
		}
	)
	self.cascade[cascade_index].is_sampleable = true
	gpu_timing.EndScope(self.cmd, self:GetTimingName(cascade_index))

	if is_last_in_batch then self:CloseBatch() end
end

function ShadowMap:GetDepthTexture(cascade_index)
	if self.mode == "point" then return self.point_depth_cubemap end

	return self.cascade[cascade_index].depth_texture
end

function ShadowMap:GetCascadeDepthTextures()
	if self.mode == "point" then return {self.point_depth_cubemap} end

	local textures = {}

	for i = 1, self.cascade_count do
		textures[i] = self.cascade[i].depth_texture
	end

	return textures
end

function ShadowMap:IsCascadeSampleable(cascade_index)
	return self.cascade[cascade_index].is_sampleable
end

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

function ShadowMap:GetCascadeSplits()
	return self.cascade_splits
end

function ShadowMap:SetLightSource(entity)
	self.light = entity
	self.last_position = nil
	self.last_rotation = nil
end

function ShadowMap:SetUpdatePolicy(policy)
	self.policy = policy or {}
end

function ShadowMap:SetRole(role)
	self.role = role
end

pvars.StartGroup("feature", {store = false})
local shadows = pvars.Setup2{
	key = "r_feature_shadows",
	default = true,
	friendly = "shadows",
	help = "every shadow map, off nothing is rendered or sampled and everything is lit unshadowed",
}
pvars.EndGroup()

function ShadowMap:IsEnabled()
	return self.enabled and (self.role == "shelter" or shadows:Get())
end

function ShadowMap:SetEnabled(enabled)
	self.enabled = enabled
end

function ShadowMap.GetActiveMaps()
	return active_maps
end

local function geometry_changed_for(self, transform)
	local library = Visual.Library

	if not library.aabb_scan_changed then return false end

	if library.AABB_CHANGED_ALL or self.mode ~= "point" or not transform then
		return true
	end

	local pos = transform:GetPosition()
	local radius_sq = self.far_plane * self.far_plane
	local boxes = library.AABB_CHANGED_BOXES

	for i = 1, #boxes do
		local box = boxes[i]
		local dx = math.max(box[1] - pos.x, 0, pos.x - box[4])
		local dy = math.max(box[2] - pos.y, 0, pos.y - box[5])
		local dz = math.max(box[3] - pos.z, 0, pos.z - box[6])

		if dx * dx + dy * dy + dz * dz <= radius_sq then return true end
	end

	return false
end

function ShadowMap:PrepareFrameUpdate()
	if not self:IsEnabled() then return nil end

	local policy = self.policy
	local transform = self.light and self.light.transform
	local mode = policy.shadow_update_mode

	if mode == nil then
		mode = self.mode == "sun" and "continuous" or "on_move"
	end

	local restart = false

	if mode == "on_move" then
		if geometry_changed_for(self, transform) then self.geometry_dirty = true end

		restart = self.geometry_dirty

		if transform then
			restart = restart or
				position_changed(
					transform:GetPosition(),
					self.last_position,
					policy.shadow_position_epsilon or 0
				) or
				rotation_changed(
					transform:GetRotation(),
					self.last_rotation,
					policy.shadow_rotation_epsilon or 0
				)
		end

		if not (restart or self.needs_completion) then return nil end
	else
		local interval = policy.shadow_update_interval

		if
			interval and
			interval > 1 and
			self.last_update_frame and
			system.GetFrameNumber() - self.last_update_frame < interval and
			not self.needs_completion
		then
			return nil
		end

		restart = true
	end

	if self.mode == "point" and transform then
		local position = transform:GetPosition()

		if not render3d.SphereInFrustum(position.x, position.y, position.z, self.far_plane) then
			return nil
		end
	end

	if restart and not self.needs_completion then
		self.next_cascade = 1
		self.geometry_dirty = false
	end

	self.scene_world_aabb = get_shadow_scene_world_aabb()
	local update_mask = self.role == "cascades" and build_shadow_cascade_update_mask(self) or nil
	self:UpdateMatrices(update_mask)
	event.Call("PrimeAllShadowMaterials", self)
	local start_index = self.next_cascade
	local cascade_count = self:GetCascadeCount()

	if start_index > cascade_count then start_index = 1 end

	local eligible_indices = {}

	for cascade_idx = start_index, cascade_count do
		if not update_mask or update_mask[cascade_idx] ~= false then
			eligible_indices[#eligible_indices + 1] = cascade_idx
		end
	end

	if #eligible_indices == 0 then
		self.next_cascade = 1
		return nil
	end

	return eligible_indices
end

function ShadowMap:FinishFrameUpdate(complete, rendered, rendered_cascades)
	if rendered then
		self.last_update_frame = system.GetFrameNumber()
		self.needs_completion = not complete

		if complete then
			self.next_cascade = 1

			if self.light and self.light.transform then
				self.last_position = self.light.transform:GetPosition():Copy()
				self.last_rotation = self.light.transform:GetRotation():Copy()
			end
		else
			self.next_cascade = self.next_cascade + (rendered_cascades or 0)
		end
	end
end

function ShadowMap:CloseBatch()
	if not self.is_recording_cascades then return end

	if self.mode == "point" then
		render.TransitionResourceFrom(
			self.point_depth_buffer,
			"general",
			{
				cmd = self.cmd,
				srcStage = "late_fragment_tests",
				srcAccess = "depth_stencil_attachment_write",
				dstStage = "compute",
				dstAccess = "shader_write",
			}
		)
	end

	self.cmd:End()
	self.is_recording_cascades = false
	render.Submit(self.cmd, self.fence)
end

local function update_all_shadow_maps(dt)
	shadow_pass_budget_frame = system.GetFrameNumber()
	shadow_passes_used = 0
	local pending = {}
	Visual.Library.ScanWorldAABBs()

	for _, map in ipairs(active_maps) do
		local eligible = map:PrepareFrameUpdate()

		if eligible then
			pending[#pending + 1] = {
				map = map,
				eligible = eligible,
				next = 1,
			}
		end
	end

	if #pending > 0 then
		local remaining = MAX_SHADOW_PASSES_PER_FRAME
		local any_rendered = false

		while remaining > 0 do
			local progressed = false

			for i = 1, #pending do
				local p = pending[i]

				if remaining > 0 and p.next <= #p.eligible then
					local complete = p.next == #p.eligible
					render_shadow_map_pass(
						p.map,
						p.eligible[p.next],
						p.next == 1,
						complete or remaining == 1
					)
					p.next = p.next + 1
					remaining = remaining - 1
					any_rendered = true
					progressed = true
				end
			end

			if not progressed then break end
		end

		for i = 1, #pending do
			local p = pending[i]

			if p.next > 1 and p.next <= #p.eligible then p.map:CloseBatch() end

			p.map:FinishFrameUpdate(p.next > #p.eligible, any_rendered, p.next - 1)
		end

		shadow_passes_used = MAX_SHADOW_PASSES_PER_FRAME - remaining
	end
end

function ShadowMap:UpdateMatrices(update_mask)
	local transform = self.light and self.light.transform
	local position = transform and transform:GetPosition()
	local rotation = transform and transform:GetRotation()

	if self.mode == "point" then
		self:UpdatePointLightMatrices(position)
	elseif self.mode == "directional" then
		local light_rotation = self.directional_rotation_flip and
			rotation * Quat():SetAngles(Deg3(0, 180, 0))
			or
			rotation
		self:UpdateLocalDirectionalLightMatrices(position, light_rotation, self.far_plane, self.ortho_size)
	else
		self:UpdateCascadeLightMatrices(rotation, update_mask)
	end
end

function ShadowMap:GetCascadeCount()
	return self.cascade_count
end

function ShadowMap:GetSize()
	return self.size
end

local function append_shadow_map_draws(shadow_map)
	local draw_stats = Visual.GetShadowDrawCallStats and
		Visual.GetShadowDrawCallStats(shadow_map) or
		nil

	if not draw_stats then return 0 end

	local total = 0

	for cascade_idx = 1, shadow_map:GetCascadeCount() do
		total = total + (draw_stats[cascade_idx] or 0)
	end

	return total
end

local function count_pending_shadow_passes(shadow_map)
	local next_cascade = shadow_map.next_cascade
	local cascade_count = shadow_map:GetCascadeCount()

	if next_cascade > cascade_count then return 0 end

	return math.max(cascade_count - next_cascade + 1, 0)
end

local shadow_overlay_summary = {
	frame = -1,
	shadow_lights = 0,
	shadow_maps = 0,
	shadow_draws = 0,
	pending_passes = 0,
	active_passes = 0,
	budget_used = 0,
	budget_max = MAX_SHADOW_PASSES_PER_FRAME,
}

local function get_shadow_overlay_summary()
	local frame = system.GetFrameNumber and system.GetFrameNumber() or 0

	if shadow_overlay_summary.frame == frame then return shadow_overlay_summary end

	shadow_overlay_summary.frame = frame
	shadow_overlay_summary.shadow_lights = 0
	shadow_overlay_summary.shadow_maps = 0
	shadow_overlay_summary.shadow_draws = 0
	shadow_overlay_summary.pending_passes = 0
	shadow_overlay_summary.active_passes = 0
	shadow_overlay_summary.budget_used = shadow_pass_budget_frame == frame and shadow_passes_used or 0
	shadow_overlay_summary.budget_max = MAX_SHADOW_PASSES_PER_FRAME
	local seen_sources = {}

	for _, shadow_map in ipairs(active_maps) do
		if not shadow_map:IsEnabled() then goto continue end

		if shadow_map.light and not seen_sources[shadow_map.light] then
			seen_sources[shadow_map.light] = true
			shadow_overlay_summary.shadow_lights = shadow_overlay_summary.shadow_lights + 1
		end

		shadow_overlay_summary.shadow_maps = shadow_overlay_summary.shadow_maps + 1
		shadow_overlay_summary.shadow_draws = shadow_overlay_summary.shadow_draws + append_shadow_map_draws(shadow_map)

		if shadow_map.needs_completion then
			shadow_overlay_summary.pending_passes = shadow_overlay_summary.pending_passes + count_pending_shadow_passes(shadow_map)
		end

		for cascade_idx = 1, shadow_map:GetCascadeCount() do
			local cascade = shadow_map.cascade and shadow_map.cascade[cascade_idx]

			if cascade and cascade.last_rendered_frame == frame then
				shadow_overlay_summary.active_passes = shadow_overlay_summary.active_passes + 1
			end
		end

		::continue::
	end

	return shadow_overlay_summary
end

function ShadowMap:OnFirstCreated()
	render_stats.RegisterGroup{
		id = "render3d_shadows",
		label = "RENDER3D SHADOWS",
	}
	render_stats.RegisterField{
		id = "r3d_shadow_lights",
		label = "R3D SHADOW LIGHTS",
		group = "render3d_shadows",
		getter = function()
			return get_shadow_overlay_summary().shadow_lights
		end,
	}
	render_stats.RegisterField{
		id = "r3d_shadow_maps",
		label = "R3D SHADOW MAPS",
		group = "render3d_shadows",
		getter = function()
			return get_shadow_overlay_summary().shadow_maps
		end,
	}
	render_stats.RegisterField{
		id = "r3d_shadow_draws",
		label = "R3D SHADOW DRAWS",
		group = "render3d_shadows",
		getter = function()
			return get_shadow_overlay_summary().shadow_draws
		end,
	}
	render_stats.RegisterField{
		id = "r3d_shadow_passes",
		label = "R3D SHADOW PASSES",
		group = "render3d_shadows",
		getter = function()
			local summary = get_shadow_overlay_summary()
			return tostring(summary.active_passes) .. "/" .. tostring(summary.budget_used)
		end,
	}
	render_stats.RegisterField{
		id = "r3d_shadow_pending",
		label = "R3D SHADOW PENDING",
		group = "render3d_shadows",
		getter = function()
			local summary = get_shadow_overlay_summary()
			return tostring(summary.pending_passes) .. "/" .. tostring(summary.budget_max)
		end,
	}
end

event.AddListener("PreFrame", "shadow_maps", update_all_shadow_maps)
return ShadowMap:Register()
