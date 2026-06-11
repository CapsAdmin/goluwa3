local ffi = require("ffi")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local test_helper = import("goluwa/helpers/test.lua")
local tasks = import("goluwa/tasks.lua")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local vk = import("goluwa/bindings/vk.lua")
local render3d = nil
local gpu_culling = library()
gpu_culling.enabled = gpu_culling.enabled ~= false
gpu_culling.async_main_view_enabled = gpu_culling.async_main_view_enabled == true
gpu_culling.occlusion_mode = gpu_culling.occlusion_mode or "hiz"
gpu_culling.scene_acceleration = gpu_culling.scene_acceleration or nil
gpu_culling.scene_dataset = gpu_culling.scene_dataset or nil
gpu_culling.frame_buffers = gpu_culling.frame_buffers or nil
gpu_culling.scene_acceleration_dirty = gpu_culling.scene_acceleration_dirty ~= false
gpu_culling.scene_acceleration_generation = gpu_culling.scene_acceleration_generation or 0
gpu_culling.published_scene_acceleration_generation = gpu_culling.published_scene_acceleration_generation or 0
gpu_culling.frame_buffers_generation = gpu_culling.frame_buffers_generation or -1
gpu_culling.main_view_async_submission_serial = gpu_culling.main_view_async_submission_serial or 0
local float16 = ffi.typeof("float[16]")
local VALID_OCCLUSION_MODES = {
	disabled = true,
	hiz = true,
}
local UINT32_SIZE = ffi.sizeof("uint32_t")
local DRAW_INDEXED_INDIRECT_COMMAND_SIZE = ffi.sizeof(vk.VkDrawIndexedIndirectCommand)
local INVALID_INDEX = 0xFFFFFFFF
local NO_INDEX_BUFFER_KEY = {}
local VISUAL_FLAG_VISIBLE = 0x1
local VISUAL_FLAG_CAST_SHADOWS = 0x2
local VISUAL_FLAG_USE_OCCLUSION = 0x4
local VISUAL_FLAG_DYNAMIC = 0x8
local VISUAL_FLAG_SHADOW_AABB_CULLABLE = 0x10
local VISUAL_FLAG_SHADOW_NON_AABB = 0x20
local ENTRY_FLAG_IGNORE_Z = 0x1
local ENTRY_FLAG_HEIGHT_DISPLACEMENT = 0x2
local NODE_FLAG_LEAF = 0x1
local GPUCullVisualRecord = ffi.typeof([[struct {
	float min_x;
	float min_y;
	float min_z;
	float max_x;
	float max_y;
	float max_z;
	float sphere_radius;
	float cull_distance;
	uint32_t flags;
	uint32_t entry_offset;
	uint32_t entry_count;
	uint32_t shadow_change_version;
}]])
local GPUCullEntryRecord = ffi.typeof([[struct {
	float local_min_x;
	float local_min_y;
	float local_min_z;
	float local_max_x;
	float local_max_y;
	float local_max_z;
	float source_min_x;
	float source_min_y;
	float source_min_z;
	float source_max_x;
	float source_max_y;
	float source_max_z;
	uint32_t visual_index;
	uint32_t entry_index;
	uint32_t index_count;
	uint32_t flags;
	uint32_t instanced_batch_index;
	uint32_t static_matrix_index;
}]])
local GPUCullInstancedBatchRecord = ffi.typeof([[struct {
	uint32_t output_offset;
	uint32_t max_count;
	uint32_t index_count;
	uint32_t reserved1;
}]])
local GPUCullNodeRecord = ffi.typeof([[struct {
	float min_x;
	float min_y;
	float min_z;
	float max_x;
	float max_y;
	float max_z;
	float max_cull_distance;
	uint32_t first;
	uint32_t last;
	uint32_t left_index;
	uint32_t right_index;
	uint32_t flags;
	uint32_t max_shadow_change_version;
	uint32_t reserved;
}]])
local FRUSTUM_PLANE_COMPONENT_COUNT = 24
local ZERO_UINT32 = ffi.new("uint32_t[1]", 0)

