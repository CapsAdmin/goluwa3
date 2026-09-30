local ffi = require("ffi")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local test_helper = import("goluwa/test.lua")
local tasks = import("goluwa/tasks.lua")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local vk = import("goluwa/bindings/vk.lua")
local system = import("goluwa/system.lua")
local Material = import("goluwa/render3d/material.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local render3d = nil
local gpu_culling = library()
gpu_culling.generation = gpu_culling.generation or 0
gpu_culling.enabled = true
-- one descriptor set per shadow view: each face of a point shadow map and
-- each sun cascade
gpu_culling.MAX_SHADOW_QUERY_OUTPUTS = 512
gpu_culling.async_main_view_enabled = true
gpu_culling.async_frustum_scale = gpu_culling.async_frustum_scale or 0.96
gpu_culling.occlusion_mode = gpu_culling.occlusion_mode or "hiz"
gpu_culling.scene_acceleration = gpu_culling.scene_acceleration or nil
gpu_culling.scene_dataset = gpu_culling.scene_dataset or nil
gpu_culling.frame_buffers = gpu_culling.frame_buffers or nil
gpu_culling.scene_acceleration_generation = gpu_culling.scene_acceleration_generation or 0
gpu_culling.frame_buffers_capacity = gpu_culling.frame_buffers_capacity or nil
gpu_culling.main_view_submission_serial = gpu_culling.main_view_submission_serial or 0
local float16 = ffi.typeof("float[16]")
local VALID_OCCLUSION_MODES = {
	disabled = true,
	hiz = true,
}
local UINT32_SIZE = ffi.sizeof("uint32_t")
local DRAW_INDEXED_INDIRECT_COMMAND_SIZE = ffi.sizeof(vk.VkDrawIndexedIndirectCommand)
local DRAW_INDIRECT_COMMAND_SIZE = ffi.sizeof(vk.VkDrawIndirectCommand)
gpu_culling.BATCH_DRAW_COMMAND_SIZE = DRAW_INDIRECT_COMMAND_SIZE
gpu_culling.MAIN_BATCH_DRAW_COMMAND_SIZE = DRAW_INDEXED_INDIRECT_COMMAND_SIZE
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
	uint32_t flags;
	uint32_t first_index;
}]])
local BATCH_FLAG_DOUBLE_SIDED = 1
local BATCH_FLAG_HEIGHT_MAP = 2
-- the main batch commands have one quarter per combination of the flags above
gpu_culling.BATCH_COMMAND_GROUP_COUNT = 4
local FRUSTUM_PLANE_COMPONENT_COUNT = 24
-- Async culling needs more slots than the swapchain has frames: at any moment one slot
-- is being culled into, one is published (its indirect commands are being drawn from),
-- and the frames that drew from earlier slots may still be in flight.
local ASYNC_SLOT_HEADROOM = 3

local function get_cull_slot_count()
	local frame_count = math.max(render.GetSwapchainImageCount() or 1, 1)
	return frame_count, frame_count + ASYNC_SLOT_HEADROOM
end

