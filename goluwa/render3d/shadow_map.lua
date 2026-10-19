local ffi = require("ffi")
local vk = import("goluwa/bindings/vk.lua")
local render = import("goluwa/render/render.lua")
local render3d = nil
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
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local render_stats = import("goluwa/render/stats.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local BatchTable = import("goluwa/render3d/batch_table.lua")
local scene_draw = import("goluwa/render3d/scene/draw.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local ShadowMap = objects.CreateTemplate("render3d_shadow_map")
local DEFAULT_FORMAT = "d32_sfloat"
local DEFAULT_POINT_COLOR_FORMAT = "r32_sfloat"
local DEFAULT_CASCADE_COUNT = 3
local FRUSTUM_PLANE_COMPONENT_COUNT = 24
local TEMP_IDENTITY_CASCADE_OVERRIDE = false
local TEMP_REUSE_FIRST_CASCADE_OVERRIDE = false
local SUN_CASTER_REACH = 20000
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
	local normal_texture = material:GetNormalTexture()
	local normal_view = normal_texture and normal_texture:GetView() or nil

	if
		not entry or
		entry.albedo_texture ~= albedo_texture or
		entry.albedo_view ~= albedo_view or
		entry.normal_texture ~= normal_texture or
		entry.normal_view ~= normal_view
	then
		entry = entry or {}
		entry.albedo_texture = albedo_texture
		entry.albedo_view = albedo_view
		entry.albedo_texture_index = pipeline:GetTextureIndex(albedo_texture)
		entry.normal_texture = normal_texture
		entry.normal_view = normal_view
		entry.normal_texture_index = pipeline:GetTextureIndex(normal_texture)
		material_cache[pipeline] = entry
	end

	return entry
end

-- what the alpha test reads besides the albedo: the normal texture's alpha for coverage, and the transforms of the uvs
local function write_shadow_uv_data(data, material, normal_texture_index)
	data.normal_texture_index = normal_texture_index

	if material then
		local base_u, base_v = material:GetBaseTextureTransformU(), material:GetBaseTextureTransformV()
		local bump_u, bump_v = material:GetBumpTransformU(), material:GetBumpTransformV()
		data.base_transform_u[0], data.base_transform_u[1], data.base_transform_u[2] = base_u.x, base_u.y, base_u.z
		data.base_transform_v[0], data.base_transform_v[1], data.base_transform_v[2] = base_v.x, base_v.y, base_v.z
		data.bump_transform_u[0], data.bump_transform_u[1], data.bump_transform_u[2] = bump_u.x, bump_u.y, bump_u.z
		data.bump_transform_v[0], data.bump_transform_v[1], data.bump_transform_v[2] = bump_v.x, bump_v.y, bump_v.z
	else
		data.base_transform_u[0], data.base_transform_u[1], data.base_transform_u[2] = 1, 0, 0
		data.base_transform_v[0], data.base_transform_v[1], data.base_transform_v[2] = 0, 1, 0
		data.bump_transform_u[0], data.bump_transform_u[1], data.bump_transform_u[2] = 1, 0, 0
		data.bump_transform_v[0], data.bump_transform_v[1], data.bump_transform_v[2] = 0, 1, 0
	end
end

local function sample_shadow_texture(texture, uv)
	return "textureLod(textures[nonuniformEXT(" .. texture .. ")], " .. uv .. ", 0.0)"
end

-- block is the GLSL expression of the struct with the material's texture indices and transforms
local function build_shadow_alpha_glsl(block)
	return (
		[[
			vec2 base_uv(vec2 uv) {
				return vec2(dot(%s.base_transform_u.xy, uv) + %s.base_transform_u.z, dot(%s.base_transform_v.xy, uv) + %s.base_transform_v.z);
			}

			vec2 bump_uv(vec2 uv) {
				return vec2(dot(%s.bump_transform_u.xy, uv) + %s.bump_transform_u.z, dot(%s.bump_transform_v.xy, uv) + %s.bump_transform_v.z);
			}
		]]
	):format(block, block, block, block, block, block, block, block) .. model_pipeline.BuildAlphaSamplingGlsl{
		albedo_texture = block .. ".albedo_texture_index",
		normal_texture = block .. ".normal_texture_index",
		color_alpha = block .. ".color_multiplier_a",
		sample = sample_shadow_texture,
		albedo_rgb = sample_shadow_texture(block .. ".albedo_texture_index", "base_uv(uv)") .. ".rgb",
	}
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

local ShadowBatchRecord = ffi.typeof(
	[[struct {
		uint32_t addresses[4];
		uint32_t index_is_32;
		int32_t albedo_texture_index;
		int32_t flags;
		float color_multiplier_a;
		float alpha_cutoff;
		int32_t normal_texture_index;
		float base_transform_u[4];
		float base_transform_v[4];
		float bump_transform_u[4];
		float bump_transform_v[4];
		$ anim;
	}]],
	ffi.typeof(model_pipeline.GetVertexAnimationUniformBufferDecl())
)
local ShadowMultiDrawPushConstants = ffi.typeof([[
	struct {
		float light_space_matrix[16];
		float light_position[3];
		float light_far_plane;
		float wind_camera[3];
		float wind_pixel_scale;
		float time;
		float prev_time;
		float detail_time;
		uint64_t batches;
		uint64_t instances;
		int32_t indexed;
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
		int normal_texture_index;
		vec4 base_transform_u;
		vec4 base_transform_v;
		vec4 bump_transform_u;
		vec4 bump_transform_v;
		VertexAnimation_t anim;
	};

	layout(buffer_reference, scalar) readonly buffer ShadowBatchData {
		ShadowBatch b[];
	};

	layout(push_constant, scalar) uniform Constants {
		mat4 light_space_matrix;
		vec3 light_position;
		float light_far_plane;
		vec3 wind_camera;
		float wind_pixel_scale;
		float time;
		float prev_time;
		float detail_time;
		uint64_t batches;
		uint64_t instances;
		int indexed;
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

			]] .. model_pipeline.BuildVertexAnimationGlsl("shadow_world", "pc.wind_camera", "pc.wind_pixel_scale") .. [[

			#define SHADOW_VERTEX_FLOATS ]] .. SHADOW_VERTEX_FLOAT_COUNT .. [[u

			void main() {
				uint batch_index = uint(gl_DrawID);
				uvec4 addresses = SHADOW_BATCH[batch_index].addresses;

				if (addresses.x == 0u && addresses.y == 0u) {
					gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
					return;
				}

				// the store's rows are drawn indexed through the index pool, so the vertex cache works and gl_VertexIndex is the
				// vertex. other lists (scatter's) are drawn by vertex count and fetch their indices here
				uint index = uint(gl_VertexIndex);
				uint64_t index_address = packUint2x32(addresses.zw);

				if (pc.indexed == 0 && index_address != 0ul) {
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
					(floatBitsToUint(shadow_world[3][3]) & 0x80000000u) != 0u ||
					SHADOW_BATCH[batch_index].anim.MainBending > 0.0 ||
					(SHADOW_BATCH[batch_index].anim.DetailBending != 0 && SHADOW_BATCH[batch_index].anim.BendSpeed > 0.0)
				) {
					vertex_animation = SHADOW_BATCH[batch_index].anim;
					vertex_animation.Time = pc.time;
					vertex_animation.PrevTime = pc.prev_time;
					vertex_animation.DetailTime = pc.detail_time;
					vertex_animation.PrevDetailTime = pc.detail_time;
					vec3 local_normal = vec3(data.v[base + 3u], data.v[base + 4u], data.v[base + 5u]);
					vec4 vertex_color = vec4(data.v[base + 13u], data.v[base + 14u], data.v[base + 15u], data.v[base + 16u]);
					vec3 world_normal = normalize(transpose(inverse(mat3(shadow_world))) * local_normal);
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
			) .. "\n" .. Material.BuildGlslFlags("SHADOW_BATCH[in_batch].flags") .. build_shadow_alpha_glsl("SHADOW_BATCH[in_batch]") .. model_pipeline.BuildAlphaDiscardGlsl("SHADOW_BATCH[in_batch].alpha_cutoff", "alpha") .. (
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

local function update_cascade_frustum_planes(cascade)
	if not cascade or not cascade.light_space_matrix or not cascade.frustum_planes then
		return
	end

	extract_frustum_planes(cascade.light_space_matrix, cascade.frustum_planes)
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

-- the cascades and cube faces of a shadow map draw the rows of the scene store: a pass writes a draw per slot (scene/draw.lua)
-- and the multi draw pipeline pulls the vertices of the batch of the slot
-- records the pass that writes the draws of a cascade, outside of its render pass
function ShadowMap:CullScene(cascade_index)
	local cascade = self.cascade[cascade_index]
	cascade.scene_shadow_buffers = cascade.scene_shadow_buffers or scene_draw.NewShadowBuffers()
	local options = self:GetGPUCullOptions(cascade_index)
	cascade.scene_shadow_count = scene_draw.CullShadow(
		self.cmd,
		cascade.scene_shadow_buffers,
		cascade.frustum_planes,
		render3d.GetCamera():GetPosition(),
		options and options.min_caster_extent,
		options and options.light_view
	)
end

-- draws what CullScene wrote, in the render pass of the cascade
function ShadowMap:DrawScene(cascade_index)
	local cascade = self.cascade[cascade_index]

	if not cascade.scene_shadow_count then return end

	local rows, serial = scene_draw.GetRows()
	local buffers = cascade.scene_shadow_buffers
	self:DrawBatches(cascade_index, "scene", rows, serial, buffers.worlds_address, buffers.commands, 20, true)
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
	self.cascade_zoom_factors = config.cascade_zoom_factors or {}
	self.cascade_splits = {}
	self.cascade = {}
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

		self.multi_draw_pipeline_variants = {}

		for depth_format in pairs(unique_formats) do
			self.multi_draw_pipeline_variants[depth_format] = create_shadow_multi_draw_pipeline_variant(
				depth_format,
				max_shadow_width,
				max_shadow_height,
				bindless_texture_capacity,
				false,
				nil
			)
		end
	end

	self.command_pool = render.GetCommandPool()
	self.cmd = self.command_pool:AllocateCommandBuffer()
	self.fence = Fence.New(render.GetDevice())
	self.is_recording_cascades = false
	self.batch_serial = 0
	self.shadow_batch_tables = {}
	self.shadow_multi_draw_push_constants = ShadowMultiDrawPushConstants()
	self.current_cascade = 1
	return self
end

function ShadowMap:OnRemove()
	for _, batch_table in pairs(self.shadow_batch_tables) do
		batch_table:Remove()
	end

	for _, cascade in ipairs(self.cascade or {}) do
		if cascade.scene_shadow_buffers then
			scene_draw.RemoveShadowBuffers(cascade.scene_shadow_buffers)
		end
	end

	for i, map in ipairs(active_maps) do
		if map == self then
			table.remove(active_maps, i)

			break
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

function ShadowMap:MarkCascadeRendered(cascade_index, shadow_volume_change_version, camera_position, camera_forward)
	local cascade = self.cascade[cascade_index]

	if not cascade then return end

	cascade.last_shadow_volume_change_version = shadow_volume_change_version or cascade.last_shadow_volume_change_version or 0
	cascade.last_camera_position = camera_position and camera_position:Copy() or nil
	cascade.last_camera_forward = camera_forward and camera_forward:Copy() or nil
	cascade.last_rendered_frame = system.GetFrameNumber and system.GetFrameNumber() or 0
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
	self:CullScene(cascade_index)
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

local function write_shadow_batch_record(self, pipeline, record, batch)
	local material = batch.material
	record.albedo_texture_index = cache_shadow_material_texture_indices(self, material, pipeline).albedo_texture_index
	record.flags = material:GetShadowFlags()
	record.color_multiplier_a = material:GetShadowOpacity()
	record.alpha_cutoff = material:GetAlphaCutoff()
	write_shadow_uv_data(record, material, cache_shadow_material_texture_indices(self, material, pipeline).normal_texture_index)
	render3d.SetCurrentPolygon3D(batch.first_polygon3d)
	model_pipeline.FillVertexAnimationData(record.anim, material)
end

local function write_shadow_batch_animation(self, pipeline, record, batch)
	render3d.SetCurrentPolygon3D(batch.first_polygon3d)
	model_pipeline.FillVertexAnimationData(record.anim, batch.material)
end

-- draws a list of {mesh, material, first_polygon3d} batches with the multi draw pipeline, from
-- VkDrawIndirectCommands (VkDrawIndexedIndirectCommands over the index pool when indexed), one for each batch. key tells the batch tables of different lists apart
function ShadowMap:DrawBatches(cascade_index, key, batches, batch_serial, instances_address, commands, stride, indexed)
	local pipeline = self.mode == "point" and
		self.multi_draw_pipeline or
		self.multi_draw_pipeline_variants[self.cascade[cascade_index].format]
	local batch_table = self.shadow_batch_tables[key or pipeline]

	if not batch_table then
		batch_table = BatchTable.New{
			label = "render3d_shadow_batches",
			record_type = ShadowBatchRecord,
			write_record = write_shadow_batch_record,
			write_animated = write_shadow_batch_animation,
			animation_version = model_pipeline.GetVertexAnimationVersion,
		}
		self.shadow_batch_tables[key or pipeline] = batch_table
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
	local wind_camera, wind_pixel_scale = model_pipeline.GetVertexAnimationView()
	push_constants.wind_camera[0] = wind_camera.x
	push_constants.wind_camera[1] = wind_camera.y
	push_constants.wind_camera[2] = wind_camera.z
	push_constants.wind_pixel_scale = wind_pixel_scale
	push_constants.time = atmosphere.GetWindTime()
	push_constants.prev_time = atmosphere.GetPreviousWindTime()
	push_constants.detail_time = atmosphere.GetWindDetailTime()
	push_constants.batches = batch_table:Update(pipeline, batches, batch_serial, self.batch_serial, self)
	push_constants.instances = instances_address
	push_constants.indexed = indexed and 1 or 0
	pipeline:Bind(self.cmd, render.GetCurrentFrame())
	self.cmd:SetViewport(0.0, 0.0, depth_texture:GetWidth(), depth_texture:GetHeight(), 0.0, 1.0)
	self.cmd:SetScissor(0, 0, depth_texture:GetWidth(), depth_texture:GetHeight())
	self.cmd:SetFrontFace(orientation.FRONT_FACE)
	self.cmd:SetCullMode("none")
	pipeline:PushConstants(self.cmd, {"vertex", "fragment"}, 0, push_constants)

	if indexed then
		self.cmd:BindIndexBuffer(index_pool.GetBuffer(), 0, "uint32")
		self.cmd:DrawIndexedIndirect(commands, 0, #batches, stride)
	else
		self.cmd:DrawIndirect(commands, 0, #batches, stride)
	end
end

function ShadowMap:PrimeMaterial(material)
	if not material then return end

	if self.mode == "point" then
		cache_shadow_material_texture_indices(self, material, self.multi_draw_pipeline)
		return
	end

	for _, pipeline in pairs(self.multi_draw_pipeline_variants) do
		cache_shadow_material_texture_indices(self, material, pipeline)
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

function ShadowMap:IsCascadeSampleable(cascade_index)
	return self.cascade[cascade_index].is_sampleable
end

function ShadowMap:GetLightSpaceMatrix(cascade_index)
	return self.cascade[cascade_index].light_space_matrix
end

function ShadowMap:GetMode()
	return self.mode
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

pvars.StartGroup("Lighting", "Shadows", {store = false, prefix = "feature_"})
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

function ShadowMap:BeginAllCascades()
	local cmds = {}

	for i = 1, self.cascade_count do
		cmds[i] = self:Begin(i)
	end

	return cmds
end

function ShadowMap:GetCascadeDepthTextures()
	if self.mode == "point" then return {self.point_depth_cubemap} end

	local textures = {}

	for i = 1, self.cascade_count do
		textures[i] = self.cascade[i].depth_texture
	end

	return textures
end

function ShadowMap:GetLightPosition()
	return self.point_light_position
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