function gpu_culling.Initialize()
	render3d = import("goluwa/render3d/render3d.lua")

	do -- main view hiz build pass
		gpu_culling.main_view_hiz_build_pass = EasyPipeline.Compute{
			DescriptorSetCount = 64,
			name = "gpu_culling_main_view_hiz_copy",
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = {
				{
					type = "combined_image_sampler",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_image",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			shader = [[
			layout(set = 0, binding = 0) uniform sampler2D source_depth_tex;
			layout(set = 0, binding = 1, r32f) uniform writeonly image2D out_hiz;

			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
				ivec2 dst_size = imageSize(out_hiz);

				if (any(greaterThanEqual(pos, dst_size))) return;

				ivec2 src_size = textureSize(source_depth_tex, 0);
				if (any(greaterThanEqual(pos, src_size))) return;
				imageStore(out_hiz, pos, vec4(texelFetch(source_depth_tex, pos, 0).r, 0.0, 0.0, 1.0));
			}
		]],
		}
	end

	do -- main view hiz reduce pass
		gpu_culling.main_view_hiz_reduce_pass = EasyPipeline.Compute{
			DescriptorSetCount = 64,
			name = "gpu_culling_main_view_hiz_reduce",
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = {
				{
					type = "storage_image",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_image",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			shader = [[
			layout(set = 0, binding = 0, r32f) uniform readonly image2D source_hiz;
			layout(set = 0, binding = 1, r32f) uniform writeonly image2D out_hiz;

			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
				ivec2 dst_size = imageSize(out_hiz);

				if (any(greaterThanEqual(pos, dst_size))) return;

				ivec2 src_size = imageSize(source_hiz);
				ivec2 src_base = pos * 2;
				float max_depth = 0.0;

				for (int y = 0; y < 2; ++y) {
					for (int x = 0; x < 2; ++x) {
						ivec2 src_pos = min(src_base + ivec2(x, y), src_size - 1);
						max_depth = max(max_depth, imageLoad(source_hiz, src_pos).r);
					}
				}

				imageStore(out_hiz, pos, vec4(max_depth, 0.0, 0.0, 1.0));
			}
		]],
		}
	end

	do -- view cull pass
		gpu_culling.main_view_cull_pass = EasyPipeline.Compute{
			DescriptorSetCount = math.max((render.GetSwapchainImageCount() or 1) + 1, 1),
			name = "gpu_culling_main_view_linear",
			LocalSize = {x = 64, y = 1, z = 1},
			descriptor_sets = {
				{
					type = "storage_buffer",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 2,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 3,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 4,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 5,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 6,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 7,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 8,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 9,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 10,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 11,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 12,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 13,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "combined_image_sampler",
					binding_index = 14,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			block = {
				{"visual_count", "int"},
				{"camera_position", "vec3"},
				{"frustum_planes", "vec4", 6},
				{"view_projection", "mat4"},
				{"viewport_height", "float"},
				{"min_screen_diameter_px", "float"},
				{"occlusion_enabled", "int"},
				{"has_source_depth_texture", "int"},
				{"occlusion_max_mip", "int"},
				{"occlusion_depth_bias", "float"},
			},
			write = function(self, block)
				block.visual_count = self.current_visual_count or 0
				block.camera_position[0] = self.current_camera_position and self.current_camera_position.x or 0
				block.camera_position[1] = self.current_camera_position and self.current_camera_position.y or 0
				block.camera_position[2] = self.current_camera_position and self.current_camera_position.z or 0

				if self.current_frustum_planes then
					ffi.copy(
						block.frustum_planes,
						self.current_frustum_planes,
						ffi.sizeof("float") * FRUSTUM_PLANE_COMPONENT_COUNT
					)
				else
					ffi.fill(block.frustum_planes, ffi.sizeof("float") * FRUSTUM_PLANE_COMPONENT_COUNT, 0)
				end

				if self.current_view_projection then
					self.current_view_projection:CopyToFloatPointer(block.view_projection)
				else
					ffi.fill(block.view_projection, ffi.sizeof("float") * 16, 0)
				end

				block.viewport_height = self.current_viewport_height or 0
				block.min_screen_diameter_px = self.current_min_screen_diameter_px or 1.0
				block.occlusion_enabled = self.current_occlusion_enabled and 1 or 0
				block.has_source_depth_texture = self.current_occlusion_depth_texture and 1 or 0
				block.occlusion_max_mip = self.current_occlusion_max_mip or 0
				block.occlusion_depth_bias = self.current_occlusion_depth_bias or 0.0015
				return block
			end,
			shader = [[
			struct VisualRecord {
				float min_x;
				float min_y;
				float min_z;
				float max_x;
				float max_y;
				float max_z;
				float sphere_radius;
				float cull_distance;
				uint flags;
				uint entry_offset;
				uint entry_count;
				uint shadow_change_version;
			};

			struct EntryRecord {
				float local_min_x;
				float local_min_y;
				float local_min_z;
				float local_max_x;
				float local_max_y;
				float local_max_z;
				float source_min_x;
				float source_min_y;
				float source_min_z;
				float source_max_x;
				float source_max_y;
				float source_max_z;
				uint visual_index;
				uint entry_index;
				uint index_count;
				uint flags;
				uint instanced_batch_index;
				uint static_matrix_index;
			};

			struct InstancedBatchRecord {
				uint output_offset;
				uint max_count;
				uint index_count;
				uint reserved1;
			};

			struct DrawIndexedIndirectCommand {
				uint indexCount;
				uint instanceCount;
				uint firstIndex;
				int vertexOffset;
				uint firstInstance;
			};

			layout(std430, set = 0, binding = 0) readonly buffer VisualBuffer {
				VisualRecord visuals[];
			};

			layout(std430, set = 0, binding = 1) writeonly buffer VisibleIndexBuffer {
				uint visible_indices[];
			};

			layout(std430, set = 0, binding = 2) buffer VisibleCountBuffer {
				uint visible_count[];
			};

			layout(std430, set = 0, binding = 3) readonly buffer EntryBuffer {
				EntryRecord entries[];
			};

			layout(std430, set = 0, binding = 4) writeonly buffer IndirectCommandBuffer {
				DrawIndexedIndirectCommand commands[];
			};

			layout(std430, set = 0, binding = 5) readonly buffer StaticInstanceWorldBuffer {
				mat4 static_instance_worlds[];
			};

			layout(std430, set = 0, binding = 6) readonly buffer InstancedBatchBuffer {
				InstancedBatchRecord instanced_batches[];
			};

			layout(std430, set = 0, binding = 7) writeonly buffer VisibleInstanceWorldBuffer {
				mat4 visible_instance_worlds[];
			};

			layout(std430, set = 0, binding = 8) buffer VisibleInstancedBatchCountBuffer {
				uint visible_instanced_batch_counts[];
			};

			layout(std430, set = 0, binding = 9) writeonly buffer FallbackVisibleIndexBuffer {
				uint fallback_visible_indices[];
			};

			layout(std430, set = 0, binding = 10) buffer FallbackVisibleCountBuffer {
				uint fallback_visible_count[];
			};

			layout(std430, set = 0, binding = 11) writeonly buffer ActiveBatchIndexBuffer {
				uint active_batch_indices[];
			};

			layout(std430, set = 0, binding = 12) buffer ActiveBatchCountBuffer {
				uint active_batch_count[];
			};

			layout(std430, set = 0, binding = 13) buffer VisibleBatchIndirectCommandBuffer {
				DrawIndexedIndirectCommand batch_commands[];
			};

			layout(set = 0, binding = 14) uniform sampler2D source_depth_tex;

			const uint VISUAL_FLAG_VISIBLE = 1u;
			const uint VISUAL_FLAG_USE_OCCLUSION = 4u;
			const uint INVALID_INDEX = 0xFFFFFFFFu;

			bool is_within_cull_distance(VisualRecord visual_record) {
				if (visual_record.cull_distance <= 0.0) return true;

				float nearest_x = clamp(compute.camera_position.x, visual_record.min_x, visual_record.max_x);
				float nearest_y = clamp(compute.camera_position.y, visual_record.min_y, visual_record.max_y);
				float nearest_z = clamp(compute.camera_position.z, visual_record.min_z, visual_record.max_z);
				float dx = compute.camera_position.x - nearest_x;
				float dy = compute.camera_position.y - nearest_y;
				float dz = compute.camera_position.z - nearest_z;
				return dx * dx + dy * dy + dz * dz <= visual_record.cull_distance * visual_record.cull_distance;
			}

			bool is_visible_in_frustum(VisualRecord visual_record) {
				for (int i = 0; i < 6; i++) {
					vec4 plane = compute.frustum_planes[i];
					float px = plane.x > 0.0 ? visual_record.max_x : visual_record.min_x;
					float py = plane.y > 0.0 ? visual_record.max_y : visual_record.min_y;
					float pz = plane.z > 0.0 ? visual_record.max_z : visual_record.min_z;

					if (plane.x * px + plane.y * py + plane.z * pz + plane.w < 0.0) {
						return false;
					}
				}

				return true;
			}

			vec4 project_world_position(vec3 world_pos) {
				return compute.view_projection * vec4(world_pos, 1.0);
			}

			bool is_camera_inside_aabb(VisualRecord visual_record) {
				return compute.camera_position.x >= visual_record.min_x &&
					compute.camera_position.x <= visual_record.max_x &&
					compute.camera_position.y >= visual_record.min_y &&
					compute.camera_position.y <= visual_record.max_y &&
					compute.camera_position.z >= visual_record.min_z &&
					compute.camera_position.z <= visual_record.max_z;
			}

			bool is_large_enough_in_screen_space(VisualRecord visual_record) {
				if (compute.viewport_height <= 0.0) return true;
				if (visual_record.sphere_radius <= 0.0) return true;

				vec3 center = vec3(
					(visual_record.min_x + visual_record.max_x) * 0.5,
					(visual_record.min_y + visual_record.max_y) * 0.5,
					(visual_record.min_z + visual_record.max_z) * 0.5
				);
				vec4 clip = project_world_position(center);

				if (clip.w <= 0.0) return true;

				float projected_radius_px = abs(compute.view_projection[1][1]) * visual_record.sphere_radius * compute.viewport_height / max(clip.w * 2.0, 1e-5);
				return projected_radius_px * 2.0 >= compute.min_screen_diameter_px;
			}

			int choose_occlusion_mip(vec2 min_uv, vec2 max_uv) {
				vec2 uv_span = max(max_uv - min_uv, vec2(0.0));
				vec2 hi_z_size = vec2(textureSize(source_depth_tex, 0));
				float max_span = max(max(uv_span.x * hi_z_size.x, uv_span.y * hi_z_size.y), 1.0);
				return clamp(int(ceil(log2(max_span))), 0, compute.occlusion_max_mip);
			}

			bool is_occluded(VisualRecord visual_record) {
				if (compute.occlusion_enabled == 0 || compute.has_source_depth_texture == 0) return false;
				if ((visual_record.flags & VISUAL_FLAG_USE_OCCLUSION) == 0u) return false;

				vec3 corners[8] = vec3[](
					vec3(visual_record.min_x, visual_record.min_y, visual_record.min_z),
					vec3(visual_record.min_x, visual_record.min_y, visual_record.max_z),
					vec3(visual_record.min_x, visual_record.max_y, visual_record.min_z),
					vec3(visual_record.min_x, visual_record.max_y, visual_record.max_z),
					vec3(visual_record.max_x, visual_record.min_y, visual_record.min_z),
					vec3(visual_record.max_x, visual_record.min_y, visual_record.max_z),
					vec3(visual_record.max_x, visual_record.max_y, visual_record.min_z),
					vec3(visual_record.max_x, visual_record.max_y, visual_record.max_z)
				);

				vec2 min_uv = vec2(1.0);
				vec2 max_uv = vec2(0.0);
				float nearest_depth = 1.0;
				bool any_valid = false;

				for (int i = 0; i < 8; ++i) {
					vec4 clip = project_world_position(corners[i]);

					if (clip.w <= 0.0) continue;

					vec3 ndc = clip.xyz / clip.w;
					vec2 uv = ndc.xy * 0.5 + 0.5;
					min_uv = min(min_uv, uv);
					max_uv = max(max_uv, uv);
					nearest_depth = min(nearest_depth, ndc.z);
					any_valid = true;
				}

				if (!any_valid) return false;
				if (max_uv.x < 0.0 || max_uv.y < 0.0 || min_uv.x > 1.0 || min_uv.y > 1.0) return false;

				min_uv = clamp(min_uv, vec2(0.0), vec2(1.0));
				max_uv = clamp(max_uv, vec2(0.0), vec2(1.0));
				int mip_level = choose_occlusion_mip(min_uv, max_uv);
				ivec2 mip_size = textureSize(source_depth_tex, mip_level);
				ivec2 texel_min = ivec2(clamp(floor(min_uv * vec2(mip_size)), vec2(0.0), vec2(mip_size - 1)));
				ivec2 texel_max = ivec2(clamp(floor(max_uv * vec2(mip_size)), vec2(0.0), vec2(mip_size - 1)));

				float sampled_depth = 0.0;
				sampled_depth = max(sampled_depth, texelFetch(source_depth_tex, texel_min, mip_level).r);
				sampled_depth = max(sampled_depth, texelFetch(source_depth_tex, ivec2(texel_max.x, texel_min.y), mip_level).r);
				sampled_depth = max(sampled_depth, texelFetch(source_depth_tex, ivec2(texel_min.x, texel_max.y), mip_level).r);
				sampled_depth = max(sampled_depth, texelFetch(source_depth_tex, texel_max, mip_level).r);

				return nearest_depth > sampled_depth + compute.occlusion_depth_bias;
			}

			void main() {
				uint visual_index = gl_GlobalInvocationID.x;

				if (visual_index >= uint(max(compute.visual_count, 0))) return;

				VisualRecord visual_record = visuals[visual_index];
				bool camera_inside_aabb = is_camera_inside_aabb(visual_record);

				if ((visual_record.flags & VISUAL_FLAG_VISIBLE) == 0u) return;
				if (!is_within_cull_distance(visual_record)) return;
				if (!is_visible_in_frustum(visual_record)) return;
				if (!camera_inside_aabb && !is_large_enough_in_screen_space(visual_record)) return;
				if (!camera_inside_aabb && is_occluded(visual_record)) return;

				for (uint entry_offset = 0u; entry_offset < visual_record.entry_count; ++entry_offset) {
					EntryRecord entry_record = entries[visual_record.entry_offset + entry_offset];

					if (entry_record.index_count == 0u) continue;

					uint write_index = atomicAdd(visible_count[0], 1u);
					uint entry_index = visual_record.entry_offset + entry_offset;
					visible_indices[write_index] = entry_index;
					commands[write_index].indexCount = entry_record.index_count;
					commands[write_index].instanceCount = 1u;
					commands[write_index].firstIndex = 0u;
					commands[write_index].vertexOffset = 0;
					commands[write_index].firstInstance = entry_index;

					if (entry_record.instanced_batch_index != INVALID_INDEX && entry_record.static_matrix_index != INVALID_INDEX) {
						InstancedBatchRecord batch_record = instanced_batches[entry_record.instanced_batch_index];
						uint local_index = atomicAdd(visible_instanced_batch_counts[entry_record.instanced_batch_index], 1u);

						if (local_index == 0u) {
							uint active_batch_write_index = atomicAdd(active_batch_count[0], 1u);
							active_batch_indices[active_batch_write_index] = entry_record.instanced_batch_index;
							batch_commands[entry_record.instanced_batch_index].indexCount = batch_record.index_count;
							batch_commands[entry_record.instanced_batch_index].firstIndex = 0u;
							batch_commands[entry_record.instanced_batch_index].vertexOffset = 0;
							batch_commands[entry_record.instanced_batch_index].firstInstance = batch_record.output_offset;
						}

						atomicAdd(batch_commands[entry_record.instanced_batch_index].instanceCount, 1u);

						if (local_index < batch_record.max_count) {
							visible_instance_worlds[batch_record.output_offset + local_index] = static_instance_worlds[entry_record.static_matrix_index];
						}
					} else {
						uint fallback_write_index = atomicAdd(fallback_visible_count[0], 1u);
						fallback_visible_indices[fallback_write_index] = entry_index;
					}
				}
			}
		]],
		}
		gpu_culling.main_view_cull_frustum_planes = ffi.new("float[24]")
	end

	do -- view aabb cull pass
		gpu_culling.shadow_view_aabb_cull_pass = EasyPipeline.Compute{
			DescriptorSetCount = math.max(gpu_culling.shadow_query_output_descriptor_count or 1, 1),
			name = "gpu_culling_shadow_view_aabb",
			LocalSize = {x = 64, y = 1, z = 1},
			descriptor_sets = {
				{
					type = "storage_buffer",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 2,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 3,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 4,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 5,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 6,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 7,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 8,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 9,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 10,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 11,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 12,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_buffer",
					binding_index = 13,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "combined_image_sampler",
					binding_index = 14,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			block = {
				{"visual_count", "int"},
				{"query_min", "vec3"},
				{"query_max", "vec3"},
				{"camera_position", "vec3"},
				{"view_projection", "mat4"},
				{"occlusion_enabled", "int"},
				{"has_source_depth_texture", "int"},
				{"occlusion_max_mip", "int"},
				{"occlusion_depth_bias", "float"},
			},
			write = function(self, block)
				block.visual_count = self.current_visual_count or 0
				block.query_min[0] = self.current_query_aabb and self.current_query_aabb.min_x or 0
				block.query_min[1] = self.current_query_aabb and self.current_query_aabb.min_y or 0
				block.query_min[2] = self.current_query_aabb and self.current_query_aabb.min_z or 0
				block.query_max[0] = self.current_query_aabb and self.current_query_aabb.max_x or 0
				block.query_max[1] = self.current_query_aabb and self.current_query_aabb.max_y or 0
				block.query_max[2] = self.current_query_aabb and self.current_query_aabb.max_z or 0
				block.camera_position[0] = self.current_camera_position and self.current_camera_position.x or 0
				block.camera_position[1] = self.current_camera_position and self.current_camera_position.y or 0
				block.camera_position[2] = self.current_camera_position and self.current_camera_position.z or 0

				if self.current_view_projection then
					self.current_view_projection:CopyToFloatPointer(block.view_projection)
				else
					ffi.fill(block.view_projection, ffi.sizeof("float") * 16, 0)
				end

				block.occlusion_enabled = self.current_occlusion_enabled and 1 or 0
				block.has_source_depth_texture = self.current_occlusion_depth_texture and 1 or 0
				block.occlusion_max_mip = self.current_occlusion_max_mip or 0
				block.occlusion_depth_bias = self.current_occlusion_depth_bias or 0.0015
				return block
			end,
			shader = [[
			struct VisualRecord {
				float min_x;
				float min_y;
				float min_z;
				float max_x;
				float max_y;
				float max_z;
				float sphere_radius;
				float cull_distance;
				uint flags;
				uint entry_offset;
				uint entry_count;
				uint shadow_change_version;
			};

			struct EntryRecord {
				float local_min_x;
				float local_min_y;
				float local_min_z;
				float local_max_x;
				float local_max_y;
				float local_max_z;
				float source_min_x;
				float source_min_y;
				float source_min_z;
				float source_max_x;
				float source_max_y;
				float source_max_z;
				uint visual_index;
				uint entry_index;
				uint index_count;
				uint flags;
				uint instanced_batch_index;
				uint static_matrix_index;
			};

			struct InstancedBatchRecord {
				uint output_offset;
				uint max_count;
				uint index_count;
				uint reserved1;
			};

			struct DrawIndexedIndirectCommand {
				uint indexCount;
				uint instanceCount;
				uint firstIndex;
				int vertexOffset;
				uint firstInstance;
			};

			layout(std430, set = 0, binding = 0) readonly buffer VisualBuffer {
				VisualRecord visuals[];
			};

			layout(std430, set = 0, binding = 1) writeonly buffer VisibleIndexBuffer {
				uint visible_indices[];
			};

			layout(std430, set = 0, binding = 2) buffer VisibleCountBuffer {
				uint visible_count[];
			};

			layout(std430, set = 0, binding = 3) readonly buffer EntryBuffer {
				EntryRecord entries[];
			};

			layout(std430, set = 0, binding = 4) readonly buffer StaticInstanceWorldBuffer {
				mat4 static_instance_worlds[];
			};

			layout(std430, set = 0, binding = 5) readonly buffer InstancedBatchBuffer {
				InstancedBatchRecord instanced_batches[];
			};

			layout(std430, set = 0, binding = 6) writeonly buffer VisibleInstanceWorldBuffer {
				mat4 visible_instance_worlds[];
			};

			layout(std430, set = 0, binding = 7) buffer VisibleInstancedBatchCountBuffer {
				uint visible_instanced_batch_counts[];
			};

			layout(std430, set = 0, binding = 8) writeonly buffer FallbackVisibleIndexBuffer {
				uint fallback_visible_indices[];
			};

			layout(std430, set = 0, binding = 9) buffer FallbackVisibleCountBuffer {
				uint fallback_visible_count[];
			};

			layout(std430, set = 0, binding = 10) writeonly buffer ActiveBatchIndexBuffer {
				uint active_batch_indices[];
			};

			layout(std430, set = 0, binding = 11) buffer ActiveBatchCountBuffer {
				uint active_batch_count[];
			};

			layout(std430, set = 0, binding = 12) buffer VisibleBatchIndirectCommandBuffer {
				DrawIndexedIndirectCommand batch_commands[];
			};

			layout(set = 0, binding = 14) uniform sampler2D source_depth_tex;

			const uint VISUAL_FLAG_CAST_SHADOWS = 2u;
			const uint VISUAL_FLAG_USE_OCCLUSION = 4u;
			const uint INVALID_INDEX = 0xFFFFFFFFu;

			bool overlaps_query(VisualRecord visual_record) {
				return visual_record.max_x >= compute.query_min.x &&
					visual_record.min_x <= compute.query_max.x &&
					visual_record.max_y >= compute.query_min.y &&
					visual_record.min_y <= compute.query_max.y &&
					visual_record.max_z >= compute.query_min.z &&
					visual_record.min_z <= compute.query_max.z;
			}

			vec4 project_world_position(vec3 world_pos) {
				return compute.view_projection * vec4(world_pos, 1.0);
			}

			bool is_camera_inside_aabb(VisualRecord visual_record) {
				return compute.camera_position.x >= visual_record.min_x &&
					compute.camera_position.x <= visual_record.max_x &&
					compute.camera_position.y >= visual_record.min_y &&
					compute.camera_position.y <= visual_record.max_y &&
					compute.camera_position.z >= visual_record.min_z &&
					compute.camera_position.z <= visual_record.max_z;
			}

			int choose_occlusion_mip(vec2 min_uv, vec2 max_uv) {
				vec2 uv_span = max(max_uv - min_uv, vec2(0.0));
				vec2 hi_z_size = vec2(textureSize(source_depth_tex, 0));
				float max_span = max(max(uv_span.x * hi_z_size.x, uv_span.y * hi_z_size.y), 1.0);
				return clamp(int(ceil(log2(max_span))), 0, compute.occlusion_max_mip);
			}

			bool is_occluded(VisualRecord visual_record) {
				if (compute.occlusion_enabled == 0 || compute.has_source_depth_texture == 0) return false;
				if ((visual_record.flags & VISUAL_FLAG_USE_OCCLUSION) == 0u) return false;

				vec3 corners[8] = vec3[](
					vec3(visual_record.min_x, visual_record.min_y, visual_record.min_z),
					vec3(visual_record.min_x, visual_record.min_y, visual_record.max_z),
					vec3(visual_record.min_x, visual_record.max_y, visual_record.min_z),
					vec3(visual_record.min_x, visual_record.max_y, visual_record.max_z),
					vec3(visual_record.max_x, visual_record.min_y, visual_record.min_z),
					vec3(visual_record.max_x, visual_record.min_y, visual_record.max_z),
					vec3(visual_record.max_x, visual_record.max_y, visual_record.min_z),
					vec3(visual_record.max_x, visual_record.max_y, visual_record.max_z)
				);

				vec2 min_uv = vec2(1.0);
				vec2 max_uv = vec2(0.0);
				float nearest_depth = 1.0;
				bool any_valid = false;

				for (int i = 0; i < 8; ++i) {
					vec4 clip = project_world_position(corners[i]);

					if (clip.w <= 0.0) continue;

					vec3 ndc = clip.xyz / clip.w;
					vec2 uv = ndc.xy * 0.5 + 0.5;
					min_uv = min(min_uv, uv);
					max_uv = max(max_uv, uv);
					nearest_depth = min(nearest_depth, ndc.z);
					any_valid = true;
				}

				if (!any_valid) return false;
				if (max_uv.x < 0.0 || max_uv.y < 0.0 || min_uv.x > 1.0 || min_uv.y > 1.0) return false;

				min_uv = clamp(min_uv, vec2(0.0), vec2(1.0));
				max_uv = clamp(max_uv, vec2(0.0), vec2(1.0));
				int mip_level = choose_occlusion_mip(min_uv, max_uv);
				ivec2 mip_size = textureSize(source_depth_tex, mip_level);
				ivec2 texel_min = ivec2(clamp(floor(min_uv * vec2(mip_size)), vec2(0.0), vec2(mip_size - 1)));
				ivec2 texel_max = ivec2(clamp(floor(max_uv * vec2(mip_size)), vec2(0.0), vec2(mip_size - 1)));

				float sampled_depth = 0.0;
				sampled_depth = max(sampled_depth, texelFetch(source_depth_tex, texel_min, mip_level).r);
				sampled_depth = max(sampled_depth, texelFetch(source_depth_tex, ivec2(texel_max.x, texel_min.y), mip_level).r);
				sampled_depth = max(sampled_depth, texelFetch(source_depth_tex, ivec2(texel_min.x, texel_max.y), mip_level).r);
				sampled_depth = max(sampled_depth, texelFetch(source_depth_tex, texel_max, mip_level).r);

				return nearest_depth > sampled_depth + compute.occlusion_depth_bias;
			}

			void main() {
				uint visual_index = gl_GlobalInvocationID.x;

				if (visual_index >= uint(max(compute.visual_count, 0))) return;

				VisualRecord visual_record = visuals[visual_index];
				bool camera_inside_aabb = is_camera_inside_aabb(visual_record);

				if ((visual_record.flags & VISUAL_FLAG_CAST_SHADOWS) == 0u) return;
				if (!overlaps_query(visual_record)) return;
				if (!camera_inside_aabb && is_occluded(visual_record)) return;

				for (uint entry_offset = 0u; entry_offset < visual_record.entry_count; ++entry_offset) {
					EntryRecord entry_record = entries[visual_record.entry_offset + entry_offset];

					if (entry_record.index_count == 0u) continue;

					uint write_index = atomicAdd(visible_count[0], 1u);
					uint entry_index = visual_record.entry_offset + entry_offset;
					visible_indices[write_index] = entry_index;

					if (entry_record.instanced_batch_index != INVALID_INDEX && entry_record.static_matrix_index != INVALID_INDEX) {
						InstancedBatchRecord batch_record = instanced_batches[entry_record.instanced_batch_index];
						uint local_index = atomicAdd(visible_instanced_batch_counts[entry_record.instanced_batch_index], 1u);

						if (local_index == 0u) {
							uint active_batch_write_index = atomicAdd(active_batch_count[0], 1u);
							active_batch_indices[active_batch_write_index] = entry_record.instanced_batch_index;
							batch_commands[entry_record.instanced_batch_index].indexCount = batch_record.index_count;
							batch_commands[entry_record.instanced_batch_index].firstIndex = 0u;
							batch_commands[entry_record.instanced_batch_index].vertexOffset = 0;
							batch_commands[entry_record.instanced_batch_index].firstInstance = batch_record.output_offset;
						}

						atomicAdd(batch_commands[entry_record.instanced_batch_index].instanceCount, 1u);

						if (local_index < batch_record.max_count) {
							visible_instance_worlds[batch_record.output_offset + local_index] = static_instance_worlds[entry_record.static_matrix_index];
						}
					} else {
						uint fallback_write_index = atomicAdd(fallback_visible_count[0], 1u);
						fallback_visible_indices[fallback_write_index] = entry_index;
					}
				}
			}
		]],
		}
		gpu_culling.shadow_view_aabb_cull_cmd = render.CreateCommandBuffer()
	end
end

local function ensure_main_view_hiz_state(width, height)
	width = math.max(1, math.floor(tonumber(width) or 1))
	height = math.max(1, math.floor(tonumber(height) or 1))
	local state = gpu_culling.main_view_hiz_state

	if
		state and
		state.width == width and
		state.height == height and
		state.texture and
		state.texture:IsValid()
	then
		return state
	end

	if state and state.texture then state.texture:Remove() end

	local texture = Texture.New{
		width = width,
		height = height,
		format = "r32_sfloat",
		mip_map_levels = (width > 1 or height > 1) and 2 or 1,
		image = {
			usage = {"sampled", "storage"},
			properties = "device_local",
		},
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			mipmap_mode = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	texture:SetDebugName("gpu culling main view hiz")
	local image = texture:GetImage()
	local mip_count = texture:GetMipMapLevels()
	local single_mip_views = {}

	for mip_level = 0, mip_count - 1 do
		single_mip_views[mip_level + 1] = image:CreateView{
			format = "r32_sfloat",
			base_mip_level = mip_level,
			level_count = 1,
			aspect = "color",
		}

		if single_mip_views[mip_level + 1].SetDebugName then
			single_mip_views[mip_level + 1]:SetDebugName("gpu culling main view hiz mip " .. mip_level)
		end
	end

	image:TransitionLayout(image.layout or "undefined", "general")
	state = {
		width = width,
		height = height,
		texture = texture,
		full_view = texture:GetView(),
		sampler = texture.sampler or render.CreateSampler(texture:GetSamplerConfig()),
		max_mip = math.max(0, mip_count - 1),
		single_mip_views = single_mip_views,
	}
	gpu_culling.main_view_hiz_state = state
	return state
end

local function get_main_view_occlusion_source()
	local depth_texture = render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture()
	local state = ensure_main_view_hiz_state(depth_texture:GetWidth(), depth_texture:GetHeight())
	return depth_texture, state.full_view, state.sampler, state.max_mip, state
end

local function build_main_view_hiz(cmd, descriptor_slot, depth_texture, state)
	if not (cmd and depth_texture and state and state.texture) then return end

	local descriptor_base = descriptor_slot * 16
	local image = state.texture:GetImage()
	local depth_view = depth_texture:GetView()
	local depth_sampler = depth_texture.sampler or render.CreateSampler(depth_texture:GetSamplerConfig())
	render.TransitionResourceToComputeStorage(
		state.texture,
		{
			cmd = cmd,
			srcStage = "top_of_pipe",
			srcAccess = "none",
			dstStage = "compute",
			dstAccess = "shader_write",
			base_mip_level = 0,
			level_count = state.max_mip + 1,
			layer_count = 1,
		}
	)
	local copy_pass = gpu_culling.main_view_hiz_build_pass
	copy_pass:UpdateDescriptorSet("combined_image_sampler", descriptor_base, 0, 0, depth_view, depth_sampler)
	copy_pass:UpdateDescriptorSet("storage_image", descriptor_base, 1, 0, state.single_mip_views[1])
	copy_pass:DispatchForSize(cmd, state.width, state.height, 1, descriptor_base)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = "compute",
		imageBarriers = {
			{
				image = image,
				srcAccessMask = "shader_write",
				dstAccessMask = "shader_read",
				oldLayout = "general",
				newLayout = "general",
				base_mip_level = 0,
				level_count = 1,
				layer_count = 1,
			},
		},
	}
	local reduce_pass = gpu_culling.main_view_hiz_reduce_pass

	for mip_level = 1, state.max_mip do
		local reduce_descriptor_slot = descriptor_base + mip_level
		reduce_pass:UpdateDescriptorSet(
			"storage_image",
			reduce_descriptor_slot,
			0,
			0,
			state.single_mip_views[mip_level]
		)
		reduce_pass:UpdateDescriptorSet(
			"storage_image",
			reduce_descriptor_slot,
			1,
			0,
			state.single_mip_views[mip_level + 1]
		)
		reduce_pass:DispatchForSize(
			cmd,
			math.max(1, math.floor((state.width + (2 ^ mip_level) - 1) / (2 ^ mip_level))),
			math.max(1, math.floor((state.height + (2 ^ mip_level) - 1) / (2 ^ mip_level))),
			1,
			reduce_descriptor_slot
		)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = "compute",
			imageBarriers = {
				{
					image = image,
					srcAccessMask = "shader_write",
					dstAccessMask = "shader_read",
					oldLayout = "general",
					newLayout = "general",
					base_mip_level = mip_level,
					level_count = 1,
					layer_count = 1,
				},
			},
		}
	end
end

local function get_main_view_hiz_frame_stamp(frame_index)
	return frame_index or render.GetCurrentFrame() or 1
end

local function get_main_view_hiz_descriptor_slot(frame_index)
	local slot = frame_index or render.GetCurrentFrame() or 1

	if slot < 1 then slot = 1 end

	return slot
end

local function ensure_main_view_hiz_built(cmd, descriptor_slot, frame_index, depth_texture, state)
	if not (cmd and depth_texture and state and state.texture) then return false end

	local frame_stamp = get_main_view_hiz_frame_stamp(frame_index)

	if
		state.last_built_frame_stamp == frame_stamp and
		state.last_built_depth_texture == depth_texture
	then
		return false
	end

	build_main_view_hiz(cmd, descriptor_slot, depth_texture, state)
	state.last_built_frame_stamp = frame_stamp
	state.last_built_depth_texture = depth_texture
	return true
end

function gpu_culling.PrepareMainViewHiZ(frame_index, cmd)
	local depth_texture, depth_view, depth_sampler, max_mip, state = get_main_view_occlusion_source()

	if gpu_culling.GetOcclusionMode() == "hiz" and depth_texture and state then
		ensure_main_view_hiz_built(
			cmd or render.GetCommandBuffer(),
			get_main_view_hiz_descriptor_slot(frame_index),
			frame_index,
			depth_texture,
			state
		)
	end

	return depth_texture, depth_view, depth_sampler, max_mip, state
end

function gpu_culling.IsEnabled()
	return gpu_culling.enabled
end

function gpu_culling.SetEnabled(enabled)
	gpu_culling.enabled = enabled == true
end

function gpu_culling.IsAsyncMainViewEnabled()
	return gpu_culling.async_main_view_enabled == true
end

function gpu_culling.SetAsyncMainViewEnabled(enabled)
	gpu_culling.async_main_view_enabled = enabled == true
end

function gpu_culling.GetOcclusionMode()
	return gpu_culling.occlusion_mode
end

function gpu_culling.SetOcclusionMode(mode)
	assert(VALID_OCCLUSION_MODES[mode], "invalid gpu culling occlusion mode: " .. tostring(mode))
	gpu_culling.occlusion_mode = mode
end

local function serialize_aabb(aabb)
	if not aabb then return nil end

	return {
		min_x = aabb.min_x,
		min_y = aabb.min_y,
		min_z = aabb.min_z,
		max_x = aabb.max_x,
		max_y = aabb.max_y,
		max_z = aabb.max_z,
	}
end

local function entry_has_height_displacement(material)
	return material and
		material.GetHeightTexture and
		material:GetHeightTexture() and
		material:GetHeightScale() > 0 or
		false
end

local function entry_uses_tessellated_displacement(material)
	return material and
		material.GetHeightTexture and
		material:GetHeightTexture() and
		material:GetHeightScale() > 0 and
		material.GetTessellationFactor and
		material:GetTessellationFactor() > 1.0 or
		false
end

local function entry_can_use_gbuffer_instancing(entry, material)
	if not material or entry_uses_tessellated_displacement(material) then
		return false
	end

	if material.GetIgnoreZ and material:GetIgnoreZ() then return false end

	local polygon3d = entry and entry.polygon3d or nil
	return polygon3d and polygon3d.GetMesh and polygon3d:GetMesh() ~= nil or false
end

local function entry_can_use_shadow_instancing(entry, material)
	if not material or entry_has_height_displacement(material) then
		return false
	end

	local polygon3d = entry and entry.polygon3d or nil
	return polygon3d and polygon3d.GetMesh and polygon3d:GetMesh() ~= nil or false
end

local function get_gbuffer_batch_material_key(material)
	return material and (material.upload_cache_key or material) or material
end

local function get_gbuffer_batch_mesh_keys(mesh)
	if not mesh or not mesh.vertex_buffer or not mesh.vertex_buffer.GetBuffer then
		return mesh, NO_INDEX_BUFFER_KEY
	end

	local vertex_buffer = mesh.vertex_buffer:GetBuffer()
	local index_buffer = mesh.index_buffer and mesh.index_buffer:GetBuffer() or NO_INDEX_BUFFER_KEY
	return vertex_buffer, index_buffer
end

local function get_or_create_instanced_batch_bucket(storage, mesh)
	local vertex_buffer_key, index_buffer_key = get_gbuffer_batch_mesh_keys(mesh)
	local vertex_buckets = storage[vertex_buffer_key]

	if not vertex_buckets then
		vertex_buckets = {}
		storage[vertex_buffer_key] = vertex_buckets
	end

	local mesh_buckets = vertex_buckets[index_buffer_key]

	if not mesh_buckets then
		mesh_buckets = {}
		vertex_buckets[index_buffer_key] = mesh_buckets
	end

	return mesh_buckets
end

local function ensure_entry_index_buffer(entry)
	local polygon3d = entry and entry.polygon3d or nil
	local mesh = polygon3d and polygon3d.GetMesh and polygon3d:GetMesh() or nil
	local index_buffer = mesh and mesh.index_buffer or nil

	if mesh and not index_buffer and mesh.GetVertexCount and mesh.UploadIndices then
		local vertex_count = mesh:GetVertexCount() or 0

		if vertex_count > 0 then
			local sequential_indices = {}

			for i = 1, vertex_count do
				sequential_indices[i] = i - 1
			end

			mesh:UploadIndices(sequential_indices)
			index_buffer = mesh.index_buffer
		end
	end

	return mesh, index_buffer
end

local function serialize_render_entry(component, entry, entry_index, dynamic)
	local material = component:GetResolvedMaterial(entry)
	local _, index_buffer = ensure_entry_index_buffer(entry)
	local world_matrix = entry.transform:GetWorldMatrix()
	return {
		component = component,
		source_entry = entry,
		entry_index = entry_index,
		polygon_guid = entry.polygon3d:GetGUID(),
		material_guid = material:GetGUID(),
		ignore_z = material and material.GetIgnoreZ and material:GetIgnoreZ() or false,
		has_height_displacement = entry_has_height_displacement(material),
		gbuffer_instancing_eligible = entry_can_use_gbuffer_instancing(entry, material),
		shadow_instancing_eligible = entry_can_use_shadow_instancing(entry, material),
		world_matrix = world_matrix,
		instanced_batch_index = nil,
		static_matrix_index = nil,
		source_aabb = serialize_aabb(entry.source_aabb),
		local_aabb = serialize_aabb(entry.aabb),
		index_count = index_buffer and index_buffer.GetIndexCount and index_buffer:GetIndexCount() or 0,
	}
end

local function serialize_component(component, dynamic)
	local owner = component and component.Owner
	local entries = component:GetRenderEntries()
	local serialized_entries = {}
	local shadow_aabb_cullable = true
	local world_aabb = serialize_aabb(component and component.GetWorldAABB and component:GetWorldAABB() or nil)
	local sphere_radius = 0

	if world_aabb then
		local extent_x = math.max((world_aabb.max_x or 0) - (world_aabb.min_x or 0), 0)
		local extent_y = math.max((world_aabb.max_y or 0) - (world_aabb.min_y or 0), 0)
		local extent_z = math.max((world_aabb.max_z or 0) - (world_aabb.min_z or 0), 0)
		sphere_radius = math.sqrt(extent_x * extent_x + extent_y * extent_y + extent_z * extent_z) * 0.5
	end

	for i, entry in ipairs(entries) do
		serialized_entries[i] = serialize_render_entry(component, entry, i, dynamic)

		if serialized_entries[i].has_height_displacement then
			shadow_aabb_cullable = false
		end
	end

	return {
		component = component,
		component_guid = component and component.GetGUID and component:GetGUID() or nil,
		owner = owner,
		owner_guid = owner and owner.GetGUID and owner:GetGUID() or nil,
		name = owner and owner.Name or tostring(component),
		dynamic = dynamic == true,
		visible = component and component.Visible == true,
		cast_shadows = component and component.CastShadows == true,
		use_occlusion_culling = component and component.UseOcclusionCulling == true,
		cull_distance = component and component.GetCullDistance and component:GetCullDistance() or nil,
		model_path = component and component.GetModelPath and component:GetModelPath() or "",
		shadow_change_version = component and component.shadow_change_version or 0,
		world_aabb = world_aabb,
		sphere_radius = sphere_radius,
		shadow_aabb_cullable = shadow_aabb_cullable,
		render_entry_count = #serialized_entries,
		entries = serialized_entries,
	}
end

local function assign_component_entry_span(component, offset_field, count_field, entry_offset, entry_count)
	if not component then return end

	component[offset_field] = entry_offset
	component[count_field] = entry_count
end

local function serialize_bvh_node(node, out_nodes)
	if not node then return nil end

	local node_index = #out_nodes + 1
	out_nodes[node_index] = {
		aabb = serialize_aabb(node.aabb),
		first = node.first,
		last = node.last,
		max_cull_distance = node.max_cull_distance or 0,
		max_shadow_change_version = node.max_shadow_change_version or 0,
		left_index = nil,
		right_index = nil,
		is_leaf = node.first ~= nil,
	}

	if not node.first then
		out_nodes[node_index].left_index = serialize_bvh_node(node.left, out_nodes)
		out_nodes[node_index].right_index = serialize_bvh_node(node.right, out_nodes)
	end

	return node_index
end

local function serialize_bvh(tree)
	if not (tree and tree.root) then return nil end

	local nodes = {}
	local root_index = serialize_bvh_node(tree.root, nodes)
	return {
		root_index = root_index,
		node_count = #nodes,
		nodes = nodes,
	}
end

local function build_scene_dataset(acceleration)
	if not acceleration then return nil end

	local dataset = {
		generation = gpu_culling.scene_acceleration_generation,
		main_visuals = {},
		main_entries = {},
		shadow_entries = {},
		static_visuals = {},
		dynamic_visuals = {},
		shadow_static_visuals = {},
		shadow_dynamic_visuals = {},
		non_aabb_shadow_visuals = {},
		static_visual_count = 0,
		dynamic_visual_count = 0,
		shadow_static_visual_count = 0,
		shadow_dynamic_visual_count = 0,
		non_aabb_shadow_visual_count = 0,
		static_entry_count = 0,
		dynamic_entry_count = 0,
		shadow_entry_count = 0,
		static_bvh = nil,
		shadow_bvh = nil,
		main_instanced_batches = {},
		main_static_instance_count = 0,
		main_static_instance_prefix_count = 0,
		shadow_instanced_batches = {},
		shadow_instance_count = 0,
		shadow_instance_world_change_version = 0,
		total_visual_count = acceleration.visual_count or 0,
	}

	for i, item in ipairs(acceleration.items or {}) do
		local component = item.component
		local entry_offset = #dataset.main_entries
		local serialized = serialize_component(component, false)
		dataset.static_visuals[i] = serialized
		dataset.main_visuals[#dataset.main_visuals + 1] = serialized

		for _, entry in ipairs(serialized.entries) do
			dataset.main_entries[#dataset.main_entries + 1] = entry
		end

		assign_component_entry_span(
			component,
			"main_gpu_entry_offset",
			"main_gpu_entry_count",
			entry_offset,
			serialized.render_entry_count
		)
		dataset.static_visual_count = dataset.static_visual_count + 1
		dataset.static_entry_count = dataset.static_entry_count + serialized.render_entry_count
	end

	for i, component in ipairs(acceleration.dynamic_components or {}) do
		local entry_offset = #dataset.main_entries
		local serialized = serialize_component(component, true)
		dataset.dynamic_visuals[i] = serialized
		dataset.main_visuals[#dataset.main_visuals + 1] = serialized

		for _, entry in ipairs(serialized.entries) do
			dataset.main_entries[#dataset.main_entries + 1] = entry
		end

		assign_component_entry_span(
			component,
			"main_gpu_entry_offset",
			"main_gpu_entry_count",
			entry_offset,
			serialized.render_entry_count
		)
		dataset.dynamic_visual_count = dataset.dynamic_visual_count + 1
		dataset.dynamic_entry_count = dataset.dynamic_entry_count + serialized.render_entry_count
	end

	for i, item in ipairs(acceleration.shadow_items or {}) do
		local component = item.component
		local entry_offset = #dataset.shadow_entries
		local serialized = serialize_component(component, false)
		dataset.shadow_static_visuals[i] = serialized

		for _, entry in ipairs(serialized.entries) do
			dataset.shadow_entries[#dataset.shadow_entries + 1] = entry
		end

		assign_component_entry_span(
			component,
			"shadow_gpu_entry_offset",
			"shadow_gpu_entry_count",
			entry_offset,
			serialized.render_entry_count
		)
		dataset.shadow_static_visual_count = dataset.shadow_static_visual_count + 1
		dataset.shadow_entry_count = dataset.shadow_entry_count + serialized.render_entry_count
	end

	for i, component in ipairs(acceleration.dynamic_shadow_components or {}) do
		local entry_offset = #dataset.shadow_entries
		local serialized = serialize_component(component, true)
		dataset.shadow_dynamic_visuals[i] = serialized

		for _, entry in ipairs(serialized.entries) do
			dataset.shadow_entries[#dataset.shadow_entries + 1] = entry
		end

		assign_component_entry_span(
			component,
			"shadow_gpu_entry_offset",
			"shadow_gpu_entry_count",
			entry_offset,
			serialized.render_entry_count
		)
		dataset.shadow_dynamic_visual_count = dataset.shadow_dynamic_visual_count + 1
		dataset.shadow_entry_count = dataset.shadow_entry_count + serialized.render_entry_count
	end

	for i, component in ipairs(acceleration.non_aabb_shadow_components or {}) do
		local entry_offset = #dataset.shadow_entries
		local serialized = serialize_component(component, true)
		dataset.non_aabb_shadow_visuals[i] = serialized

		for _, entry in ipairs(serialized.entries) do
			dataset.shadow_entries[#dataset.shadow_entries + 1] = entry
		end

		assign_component_entry_span(
			component,
			"shadow_gpu_entry_offset",
			"shadow_gpu_entry_count",
			entry_offset,
			serialized.render_entry_count
		)
		dataset.non_aabb_shadow_visual_count = dataset.non_aabb_shadow_visual_count + 1
		dataset.shadow_entry_count = dataset.shadow_entry_count + serialized.render_entry_count
	end

	dataset.static_bvh = serialize_bvh(acceleration.tree)
	dataset.shadow_bvh = serialize_bvh(acceleration.shadow_tree)

	do
		local batches = {}
		local instance_offset = 0

		for _, visual in ipairs(dataset.static_visuals) do
			for _, entry in ipairs(visual.entries or {}) do
				if entry.gbuffer_instancing_eligible and entry.world_matrix then
					local polygon3d = entry.source_entry and entry.source_entry.polygon3d or nil
					local mesh = polygon3d and polygon3d.GetMesh and polygon3d:GetMesh() or nil
					local material = entry.source_entry and
						visual.component:GetResolvedMaterial(entry.source_entry) or
						nil
					local mesh_batches = get_or_create_instanced_batch_bucket(batches, mesh)
					local material_key = get_gbuffer_batch_material_key(material)
					local batch = mesh_batches[material_key]

					if not batch then
						batch = {
							batch_index = #dataset.main_instanced_batches,
							mesh = mesh,
							material = material,
							material_key = material_key,
							first_polygon3d = polygon3d,
							output_offset = 0,
							max_count = 0,
						}
						mesh_batches[material_key] = batch
						dataset.main_instanced_batches[#dataset.main_instanced_batches + 1] = batch
					end

					entry.instanced_batch_index = batch.batch_index
					entry.static_matrix_index = dataset.main_static_instance_count
					batch.max_count = batch.max_count + 1
					dataset.main_static_instance_count = dataset.main_static_instance_count + 1
				end
			end
		end

		for _, batch in ipairs(dataset.main_instanced_batches) do
			batch.output_offset = instance_offset
			instance_offset = instance_offset + batch.max_count
		end

		dataset.main_static_instance_prefix_count = dataset.main_static_instance_count
	end

	do
		local batches = {}

		for _, batch in ipairs(dataset.main_instanced_batches) do
			local mesh_batches = get_or_create_instanced_batch_bucket(batches, batch.mesh)
			mesh_batches[batch.material_key or
			get_gbuffer_batch_material_key(batch.material)] = batch
		end

		for _, visual in ipairs(dataset.dynamic_visuals) do
			for _, entry in ipairs(visual.entries or {}) do
				if entry.gbuffer_instancing_eligible and entry.world_matrix then
					local polygon3d = entry.source_entry and entry.source_entry.polygon3d or nil
					local mesh = polygon3d and polygon3d.GetMesh and polygon3d:GetMesh() or nil
					local material = entry.source_entry and
						visual.component:GetResolvedMaterial(entry.source_entry) or
						nil
					local mesh_batches = get_or_create_instanced_batch_bucket(batches, mesh)
					local material_key = get_gbuffer_batch_material_key(material)
					local batch = mesh_batches[material_key]

					if not batch then
						batch = {
							batch_index = #dataset.main_instanced_batches,
							mesh = mesh,
							material = material,
							material_key = material_key,
							first_polygon3d = polygon3d,
							output_offset = 0,
							max_count = 0,
						}
						mesh_batches[material_key] = batch
						dataset.main_instanced_batches[#dataset.main_instanced_batches + 1] = batch
					end

					entry.instanced_batch_index = batch.batch_index
					entry.static_matrix_index = dataset.main_static_instance_count
					batch.max_count = batch.max_count + 1
					dataset.main_static_instance_count = dataset.main_static_instance_count + 1
				end
			end
		end

		local instance_offset = 0

		for _, batch in ipairs(dataset.main_instanced_batches) do
			batch.output_offset = instance_offset
			instance_offset = instance_offset + batch.max_count
		end
	end

	do
		local batches = {}
		local instance_offset = 0

		for _, visual in ipairs(dataset.shadow_static_visuals) do
			for _, entry in ipairs(visual.entries or {}) do
				if entry.shadow_instancing_eligible then
					local polygon3d = entry.source_entry and entry.source_entry.polygon3d or nil
					local mesh = polygon3d and polygon3d.GetMesh and polygon3d:GetMesh() or nil
					local material = entry.source_entry and
						visual.component:GetResolvedMaterial(entry.source_entry) or
						nil
					local mesh_batches = get_or_create_instanced_batch_bucket(batches, mesh)
					local material_key = get_gbuffer_batch_material_key(material)
					local batch = mesh_batches[material_key]

					if not batch then
						batch = {
							batch_index = #dataset.shadow_instanced_batches,
							mesh = mesh,
							material = material,
							material_key = material_key,
							first_polygon3d = polygon3d,
							first_world_matrix = entry.world_matrix,
							output_offset = 0,
							max_count = 0,
							entries = {},
						}
						mesh_batches[material_key] = batch
						dataset.shadow_instanced_batches[#dataset.shadow_instanced_batches + 1] = batch
					end

					entry.instanced_batch_index = batch.batch_index
					entry.static_matrix_index = dataset.shadow_instance_count
					batch.max_count = batch.max_count + 1
					batch.entries[#batch.entries + 1] = entry
					dataset.shadow_instance_count = dataset.shadow_instance_count + 1
					dataset.shadow_instance_world_change_version = math.max(dataset.shadow_instance_world_change_version, visual.shadow_change_version or 0)
				end
			end
		end

		for _, visual in ipairs(dataset.shadow_dynamic_visuals) do
			for _, entry in ipairs(visual.entries or {}) do
				if entry.shadow_instancing_eligible then
					local polygon3d = entry.source_entry and entry.source_entry.polygon3d or nil
					local mesh = polygon3d and polygon3d.GetMesh and polygon3d:GetMesh() or nil
					local material = entry.source_entry and
						visual.component:GetResolvedMaterial(entry.source_entry) or
						nil
					local mesh_batches = get_or_create_instanced_batch_bucket(batches, mesh)
					local material_key = get_gbuffer_batch_material_key(material)
					local batch = mesh_batches[material_key]

					if not batch then
						batch = {
							batch_index = #dataset.shadow_instanced_batches,
							mesh = mesh,
							material = material,
							material_key = material_key,
							first_polygon3d = polygon3d,
							first_world_matrix = entry.world_matrix,
							output_offset = 0,
							max_count = 0,
							entries = {},
						}
						mesh_batches[material_key] = batch
						dataset.shadow_instanced_batches[#dataset.shadow_instanced_batches + 1] = batch
					end

					entry.instanced_batch_index = batch.batch_index
					entry.static_matrix_index = dataset.shadow_instance_count
					batch.max_count = batch.max_count + 1
					batch.entries[#batch.entries + 1] = entry
					dataset.shadow_instance_count = dataset.shadow_instance_count + 1
					dataset.shadow_instance_world_change_version = math.max(dataset.shadow_instance_world_change_version, visual.shadow_change_version or 0)
				end
			end
		end

		for _, batch in ipairs(dataset.shadow_instanced_batches) do
			batch.output_offset = instance_offset
			instance_offset = instance_offset + batch.max_count
		end
	end

	return dataset
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

local cache = {}

local function new_ffi_array(ctype, count)
	cache[ctype] = cache[ctype] or {}
	cache[ctype][count] = cache[ctype][count] or ffi.typeof("$[?]", ctype)
	return ffi.new(cache[ctype][count], math.max(count, 1))
end

local function set_record_aabb(record, min_prefix, max_prefix, aabb)
	aabb = aabb or {}
	record[min_prefix .. "x"] = aabb.min_x or 0
	record[min_prefix .. "y"] = aabb.min_y or 0
	record[min_prefix .. "z"] = aabb.min_z or 0
	record[max_prefix .. "x"] = aabb.max_x or 0
	record[max_prefix .. "y"] = aabb.max_y or 0
	record[max_prefix .. "z"] = aabb.max_z or 0
end

local function get_visual_flags(serialized_visual, extra_flags)
	local flags = extra_flags or 0

	if serialized_visual.visible then flags = flags + VISUAL_FLAG_VISIBLE end

	if serialized_visual.cast_shadows then
		flags = flags + VISUAL_FLAG_CAST_SHADOWS
	end

	if serialized_visual.use_occlusion_culling then
		flags = flags + VISUAL_FLAG_USE_OCCLUSION
	end

	if serialized_visual.dynamic then flags = flags + VISUAL_FLAG_DYNAMIC end

	if serialized_visual.shadow_aabb_cullable then
		flags = flags + VISUAL_FLAG_SHADOW_AABB_CULLABLE
	end

	return flags
end

local function get_entry_flags(entry)
	local flags = 0

	if entry.ignore_z then flags = flags + ENTRY_FLAG_IGNORE_Z end

	if entry.has_height_displacement then
		flags = flags + ENTRY_FLAG_HEIGHT_DISPLACEMENT
	end

	return flags
end

local function flatten_visual_upload(visuals, extra_flags)
	local visual_records = new_ffi_array(GPUCullVisualRecord, #visuals)
	local entry_count = 0

	for _, visual in ipairs(visuals) do
		entry_count = entry_count + (visual.render_entry_count or 0)
	end

	local entry_records = new_ffi_array(GPUCullEntryRecord, entry_count)
	local entry_offset = 0

	for visual_index, visual in ipairs(visuals) do
		local visual_record = visual_records[visual_index - 1]
		set_record_aabb(visual_record, "min_", "max_", visual.world_aabb)
		visual_record.sphere_radius = visual.sphere_radius or 0
		visual_record.cull_distance = visual.cull_distance or 0
		visual_record.flags = get_visual_flags(visual, extra_flags)
		visual_record.entry_offset = entry_offset
		visual_record.entry_count = visual.render_entry_count or 0
		visual_record.shadow_change_version = visual.shadow_change_version or 0

		for entry_index, entry in ipairs(visual.entries or {}) do
			local entry_record = entry_records[entry_offset]
			set_record_aabb(entry_record, "local_min_", "local_max_", entry.local_aabb)
			set_record_aabb(entry_record, "source_min_", "source_max_", entry.source_aabb)
			entry_record.visual_index = visual_index - 1
			entry_record.entry_index = (entry.entry_index or entry_index) - 1
			entry_record.index_count = entry.index_count or 0
			entry_record.flags = get_entry_flags(entry)
			entry_record.instanced_batch_index = entry.instanced_batch_index or INVALID_INDEX
			entry_record.static_matrix_index = entry.static_matrix_index or INVALID_INDEX
			entry_offset = entry_offset + 1
		end
	end

	return {
		visual_records = visual_records,
		visual_count = #visuals,
		visual_byte_size = math.max(#visuals, 1) * ffi.sizeof(GPUCullVisualRecord),
		entry_records = entry_records,
		entry_count = entry_count,
		entry_byte_size = math.max(entry_count, 1) * ffi.sizeof(GPUCullEntryRecord),
	}
end

local function flatten_static_instance_world_upload(dataset)
	local entry_count = dataset.main_static_instance_count or 0
	local world_matrices = ffi.new("float[?]", math.max(entry_count * 16, 16))

	for _, visual in ipairs(dataset.static_visuals or {}) do
		for _, entry in ipairs(visual.entries or {}) do
			if entry.static_matrix_index ~= nil and entry.world_matrix then
				entry.world_matrix:CopyToFloatPointer(world_matrices + entry.static_matrix_index * 16)
			end
		end
	end

	for _, visual in ipairs(dataset.dynamic_visuals or {}) do
		for _, entry in ipairs(visual.entries or {}) do
			if entry.static_matrix_index ~= nil and entry.world_matrix then
				entry.world_matrix:CopyToFloatPointer(world_matrices + entry.static_matrix_index * 16)
			end
		end
	end

	return {
		world_matrices = world_matrices,
		entry_count = entry_count,
		byte_size = math.max(entry_count * 16, 16) * ffi.sizeof("float"),
	}
end

local function flatten_shadow_instance_world_upload(dataset)
	local entry_count = dataset.shadow_instance_count or 0
	local world_matrices = ffi.new("float[?]", math.max(entry_count * 16, 16))

	for _, visual in ipairs(dataset.shadow_static_visuals or {}) do
		for _, entry in ipairs(visual.entries or {}) do
			if entry.static_matrix_index ~= nil and entry.world_matrix then
				entry.world_matrix:CopyToFloatPointer(world_matrices + entry.static_matrix_index * 16)
			end
		end
	end

	for _, visual in ipairs(dataset.shadow_dynamic_visuals or {}) do
		for _, entry in ipairs(visual.entries or {}) do
			if entry.static_matrix_index ~= nil and entry.world_matrix then
				entry.world_matrix:CopyToFloatPointer(world_matrices + entry.static_matrix_index * 16)
			end
		end
	end

	return {
		world_matrices = world_matrices,
		entry_count = entry_count,
		byte_size = math.max(entry_count * 16, 16) * ffi.sizeof("float"),
	}
end

local function flatten_instanced_batch_upload(dataset)
	local batch_count = #(dataset.main_instanced_batches or {})
	local batch_records = new_ffi_array(GPUCullInstancedBatchRecord, batch_count)

	for batch_index, batch in ipairs(dataset.main_instanced_batches or {}) do
		local batch_record = batch_records[batch_index - 1]
		batch_record.output_offset = batch.output_offset or 0
		batch_record.max_count = batch.max_count or 0
		batch_record.index_count = batch.mesh and
			batch.mesh.index_buffer and
			batch.mesh.index_buffer.GetIndexCount and
			batch.mesh.index_buffer:GetIndexCount() or
			0
		batch_record.reserved1 = 0
	end

	return {
		batch_records = batch_records,
		batch_count = batch_count,
		byte_size = math.max(batch_count, 1) * ffi.sizeof(GPUCullInstancedBatchRecord),
	}
end

local function flatten_shadow_instanced_batch_upload(dataset)
	local batch_count = #(dataset.shadow_instanced_batches or {})
	local batch_records = new_ffi_array(GPUCullInstancedBatchRecord, batch_count)

	for batch_index, batch in ipairs(dataset.shadow_instanced_batches or {}) do
		local batch_record = batch_records[batch_index - 1]
		batch_record.output_offset = batch.output_offset or 0
		batch_record.max_count = batch.max_count or 0
		batch_record.index_count = batch.mesh and
			batch.mesh.index_buffer and
			batch.mesh.index_buffer.GetIndexCount and
			batch.mesh.index_buffer:GetIndexCount() or
			0
		batch_record.reserved1 = 0
	end

	return {
		batch_records = batch_records,
		batch_count = batch_count,
		byte_size = math.max(batch_count, 1) * ffi.sizeof(GPUCullInstancedBatchRecord),
	}
end

local function flatten_bvh_upload(serialized_bvh)
	local nodes = serialized_bvh and serialized_bvh.nodes or {}
	local node_records = new_ffi_array(GPUCullNodeRecord, #nodes)

	for node_index, node in ipairs(nodes) do
		local node_record = node_records[node_index - 1]
		set_record_aabb(node_record, "min_", "max_", node.aabb)
		node_record.max_cull_distance = node.max_cull_distance or 0
		node_record.first = node.first and (node.first - 1) or INVALID_INDEX
		node_record.last = node.last and (node.last - 1) or INVALID_INDEX
		node_record.left_index = node.left_index and (node.left_index - 1) or INVALID_INDEX
		node_record.right_index = node.right_index and (node.right_index - 1) or INVALID_INDEX
		node_record.flags = node.is_leaf and NODE_FLAG_LEAF or 0
		node_record.max_shadow_change_version = node.max_shadow_change_version or 0
	end

	return {
		node_records = node_records,
		node_count = #nodes,
		node_byte_size = math.max(#nodes, 1) * ffi.sizeof(GPUCullNodeRecord),
		root_index = serialized_bvh and
			serialized_bvh.root_index and
			(
				serialized_bvh.root_index - 1
			)
			or
			INVALID_INDEX,
	}
end

local function build_dataset_upload(dataset)
	if not dataset then return nil end

	local main_visuals = {}

	for _, visual in ipairs(dataset.static_visuals or {}) do
		main_visuals[#main_visuals + 1] = visual
	end

	for _, visual in ipairs(dataset.dynamic_visuals or {}) do
		main_visuals[#main_visuals + 1] = visual
	end

	local shadow_visuals = {}

	for _, visual in ipairs(dataset.shadow_static_visuals or {}) do
		shadow_visuals[#shadow_visuals + 1] = visual
	end

	for _, visual in ipairs(dataset.shadow_dynamic_visuals or {}) do
		shadow_visuals[#shadow_visuals + 1] = visual
	end

	for _, visual in ipairs(dataset.non_aabb_shadow_visuals or {}) do
		shadow_visuals[#shadow_visuals + 1] = visual
	end

	return {
		main = flatten_visual_upload(main_visuals),
		shadow = flatten_visual_upload(shadow_visuals, VISUAL_FLAG_SHADOW_NON_AABB),
		main_static_instance_worlds = flatten_static_instance_world_upload(dataset),
		main_instanced_batches = flatten_instanced_batch_upload(dataset),
		shadow_instance_worlds = flatten_shadow_instance_world_upload(dataset),
		shadow_instanced_batches = flatten_shadow_instanced_batch_upload(dataset),
		static_bvh = flatten_bvh_upload(dataset.static_bvh),
		shadow_bvh = flatten_bvh_upload(dataset.shadow_bvh),
		layout = {
			generation = dataset.generation,
			main_visual_count = #main_visuals,
			main_entry_count = (dataset.static_entry_count or 0) + (dataset.dynamic_entry_count or 0),
			main_instanced_batch_count = #(dataset.main_instanced_batches or {}),
			main_static_instance_count = dataset.main_static_instance_count or 0,
			shadow_visual_count = #shadow_visuals,
			shadow_static_visual_count = dataset.shadow_static_visual_count or 0,
			shadow_entry_count = dataset.shadow_entry_count or 0,
			shadow_instanced_batch_count = #(dataset.shadow_instanced_batches or {}),
			shadow_instance_count = dataset.shadow_instance_count or 0,
			static_bvh_node_count = dataset.static_bvh and dataset.static_bvh.node_count or 0,
			static_bvh_root_index = dataset.static_bvh and (dataset.static_bvh.root_index - 1) or INVALID_INDEX,
			shadow_bvh_node_count = dataset.shadow_bvh and dataset.shadow_bvh.node_count or 0,
			shadow_bvh_root_index = dataset.shadow_bvh and (dataset.shadow_bvh.root_index - 1) or INVALID_INDEX,
		},
	}
end

local function remove_buffer(buffer)
	if buffer and buffer.Remove then buffer:Remove() end
end

local function clear_dataset_buffers()
	local dataset_buffers = gpu_culling.dataset_buffers

	if dataset_buffers then
		remove_buffer(dataset_buffers.main_visual_buffer)
		remove_buffer(dataset_buffers.main_entry_buffer)
		remove_buffer(dataset_buffers.main_static_instance_world_buffer)
		remove_buffer(dataset_buffers.main_instanced_batch_buffer)
		remove_buffer(dataset_buffers.shadow_visual_buffer)
		remove_buffer(dataset_buffers.shadow_entry_buffer)
		remove_buffer(dataset_buffers.shadow_instanced_batch_buffer)
		remove_buffer(dataset_buffers.static_bvh_node_buffer)
		remove_buffer(dataset_buffers.shadow_bvh_node_buffer)
	end

	gpu_culling.dataset_buffers = nil
	gpu_culling.dataset_buffers_generation = -1
end

local function clear_frame_buffers()
	for _, frame_buffers in ipairs(gpu_culling.frame_buffers or {}) do
		remove_buffer(frame_buffers.visible_index_buffer)
		remove_buffer(frame_buffers.fallback_visible_index_buffer)
		remove_buffer(frame_buffers.fallback_visible_count_buffer)
		remove_buffer(frame_buffers.main_instance_world_buffer)
		remove_buffer(frame_buffers.shadow_instance_world_buffer)
		remove_buffer(frame_buffers.indirect_command_buffer)
		remove_buffer(frame_buffers.indirect_count_buffer)
		remove_buffer(frame_buffers.visible_instanced_batch_count_buffer)
		remove_buffer(frame_buffers.visible_batch_indirect_command_buffer)
		remove_buffer(frame_buffers.active_batch_index_buffer)
		remove_buffer(frame_buffers.active_batch_count_buffer)

		if frame_buffers.visible_instance_vertex_buffer then
			frame_buffers.visible_instance_vertex_buffer:Remove()
		end

		if frame_buffers.main_view_cull_cmd then
			frame_buffers.main_view_cull_cmd:Remove()
		end

		if frame_buffers.main_view_cull_fence then
			frame_buffers.main_view_cull_fence:Remove()
		end
	end

	gpu_culling.frame_buffers = nil
	gpu_culling.frame_buffers_generation = -1
	gpu_culling.main_view_async_slot_index = nil
end

local function create_buffer(label, byte_size, usage, data)
	return render.CreateBuffer{
		byte_size = byte_size,
		buffer_usage = usage,
		memory_property = {"host_visible", "host_coherent"},
		label = label,
		data = data,
	}
end

local function ensure_shadow_query_output_descriptor_capacity(descriptor_slot)
	descriptor_slot = math.max(tonumber(descriptor_slot) or 1, 1)

	if descriptor_slot > (gpu_culling.shadow_query_output_descriptor_count or 0) then
		gpu_culling.shadow_query_output_descriptor_count = descriptor_slot

		if gpu_culling.shadow_view_aabb_cull_pass then
			gpu_culling.shadow_view_aabb_cull_pass:Remove()
		end

		gpu_culling.shadow_view_aabb_cull_pass = nil
	end

	return descriptor_slot
end

local function allocate_shadow_query_output_descriptor_slot()
	local descriptor_slot = (gpu_culling.next_shadow_query_output_descriptor_slot or 0) + 1
	gpu_culling.next_shadow_query_output_descriptor_slot = descriptor_slot
	return ensure_shadow_query_output_descriptor_capacity(descriptor_slot)
end

local function create_shadow_query_output(
	label_prefix,
	shadow_entry_capacity,
	shadow_instanced_batch_count,
	shadow_instance_capacity,
	descriptor_slot
)
	local layout = gpu_culling.dataset_buffers and gpu_culling.dataset_buffers.layout or nil
	shadow_entry_capacity = math.max(shadow_entry_capacity or (layout and layout.shadow_entry_count) or 0, 1)
	shadow_instanced_batch_count = math.max(
		shadow_instanced_batch_count or
			(
				layout and
				layout.shadow_instanced_batch_count
			)
			or
			0,
		1
	)
	shadow_instance_capacity = math.max(shadow_instance_capacity or (layout and layout.shadow_instance_count) or 0, 1)
	label_prefix = label_prefix or "gpu_culling_shadow_query"
	descriptor_slot = descriptor_slot and
		ensure_shadow_query_output_descriptor_capacity(descriptor_slot) or
		allocate_shadow_query_output_descriptor_slot()
	return {
		descriptor_slot = descriptor_slot,
		shadow_entry_capacity = shadow_entry_capacity,
		shadow_instanced_batch_count = shadow_instanced_batch_count,
		shadow_instance_capacity = shadow_instance_capacity,
		shadow_visible_index_buffer = create_buffer(
			label_prefix .. "_visible_indices",
			shadow_entry_capacity * UINT32_SIZE,
			{"storage_buffer"}
		),
		shadow_visible_count_buffer = create_buffer(label_prefix .. "_visible_count", UINT32_SIZE, {"storage_buffer"}),
		shadow_fallback_visible_index_buffer = create_buffer(
			label_prefix .. "_fallback_visible_indices",
			shadow_entry_capacity * UINT32_SIZE,
			{"storage_buffer"}
		),
		shadow_fallback_visible_count_buffer = create_buffer(label_prefix .. "_fallback_visible_count", UINT32_SIZE, {"storage_buffer"}),
		shadow_active_batch_index_buffer = create_buffer(
			label_prefix .. "_active_batch_indices",
			shadow_instanced_batch_count * UINT32_SIZE,
			{"storage_buffer"}
		),
		shadow_active_batch_count_buffer = create_buffer(label_prefix .. "_active_batch_count", UINT32_SIZE, {"storage_buffer"}),
		shadow_visible_instanced_batch_count_zero_data = ffi.new("uint32_t[?]", shadow_instanced_batch_count),
		shadow_visible_instanced_batch_count_buffer = create_buffer(
			label_prefix .. "_visible_instanced_batch_counts",
			shadow_instanced_batch_count * UINT32_SIZE,
			{"storage_buffer"}
		),
		shadow_visible_batch_indirect_zero_data = ffi.new(
			"uint8_t[?]",
			math.max(shadow_instanced_batch_count * DRAW_INDEXED_INDIRECT_COMMAND_SIZE, 1)
		),
		shadow_visible_batch_indirect_command_buffer = create_buffer(
			label_prefix .. "_visible_batch_indirect_commands",
			shadow_instanced_batch_count * DRAW_INDEXED_INDIRECT_COMMAND_SIZE,
			{"storage_buffer", "indirect_buffer"}
		),
		shadow_visible_instance_vertex_buffer = VertexBuffer.New(
			shadow_instance_capacity,
			{
				{
					lua_name = "instance_world",
					lua_type = float16,
					offset = 0,
				},
			},
			label_prefix .. "_visible_instances"
		),
	}
end

local function remove_shadow_query_output(output)
	if not output then return end

	remove_buffer(output.shadow_visible_index_buffer)
	remove_buffer(output.shadow_visible_count_buffer)
	remove_buffer(output.shadow_fallback_visible_index_buffer)
	remove_buffer(output.shadow_fallback_visible_count_buffer)
	remove_buffer(output.shadow_active_batch_index_buffer)
	remove_buffer(output.shadow_active_batch_count_buffer)
	remove_buffer(output.shadow_visible_instanced_batch_count_buffer)
	remove_buffer(output.shadow_visible_batch_indirect_command_buffer)

	if output.shadow_visible_instance_vertex_buffer then
		output.shadow_visible_instance_vertex_buffer:Remove()
	end
end

function gpu_culling.CreateShadowQueryOutput(
	label_prefix,
	shadow_entry_capacity,
	shadow_instanced_batch_count,
	shadow_instance_capacity,
	descriptor_slot
)
	return create_shadow_query_output(
		label_prefix,
		shadow_entry_capacity,
		shadow_instanced_batch_count,
		shadow_instance_capacity,
		descriptor_slot
	)
end

function gpu_culling.RemoveShadowQueryOutput(output)
	remove_shadow_query_output(output)
end

local function build_dataset_buffers(dataset)
	if not dataset then return nil end

	local device = render.GetDevice and render.GetDevice() or nil

	if not (device and device.IsValid and device:IsValid()) then return nil end

	local upload = build_dataset_upload(dataset)
	return {
		generation = dataset.generation,
		layout = upload.layout,
		main_visual_buffer = create_buffer(
			"gpu_culling_main_visual_upload",
			upload.main.visual_byte_size,
			{"storage_buffer"},
			upload.main.visual_records
		),
		main_entry_buffer = create_buffer(
			"gpu_culling_main_entry_upload",
			upload.main.entry_byte_size,
			{"storage_buffer"},
			upload.main.entry_records
		),
		main_static_instance_world_buffer = create_buffer(
			"gpu_culling_main_static_instance_world_upload",
			upload.main_static_instance_worlds.byte_size,
			{"storage_buffer"},
			upload.main_static_instance_worlds.world_matrices
		),
		main_instanced_batch_buffer = create_buffer(
			"gpu_culling_main_instanced_batch_upload",
			upload.main_instanced_batches.byte_size,
			{"storage_buffer"},
			upload.main_instanced_batches.batch_records
		),
		shadow_visual_buffer = create_buffer(
			"gpu_culling_shadow_visual_upload",
			upload.shadow.visual_byte_size,
			{"storage_buffer"},
			upload.shadow.visual_records
		),
		shadow_entry_buffer = create_buffer(
			"gpu_culling_shadow_entry_upload",
			upload.shadow.entry_byte_size,
			{"storage_buffer"},
			upload.shadow.entry_records
		),
		shadow_instanced_batch_buffer = create_buffer(
			"gpu_culling_shadow_instanced_batch_upload",
			upload.shadow_instanced_batches.byte_size,
			{"storage_buffer"},
			upload.shadow_instanced_batches.batch_records
		),
		static_bvh_node_buffer = create_buffer(
			"gpu_culling_static_bvh_upload",
			upload.static_bvh.node_byte_size,
			{"storage_buffer"},
			upload.static_bvh.node_records
		),
		shadow_bvh_node_buffer = create_buffer(
			"gpu_culling_shadow_bvh_upload",
			upload.shadow_bvh.node_byte_size,
			{"storage_buffer"},
			upload.shadow_bvh.node_records
		),
	}
end

local function resolve_frame_slot(frame_index)
	local frame_count = math.max(render.GetSwapchainImageCount() or 1, 1)
	local slot = frame_index or render.GetCurrentFrame() or 1

	if slot < 1 then slot = 1 end

	if slot > frame_count then slot = ((slot - 1) % frame_count) + 1 end

	return slot
end

local function update_cull_result(
	result,
	frame_index,
	visible_count,
	visible_entry_index_ptr,
	fallback_visible_entry_count,
	fallback_visible_entry_index_ptr,
	indirect_command_count,
	visible_entry_indices_ready
)
	result.frame_index = frame_index
	result.visible_count = visible_count
	result.visible_indices = nil
	result.visible_entry_count = visible_count
	result.visible_entry_index_ptr = visible_entry_index_ptr
	result.visible_entry_indices = nil
	result.fallback_visible_entry_count = fallback_visible_entry_count or 0
	result.fallback_visible_entry_index_ptr = fallback_visible_entry_index_ptr
	result.fallback_visible_entry_indices = nil
	result.indirect_command_count = indirect_command_count
	result.visible_entry_indices_ready = visible_entry_indices_ready == true
	return result
end

local function ensure_dataset_buffers(dataset)
	if not dataset then
		clear_dataset_buffers()
		return nil
	end

	if
		gpu_culling.dataset_buffers_generation == dataset.generation and
		gpu_culling.dataset_buffers
	then
		return gpu_culling.dataset_buffers
	end

	clear_dataset_buffers()
	gpu_culling.dataset_buffers = build_dataset_buffers(dataset)
	gpu_culling.dataset_buffers_generation = gpu_culling.dataset_buffers and dataset.generation or -1
	return gpu_culling.dataset_buffers
end

local function build_frame_buffers(dataset)
	if not dataset then return nil end

	local device = render.GetDevice and render.GetDevice() or nil

	if not (device and device.IsValid and device:IsValid()) then return nil end

	local frame_count = math.max(render.GetSwapchainImageCount and render.GetSwapchainImageCount() or 1, 1)
	local total_slot_count = frame_count + 1
	local visible_entry_capacity = math.max((dataset.static_entry_count or 0) + (dataset.dynamic_entry_count or 0), 1)
	local instanced_batch_count = math.max(#(dataset.main_instanced_batches or {}), 1)
	local static_instance_capacity = math.max(dataset.main_static_instance_count or 0, 1)
	local shadow_instance_capacity = math.max(dataset.shadow_instance_count or 0, 1)
	local frame_buffers = {}

	for frame_index = 1, total_slot_count do
		frame_buffers[frame_index] = {
			frame_index = frame_index,
			visible_entry_capacity = visible_entry_capacity,
			visible_index_buffer = create_buffer(
				"gpu_culling_visible_indices_" .. frame_index,
				visible_entry_capacity * UINT32_SIZE,
				{"storage_buffer"}
			),
			fallback_visible_index_buffer = create_buffer(
				"gpu_culling_fallback_visible_indices_" .. frame_index,
				visible_entry_capacity * UINT32_SIZE,
				{"storage_buffer"}
			),
			fallback_visible_count_buffer = create_buffer(
				"gpu_culling_fallback_visible_count_" .. frame_index,
				UINT32_SIZE,
				{"storage_buffer"}
			),
			main_instance_world_buffer = create_buffer(
				"gpu_culling_main_instance_worlds_" .. frame_index,
				math.max(static_instance_capacity * 16, 16) * ffi.sizeof("float"),
				{"storage_buffer"}
			),
			main_instance_world_upload_data = ffi.new("float[?]", math.max(static_instance_capacity * 16, 16)),
			main_instance_world_upload_generation = -1,
			shadow_instance_world_buffer = create_buffer(
				"gpu_culling_shadow_instance_worlds_" .. frame_index,
				math.max(shadow_instance_capacity * 16, 16) * ffi.sizeof("float"),
				{"storage_buffer"}
			),
			shadow_instance_world_upload_data = ffi.new("float[?]", math.max(shadow_instance_capacity * 16, 16)),
			shadow_instance_world_upload_change_version = -1,
			indirect_command_buffer = create_buffer(
				"gpu_culling_indirect_commands_" .. frame_index,
				visible_entry_capacity * DRAW_INDEXED_INDIRECT_COMMAND_SIZE,
				{"storage_buffer", "indirect_buffer"}
			),
			indirect_count_buffer = create_buffer(
				"gpu_culling_indirect_count_" .. frame_index,
				UINT32_SIZE,
				{"storage_buffer", "indirect_buffer"}
			),
			visible_instanced_batch_count_zero_data = ffi.new("uint32_t[?]", instanced_batch_count),
			visible_instanced_batch_count_buffer = create_buffer(
				"gpu_culling_visible_instanced_batch_counts_" .. frame_index,
				instanced_batch_count * UINT32_SIZE,
				{"storage_buffer"}
			),
			visible_batch_indirect_zero_data = ffi.new(
				"uint8_t[?]",
				math.max(instanced_batch_count * DRAW_INDEXED_INDIRECT_COMMAND_SIZE, 1)
			),
			visible_batch_indirect_command_buffer = create_buffer(
				"gpu_culling_visible_batch_indirect_commands_" .. frame_index,
				instanced_batch_count * DRAW_INDEXED_INDIRECT_COMMAND_SIZE,
				{"storage_buffer", "indirect_buffer"}
			),
			active_batch_index_buffer = create_buffer(
				"gpu_culling_active_batch_indices_" .. frame_index,
				instanced_batch_count * UINT32_SIZE,
				{"storage_buffer"}
			),
			active_batch_count_buffer = create_buffer(
				"gpu_culling_active_batch_count_" .. frame_index,
				UINT32_SIZE,
				{"storage_buffer"}
			),
			visible_instance_vertex_buffer = VertexBuffer.New(
				static_instance_capacity,
				{
					{
						lua_name = "instance_world",
						lua_type = float16,
						offset = 0,
					},
				},
				"gpu_culling_visible_instances_" .. frame_index
			),
			main_view_cull_cmd = render.CreateCommandBuffer(),
			main_view_cull_fence = Fence.New(device),
			main_view_cull_pending_serial = nil,
			main_view_cull_completed_serial = nil,
			main_view_cull_cached_result = nil,
			main_view_cull_result = nil,
			shadow_view_cull_result = nil,
		}
	end

	gpu_culling.main_view_async_slot_index = total_slot_count
	return frame_buffers
end

local function update_main_view_async_slot_completion(output, queue)
	if not (output and output.main_view_cull_pending_serial) then return end

	if not output.main_view_cull_fence:IsSignaled() then return end

	if queue:HasPendingSubmission(output.main_view_cull_fence) then
		queue:RetireFence(output.main_view_cull_fence)
	end

	local fallback_visible_count_ptr = ffi.cast("uint32_t*", output.fallback_visible_count_buffer:Map())
	local fallback_visible_count = tonumber(fallback_visible_count_ptr[0])
	local fallback_visible_index_ptr = ffi.cast("uint32_t*", output.fallback_visible_index_buffer:Map())
	output.main_view_cull_cached_result = update_cull_result(
		output.main_view_cull_cached_result or {},
		output.frame_index,
		nil,
		nil,
		fallback_visible_count,
		fallback_visible_index_ptr,
		nil,
		false
	)
	output.main_view_cull_completed_serial = output.main_view_cull_pending_serial
	output.main_view_cull_pending_serial = nil
end

local function get_latest_main_view_async_result(frame_buffers)
	local queue = render.GetQueue()
	local latest_serial = -1
	local latest_result = nil

	for _, output in ipairs(frame_buffers or {}) do
		update_main_view_async_slot_completion(output, queue)

		if
			output.main_view_cull_completed_serial and
			output.main_view_cull_completed_serial > latest_serial and
			output.main_view_cull_cached_result
		then
			latest_serial = output.main_view_cull_completed_serial
			latest_result = output.main_view_cull_cached_result
		end
	end

	return latest_result
end

local function should_use_async_main_view_culling(read_visible_entry_indices)
	if read_visible_entry_indices then return false end

	if not gpu_culling.IsAsyncMainViewEnabled() then return false end

	if
		test_helper.GetCurrentRunningTestName and
		test_helper.GetCurrentRunningTestName() ~= ""
	then
		return false
	end

	local active_task = tasks.GetActiveTask and tasks.GetActiveTask() or nil

	if active_task and active_task.is_test_task then return false end

	return true
end

local function upload_shadow_instance_worlds(output, dataset)
	local entry_count = dataset and dataset.shadow_instance_count or 0
	local shadow_change_version = dataset and dataset.shadow_instance_world_change_version or 0

	if output.shadow_instance_world_upload_change_version == shadow_change_version then
		return
	end

	if entry_count <= 0 then
		output.shadow_instance_world_upload_change_version = shadow_change_version
		return
	end

	local world_matrices = output.shadow_instance_world_upload_data

	for _, entry in ipairs(dataset.shadow_entries or {}) do
		if entry.static_matrix_index ~= nil then
			local component = entry.component
			local source_entry = entry.source_entry
			local transform = source_entry and source_entry.transform or nil
			local world_matrix = transform and
				transform.GetWorldMatrix and
				transform:GetWorldMatrix() or
				component:GetWorldMatrix()

			if world_matrix then
				world_matrix:CopyToFloatPointer(world_matrices + entry.static_matrix_index * 16)
			end
		end
	end

	output.shadow_instance_world_buffer:CopyData(world_matrices, entry_count * 16 * ffi.sizeof("float"), 0)
	output.shadow_instance_world_upload_change_version = shadow_change_version
end

local function upload_main_instance_worlds(output, dataset)
	local entry_count = dataset and dataset.main_static_instance_count or 0
	local generation = dataset and dataset.generation or -1
	local float_size = ffi.sizeof("float")
	local byte_count = entry_count * 16 * float_size
	local dynamic_start = dataset and dataset.main_static_instance_prefix_count or 0
	local dynamic_count = math.max(entry_count - dynamic_start, 0)

	if entry_count <= 0 then
		output.main_instance_world_upload_generation = generation
		return
	end

	local world_matrices = output.main_instance_world_upload_data

	if output.main_instance_world_upload_generation ~= generation then
		local dataset_buffers = gpu_culling.dataset_buffers
		local static_worlds = dataset_buffers and
			dataset_buffers.main_static_instance_worlds or
			flatten_static_instance_world_upload(dataset)
		ffi.copy(world_matrices, static_worlds.world_matrices, byte_count)
		output.main_instance_world_upload_generation = generation

		for _, visual in ipairs(dataset.dynamic_visuals or {}) do
			for _, entry in ipairs(visual.entries or {}) do
				if entry.static_matrix_index ~= nil then
					local component = entry.component
					local source_entry = entry.source_entry
					local transform = source_entry and source_entry.transform or nil
					local world_matrix = transform and
						transform.GetWorldMatrix and
						transform:GetWorldMatrix() or
						component:GetWorldMatrix()

					if world_matrix then
						world_matrix:CopyToFloatPointer(world_matrices + entry.static_matrix_index * 16)
					end
				end
			end
		end

		output.main_instance_world_buffer:CopyData(world_matrices, byte_count, 0)
		return
	end

	if dynamic_count <= 0 then return end

	for _, visual in ipairs(dataset.dynamic_visuals or {}) do
		for _, entry in ipairs(visual.entries or {}) do
			if entry.static_matrix_index ~= nil then
				local component = entry.component
				local source_entry = entry.source_entry
				local transform = source_entry and source_entry.transform or nil
				local world_matrix = transform and
					transform.GetWorldMatrix and
					transform:GetWorldMatrix() or
					component:GetWorldMatrix()

				if world_matrix then
					world_matrix:CopyToFloatPointer(world_matrices + entry.static_matrix_index * 16)
				end
			end
		end
	end

	output.main_instance_world_buffer:CopyData(
		world_matrices + dynamic_start * 16,
		dynamic_count * 16 * float_size,
		dynamic_start * 16 * float_size
	)
end

local function ensure_frame_buffers(dataset)
	if not dataset then
		clear_frame_buffers()
		return nil
	end

	if
		gpu_culling.frame_buffers_generation == dataset.generation and
		gpu_culling.frame_buffers
	then
		return gpu_culling.frame_buffers
	end

	clear_frame_buffers()
	gpu_culling.frame_buffers = build_frame_buffers(dataset)
	gpu_culling.frame_buffers_generation = gpu_culling.frame_buffers and dataset.generation or -1
	return gpu_culling.frame_buffers
end

function gpu_culling.InvalidateSceneAcceleration()
	gpu_culling.scene_acceleration_generation = gpu_culling.scene_acceleration_generation + 1
	gpu_culling.scene_acceleration_dirty = true
	gpu_culling.scene_acceleration = nil
	gpu_culling.scene_dataset = nil
	clear_dataset_buffers()
	clear_frame_buffers()
end

function gpu_culling.PublishSceneAcceleration(acceleration)
	gpu_culling.scene_acceleration = acceleration
	gpu_culling.scene_dataset = build_scene_dataset(acceleration)
	ensure_dataset_buffers(gpu_culling.scene_dataset)
	ensure_frame_buffers(gpu_culling.scene_dataset)
	gpu_culling.scene_acceleration_dirty = false
	gpu_culling.published_scene_acceleration_generation = gpu_culling.scene_acceleration_generation
	return acceleration
end

function gpu_culling.GetSceneAcceleration()
	return gpu_culling.scene_acceleration
end

function gpu_culling.GetSceneDataset()
	return gpu_culling.scene_dataset
end

function gpu_culling.GetFrameBuffers()
	return gpu_culling.frame_buffers
end

function gpu_culling.GetDatasetBuffers()
	return gpu_culling.dataset_buffers
end

function gpu_culling.GetFrameBuffersGeneration()
	return gpu_culling.frame_buffers_generation
end

function gpu_culling.GetDatasetBuffersGeneration()
	return gpu_culling.dataset_buffers_generation or -1
end

function gpu_culling.GetUploadTypes()
	return {
		visual_record = GPUCullVisualRecord,
		entry_record = GPUCullEntryRecord,
		node_record = GPUCullNodeRecord,
		flags = {
			visual_visible = VISUAL_FLAG_VISIBLE,
			visual_cast_shadows = VISUAL_FLAG_CAST_SHADOWS,
			visual_use_occlusion = VISUAL_FLAG_USE_OCCLUSION,
			visual_dynamic = VISUAL_FLAG_DYNAMIC,
			visual_shadow_aabb_cullable = VISUAL_FLAG_SHADOW_AABB_CULLABLE,
			visual_shadow_non_aabb = VISUAL_FLAG_SHADOW_NON_AABB,
			entry_ignore_z = ENTRY_FLAG_IGNORE_Z,
			entry_height_displacement = ENTRY_FLAG_HEIGHT_DISPLACEMENT,
			node_leaf = NODE_FLAG_LEAF,
		},
		invalid_index = INVALID_INDEX,
	}
end

function gpu_culling.RunMainViewFrustumCulling(
	view_projection_matrix,
	camera_position,
	frame_index,
	include_visible_entry_indices
)
	local dataset = gpu_culling.scene_dataset
	local dataset_buffers = gpu_culling.dataset_buffers
	local frame_buffers = gpu_culling.frame_buffers
	local read_visible_entry_indices = include_visible_entry_indices ~= false
	local use_async_main_view = should_use_async_main_view_culling(read_visible_entry_indices)
	local read_visible_results = read_visible_entry_indices
	local read_indirect_results = read_visible_entry_indices

	if not (dataset and dataset_buffers and frame_buffers) then return nil end

	local visual_count = dataset_buffers.layout and dataset_buffers.layout.main_visual_count or 0

	if visual_count <= 0 then
		gpu_culling.empty_main_view_cull_result = update_cull_result(
			gpu_culling.empty_main_view_cull_result or {},
			resolve_frame_slot(frame_index),
			0,
			nil,
			0,
			nil,
			0,
			read_visible_entry_indices
		)
		return gpu_culling.empty_main_view_cull_result
	end

	local slot = use_async_main_view and
		gpu_culling.main_view_async_slot_index or
		resolve_frame_slot(frame_index)
	local output = frame_buffers[slot]
	local occlusion_enabled = gpu_culling.GetOcclusionMode() == "hiz"
	local occlusion_depth_texture, occlusion_depth_view, occlusion_depth_sampler, occlusion_max_mip, occlusion_hiz_state = get_main_view_occlusion_source()
	local viewport_height = 0

	if occlusion_depth_texture and occlusion_depth_texture.GetSize then
		local size = occlusion_depth_texture:GetSize()
		viewport_height = size and size.y or 0
	end

	if use_async_main_view and output.main_view_cull_pending_serial then
		update_main_view_async_slot_completion(output, render.GetQueue())
	end

	if use_async_main_view and output.main_view_cull_pending_serial then
		return get_latest_main_view_async_result(frame_buffers)
	end

	local frustum_planes = gpu_culling.main_view_cull_frustum_planes
	extract_frustum_planes(view_projection_matrix, frustum_planes)
	upload_main_instance_worlds(output, dataset)
	output.indirect_count_buffer:CopyData(ZERO_UINT32, UINT32_SIZE, 0)
	output.fallback_visible_count_buffer:CopyData(ZERO_UINT32, UINT32_SIZE, 0)
	output.active_batch_count_buffer:CopyData(ZERO_UINT32, UINT32_SIZE, 0)
	output.visible_batch_indirect_command_buffer:CopyData(
		output.visible_batch_indirect_zero_data,
		output.visible_batch_indirect_command_buffer.size,
		0
	)
	output.visible_instanced_batch_count_buffer:CopyData(
		output.visible_instanced_batch_count_zero_data,
		output.visible_instanced_batch_count_buffer.size,
		0
	)
	local pass = gpu_culling.main_view_cull_pass
	pass.current_visual_count = visual_count
	pass.current_camera_position = camera_position
	pass.current_frustum_planes = frustum_planes
	pass.current_view_projection = view_projection_matrix
	pass.current_viewport_height = viewport_height
	pass.current_min_screen_diameter_px = 1.0
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		0,
		0,
		dataset_buffers.main_visual_buffer,
		dataset_buffers.main_visual_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		1,
		0,
		output.visible_index_buffer,
		output.visible_index_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		2,
		0,
		output.indirect_count_buffer,
		output.indirect_count_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		3,
		0,
		dataset_buffers.main_entry_buffer,
		dataset_buffers.main_entry_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		4,
		0,
		output.indirect_command_buffer,
		output.indirect_command_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		5,
		0,
		output.main_instance_world_buffer,
		output.main_instance_world_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		6,
		0,
		dataset_buffers.main_instanced_batch_buffer,
		dataset_buffers.main_instanced_batch_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		7,
		0,
		output.visible_instance_vertex_buffer.buffer,
		output.visible_instance_vertex_buffer.byte_size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		8,
		0,
		output.visible_instanced_batch_count_buffer,
		output.visible_instanced_batch_count_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		9,
		0,
		output.fallback_visible_index_buffer,
		output.fallback_visible_index_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		10,
		0,
		output.fallback_visible_count_buffer,
		output.fallback_visible_count_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		11,
		0,
		output.active_batch_index_buffer,
		output.active_batch_index_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		12,
		0,
		output.active_batch_count_buffer,
		output.active_batch_count_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		13,
		0,
		output.visible_batch_indirect_command_buffer,
		output.visible_batch_indirect_command_buffer.size
	)
	local cmd = output.main_view_cull_cmd
	cmd:Reset()
	cmd:Begin()
	occlusion_depth_texture, occlusion_depth_view, occlusion_depth_sampler, occlusion_max_mip, occlusion_hiz_state = gpu_culling.PrepareMainViewHiZ(frame_index, cmd)
	pass.current_occlusion_enabled = occlusion_enabled
	pass.current_occlusion_depth_texture = occlusion_enabled and occlusion_depth_texture or nil
	pass.current_occlusion_max_mip = occlusion_enabled and occlusion_max_mip or 0
	pass.current_occlusion_depth_bias = 0.0015

	if
		output.last_main_view_occlusion_view ~= occlusion_depth_view or
		output.last_main_view_occlusion_sampler ~= occlusion_depth_sampler
	then
		pass:UpdateDescriptorSet(
			"combined_image_sampler",
			slot,
			14,
			0,
			occlusion_depth_view,
			occlusion_depth_sampler,
			nil,
			nil,
			"general"
		)
		output.last_main_view_occlusion_view = occlusion_depth_view
		output.last_main_view_occlusion_sampler = occlusion_depth_sampler
	end

	pass:DispatchForSize(cmd, visual_count, 1, 1, slot)
	local buffer_barriers = {
		{
			buffer = output.visible_instanced_batch_count_buffer,
			size = output.visible_instanced_batch_count_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
		{
			buffer = output.active_batch_index_buffer,
			size = output.active_batch_index_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
		{
			buffer = output.active_batch_count_buffer,
			size = output.active_batch_count_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
		{
			buffer = output.visible_batch_indirect_command_buffer,
			size = output.visible_batch_indirect_command_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "indirect_command_read",
		},
		{
			buffer = output.visible_instance_vertex_buffer.buffer,
			size = output.visible_instance_vertex_buffer.byte_size,
			srcAccessMask = "shader_write",
			dstAccessMask = "vertex_attribute_read",
		},
		{
			buffer = output.fallback_visible_index_buffer,
			size = output.fallback_visible_index_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
		{
			buffer = output.fallback_visible_count_buffer,
			size = output.fallback_visible_count_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
	}

	if read_visible_entry_indices then
		table.insert(
			buffer_barriers,
			1,
			{
				buffer = output.visible_index_buffer,
				size = output.visible_index_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = "host_read",
			}
		)
	end

	if read_indirect_results then
		table.insert(
			buffer_barriers,
			1,
			{
				buffer = output.indirect_command_buffer,
				size = output.indirect_command_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = "host_read",
			}
		)
		table.insert(
			buffer_barriers,
			1,
			{
				buffer = output.indirect_count_buffer,
				size = output.indirect_count_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = "host_read",
			}
		)
	end

	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"host", "vertex_input", "draw_indirect"},
		bufferBarriers = buffer_barriers,
	}
	cmd:End()

	if use_async_main_view then
		gpu_culling.main_view_async_submission_serial = gpu_culling.main_view_async_submission_serial + 1
		render.Submit(cmd, output.main_view_cull_fence)
		output.main_view_cull_pending_serial = gpu_culling.main_view_async_submission_serial
		return get_latest_main_view_async_result(frame_buffers)
	end

	render.SubmitAndWait(cmd)
	local visible_count = nil
	local fallback_visible_count_ptr = ffi.cast("uint32_t*", output.fallback_visible_count_buffer:Map())
	local fallback_visible_count = tonumber(fallback_visible_count_ptr[0])
	local fallback_visible_index_ptr = ffi.cast("uint32_t*", output.fallback_visible_index_buffer:Map())
	local visible_index_ptr = nil

	if read_indirect_results then
		local visible_count_ptr = ffi.cast("uint32_t*", output.indirect_count_buffer:Map())
		visible_count = tonumber(visible_count_ptr[0])
	end

	if read_visible_entry_indices then
		visible_index_ptr = ffi.cast("uint32_t*", output.visible_index_buffer:Map())
	end

	output.main_view_cull_result = update_cull_result(
		output.main_view_cull_result or {},
		slot,
		visible_count,
		visible_index_ptr,
		fallback_visible_count,
		fallback_visible_index_ptr,
		visible_count,
		read_visible_entry_indices
	)
	return output.main_view_cull_result
end

function gpu_culling.RunShadowViewAABBCulling(query_aabb, shadow_output, frame_index, include_visible_entry_indices)
	if not gpu_culling.shadow_view_aabb_cull_pass then return nil end

	local dataset = gpu_culling.scene_dataset
	local dataset_buffers = gpu_culling.dataset_buffers
	local frame_buffers = gpu_culling.frame_buffers
	local read_visible_entry_indices = include_visible_entry_indices ~= false
	local read_visible_results = read_visible_entry_indices

	if
		not (
			query_aabb and
			shadow_output and
			dataset and
			dataset_buffers and
			frame_buffers
		)
	then
		return nil
	end

	local visual_count = dataset_buffers.layout and dataset_buffers.layout.shadow_visual_count or 0

	if visual_count <= 0 then
		gpu_culling.empty_shadow_view_cull_result = update_cull_result(
			gpu_culling.empty_shadow_view_cull_result or {},
			resolve_frame_slot(frame_index),
			0,
			nil,
			0,
			nil,
			0,
			read_visible_entry_indices
		)
		return gpu_culling.empty_shadow_view_cull_result
	end

	local slot = resolve_frame_slot(frame_index)
	local output = frame_buffers[slot]
	local descriptor_slot = shadow_output.descriptor_slot

	if not (output and descriptor_slot) then return nil end

	local occlusion_enabled = gpu_culling.GetOcclusionMode() == "hiz"
	local occlusion_depth_texture, occlusion_depth_view, occlusion_depth_sampler, occlusion_max_mip, occlusion_hiz_state = get_main_view_occlusion_source()
	local camera = render3d.GetCamera()
	local view_projection_matrix = camera:BuildViewMatrix() * camera:BuildProjectionMatrix()
	upload_shadow_instance_worlds(output, dataset)
	shadow_output.shadow_visible_count_buffer:CopyData(ZERO_UINT32, UINT32_SIZE, 0)
	shadow_output.shadow_fallback_visible_count_buffer:CopyData(ZERO_UINT32, UINT32_SIZE, 0)
	shadow_output.shadow_active_batch_count_buffer:CopyData(ZERO_UINT32, UINT32_SIZE, 0)
	shadow_output.shadow_visible_batch_indirect_command_buffer:CopyData(
		shadow_output.shadow_visible_batch_indirect_zero_data,
		shadow_output.shadow_visible_batch_indirect_command_buffer.size,
		0
	)
	shadow_output.shadow_visible_instanced_batch_count_buffer:CopyData(
		shadow_output.shadow_visible_instanced_batch_count_zero_data,
		shadow_output.shadow_visible_instanced_batch_count_buffer.size,
		0
	)
	local pass = gpu_culling.shadow_view_aabb_cull_pass
	pass.current_visual_count = visual_count
	pass.current_query_aabb = query_aabb
	pass.current_camera_position = camera:GetPosition()
	pass.current_view_projection = view_projection_matrix
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		0,
		0,
		dataset_buffers.shadow_visual_buffer,
		dataset_buffers.shadow_visual_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		1,
		0,
		shadow_output.shadow_visible_index_buffer,
		shadow_output.shadow_visible_index_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		2,
		0,
		shadow_output.shadow_visible_count_buffer,
		shadow_output.shadow_visible_count_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		3,
		0,
		dataset_buffers.shadow_entry_buffer,
		dataset_buffers.shadow_entry_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		4,
		0,
		output.shadow_instance_world_buffer,
		output.shadow_instance_world_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		5,
		0,
		dataset_buffers.shadow_instanced_batch_buffer,
		dataset_buffers.shadow_instanced_batch_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		6,
		0,
		shadow_output.shadow_visible_instance_vertex_buffer.buffer,
		shadow_output.shadow_visible_instance_vertex_buffer.byte_size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		7,
		0,
		shadow_output.shadow_visible_instanced_batch_count_buffer,
		shadow_output.shadow_visible_instanced_batch_count_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		8,
		0,
		shadow_output.shadow_fallback_visible_index_buffer,
		shadow_output.shadow_fallback_visible_index_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		9,
		0,
		shadow_output.shadow_fallback_visible_count_buffer,
		shadow_output.shadow_fallback_visible_count_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		10,
		0,
		shadow_output.shadow_active_batch_index_buffer,
		shadow_output.shadow_active_batch_index_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		11,
		0,
		shadow_output.shadow_active_batch_count_buffer,
		shadow_output.shadow_active_batch_count_buffer.size
	)
	pass:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_slot,
		12,
		0,
		shadow_output.shadow_visible_batch_indirect_command_buffer,
		shadow_output.shadow_visible_batch_indirect_command_buffer.size
	)
	local cmd = gpu_culling.shadow_view_aabb_cull_cmd
	cmd:Reset()
	cmd:Begin()
	occlusion_depth_texture, occlusion_depth_view, occlusion_depth_sampler, occlusion_max_mip, occlusion_hiz_state = gpu_culling.PrepareMainViewHiZ(frame_index, cmd)
	pass.current_occlusion_enabled = occlusion_enabled
	pass.current_occlusion_depth_texture = occlusion_enabled and occlusion_depth_texture or nil
	pass.current_occlusion_max_mip = occlusion_enabled and occlusion_max_mip or 0
	pass.current_occlusion_depth_bias = 0.0015
	pass:UpdateDescriptorSet(
		"combined_image_sampler",
		descriptor_slot,
		14,
		0,
		occlusion_depth_view,
		occlusion_depth_sampler,
		nil,
		nil,
		"general"
	)
	pass:DispatchForSize(cmd, visual_count, 1, 1, descriptor_slot)
	local buffer_barriers = {
		{
			buffer = shadow_output.shadow_visible_instanced_batch_count_buffer,
			size = shadow_output.shadow_visible_instanced_batch_count_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
		{
			buffer = shadow_output.shadow_visible_instance_vertex_buffer.buffer,
			size = shadow_output.shadow_visible_instance_vertex_buffer.byte_size,
			srcAccessMask = "shader_write",
			dstAccessMask = "vertex_attribute_read",
		},
		{
			buffer = shadow_output.shadow_fallback_visible_index_buffer,
			size = shadow_output.shadow_fallback_visible_index_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
		{
			buffer = shadow_output.shadow_fallback_visible_count_buffer,
			size = shadow_output.shadow_fallback_visible_count_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
		{
			buffer = shadow_output.shadow_active_batch_index_buffer,
			size = shadow_output.shadow_active_batch_index_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
		{
			buffer = shadow_output.shadow_active_batch_count_buffer,
			size = shadow_output.shadow_active_batch_count_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		},
		{
			buffer = shadow_output.shadow_visible_batch_indirect_command_buffer,
			size = shadow_output.shadow_visible_batch_indirect_command_buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "indirect_command_read",
		},
	}

	if read_visible_entry_indices then
		table.insert(
			buffer_barriers,
			1,
			{
				buffer = shadow_output.shadow_visible_index_buffer,
				size = shadow_output.shadow_visible_index_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = "host_read",
			}
		)
	end

	if read_visible_results then
		table.insert(
			buffer_barriers,
			1,
			{
				buffer = shadow_output.shadow_visible_count_buffer,
				size = shadow_output.shadow_visible_count_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = "host_read",
			}
		)
	end

	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"host", "vertex_input", "draw_indirect"},
		bufferBarriers = buffer_barriers,
	}
	cmd:End()
	render.SubmitAndWait(cmd)
	local visible_count = nil
	local fallback_visible_count_ptr = ffi.cast("uint32_t*", shadow_output.shadow_fallback_visible_count_buffer:Map())
	local fallback_visible_count = tonumber(fallback_visible_count_ptr[0])
	local fallback_visible_index_ptr = ffi.cast("uint32_t*", shadow_output.shadow_fallback_visible_index_buffer:Map())
	local visible_index_ptr = nil

	if read_visible_results then
		local visible_count_ptr = ffi.cast("uint32_t*", shadow_output.shadow_visible_count_buffer:Map())
		visible_count = tonumber(visible_count_ptr[0])
	end

	if read_visible_entry_indices then
		visible_index_ptr = ffi.cast("uint32_t*", shadow_output.shadow_visible_index_buffer:Map())
	end

	local result = update_cull_result(
		{},
		slot,
		visible_count,
		visible_index_ptr,
		fallback_visible_count,
		fallback_visible_index_ptr,
		visible_count,
		read_visible_entry_indices
	)
	result.shadow_output = shadow_output
	return result
end

function gpu_culling.GetVisibleEntrySpan(cull_result, prefer_visible_entry_indices)
	if not cull_result then return nil, 0 end

	if prefer_visible_entry_indices ~= false then
		if cull_result.visible_entry_indices_ready then
			return cull_result.visible_entry_index_ptr, cull_result.visible_entry_count or 0
		end

		return cull_result.fallback_visible_entry_index_ptr,
		cull_result.fallback_visible_entry_count or 0
	end

	return cull_result.fallback_visible_entry_index_ptr,
	cull_result.fallback_visible_entry_count or 0
end

function gpu_culling.GetShadowActiveBatchSpan(cull_result)
	if not cull_result then return nil, 0 end

	local output = cull_result.shadow_output

	if not output then return nil, 0 end

	local active_batch_count_ptr = ffi.cast("uint32_t *", output.shadow_active_batch_count_buffer:Map())
	local active_batch_indices = ffi.cast("uint32_t *", output.shadow_active_batch_index_buffer:Map())
	return active_batch_indices, tonumber(active_batch_count_ptr[0] or 0)
end

function gpu_culling.IsAnyVisibleEntryInRange(cull_result, first_entry_index, entry_count, prefer_visible_entry_indices)
	if not cull_result then return nil end

	if not first_entry_index or not entry_count or entry_count <= 0 then
		return false
	end

	local entry_index_ptr, visible_entry_count = gpu_culling.GetVisibleEntrySpan(cull_result, prefer_visible_entry_indices)

	if not entry_index_ptr or visible_entry_count <= 0 then return false end

	local last_entry_index = first_entry_index + entry_count - 1
	local low = 0
	local high = visible_entry_count - 1

	while low <= high do
		local mid = math.floor((low + high) * 0.5)
		local entry_index = tonumber(entry_index_ptr[mid])

		if entry_index < first_entry_index then
			low = mid + 1
		elseif entry_index > last_entry_index then
			high = mid - 1
		else
			return true
		end
	end

	return false
end

function gpu_culling.ForEachVisibleEntryIndex(cull_result, callback, prefer_visible_entry_indices)
	local entry_index_ptr, entry_count = gpu_culling.GetVisibleEntrySpan(cull_result, prefer_visible_entry_indices)

	if not entry_index_ptr then return 0 end

	for i = 0, entry_count - 1 do
		callback(tonumber(entry_index_ptr[i]), i + 1)
	end

	return entry_count
end

function gpu_culling.IsSceneAccelerationDirty()
	return gpu_culling.scene_acceleration_dirty
end

function gpu_culling.GetSceneAccelerationGeneration()
	return gpu_culling.scene_acceleration_generation
end

function gpu_culling.GetPublishedSceneAccelerationGeneration()
	return gpu_culling.published_scene_acceleration_generation
end

return gpu_culling