function gpu_culling.Initialize()
	render3d = import("goluwa/render3d/render3d.lua")
	local hiz_descriptor_set_count = (math.max(render.GetSwapchainImageCount() or 1, 1) + 1) * 16

	do -- main view hiz build pass
		gpu_culling.main_view_hiz_build_pass = EasyPipeline.Compute{
			DescriptorSetCount = hiz_descriptor_set_count,
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
			DescriptorSetCount = hiz_descriptor_set_count,
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
		local sync_slot_count, async_slot_count = get_cull_slot_count()
		gpu_culling.main_view_cull_pass = EasyPipeline.Compute{
			DescriptorSetCount = sync_slot_count + async_slot_count,
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
				{
					type = "storage_buffer",
					binding_index = 15,
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
				uint flags;
				uint first_index;
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

			// one command per batch in each quarter, indexed by the batch's double
			// sided and height map flags, with the others left at zero instances.
			// the draws index the shared index pool (see index_pool.lua)
			layout(std430, set = 0, binding = 13) buffer VisibleBatchIndirectCommandBuffer {
				DrawIndexedIndirectCommand batch_commands[];
			};

			layout(set = 0, binding = 14) uniform sampler2D source_depth_tex;

			// indexed by entry index so the cpu can ask "is this component visible"
			// without searching the append-ordered visible list
			layout(std430, set = 0, binding = 15) writeonly buffer EntryVisibilityBuffer {
				uint entry_visible[];
			};

			const uint VISUAL_FLAG_VISIBLE = 1u;
			const uint VISUAL_FLAG_USE_OCCLUSION = 4u;
			const uint INVALID_INDEX = 0xFFFFFFFFu;
			const uint BATCH_FLAG_DOUBLE_SIDED = ]] .. BATCH_FLAG_DOUBLE_SIDED .. [[u;
			const uint BATCH_FLAG_HEIGHT_MAP = ]] .. BATCH_FLAG_HEIGHT_MAP .. [[u;
			const uint BATCH_COMMAND_GROUP_COUNT = ]] .. gpu_culling.BATCH_COMMAND_GROUP_COUNT .. [[u;

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
				bool crosses_near_plane = false;

				for (int i = 0; i < 8; ++i) {
					vec4 clip = project_world_position(corners[i]);

					if (clip.w <= 0.0) {
						crosses_near_plane = true;
						continue;
					}

					vec3 ndc = clip.xyz / clip.w;
					vec2 uv = ndc.xy * 0.5 + 0.5;
					min_uv = min(min_uv, uv);
					max_uv = max(max_uv, uv);
					nearest_depth = min(nearest_depth, ndc.z);
					any_valid = true;
				}

				if (!any_valid || crosses_near_plane) return false;
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
					entry_visible[entry_index] = 1u;
					commands[write_index].indexCount = entry_record.index_count;
					commands[write_index].instanceCount = 1u;
					commands[write_index].firstIndex = 0u;
					commands[write_index].vertexOffset = 0;
					commands[write_index].firstInstance = entry_index;

					if (entry_record.instanced_batch_index != INVALID_INDEX && entry_record.static_matrix_index != INVALID_INDEX) {
						InstancedBatchRecord batch_record = instanced_batches[entry_record.instanced_batch_index];
						uint local_index = atomicAdd(visible_instanced_batch_counts[entry_record.instanced_batch_index], 1u);

						uint command_index = entry_record.instanced_batch_index + (batch_record.flags & (BATCH_FLAG_DOUBLE_SIDED | BATCH_FLAG_HEIGHT_MAP)) * (uint(batch_commands.length()) / BATCH_COMMAND_GROUP_COUNT);

						if (local_index == 0u) {
							uint active_batch_write_index = atomicAdd(active_batch_count[0], 1u);
							active_batch_indices[active_batch_write_index] = entry_record.instanced_batch_index;
							batch_commands[command_index].indexCount = batch_record.index_count;
							batch_commands[command_index].firstIndex = batch_record.first_index;
							batch_commands[command_index].vertexOffset = 0;
							batch_commands[command_index].firstInstance = batch_record.output_offset;
						}

						atomicAdd(batch_commands[command_index].instanceCount, 1u);

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
			DescriptorSetCount = gpu_culling.MAX_SHADOW_QUERY_OUTPUTS,
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
				{"light_view", "mat4"},
				{"min_caster_extent", "float"},
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

				if self.current_light_view then
					self.current_light_view:CopyToFloatPointer(block.light_view)
					block.min_caster_extent = self.current_min_caster_extent or 0.0
				else
					ffi.fill(block.light_view, ffi.sizeof("float") * 16, 0)
					block.min_caster_extent = 0.0
				end

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
				uint flags;
				uint first_index;
			};

			// shadow draws pull their vertices through the index buffer themselves, so
			// every batch is a plain draw of index_count vertices
			struct DrawIndirectCommand {
				uint vertexCount;
				uint instanceCount;
				uint firstVertex;
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
				DrawIndirectCommand batch_commands[];
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
				bool crosses_near_plane = false;

				for (int i = 0; i < 8; ++i) {
					vec4 clip = project_world_position(corners[i]);

					if (clip.w <= 0.0) {
						crosses_near_plane = true;
						continue;
					}

					vec3 ndc = clip.xyz / clip.w;
					vec2 uv = ndc.xy * 0.5 + 0.5;
					min_uv = min(min_uv, uv);
					max_uv = max(max_uv, uv);
					nearest_depth = min(nearest_depth, ndc.z);
					any_valid = true;
				}

				if (!any_valid || crosses_near_plane) return false;
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

				// matches ShadowMap:IsWorldAABBTooSmall from the cpu fallback path:
				// cull casters below the min texel size on both light axes
				if (compute.min_caster_extent > 0.0) {
					vec3 half_size = 0.5 * vec3(
						visual_record.max_x - visual_record.min_x,
						visual_record.max_y - visual_record.min_y,
						visual_record.max_z - visual_record.min_z
					);
					mat3 light_rot = mat3(compute.light_view);
					float extent_x = (abs(light_rot[0].x) * half_size.x + abs(light_rot[0].y) * half_size.y + abs(light_rot[0].z) * half_size.z) * 2.0;
					float extent_y = (abs(light_rot[1].x) * half_size.x + abs(light_rot[1].y) * half_size.y + abs(light_rot[1].z) * half_size.z) * 2.0;

					if (extent_x < compute.min_caster_extent && extent_y < compute.min_caster_extent) return;
				}

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
							batch_commands[entry_record.instanced_batch_index].vertexCount = batch_record.index_count;
							batch_commands[entry_record.instanced_batch_index].firstVertex = 0u;
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

function gpu_culling.Shutdown()
	if
		gpu_culling.main_view_hiz_build_pass and
		gpu_culling.main_view_hiz_build_pass.Remove
	then
		gpu_culling.main_view_hiz_build_pass:Remove()
	end

	gpu_culling.main_view_hiz_build_pass = nil

	if
		gpu_culling.main_view_hiz_reduce_pass and
		gpu_culling.main_view_hiz_reduce_pass.Remove
	then
		gpu_culling.main_view_hiz_reduce_pass:Remove()
	end

	gpu_culling.main_view_hiz_reduce_pass = nil
	local state = gpu_culling.main_view_hiz_state

	if state and state.buffers then
		for _, buffer in ipairs(state.buffers) do
			if buffer and buffer.texture then buffer.texture:Remove() end
		end
	end

	gpu_culling.main_view_hiz_state = nil

	if
		gpu_culling.shadow_view_aabb_cull_cmd and
		gpu_culling.shadow_view_aabb_cull_cmd.Remove
	then
		gpu_culling.shadow_view_aabb_cull_cmd:Remove()
	end

	gpu_culling.shadow_view_aabb_cull_cmd = nil
end

local HIZ_BUFFER_COUNT = 2

local function create_main_view_hiz_buffer(width, height, index)
	local mip_count = 1
	local largest_dimension = math.max(width, height)

	while largest_dimension > 1 do
		largest_dimension = math.floor(largest_dimension * 0.5)
		mip_count = mip_count + 1
	end

	local texture = Texture.New{
		width = width,
		height = height,
		format = "r32_sfloat",
		mip_map_levels = mip_count,
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
	texture:SetDebugName("gpu culling main view hiz " .. index)
	local image = texture:GetImage()
	local single_mip_views = {}

	for mip_level = 0, mip_count - 1 do
		single_mip_views[mip_level + 1] = image:CreateView{
			format = "r32_sfloat",
			base_mip_level = mip_level,
			level_count = 1,
			aspect = "color",
		}
		single_mip_views[mip_level + 1]:SetDebugName("gpu culling main view hiz " .. index .. " mip " .. mip_level)
	end

	image:TransitionLayout(image.layout or "undefined", "general")
	local buffer = {
		index = index,
		texture = texture,
		image = image,
		view = texture:GetView(),
		sampler = texture.sampler or render.CreateSampler(texture:GetSamplerConfig()),
		max_mip = mip_count - 1,
		single_mip_views = single_mip_views,
		built = false,
		mip_barriers = {},
	}

	for mip_level = 0, mip_count - 1 do
		buffer.mip_barriers[mip_level + 1] = {
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

	return buffer
end

local function ensure_main_view_hiz_state(width, height)
	local state = gpu_culling.main_view_hiz_state

	if state and state.width == width and state.height == height then
		return state
	end

	if state then
		for _, buffer in ipairs(state.buffers) do
			buffer.texture:Remove()
		end
	end

	state = {
		width = width,
		height = height,
		buffers = {},
		-- the async cull samples the pyramid built during the previous frame, so the
		-- frame that rebuilds it must not write the one an in-flight cull is reading
		write_index = 1,
		latest = nil,
	}

	for index = 1, HIZ_BUFFER_COUNT do
		state.buffers[index] = create_main_view_hiz_buffer(width, height, index)
	end

	gpu_culling.main_view_hiz_state = state
	return state
end

local function get_main_view_hiz_state()
	local depth_texture = render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture()
	return ensure_main_view_hiz_state(depth_texture:GetWidth(), depth_texture:GetHeight()),
	depth_texture
end

-- Records a rebuild of the hi-z pyramid from the gbuffer depth into cmd. render3d calls
-- this once per frame, right after the gbuffer pass, so the depth is complete. The
-- pyramid it produces is what the *next* frame's culling samples.
function gpu_culling.PrepareMainViewHiZ(cmd)
	if gpu_culling.GetOcclusionMode() ~= "hiz" then return end

	local state, depth_texture = get_main_view_hiz_state()
	local buffer = state.buffers[state.write_index]
	-- an async cull submitted a frame ago may still be sampling this pyramid, and it
	-- was submitted separately from cmd, so nothing but the fence orders them
	gpu_culling.WaitForCullsSamplingHiZ(buffer)
	local descriptor_base = math.max(render.GetCurrentFrame() or 1, 1) * 16
	local copy_pass = gpu_culling.main_view_hiz_build_pass
	-- the texture rather than its view and sampler, so the descriptor names its sampled layout
	copy_pass:UpdateDescriptorSet("combined_image_sampler", descriptor_base, 0, 0, depth_texture)
	copy_pass:UpdateDescriptorSet("storage_image", descriptor_base, 1, 0, buffer.single_mip_views[1])
	copy_pass:DispatchForSize(cmd, state.width, state.height, 1, descriptor_base)
	cmd:PipelineBarrier(buffer.mip_barriers[1])
	local reduce_pass = gpu_culling.main_view_hiz_reduce_pass

	for mip_level = 1, buffer.max_mip do
		local reduce_descriptor_slot = descriptor_base + mip_level
		reduce_pass:UpdateDescriptorSet(
			"storage_image",
			reduce_descriptor_slot,
			0,
			0,
			buffer.single_mip_views[mip_level]
		)
		reduce_pass:UpdateDescriptorSet(
			"storage_image",
			reduce_descriptor_slot,
			1,
			0,
			buffer.single_mip_views[mip_level + 1]
		)
		reduce_pass:DispatchForSize(
			cmd,
			math.max(1, math.floor((state.width + (2 ^ mip_level) - 1) / (2 ^ mip_level))),
			math.max(1, math.floor((state.height + (2 ^ mip_level) - 1) / (2 ^ mip_level))),
			1,
			reduce_descriptor_slot
		)
		cmd:PipelineBarrier(buffer.mip_barriers[mip_level + 1])
	end

	buffer.built = true
	state.latest = buffer
	state.write_index = (state.write_index % HIZ_BUFFER_COUNT) + 1
end

local function bind_main_view_hiz(pass, descriptor_slot, output, state, hiz_buffer)
	hiz_buffer = hiz_buffer or state.buffers[1]

	if output.last_hiz_view == hiz_buffer.view and output.last_hiz_pass == pass then
		return
	end

	pass:UpdateDescriptorSet(
		"combined_image_sampler",
		descriptor_slot,
		14,
		0,
		hiz_buffer.view,
		hiz_buffer.sampler,
		nil,
		nil,
		"general"
	)
	output.last_hiz_view = hiz_buffer.view
	output.last_hiz_pass = pass
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

local function get_gbuffer_batch_mesh_keys(mesh)
	-- a mesh not uploaded yet (NULL) gets its own bucket
	if not mesh:IsValid() then return mesh, NO_INDEX_BUFFER_KEY end

	return mesh.vertex_buffer:GetBuffer(),
	mesh.index_buffer and mesh.index_buffer:GetBuffer() or NO_INDEX_BUFFER_KEY
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
	local mesh = entry.polygon3d:GetMesh()

	if mesh:IsValid() and not mesh.index_buffer then
		local vertex_count = mesh:GetVertexCount()

		if vertex_count > 0 then
			local sequential_indices = {}

			for i = 1, vertex_count do
				sequential_indices[i] = i - 1
			end

			mesh:UploadIndices(sequential_indices, vertex_count > 65535 and "uint32_t" or "uint16_t")
		end
	end

	return mesh, mesh.index_buffer
end

local function serialize_render_entry(component, entry, entry_index, dynamic)
	local material = component:GetResolvedMaterial(entry)
	local mesh, index_buffer = ensure_entry_index_buffer(entry)
	local world_matrix = entry.transform:GetWorldMatrix()
	local has_height_displacement = material:HasHeightMap()
	return {
		component = component,
		source_entry = entry,
		entry_index = entry_index,
		polygon_guid = entry.polygon3d:GetGUID(),
		material_guid = material:GetGUID(),
		ignore_z = material:GetIgnoreZ(),
		transparent = material:IsTransparent(),
		has_height_displacement = has_height_displacement,
		-- ignore z and translucent materials are drawn by the forward passes
		gbuffer_instancing_eligible = not material:GetIgnoreZ() and not material:IsTransparent(),
		shadow_instancing_eligible = not has_height_displacement,
		batch_mesh = mesh,
		batch_material = material,
		batch_material_key = material.upload_cache_key or material,
		world_matrix = world_matrix,
		instanced_batch_index = nil,
		static_matrix_index = nil,
		source_aabb = serialize_aabb(entry.source_aabb),
		local_aabb = serialize_aabb(entry.aabb),
		index_count = index_buffer and index_buffer:GetIndexCount() or 0,
	}
end

local function get_aabb_sphere_radius(aabb)
	if not aabb then return 0 end

	local extent_x = math.max(aabb.max_x - aabb.min_x, 0)
	local extent_y = math.max(aabb.max_y - aabb.min_y, 0)
	local extent_z = math.max(aabb.max_z - aabb.min_z, 0)
	return math.sqrt(extent_x * extent_x + extent_y * extent_y + extent_z * extent_z) * 0.5
end

local function serialize_component(component, dynamic)
	local owner = component.Owner
	local serialized_entries = {}
	local shadow_aabb_cullable = true
	local world_aabb = serialize_aabb(component:GetWorldAABB())

	for i, entry in ipairs(component:GetRenderEntries()) do
		serialized_entries[i] = serialize_render_entry(component, entry, i, dynamic)

		if serialized_entries[i].has_height_displacement then
			shadow_aabb_cullable = false
		end
	end

	return {
		component = component,
		component_guid = component:GetGUID(),
		owner = owner,
		owner_guid = owner and owner:GetGUID() or nil,
		name = owner and owner.Name or tostring(component),
		dynamic = dynamic == true,
		visible = component.Visible == true,
		cast_shadows = component.CastShadows == true,
		use_occlusion_culling = component.UseOcclusionCulling == true,
		cull_distance = component:GetCullDistance(),
		model_path = component:GetModelPath(),
		shadow_change_version = component.shadow_change_version or 0,
		world_aabb = world_aabb,
		sphere_radius = get_aabb_sphere_radius(world_aabb),
		shadow_aabb_cullable = shadow_aabb_cullable,
		render_entry_count = #serialized_entries,
		entries = serialized_entries,
	}
end

local function get_visual_flags(serialized_visual, extra_flags)
	local flags = extra_flags

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

-- side_scale below 1 shrinks the projection's lateral rows, which is exactly a wider
-- field of view. Async culling runs a frame ahead of the draws that use it, so the
-- frustum is widened slightly to keep objects rotating into view from popping in late.
local function extract_frustum_planes(proj_view_matrix, out_planes, side_scale)
	local m = proj_view_matrix
	local x0, x1, x2, x3 = m.m00 * side_scale, m.m10 * side_scale, m.m20 * side_scale, m.m30 * side_scale
	local y0, y1, y2, y3 = m.m01 * side_scale, m.m11 * side_scale, m.m21 * side_scale, m.m31 * side_scale
	out_planes[0] = m.m03 + x0
	out_planes[1] = m.m13 + x1
	out_planes[2] = m.m23 + x2
	out_planes[3] = m.m33 + x3
	out_planes[4] = m.m03 - x0
	out_planes[5] = m.m13 - x1
	out_planes[6] = m.m23 - x2
	out_planes[7] = m.m33 - x3
	out_planes[8] = m.m03 + y0
	out_planes[9] = m.m13 + y1
	out_planes[10] = m.m23 + y2
	out_planes[11] = m.m33 + y3
	out_planes[12] = m.m03 - y0
	out_planes[13] = m.m13 - y1
	out_planes[14] = m.m23 - y2
	out_planes[15] = m.m33 - y3
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

local function remove_buffer(buffer)
	if buffer then buffer:Remove() end
end

local function grow_capacity(required, previous)
	local grown = math.ceil((previous or 0) * 1.5)
	return grown > required and grown or required
end

-- A slot's buffers are read by the gpu long after its cull finished: the draws that
-- consume them are recorded into the frame command buffer and submitted at end of
-- frame. Destroying or rewriting one while that is outstanding is what produced the
-- flickering, so every teardown drains first.
local function wait_for_pending_culls()
	local queue = render.GetQueue()

	for _, output in ipairs(gpu_culling.frame_buffers or {}) do
		if output.cull_pending_serial then
			output.cull_fence:Wait()
			queue:RetireFence(output.cull_fence)
			output.cull_pending_serial = nil
		end
	end
end

local function clear_frame_buffers()
	wait_for_pending_culls()

	for _, frame_buffers in ipairs(gpu_culling.frame_buffers or {}) do
		remove_buffer(frame_buffers.visible_index_buffer)
		remove_buffer(frame_buffers.entry_visibility_buffer)
		remove_buffer(frame_buffers.fallback_visible_index_buffer)
		remove_buffer(frame_buffers.fallback_visible_count_buffer)
		remove_buffer(frame_buffers.main_instance_world_buffer)
		remove_buffer(frame_buffers.indirect_command_buffer)
		remove_buffer(frame_buffers.indirect_count_buffer)
		remove_buffer(frame_buffers.visible_instanced_batch_count_buffer)
		remove_buffer(frame_buffers.visible_batch_indirect_command_buffer)
		remove_buffer(frame_buffers.active_batch_index_buffer)
		remove_buffer(frame_buffers.active_batch_count_buffer)
		frame_buffers.visible_instance_vertex_buffer:Remove()

		if frame_buffers.cull_cmd then frame_buffers.cull_cmd:Remove() end

		if frame_buffers.cull_fence then frame_buffers.cull_fence:Remove() end
	end

	gpu_culling.frame_buffers = nil
	gpu_culling.frame_buffers_capacity = nil
	gpu_culling.async_slot_indices = nil
	gpu_culling.published_async_slot = nil
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

local function create_buffer_with_data(label, byte_capacity, usage, data, data_byte_size)
	local buffer = render.CreateBuffer{
		byte_size = math.max(byte_capacity, 1),
		buffer_usage = usage,
		memory_property = {"host_visible", "host_coherent"},
		label = label,
	}

	if data then buffer:CopyData(data, data_byte_size) end

	return buffer
end

local function ensure_shadow_query_output_descriptor_capacity(descriptor_slot)
	descriptor_slot = math.max(tonumber(descriptor_slot) or 1, 1)

	if descriptor_slot > gpu_culling.MAX_SHADOW_QUERY_OUTPUTS then
		error(
			"gpu_culling: more than " .. gpu_culling.MAX_SHADOW_QUERY_OUTPUTS .. " shadow views (each point shadow face and sun cascade is one)",
			2
		)
	end

	if descriptor_slot > (gpu_culling.shadow_query_output_descriptor_count or 0) then
		gpu_culling.shadow_query_output_descriptor_count = descriptor_slot
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
	shadow_entry_capacity = math.max(shadow_entry_capacity or (layout and layout.shadow_entry_capacity) or 0, 1)
	shadow_instanced_batch_count = math.max(
		shadow_instanced_batch_count or
			(
				layout and
				layout.shadow_instanced_batch_capacity
			)
			or
			0,
		1
	)
	shadow_instance_capacity = math.max(shadow_instance_capacity or (layout and layout.shadow_instance_capacity) or 0, 1)
	label_prefix = label_prefix or "gpu_culling_shadow_query"
	descriptor_slot = descriptor_slot and
		ensure_shadow_query_output_descriptor_capacity(descriptor_slot) or
		allocate_shadow_query_output_descriptor_slot()
	return {
		label_prefix = label_prefix,
		generation = gpu_culling.generation,
		descriptor_slot = descriptor_slot,
		shadow_entry_capacity = shadow_entry_capacity,
		shadow_instanced_batch_count = shadow_instanced_batch_count,
		shadow_instance_capacity = shadow_instance_capacity,
		shadow_visible_index_buffer = create_buffer(
			label_prefix .. "_visible_indices",
			shadow_entry_capacity * UINT32_SIZE,
			{"storage_buffer"}
		),
		shadow_visible_count_buffer = create_buffer(label_prefix .. "_visible_count", UINT32_SIZE, {"storage_buffer", "transfer_dst"}),
		shadow_fallback_visible_index_buffer = create_buffer(
			label_prefix .. "_fallback_visible_indices",
			shadow_entry_capacity * UINT32_SIZE,
			{"storage_buffer"}
		),
		shadow_fallback_visible_count_buffer = create_buffer(
			label_prefix .. "_fallback_visible_count",
			UINT32_SIZE,
			{"storage_buffer", "transfer_dst"}
		),
		shadow_active_batch_index_buffer = create_buffer(
			label_prefix .. "_active_batch_indices",
			shadow_instanced_batch_count * UINT32_SIZE,
			{"storage_buffer"}
		),
		shadow_active_batch_count_buffer = create_buffer(
			label_prefix .. "_active_batch_count",
			UINT32_SIZE,
			{"storage_buffer", "transfer_dst"}
		),
		shadow_visible_instanced_batch_count_buffer = create_buffer(
			label_prefix .. "_visible_instanced_batch_counts",
			shadow_instanced_batch_count * UINT32_SIZE,
			{"storage_buffer", "transfer_dst"}
		),
		shadow_visible_batch_indirect_command_buffer = create_buffer(
			label_prefix .. "_visible_batch_indirect_commands",
			shadow_instanced_batch_count * DRAW_INDIRECT_COMMAND_SIZE,
			{"storage_buffer", "indirect_buffer", "transfer_dst"}
		),
		shadow_instance_world_buffer = create_buffer(
			label_prefix .. "_instance_worlds",
			shadow_instance_capacity * 16 * ffi.sizeof("float"),
			{"storage_buffer"}
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
	remove_buffer(output.shadow_instance_world_buffer)

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

function gpu_culling.RecreateShadowQueryOutput(output)
	if not output then return nil end

	remove_shadow_query_output(output)
	local fresh = create_shadow_query_output(
		output.label_prefix,
		output.shadow_entry_capacity,
		output.shadow_instanced_batch_count,
		output.shadow_instance_capacity,
		output.descriptor_slot
	)

	for key, value in pairs(fresh) do
		output[key] = value
	end

	output.last_hiz_view = nil
	output.last_hiz_pass = nil
	output.sampled_hiz_buffer = nil
	output.cull_pending_serial = nil
	return output
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
	result.dataset_generation = nil
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

local function build_frame_buffers(dataset, capacity)
	if not dataset then return nil end

	local device = render.GetDevice()

	if not device:IsValid() then return nil end

	local frame_count, async_slot_count = get_cull_slot_count()
	local total_slot_count = frame_count + async_slot_count
	local visible_entry_capacity = math.max(capacity.entry_count, 1)
	local instanced_batch_count = math.max(capacity.batch_count, 1)
	local static_instance_capacity = math.max(capacity.instance_count, 1)
	local frame_buffers = {}
	local async_slot_indices = {}

	for frame_index = 1, total_slot_count do
		frame_buffers[frame_index] = {
			frame_index = frame_index,
			visible_entry_capacity = visible_entry_capacity,
			entry_visibility_capacity = visible_entry_capacity,
			instanced_batch_count = instanced_batch_count,
			visible_index_buffer = create_buffer(
				"gpu_culling_visible_indices_" .. frame_index,
				visible_entry_capacity * UINT32_SIZE,
				{"storage_buffer"}
			),
			entry_visibility_buffer = create_buffer(
				"gpu_culling_entry_visibility_" .. frame_index,
				visible_entry_capacity * UINT32_SIZE,
				{"storage_buffer", "transfer_dst"}
			),
			fallback_visible_index_buffer = create_buffer(
				"gpu_culling_fallback_visible_indices_" .. frame_index,
				visible_entry_capacity * UINT32_SIZE,
				{"storage_buffer"}
			),
			fallback_visible_count_buffer = create_buffer(
				"gpu_culling_fallback_visible_count_" .. frame_index,
				UINT32_SIZE,
				{"storage_buffer", "transfer_dst"}
			),
			main_instance_world_buffer = create_buffer(
				"gpu_culling_main_instance_worlds_" .. frame_index,
				math.max(static_instance_capacity * 16, 16) * ffi.sizeof("float"),
				{"storage_buffer"}
			),
			indirect_command_buffer = create_buffer(
				"gpu_culling_indirect_commands_" .. frame_index,
				visible_entry_capacity * DRAW_INDEXED_INDIRECT_COMMAND_SIZE,
				{"storage_buffer", "indirect_buffer"}
			),
			indirect_count_buffer = create_buffer(
				"gpu_culling_indirect_count_" .. frame_index,
				UINT32_SIZE,
				{"storage_buffer", "indirect_buffer", "transfer_dst"}
			),
			visible_instanced_batch_count_buffer = create_buffer(
				"gpu_culling_visible_instanced_batch_counts_" .. frame_index,
				instanced_batch_count * UINT32_SIZE,
				{"storage_buffer", "transfer_dst"}
			),
			visible_batch_indirect_command_buffer = create_buffer(
				"gpu_culling_visible_batch_indirect_commands_" .. frame_index,
				instanced_batch_count * gpu_culling.BATCH_COMMAND_GROUP_COUNT * DRAW_INDEXED_INDIRECT_COMMAND_SIZE,
				{"storage_buffer", "indirect_buffer", "transfer_dst"}
			),
			batch_command_capacity = instanced_batch_count,
			active_batch_index_buffer = create_buffer(
				"gpu_culling_active_batch_indices_" .. frame_index,
				instanced_batch_count * UINT32_SIZE,
				{"storage_buffer"}
			),
			active_batch_count_buffer = create_buffer(
				"gpu_culling_active_batch_count_" .. frame_index,
				UINT32_SIZE,
				{"storage_buffer", "transfer_dst"}
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
			cull_cmd = render.CreateCommandBuffer(),
			cull_fence = Fence.New(device),
			cull_pending_serial = nil,
			cull_completed_serial = nil,
			cull_result = nil,
			-- the submission serial that must complete before the slot may be rewritten,
			-- captured from the frame that last drew using this slot's buffers
			release_serial = 0,
			published_frame = nil,
			sampled_hiz_buffer = nil,
			shadow_view_cull_result = nil,
		}
	end

	for index = 1, async_slot_count do
		async_slot_indices[index] = frame_count + index
	end

	gpu_culling.async_slot_indices = async_slot_indices
	gpu_culling.published_async_slot = nil
	return frame_buffers
end

local function collect_cull_result(output)
	local visible_count = tonumber(ffi.cast("uint32_t*", output.indirect_count_buffer:Map())[0])
	local result = update_cull_result(
		output.cull_result or {},
		output.frame_index,
		visible_count,
		ffi.cast("uint32_t*", output.visible_index_buffer:Map()),
		tonumber(ffi.cast("uint32_t*", output.fallback_visible_count_buffer:Map())[0]),
		ffi.cast("uint32_t*", output.fallback_visible_index_buffer:Map()),
		visible_count,
		true
	)
	result.entry_visibility_ptr = ffi.cast("uint32_t*", output.entry_visibility_buffer:Map())
	result.entry_visibility_count = output.entry_visibility_capacity
	result.dataset_generation = output.cull_dataset_generation
	return result
end

local function update_async_slot_completion(output, queue)
	if not output.cull_pending_serial then return end

	if not output.cull_fence:IsSignaled() then return end

	if queue:HasPendingSubmission(output.cull_fence) then
		queue:RetireFence(output.cull_fence)
	end

	output.cull_result = collect_cull_result(output)
	output.cull_completed_serial = output.cull_pending_serial
	output.cull_pending_serial = nil
end

-- Waiting must still land the cull's result. Dropping it let the slot be dispatched
-- into again, and when the gpu ran a frame behind every cull was dropped this way,
-- so the published result stayed stale for seconds.
function gpu_culling.WaitForCullsSamplingHiZ(hiz_buffer)
	local queue = render.GetQueue()

	for _, output in ipairs(gpu_culling.frame_buffers or {}) do
		if output.cull_pending_serial and output.sampled_hiz_buffer == hiz_buffer then
			output.cull_fence:Wait()
			update_async_slot_completion(output, queue)
		end
	end
end

-- The freshest slot whose cull has landed. Publishing pins it: nothing may dispatch into
-- it again until the frames that drew from it have retired.
local function publish_latest_async_result(frame_buffers)
	local queue = render.GetQueue()
	local latest = gpu_culling.published_async_slot

	for _, slot_index in ipairs(gpu_culling.async_slot_indices) do
		local output = frame_buffers[slot_index]
		update_async_slot_completion(output, queue)

		if
			output.cull_completed_serial and
			output.cull_result and
			(
				not latest or
				output.cull_completed_serial > latest.cull_completed_serial
			)
		then
			latest = output
		end
	end

	if not latest then return nil end

	gpu_culling.published_async_slot = latest
	latest.published_frame = system.GetFrameNumber()
	return latest.cull_result
end

-- A slot is reusable once its own cull has landed and every frame that drew from it has
-- completed on the gpu. The release serial is stamped a frame after publishing, by which
-- point the frame that consumed the slot has been submitted and has a serial to wait on.
local function acquire_async_slot(frame_buffers)
	local device = render.GetDevice()
	local completed_serial = device:GetCompletedSubmissionSerial()
	local published = gpu_culling.published_async_slot

	for _, slot_index in ipairs(gpu_culling.async_slot_indices) do
		local output = frame_buffers[slot_index]

		if
			not output.cull_pending_serial and
			output ~= published and
			completed_serial >= output.release_serial
		then
			return output
		end
	end

	return nil
end

-- Called once per frame before dispatching. The slot published last frame was drawn from
-- by that frame's command buffer, which has been submitted by now, so its serial bounds
-- when the slot becomes writable again.
local function stamp_published_slot_release(frame_buffers)
	local published = gpu_culling.published_async_slot

	if not published then return end

	local current_frame = system.GetFrameNumber()

	if published.published_frame == current_frame then return end

	published.release_serial = render.GetDevice().last_submission_serial or 0
end

local function should_use_async_main_view_culling()
	if not gpu_culling.IsAsyncMainViewEnabled() then return false end

	if test_helper.GetCurrentRunningTestName() ~= "" then return false end

	local active_task = tasks.GetActiveTask()

	if active_task and active_task.is_test_task then return false end

	return true
end

--[[
	The scene dataset persists across scene changes. Every visual, render entry,
	instance matrix and instanced batch owns a stable slot, so adding, removing
	or moving one visual patches its own records and uploads only those, instead
	of re-serializing the whole scene.

	Because slots are stable, a cull result stays usable after a patch: its
	indices still name the same records, or a DEAD_ENTRY once a visual is gone.
	Only a rebuild (the first build, compaction, a full invalidation) or a
	reallocation of the per-frame buffers starts a new generation.

	Batches own a region of the per-frame instance output. A batch that outgrows
	its region moves to a bigger one at the end, and the space it leaves is
	reclaimed by the next compaction.
]]
local DEAD_ENTRY = {}
gpu_culling.DEAD_ENTRY = DEAD_ENTRY
local VISUAL_RECORD_SIZE = ffi.sizeof(GPUCullVisualRecord)
local ENTRY_RECORD_SIZE = ffi.sizeof(GPUCullEntryRecord)
local BATCH_RECORD_SIZE = ffi.sizeof(GPUCullInstancedBatchRecord)
local MATRIX_SIZE = 16 * ffi.sizeof("float")
local VisualRecordArray = ffi.typeof("$[?]", GPUCullVisualRecord)
local EntryRecordArray = ffi.typeof("$[?]", GPUCullEntryRecord)
local BatchRecordArray = ffi.typeof("$[?]", GPUCullInstancedBatchRecord)
local FloatArray = ffi.typeof("float[?]")
-- a cull result a few frames old may still name a freed batch, so its index is
-- only handed to a different mesh and material once those results are gone
local BATCH_RECYCLE_DELAY = 8

local function registry_insert(registry, index_field, value)
	registry[#registry + 1] = value
	value[index_field] = #registry
end

local function registry_remove(registry, index_field, value)
	local index = value[index_field]
	local last_index = #registry
	local last = registry[last_index]
	registry[index] = last
	registry[last_index] = nil
	value[index_field] = nil

	if last ~= value then last[index_field] = index end
end

local function grow_array(ctype, old, old_capacity, required, element_size)
	local capacity = grow_capacity(required, old_capacity)
	local new = ctype(capacity)

	if old then ffi.copy(new, old, old_capacity * element_size) end

	return new, capacity
end

local function ensure_visual_capacity(view, count)
	if count <= view.visual_capacity then return end

	view.visual_records, view.visual_capacity = grow_array(
		VisualRecordArray,
		view.visual_records,
		view.visual_capacity,
		count,
		VISUAL_RECORD_SIZE
	)
end

local function ensure_entry_capacity(view, count)
	if count <= view.entry_capacity then return end

	view.entry_records, view.entry_capacity = grow_array(
		EntryRecordArray,
		view.entry_records,
		view.entry_capacity,
		count,
		ENTRY_RECORD_SIZE
	)
end

local function ensure_batch_capacity(view, count)
	if count <= view.batch_capacity then return end

	view.batch_records, view.batch_capacity = grow_array(
		BatchRecordArray,
		view.batch_records,
		view.batch_capacity,
		count,
		BATCH_RECORD_SIZE
	)
end

local function ensure_matrix_capacity(view, count)
	if count <= view.matrix_capacity then return end

	local capacity = grow_capacity(count, view.matrix_capacity)
	local worlds = FloatArray(capacity * 16)

	if view.worlds then
		ffi.copy(worlds, view.worlds, view.matrix_capacity * MATRIX_SIZE)
	end

	view.worlds = worlds
	view.matrix_capacity = capacity
end

-- unique across views, so a table keyed on a view's serial notices a new
-- dataset's view as well
local last_batch_serial = 0

local function next_batch_serial()
	last_batch_serial = last_batch_serial + 1
	return last_batch_serial
end

local function create_view(is_main)
	local view = {
		is_main = is_main,
		visual_flags = is_main and 0 or VISUAL_FLAG_SHADOW_NON_AABB,
		visuals = {},
		visual_free = {},
		visual_count = 0,
		live_visual_count = 0,
		entries = {},
		entry_free = {},
		entry_count = 0,
		entry_waste = 0,
		matrix_free = {},
		matrix_count = 0,
		batches = {},
		-- changes whenever a batch gets a mesh or material
		batch_serial = next_batch_serial(),
		batch_lookup = {},
		batch_free = {},
		batch_free_head = 1,
		batch_free_tail = 0,
		dead_batch_count = 0,
		output_count = 0,
		output_waste = 0,
		output_capacity = 1,
		visual_capacity = 0,
		entry_capacity = 0,
		batch_capacity = 0,
		matrix_capacity = 0,
		dirty_visuals = {},
		dirty_entries = {},
		dirty_batches = {},
		-- matrix indices written since world_log_base; outputs replay the log to
		-- catch up, or copy every matrix when they fell behind a truncation
		world_log = {},
		world_log_base = 0,
		dynamic = {},
		-- during a rebuild batches only count their instances, and their output
		-- regions are laid out once every visual is in
		deferred_layout = true,
	}
	ensure_visual_capacity(view, 1)
	ensure_entry_capacity(view, 1)
	ensure_batch_capacity(view, 1)
	ensure_matrix_capacity(view, 1)
	return view
end

local function alloc_visual_slot(view)
	local free = view.visual_free
	local slot = free[#free]

	if slot then
		free[#free] = nil
		return slot
	end

	slot = view.visual_count
	view.visual_count = slot + 1
	ensure_visual_capacity(view, slot + 1)
	return slot
end

local function alloc_entry_span(view, count)
	local free = view.entry_free[count]
	local offset = free and free[#free]

	if offset then
		free[#free] = nil
		view.entry_waste = view.entry_waste - count
		return offset
	end

	offset = view.entry_count
	view.entry_count = offset + count
	ensure_entry_capacity(view, offset + count)
	return offset
end

local function free_entry_span(view, offset, count)
	local free = view.entry_free[count]

	if not free then
		free = {}
		view.entry_free[count] = free
	end

	free[#free + 1] = offset
	view.entry_waste = view.entry_waste + count
end

local function alloc_matrix(view)
	local free = view.matrix_free
	local index = free[#free]

	if index then
		free[#free] = nil
		return index
	end

	index = view.matrix_count
	view.matrix_count = index + 1
	ensure_matrix_capacity(view, index + 1)
	return index
end

local function write_batch_record(view, batch)
	local record = view.batch_records[batch.batch_index]
	local index_buffer = batch.mesh.index_buffer
	record.output_offset = batch.output_offset or 0
	record.max_count = batch.capacity or 0
	record.index_count = index_buffer and index_buffer:GetIndexCount() or 0
	record.first_index = batch.material and index_buffer and index_pool.GetFirstIndex(index_buffer) or 0
	-- a freed batch has no material and draws nothing
	record.flags = batch.material and
		(
			(
				batch.material:GetDoubleSided() and
				BATCH_FLAG_DOUBLE_SIDED or
				0
			) + (
				batch.material:HasHeightMap() and
				BATCH_FLAG_HEIGHT_MAP or
				0
			)
		)
		or
		0
	local dirty = view.dirty_batches
	dirty[#dirty + 1] = batch.batch_index
end

local function allocate_batch_output(view, batch, capacity)
	if batch.capacity then
		view.output_waste = view.output_waste + batch.capacity
	end

	batch.output_offset = view.output_count
	batch.capacity = capacity
	view.output_count = view.output_count + capacity
end

local function pop_recyclable_batch(view)
	local free = view.batch_free
	local frame = system.GetFrameNumber()

	while true do
		local record = free[view.batch_free_head]

		if not record then return nil end

		-- a batch that was revived, or freed again later, left a stale record
		if record.batch.freed_frame ~= record.frame then
			free[view.batch_free_head] = nil
			view.batch_free_head = view.batch_free_head + 1
		elseif record.frame + BATCH_RECYCLE_DELAY <= frame then
			free[view.batch_free_head] = nil
			view.batch_free_head = view.batch_free_head + 1
			return record.batch
		else
			return nil
		end
	end
end

local function acquire_batch(view, entry)
	local mesh = entry.batch_mesh
	local material_key = entry.batch_material_key
	local mesh_batches = get_or_create_instanced_batch_bucket(view.batch_lookup, mesh)
	local batch = mesh_batches[material_key]

	if not batch or batch.freed_frame then
		if batch then
			view.dead_batch_count = view.dead_batch_count - 1
			batch.freed_frame = nil
		else
			batch = pop_recyclable_batch(view)

			if batch then
				view.dead_batch_count = view.dead_batch_count - 1
				batch.freed_frame = nil
				batch.lookup[batch.material_key] = nil
			else
				batch = {batch_index = #view.batches, count = 0}
				view.batches[#view.batches + 1] = batch
				ensure_batch_capacity(view, #view.batches)
			end

			batch.material_key = material_key
			batch.lookup = mesh_batches
			mesh_batches[material_key] = batch
		end

		batch.mesh = mesh
		batch.material = entry.batch_material
		batch.first_polygon3d = entry.source_entry.polygon3d
		view.batch_serial = next_batch_serial()

		if not view.deferred_layout then
			if not batch.capacity then allocate_batch_output(view, batch, 2) end

			write_batch_record(view, batch)
		end
	end

	if not view.deferred_layout and batch.count >= batch.capacity then
		allocate_batch_output(view, batch, batch.capacity * 2)
		write_batch_record(view, batch)
	end

	batch.count = batch.count + 1
	return batch
end

local function release_batch(view, batch)
	batch.count = batch.count - 1

	if batch.count > 0 then return end

	local frame = system.GetFrameNumber()
	batch.freed_frame = frame
	view.dead_batch_count = view.dead_batch_count + 1
	-- the mesh and material may be removed along with their last visual, and
	-- the draws skip a batch whose mesh is not valid
	batch.mesh = NULL
	batch.material = nil
	batch.first_polygon3d = nil
	view.batch_free_tail = view.batch_free_tail + 1
	view.batch_free[view.batch_free_tail] = {batch = batch, frame = frame}
end

local function layout_batches(view)
	view.deferred_layout = false
	view.output_count = 0
	view.output_waste = 0

	for _, batch in ipairs(view.batches) do
		batch.capacity = nil
		allocate_batch_output(view, batch, batch.count + math.ceil(batch.count / 8))
		write_batch_record(view, batch)
	end
end

local function write_entry_world(view, entry)
	local source_entry = entry.source_entry
	local world_matrix = source_entry.transform and
		source_entry.transform:GetWorldMatrix() or
		entry.component:GetWorldMatrix()
	world_matrix:CopyToFloatPointer(view.worlds + entry.static_matrix_index * 16)
	local log = view.world_log
	log[#log + 1] = entry.static_matrix_index
end

local function write_entry_record(view, entry, visual_slot)
	local record = view.entry_records[entry.slot]
	local aabb = entry.local_aabb

	if aabb then
		record.local_min_x = aabb.min_x
		record.local_min_y = aabb.min_y
		record.local_min_z = aabb.min_z
		record.local_max_x = aabb.max_x
		record.local_max_y = aabb.max_y
		record.local_max_z = aabb.max_z
	else
		record.local_min_x = 0
		record.local_min_y = 0
		record.local_min_z = 0
		record.local_max_x = 0
		record.local_max_y = 0
		record.local_max_z = 0
	end

	aabb = entry.source_aabb

	if aabb then
		record.source_min_x = aabb.min_x
		record.source_min_y = aabb.min_y
		record.source_min_z = aabb.min_z
		record.source_max_x = aabb.max_x
		record.source_max_y = aabb.max_y
		record.source_max_z = aabb.max_z
	else
		record.source_min_x = 0
		record.source_min_y = 0
		record.source_min_z = 0
		record.source_max_x = 0
		record.source_max_y = 0
		record.source_max_z = 0
	end

	record.visual_index = visual_slot
	record.entry_index = entry.entry_index - 1
	record.index_count = entry.index_count
	record.flags = get_entry_flags(entry)
	record.instanced_batch_index = entry.instanced_batch_index or INVALID_INDEX
	record.static_matrix_index = entry.static_matrix_index or INVALID_INDEX
	local dirty = view.dirty_entries
	dirty[#dirty + 1] = entry.slot
end

local function write_visual_record(view, serialized)
	local record = view.visual_records[serialized.slot]
	local aabb = serialized.world_aabb

	if aabb then
		record.min_x = aabb.min_x
		record.min_y = aabb.min_y
		record.min_z = aabb.min_z
		record.max_x = aabb.max_x
		record.max_y = aabb.max_y
		record.max_z = aabb.max_z
	else
		record.min_x = 0
		record.min_y = 0
		record.min_z = 0
		record.max_x = 0
		record.max_y = 0
		record.max_z = 0
	end

	record.sphere_radius = serialized.sphere_radius
	record.cull_distance = serialized.cull_distance
	record.flags = get_visual_flags(serialized, view.visual_flags)
	record.entry_offset = serialized.entry_offset
	record.entry_count = serialized.render_entry_count
	record.shadow_change_version = serialized.shadow_change_version
	local dirty = view.dirty_visuals
	dirty[#dirty + 1] = serialized.slot
end

local function add_visual(dataset, view, component, kind)
	local dynamic = kind ~= "static"
	local serialized = serialize_component(component, dynamic)
	local slot = alloc_visual_slot(view)
	local count = serialized.render_entry_count
	serialized.view = view
	serialized.kind = kind
	serialized.slot = slot
	serialized.entry_offset = count > 0 and alloc_entry_span(view, count) or 0

	for i, entry in ipairs(serialized.entries) do
		entry.slot = serialized.entry_offset + i - 1
		view.entries[entry.slot + 1] = entry

		if
			view.is_main and
			entry.gbuffer_instancing_eligible or
			not view.is_main and
			entry.shadow_instancing_eligible
		then
			local batch = acquire_batch(view, entry)
			entry.batch = batch
			entry.instanced_batch_index = batch.batch_index
			entry.static_matrix_index = alloc_matrix(view)
			write_entry_world(view, entry)
		elseif not view.is_main then
			-- the shadow draw culls and draws entries it cannot instance on the
			-- cpu. non-aabb visuals are height displaced past their bounds, so
			-- they skip the bounds test
			entry.skip_shadow_aabb_cull = kind == "non_aabb"
			registry_insert(dataset.shadow_fallback_entries, "shadow_fallback_index", entry)
		end

		write_entry_record(view, entry, slot)
	end

	write_visual_record(view, serialized)
	view.visuals[slot + 1] = serialized
	view.live_visual_count = view.live_visual_count + 1

	if dynamic then registry_insert(view.dynamic, "dynamic_index", serialized) end

	return serialized
end

local function remove_visual(dataset, view, serialized)
	for _, entry in ipairs(serialized.entries) do
		if entry.batch then
			release_batch(view, entry.batch)
			local free = view.matrix_free
			free[#free + 1] = entry.static_matrix_index
			entry.batch = nil
		end

		if entry.shadow_fallback_index then
			registry_remove(dataset.shadow_fallback_entries, "shadow_fallback_index", entry)
		end

		view.entries[entry.slot + 1] = DEAD_ENTRY
		local record = view.entry_records[entry.slot]
		record.index_count = 0
		record.instanced_batch_index = INVALID_INDEX
		record.static_matrix_index = INVALID_INDEX
		local dirty = view.dirty_entries
		dirty[#dirty + 1] = entry.slot
	end

	if serialized.render_entry_count > 0 then
		free_entry_span(view, serialized.entry_offset, serialized.render_entry_count)
	end

	local record = view.visual_records[serialized.slot]
	record.flags = 0
	record.entry_count = 0
	local dirty = view.dirty_visuals
	dirty[#dirty + 1] = serialized.slot
	view.visuals[serialized.slot + 1] = false
	view.visual_free[#view.visual_free + 1] = serialized.slot
	view.live_visual_count = view.live_visual_count - 1

	if serialized.dynamic_index then
		registry_remove(view.dynamic, "dynamic_index", serialized)
	end
end

-- bounds, flags and matrices change in place, the slots stay
local function refresh_visual(view, serialized)
	local component = serialized.component
	local world_aabb = serialize_aabb(component:GetWorldAABB())
	serialized.world_aabb = world_aabb
	serialized.sphere_radius = get_aabb_sphere_radius(world_aabb)
	serialized.visible = component.Visible == true
	serialized.cast_shadows = component.CastShadows == true
	serialized.use_occlusion_culling = component.UseOcclusionCulling == true
	serialized.cull_distance = component:GetCullDistance()
	serialized.shadow_change_version = component.shadow_change_version or 0
	write_visual_record(view, serialized)

	for _, entry in ipairs(serialized.entries) do
		if entry.static_matrix_index then write_entry_world(view, entry) end
	end
end

local function update_view_visual(dataset, view, component, field, kind, structure_changed)
	local serialized = component[field]

	-- left over from a dataset that was rebuilt since
	if serialized and serialized.view ~= view then serialized = nil end

	if serialized and kind == serialized.kind and not structure_changed then
		refresh_visual(view, serialized)
		return serialized
	end

	if serialized then remove_visual(dataset, view, serialized) end

	serialized = kind and add_visual(dataset, view, component, kind) or nil
	component[field] = serialized
	return serialized
end

local function sync_record_buffer(buffers, name, records, count, capacity, record_size, dirty, full)
	local buffer = buffers[name]

	if not buffer or buffer.size < capacity * record_size then
		if buffer then
			wait_for_pending_culls()
			remove_buffer(buffer)
		end

		buffer = create_buffer("gpu_culling_" .. name, capacity * record_size, {"storage_buffer"})
		buffers[name] = buffer
		full = true
	end

	local mapped = buffer:Map()

	if full or #dirty * 4 > count then
		if count > 0 then ffi.copy(mapped, records, count * record_size) end
	else
		for i = 1, #dirty do
			local index = dirty[i]
			ffi.copy(mapped + index * record_size, records + index, record_size)
		end
	end

	table.clear(dirty)
end

local function sync_view_buffers(buffers, view, prefix)
	local full = buffers[prefix .. "_view"] ~= view
	buffers[prefix .. "_view"] = view
	sync_record_buffer(
		buffers,
		prefix .. "_visual_buffer",
		view.visual_records,
		view.visual_count,
		view.visual_capacity,
		VISUAL_RECORD_SIZE,
		view.dirty_visuals,
		full
	)
	sync_record_buffer(
		buffers,
		prefix .. "_entry_buffer",
		view.entry_records,
		view.entry_count,
		view.entry_capacity,
		ENTRY_RECORD_SIZE,
		view.dirty_entries,
		full
	)
	sync_record_buffer(
		buffers,
		prefix .. "_instanced_batch_buffer",
		view.batch_records,
		#view.batches,
		view.batch_capacity,
		BATCH_RECORD_SIZE,
		view.dirty_batches,
		full
	)
end

local function prepare_view(view)
	if view.deferred_layout then layout_batches(view) end

	if view.output_count > view.output_capacity then
		view.output_capacity = grow_capacity(view.output_count, view.output_capacity)
	end

	local log = view.world_log

	if #log > math.max(4096, view.matrix_count) then
		view.world_log_base = view.world_log_base + #log
		view.world_log = {}
	end
end

local function get_instance_capacity(view)
	return math.max(view.matrix_capacity, view.output_capacity)
end

-- Brings an output's copy of the view's instance matrices up to date: it
-- replays the matrices written since its last sync, or copies all of them
-- when it is new, belongs to an older view or fell behind a log truncation.
local function sync_output_worlds(view, output, buffer)
	local log = view.world_log
	local base = view.world_log_base
	local serial = base + #log

	if
		output.world_view == view and
		output.world_matrix_capacity == view.matrix_capacity and
		output.world_serial >= base and
		(
			serial - output.world_serial
		) * 4 < view.matrix_count
	then
		if output.world_serial == serial then return end

		local mapped = buffer:Map()
		local worlds = view.worlds

		for i = output.world_serial - base + 1, #log do
			local index = log[i]
			ffi.copy(mapped + index * MATRIX_SIZE, worlds + index * 16, MATRIX_SIZE)
		end
	else
		if view.matrix_count > 0 then
			ffi.copy(buffer:Map(), view.worlds, view.matrix_count * MATRIX_SIZE)
		end

		output.world_view = view
		output.world_matrix_capacity = view.matrix_capacity
	end

	output.world_serial = serial
end

local function upload_shadow_instance_worlds(output, dataset)
	sync_output_worlds(dataset.shadow, output, output.shadow_instance_world_buffer)
end

local function upload_main_instance_worlds(output, dataset)
	sync_output_worlds(dataset.main, output, output.main_instance_world_buffer)
end

local function ensure_frame_buffers(dataset)
	local main = dataset.main
	local key = {
		entry_count = main.entry_capacity,
		batch_count = main.batch_capacity,
		instance_count = get_instance_capacity(main),
	}
	local previous = gpu_culling.frame_buffers_capacity

	if
		gpu_culling.frame_buffers and
		previous.entry_count >= key.entry_count and
		previous.batch_count >= key.batch_count and
		previous.instance_count >= key.instance_count
	then
		return gpu_culling.frame_buffers
	end

	local capacity = {
		entry_count = grow_capacity(key.entry_count, previous and previous.entry_count),
		batch_count = grow_capacity(key.batch_count, previous and previous.batch_count),
		instance_count = grow_capacity(key.instance_count, previous and previous.instance_count),
	}
	clear_frame_buffers()
	gpu_culling.frame_buffers = build_frame_buffers(dataset, capacity)
	gpu_culling.frame_buffers_capacity = gpu_culling.frame_buffers and capacity or nil
	-- cull results name the slots they were culled into, which are gone now
	gpu_culling.scene_acceleration_generation = gpu_culling.scene_acceleration_generation + 1
	dataset.generation = gpu_culling.scene_acceleration_generation
	return gpu_culling.frame_buffers
end

local function flush_scene_dataset()
	local dataset = gpu_culling.scene_dataset
	local device = render.GetDevice()

	if not (device and device:IsValid()) then return end

	local main = dataset.main
	local shadow = dataset.shadow
	prepare_view(main)
	prepare_view(shadow)

	-- a material that turned double sided or gained a height map moves its
	-- batches to another quarter of the main batch commands
	if main.material_flags_generation ~= Material.flags_generation then
		main.material_flags_generation = Material.flags_generation

		for _, batch in ipairs(main.batches) do
			write_batch_record(main, batch)
		end
	end

	ensure_frame_buffers(dataset)
	local buffers = gpu_culling.dataset_buffers or {}
	gpu_culling.dataset_buffers = buffers
	sync_view_buffers(buffers, main, "main")
	sync_view_buffers(buffers, shadow, "shadow")
	buffers.generation = dataset.generation
	buffers.layout = {
		generation = dataset.generation,
		main_visual_count = main.visual_count,
		main_entry_count = main.entry_count,
		main_instanced_batch_count = #main.batches,
		shadow_visual_count = shadow.visual_count,
		shadow_entry_capacity = shadow.entry_capacity,
		shadow_instanced_batch_capacity = shadow.batch_capacity,
		shadow_instance_capacity = get_instance_capacity(shadow),
	}
	gpu_culling.dataset_buffers_generation = dataset.generation
end

-- Starts an empty dataset. Visuals are added with UpdateSceneVisual and the
-- next PublishSceneAcceleration lays out the batches and uploads everything.
function gpu_culling.ResetSceneDataset()
	gpu_culling.scene_acceleration_generation = gpu_culling.scene_acceleration_generation + 1
	local main = create_view(true)
	local shadow = create_view(false)
	gpu_culling.scene_dataset = {
		generation = gpu_culling.scene_acceleration_generation,
		main = main,
		shadow = shadow,
		main_entries = main.entries,
		shadow_entries = shadow.entries,
		main_instanced_batches = main.batches,
		shadow_instanced_batches = shadow.batches,
		shadow_fallback_entries = {},
	}
end

-- main_kind is false, "static" or "dynamic", shadow_kind is false, "static",
-- "dynamic" or "non_aabb". structure_changed means the render entries changed,
-- which re-serializes the visual instead of refreshing it in place.
function gpu_culling.UpdateSceneVisual(component, main_kind, shadow_kind, structure_changed)
	local dataset = gpu_culling.scene_dataset
	local main = update_view_visual(dataset, dataset.main, component, "gpu_main_visual", main_kind, structure_changed)
	local shadow = update_view_visual(
		dataset,
		dataset.shadow,
		component,
		"gpu_shadow_visual",
		shadow_kind,
		structure_changed
	)
	component.main_gpu_entry_offset = main and main.entry_offset or nil
	component.main_gpu_entry_count = main and main.render_entry_count or nil
	component.shadow_gpu_entry_offset = shadow and shadow.entry_offset or nil
	component.shadow_gpu_entry_count = shadow and shadow.render_entry_count or nil
end

-- dynamic visuals can move every frame without being invalidated (interpolated
-- physics), so their bounds and matrices are refreshed once per frame
function gpu_culling.RefreshDynamicSceneVisuals()
	local dataset = gpu_culling.scene_dataset

	if not dataset then return end

	local main = dataset.main
	local shadow = dataset.shadow

	if not main.dynamic[1] and not shadow.dynamic[1] then return end

	for _, serialized in ipairs(main.dynamic) do
		refresh_visual(main, serialized)
	end

	for _, serialized in ipairs(shadow.dynamic) do
		refresh_visual(shadow, serialized)
	end

	flush_scene_dataset()
end

-- patches leave freed entry spans, output regions and batches behind; once
-- they make up a large part of the dataset it is cheaper to rebuild it
do
	local function is_view_fragmented(view)
		return view.entry_waste > 4096 and
			view.entry_waste * 2 > view.entry_count or
			view.output_waste > 4096 and
			view.output_waste * 2 > view.output_count or
			view.dead_batch_count > 256 and
			view.dead_batch_count * 2 > #view.batches
	end

	function gpu_culling.NeedsSceneDatasetCompaction()
		local dataset = gpu_culling.scene_dataset

		if not dataset then return false end

		return is_view_fragmented(dataset.main) or is_view_fragmented(dataset.shadow)
	end
end

function gpu_culling.PublishSceneAcceleration(acceleration)
	gpu_culling.scene_acceleration = acceleration
	flush_scene_dataset()
	return acceleration
end

function gpu_culling.GetSceneAcceleration()
	return gpu_culling.scene_acceleration
end

function gpu_culling.GetSceneDataset()
	return gpu_culling.scene_dataset
end

-- a cull result's visible indices point into the dataset that was current when
-- the cull was dispatched. if the scene changed since (terrain streaming does
-- this constantly), the indices no longer line up with the live dataset's
-- entry/batch lists and must not be consumed
function gpu_culling.IsCullResultCurrent(cull_result)
	local dataset = gpu_culling.scene_dataset

	if not dataset or not cull_result then return false end

	return cull_result.dataset_generation == dataset.generation
end

function gpu_culling.GetFrameBuffers()
	return gpu_culling.frame_buffers
end

function gpu_culling.GetDatasetBuffers()
	return gpu_culling.dataset_buffers
end

function gpu_culling.GetDatasetBuffersGeneration()
	return gpu_culling.dataset_buffers_generation or -1
end

function gpu_culling.GetUploadTypes()
	return {
		visual_record = GPUCullVisualRecord,
		entry_record = GPUCullEntryRecord,
		flags = {
			visual_visible = VISUAL_FLAG_VISIBLE,
			visual_cast_shadows = VISUAL_FLAG_CAST_SHADOWS,
			visual_use_occlusion = VISUAL_FLAG_USE_OCCLUSION,
			visual_dynamic = VISUAL_FLAG_DYNAMIC,
			visual_shadow_aabb_cullable = VISUAL_FLAG_SHADOW_AABB_CULLABLE,
			visual_shadow_non_aabb = VISUAL_FLAG_SHADOW_NON_AABB,
			entry_ignore_z = ENTRY_FLAG_IGNORE_Z,
			entry_height_displacement = ENTRY_FLAG_HEIGHT_DISPLACEMENT,
		},
		invalid_index = INVALID_INDEX,
	}
end

local function record_cull_dispatch(
	output,
	slot,
	dataset,
	dataset_buffers,
	visual_count,
	view_projection_matrix,
	camera_position,
	frustum_planes,
	read_visible_entry_indices
)
	local pass = gpu_culling.main_view_cull_pass
	output.cull_dataset_generation = dataset.generation
	local hiz_state = get_main_view_hiz_state()
	local hiz_buffer = hiz_state.latest
	local occlusion_enabled = gpu_culling.GetOcclusionMode() == "hiz" and hiz_buffer ~= nil
	upload_main_instance_worlds(output, dataset)
	pass.current_visual_count = visual_count
	pass.current_camera_position = camera_position
	pass.current_frustum_planes = frustum_planes
	pass.current_view_projection = view_projection_matrix
	pass.current_viewport_height = hiz_state.height
	pass.current_min_screen_diameter_px = 1.0
	pass.current_occlusion_enabled = occlusion_enabled
	pass.current_occlusion_depth_texture = occlusion_enabled and hiz_buffer or nil
	pass.current_occlusion_max_mip = occlusion_enabled and hiz_buffer.max_mip or 0
	pass.current_occlusion_depth_bias = 0.0
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
	pass:UpdateDescriptorSet(
		"storage_buffer",
		slot,
		15,
		0,
		output.entry_visibility_buffer,
		output.entry_visibility_buffer.size
	)
	bind_main_view_hiz(pass, slot, output, hiz_state, hiz_buffer)
	local cmd = output.cull_cmd
	cmd:Reset()
	cmd:Begin()
	-- zero the accumulators on the gpu rather than through a host write, so the clear is
	-- ordered against this slot's previous dispatch instead of racing it
	cmd:FillBuffer(output.indirect_count_buffer, 0, output.indirect_count_buffer.size, 0)
	cmd:FillBuffer(output.fallback_visible_count_buffer, 0, output.fallback_visible_count_buffer.size, 0)
	cmd:FillBuffer(output.active_batch_count_buffer, 0, output.active_batch_count_buffer.size, 0)
	cmd:FillBuffer(output.entry_visibility_buffer, 0, output.entry_visibility_buffer.size, 0)
	cmd:FillBuffer(
		output.visible_batch_indirect_command_buffer,
		0,
		output.visible_batch_indirect_command_buffer.size,
		0
	)
	cmd:FillBuffer(
		output.visible_instanced_batch_count_buffer,
		0,
		output.visible_instanced_batch_count_buffer.size,
		0
	)
	cmd:PipelineBarrier{
		srcStage = "transfer",
		dstStage = "compute",
		bufferBarriers = {
			{
				buffer = output.indirect_count_buffer,
				size = output.indirect_count_buffer.size,
				srcAccessMask = "transfer_write",
				dstAccessMask = {"shader_read", "shader_write"},
			},
			{
				buffer = output.fallback_visible_count_buffer,
				size = output.fallback_visible_count_buffer.size,
				srcAccessMask = "transfer_write",
				dstAccessMask = {"shader_read", "shader_write"},
			},
			{
				buffer = output.active_batch_count_buffer,
				size = output.active_batch_count_buffer.size,
				srcAccessMask = "transfer_write",
				dstAccessMask = {"shader_read", "shader_write"},
			},
			{
				buffer = output.entry_visibility_buffer,
				size = output.entry_visibility_buffer.size,
				srcAccessMask = "transfer_write",
				dstAccessMask = "shader_write",
			},
			{
				buffer = output.visible_batch_indirect_command_buffer,
				size = output.visible_batch_indirect_command_buffer.size,
				srcAccessMask = "transfer_write",
				dstAccessMask = {"shader_read", "shader_write"},
			},
			{
				buffer = output.visible_instanced_batch_count_buffer,
				size = output.visible_instanced_batch_count_buffer.size,
				srcAccessMask = "transfer_write",
				dstAccessMask = {"shader_read", "shader_write"},
			},
		},
	}
	pass:DispatchForSize(cmd, visual_count, 1, 1, slot)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"host", "vertex_input", "vertex_shader", "draw_indirect"},
		bufferBarriers = {
			{
				buffer = output.visible_index_buffer,
				size = output.visible_index_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = "host_read",
			},
			{
				buffer = output.entry_visibility_buffer,
				size = output.entry_visibility_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = "host_read",
			},
			{
				buffer = output.indirect_command_buffer,
				size = output.indirect_command_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = {"host_read", "indirect_command_read"},
			},
			{
				buffer = output.indirect_count_buffer,
				size = output.indirect_count_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = {"host_read", "indirect_command_read"},
			},
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
				dstAccessMask = {"vertex_attribute_read", "shader_read"},
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
		},
	}
	cmd:End()
	output.sampled_hiz_buffer = hiz_buffer
	return cmd
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

	if not (dataset and dataset_buffers and frame_buffers) then return nil end

	local read_visible_entry_indices = include_visible_entry_indices ~= false
	local use_async = should_use_async_main_view_culling()
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
			true
		)
		gpu_culling.empty_main_view_cull_result.dataset_generation = dataset.generation
		return gpu_culling.empty_main_view_cull_result
	end

	local frustum_planes = gpu_culling.main_view_cull_frustum_planes
	extract_frustum_planes(
		view_projection_matrix,
		frustum_planes,
		use_async and gpu_culling.async_frustum_scale or 1
	)

	if not use_async then
		local slot = resolve_frame_slot(frame_index)
		local output = frame_buffers[slot]
		local cmd = record_cull_dispatch(
			output,
			slot,
			dataset,
			dataset_buffers,
			visual_count,
			view_projection_matrix,
			camera_position,
			frustum_planes,
			read_visible_entry_indices
		)
		render.SubmitAndWait(cmd)
		output.cull_result = collect_cull_result(output)
		return output.cull_result
	end

	stamp_published_slot_release(frame_buffers)
	local output = acquire_async_slot(frame_buffers)

	if output then
		local cmd = record_cull_dispatch(
			output,
			output.frame_index,
			dataset,
			dataset_buffers,
			visual_count,
			view_projection_matrix,
			camera_position,
			frustum_planes,
			read_visible_entry_indices
		)
		gpu_culling.main_view_submission_serial = gpu_culling.main_view_submission_serial + 1
		render.Submit(cmd, output.cull_fence)
		output.cull_pending_serial = gpu_culling.main_view_submission_serial
	end

	return publish_latest_async_result(frame_buffers)
end

-- options: {light_view = Matrix44, min_caster_extent = number} for min-caster-texel culling
local SHADOW_CULL_BINDINGS = {
	{"dataset", "shadow_visual_buffer"},
	{"output", "shadow_visible_index_buffer"},
	{"output", "shadow_visible_count_buffer"},
	{"dataset", "shadow_entry_buffer"},
	{"output", "shadow_instance_world_buffer"},
	{"dataset", "shadow_instanced_batch_buffer"},
	{"output", "shadow_visible_instance_vertex_buffer"},
	{"output", "shadow_visible_instanced_batch_count_buffer"},
	{"output", "shadow_fallback_visible_index_buffer"},
	{"output", "shadow_fallback_visible_count_buffer"},
	{"output", "shadow_active_batch_index_buffer"},
	{"output", "shadow_active_batch_count_buffer"},
	{"output", "shadow_visible_batch_indirect_command_buffer"},
}
local SHADOW_CULL_RESET_BUFFERS = {
	"shadow_visible_count_buffer",
	"shadow_fallback_visible_count_buffer",
	"shadow_active_batch_count_buffer",
	"shadow_visible_instanced_batch_count_buffer",
	"shadow_visible_batch_indirect_command_buffer",
}

-- Records the shadow view cull into cmd, outside of any rendering. Every buffer it
-- writes belongs to shadow_output, so the caller must know the gpu is done with
-- shadow_output's previous cull before calling this.
-- Returns false when there is nothing to cull.
local function record_shadow_view_cull(cmd, query_aabb, shadow_output, options)
	local dataset = gpu_culling.scene_dataset
	local dataset_buffers = gpu_culling.dataset_buffers
	local pass = gpu_culling.shadow_view_aabb_cull_pass
	local visual_count = dataset_buffers.layout.shadow_visual_count

	if visual_count <= 0 then return false end

	if shadow_output.generation ~= gpu_culling.generation then
		gpu_culling.RecreateShadowQueryOutput(shadow_output)
	end

	local descriptor_slot = shadow_output.descriptor_slot
	upload_shadow_instance_worlds(shadow_output, dataset)
	local reset_barriers = shadow_output.shadow_cull_reset_barriers

	if not reset_barriers then
		reset_barriers = {}

		for i, name in ipairs(SHADOW_CULL_RESET_BUFFERS) do
			reset_barriers[i] = {
				buffer = shadow_output[name],
				size = shadow_output[name].size,
				srcAccessMask = "transfer_write",
				dstAccessMask = {"shader_read", "shader_write"},
			}
		end

		shadow_output.shadow_cull_reset_barriers = reset_barriers
	end

	for _, name in ipairs(SHADOW_CULL_RESET_BUFFERS) do
		cmd:FillBuffer(shadow_output[name], 0, shadow_output[name].size, 0)
	end

	cmd:PipelineBarrier{
		srcStage = "transfer",
		dstStage = "compute",
		bufferBarriers = reset_barriers,
	}

	for binding, source in ipairs(SHADOW_CULL_BINDINGS) do
		local buffer = (source[1] == "dataset" and dataset_buffers or shadow_output)[source[2]]

		if buffer == shadow_output.shadow_visible_instance_vertex_buffer then
			pass:UpdateDescriptorSet(
				"storage_buffer",
				descriptor_slot,
				binding - 1,
				0,
				buffer.buffer,
				buffer.byte_size
			)
		else
			pass:UpdateDescriptorSet("storage_buffer", descriptor_slot, binding - 1, 0, buffer, buffer.size)
		end
	end

	local camera = render3d.GetCamera()
	pass.current_visual_count = visual_count
	pass.current_query_aabb = query_aabb
	pass.current_camera_position = camera:GetPosition()
	pass.current_view_projection = camera:BuildViewMatrix() * camera:BuildProjectionMatrix()
	pass.current_light_view = options and options.light_view or nil
	pass.current_min_caster_extent = options and options.min_caster_extent or nil
	pass.current_occlusion_enabled = false
	pass.current_occlusion_depth_texture = nil
	pass.current_occlusion_max_mip = 0
	pass.current_occlusion_depth_bias = 0.0015
	bind_main_view_hiz(pass, descriptor_slot, shadow_output, get_main_view_hiz_state(), nil)
	pass:DispatchForSize(cmd, visual_count, 1, 1, descriptor_slot)
	return true
end

local function can_cull_shadow_view()
	return gpu_culling.shadow_view_aabb_cull_pass and
		gpu_culling.scene_dataset and
		gpu_culling.dataset_buffers and
		gpu_culling.frame_buffers
end

-- Culls synchronously and reads the visible entries back. This stalls until the
-- gpu has drained everything queued before it, so it is for queries and tests;
-- shadow rendering uses RecordShadowViewAABBCulling.
function gpu_culling.RunShadowViewAABBCulling(query_aabb, shadow_output, frame_index, include_visible_entry_indices, options)
	if not (query_aabb and shadow_output and can_cull_shadow_view()) then
		return nil
	end

	local read_visible_entry_indices = include_visible_entry_indices ~= false
	local cmd = gpu_culling.shadow_view_aabb_cull_cmd
	cmd:Reset()
	cmd:Begin()

	if not record_shadow_view_cull(cmd, query_aabb, shadow_output, options) then
		cmd:End()
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
		gpu_culling.empty_shadow_view_cull_result.dataset_generation = gpu_culling.scene_dataset.generation
		return gpu_culling.empty_shadow_view_cull_result
	end

	local host_buffers = {
		shadow_output.shadow_visible_count_buffer,
		shadow_output.shadow_fallback_visible_index_buffer,
		shadow_output.shadow_fallback_visible_count_buffer,
		shadow_output.shadow_active_batch_index_buffer,
		shadow_output.shadow_active_batch_count_buffer,
		shadow_output.shadow_visible_instanced_batch_count_buffer,
	}

	if read_visible_entry_indices then
		host_buffers[#host_buffers + 1] = shadow_output.shadow_visible_index_buffer
	end

	local buffer_barriers = {}

	for i, buffer in ipairs(host_buffers) do
		buffer_barriers[i] = {
			buffer = buffer,
			size = buffer.size,
			srcAccessMask = "shader_write",
			dstAccessMask = "host_read",
		}
	end

	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = "host",
		bufferBarriers = buffer_barriers,
	}
	cmd:End()
	render.SubmitAndWait(cmd)
	local visible_count = tonumber(ffi.cast("uint32_t*", shadow_output.shadow_visible_count_buffer:Map())[0])
	local result = update_cull_result(
		{},
		resolve_frame_slot(frame_index),
		visible_count,
		read_visible_entry_indices and
			ffi.cast("uint32_t*", shadow_output.shadow_visible_index_buffer:Map()) or
			nil,
		tonumber(ffi.cast("uint32_t*", shadow_output.shadow_fallback_visible_count_buffer:Map())[0]),
		ffi.cast("uint32_t*", shadow_output.shadow_fallback_visible_index_buffer:Map()),
		visible_count,
		read_visible_entry_indices
	)
	result.dataset_generation = gpu_culling.scene_dataset.generation
	result.shadow_output = shadow_output
	return result
end

-- Records the shadow view cull into cmd, followed by a barrier that makes its
-- indirect commands and instance matrices readable by draws later in cmd. Nothing
-- is read back: the draws consume shadow_output's buffers on the gpu.
-- Returns nil when there is nothing to draw.
function gpu_culling.RecordShadowViewAABBCulling(cmd, query_aabb, shadow_output, options)
	if not can_cull_shadow_view() then return nil end

	if not record_shadow_view_cull(cmd, query_aabb, shadow_output, options) then
		return nil
	end

	local draw_barriers = shadow_output.shadow_cull_draw_barriers

	if not draw_barriers then
		draw_barriers = {
			{
				buffer = shadow_output.shadow_visible_batch_indirect_command_buffer,
				size = shadow_output.shadow_visible_batch_indirect_command_buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = "indirect_command_read",
			},
			{
				buffer = shadow_output.shadow_visible_instance_vertex_buffer.buffer,
				size = shadow_output.shadow_visible_instance_vertex_buffer.byte_size,
				srcAccessMask = "shader_write",
				dstAccessMask = {"vertex_attribute_read", "shader_read"},
			},
		}
		shadow_output.shadow_cull_draw_barriers = draw_barriers
	end

	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"draw_indirect", "vertex_input", "vertex_shader"},
		bufferBarriers = draw_barriers,
	}
	local result = shadow_output.shadow_draw_cull_result or {}
	result.dataset_generation = gpu_culling.scene_dataset.generation
	result.shadow_output = shadow_output
	shadow_output.shadow_draw_cull_result = result
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

-- The shader appends visible entries with an atomic counter, so the visible list is in
-- arbitrary order and cannot be searched. The per-entry visibility buffer is indexed
-- directly instead, which is both exact and cheaper.
function gpu_culling.IsAnyVisibleEntryInRange(cull_result, first_entry_index, entry_count)
	if not cull_result then return nil end

	if not first_entry_index or not entry_count or entry_count <= 0 then
		return false
	end

	local entry_visibility_ptr = cull_result.entry_visibility_ptr

	if not entry_visibility_ptr then return false end

	local last_entry_index = math.min(first_entry_index + entry_count, cull_result.entry_visibility_count or 0) - 1

	for entry_index = first_entry_index, last_entry_index do
		if entry_visibility_ptr[entry_index] ~= 0 then return true end
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

return gpu_culling
