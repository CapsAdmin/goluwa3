local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local lod = import("goluwa/render3d/lod.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local store = import("goluwa/render3d/scene/store.lua")
local draw = {}
-- the main view drawn from the scene store: one pass writes an indexed indirect draw for every row that is in view, the
-- world matrices and the previous ones of its instance, and the gbuffer's multi draw pipelines draw them, with a record
-- of the row's mesh and material as the batch (the rows are the batches, so the draws need no cpu list of what is visible)
pvars.StartGroup("Rendering", "Scene draw", {store = false})
draw.enabled = pvars.Setup2{
	key = "r_scene_draw",
	default = true,
	help = "draw the main view from the scene store, off draws it from the culling's own dataset",
}
pvars.EndGroup()
local LOCAL_SIZE = 64
local COMMAND_SIZE = 20
local GROUPS = 4
local DEAD_MESH = {IsValid = function() return false end}
local DEAD_ROW = {mesh = DEAD_MESH}
-- a row does not keep its mesh, material or polygon alive, the visual does, and a mesh that is gone reads as a dead row
local ROW_META = {__mode = "v", __index = DEAD_ROW}
local rows = {}
local slot_of = {}
local free_slots = {}
local slot_rows
draw.serial = 0

-- a drawn row has a slot of its own, the slots are what the draws index (the batch records, the matrices), so rows that
-- are not drawn, and the rows of producers, cost nothing
function draw.SetRow(id, mesh, material, polygon3d)
	slot_rows = slot_rows or store.CreateTable{name = "draw_slot_rows", ctype = "uint32_t", capacity = 4096}
	local slot = slot_of[id]

	if slot then
		local row = rows[slot + 1]

		if row.mesh == mesh and row.material == material then return end
	else
		slot = table.remove(free_slots) or #rows
		slot_of[id] = slot
		slot_rows:Reserve(slot + 1)
		slot_rows:Get()[slot] = id
	end

	rows[slot + 1] = setmetatable({mesh = mesh, material = material, first_polygon3d = polygon3d}, ROW_META)
	draw.serial = draw.serial + 1
end

function draw.ClearRow(id)
	local slot = slot_of[id]

	if not slot then return end

	rows[slot + 1] = DEAD_ROW
	slot_rows:Get()[slot] = 0xFFFFFFFF
	slot_of[id] = nil
	free_slots[#free_slots + 1] = slot
	draw.serial = draw.serial + 1
end

local cull_pipeline
local state = {}
local args_ring

local function get_cull_pipeline()
	if cull_pipeline then return cull_pipeline end

	cull_pipeline = EasyPipeline.Compute{
		name = "scene_draw_cull",
		DescriptorSetCount = math.max(render.GetSwapchainImageCount() or 1, 1),
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		descriptor_sets = {
			{type = "combined_image_sampler", binding_index = 0, stageFlags = "compute", set_index = 0},
		},
		block = {
			{"args", "uint64_t"},
			{"camera_position", "vec3"},
			{"count", "int"},
			{"capacity", "int"},
			{"frustum_planes", "vec4", 6},
			{"view_projection", "mat4"},
			{"viewport_height", "float"},
			{"lod_forced", "int"},
			{"lod_scale", "float"},
			{"lod_fade_width", "float"},
			{"culling_enabled", "int"},
			{"occlusion_enabled", "int"},
			{"occlusion_max_mip", "int"},
			{"occlusion_depth_bias", "float"},
		},
		write = function(self, block)
			block.args = state.args_address
			block.camera_position[0] = state.camera.x
			block.camera_position[1] = state.camera.y
			block.camera_position[2] = state.camera.z
			block.count = state.count
			block.capacity = state.capacity
			ffi.copy(block.frustum_planes, state.planes, ffi.sizeof("float") * 24)
			state.view_projection:CopyToFloatPointer(block.view_projection)
			block.viewport_height = state.viewport_height
			block.lod_forced = lod.GetForcedLevel()
			block.lod_scale = lod.GetScale()
			block.lod_fade_width = lod.GetFadeWidth()
			block.culling_enabled = state.culling and 1 or 0
			block.occlusion_enabled = state.occlusion_max_mip and 1 or 0
			block.occlusion_max_mip = state.occlusion_max_mip or 0
			block.occlusion_depth_bias = 0.0
			return block
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0) uniform sampler2D source_depth_tex;
			#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
			#extension GL_EXT_buffer_reference : require
			#extension GL_EXT_scalar_block_layout : require

			struct tlas_instance {
				float m[12];
				uint custom_and_mask;
				uint flags;
				uint64_t blas;
			};

			struct instance_data {
				uint mesh_row;
				uint material_row;
				uint flags;
				uint mask_lod;
				vec4 bounds;
				vec2 lod;
				vec2 pad;
			};

			struct raster_data {
				vec3 box_min;
				vec3 box_max;
				float cull_distance;
				uint flags;
				float prev[12];
			};

			struct mesh_row {
				uint64_t vertex_address;
				uint64_t index_address;
				uint64_t blas;
				uint triangle_count;
				uint vertex_stride;
				uint flags;
				uint pool_first_index;
			};

			struct draw_command {
				uint index_count;
				uint instance_count;
				uint first_index;
				int vertex_offset;
				uint first_instance;
			};

			layout(buffer_reference, scalar) readonly buffer TLASArray { tlas_instance t[]; };
			layout(buffer_reference, scalar) readonly buffer DataArray { instance_data d[]; };
			layout(buffer_reference, scalar) readonly buffer RasterArray { raster_data r[]; };
			layout(buffer_reference, scalar) readonly buffer MeshArray { mesh_row m[]; };
			layout(buffer_reference, scalar) writeonly buffer CommandArray { draw_command c[]; };
			layout(buffer_reference, std430) writeonly buffer WorldArray { mat4 w[]; };
			layout(buffer_reference, scalar) readonly buffer SlotArray { uint r[]; };

			struct draw_args {
				uint64_t tlas;
				uint64_t data;
				uint64_t raster;
				uint64_t meshes;
				uint64_t commands;
				uint64_t worlds;
				uint64_t prev_worlds;
				uint64_t slot_rows;
			};

			layout(buffer_reference, scalar) readonly buffer ArgsRef { draw_args a; };
			#define ARGS ArgsRef(compute.args).a
		]],
		shader = [[
			// a level of detail: whether it is drawn at this ratio, and the fade that dithers it into the next one, 0 for
			// none, towards 1 for a level on its way out, towards -1 for one that is just coming in
			bool select_lod(uint level, uint last, float near_ratio, float far_ratio, float ratio, out float fade) {
				fade = 0.0;

				if (compute.lod_forced >= 0) return level == min(uint(compute.lod_forced), last);

				float width = compute.lod_fade_width;
				bool has_near = level > 0u;
				bool has_far = level < last;
				float near_start = near_ratio * (1.0 - width);

				if (has_near && ratio < near_start) return false;
				if (has_far && ratio >= far_ratio * (1.0 + width)) return false;

				if (width > 0.0) {
					if (has_near) {
						float incoming = clamp((ratio - near_start) / (near_ratio * 2.0 * width), 0.0, 1.0);

						if (incoming < 1.0) {
							fade = incoming - 1.0;
							return incoming > 0.0;
						}
					}

					if (has_far) {
						float outgoing = clamp((ratio - far_ratio * (1.0 - width)) / (far_ratio * 2.0 * width), 0.0, 1.0);
						fade = outgoing;
						return outgoing < 1.0;
					}
				}

				return true;
			}

			// a box the depth pyramid of the last frame hides completely
			bool is_occluded(raster_data raster) {
				if (compute.occlusion_enabled == 0 || (raster.flags & 2u) == 0u) return false;

				vec2 min_uv = vec2(1.0);
				vec2 max_uv = vec2(0.0);
				float nearest_depth = 0.0;

				for (int i = 0; i < 8; ++i) {
					vec3 corner = vec3((i & 1) != 0 ? raster.box_max.x : raster.box_min.x, (i & 2) != 0 ? raster.box_max.y : raster.box_min.y, (i & 4) != 0 ? raster.box_max.z : raster.box_min.z);
					vec4 clip = compute.view_projection * vec4(corner, 1.0);

					if (clip.w <= 0.0) return false;

					vec3 ndc = clip.xyz / clip.w;
					vec2 uv = ndc.xy * 0.5 + 0.5;
					min_uv = min(min_uv, uv);
					max_uv = max(max_uv, uv);
					nearest_depth = max(nearest_depth, ndc.z);
				}

				if (max_uv.x < 0.0 || max_uv.y < 0.0 || min_uv.x > 1.0 || min_uv.y > 1.0) return false;

				min_uv = clamp(min_uv, vec2(0.0), vec2(1.0));
				max_uv = clamp(max_uv, vec2(0.0), vec2(1.0));
				vec2 hi_z_size = vec2(textureSize(source_depth_tex, 0));
				vec2 span = max(max_uv - min_uv, vec2(0.0));
				int mip_level = clamp(int(ceil(log2(max(max(span.x * hi_z_size.x, span.y * hi_z_size.y), 1.0)))), 0, compute.occlusion_max_mip);
				ivec2 mip_size = textureSize(source_depth_tex, mip_level);
				vec2 texels = hi_z_size / exp2(float(mip_level));
				ivec2 texel_min = ivec2(clamp(floor(min_uv * texels), vec2(0.0), vec2(mip_size - 1)));
				ivec2 texel_max = ivec2(clamp(floor(max_uv * texels), vec2(0.0), vec2(mip_size - 1)));
				float sampled = 1.0;
				sampled = min(sampled, texelFetch(source_depth_tex, texel_min, mip_level).r);
				sampled = min(sampled, texelFetch(source_depth_tex, ivec2(texel_max.x, texel_min.y), mip_level).r);
				sampled = min(sampled, texelFetch(source_depth_tex, ivec2(texel_min.x, texel_max.y), mip_level).r);
				sampled = min(sampled, texelFetch(source_depth_tex, texel_max, mip_level).r);
				return nearest_depth < sampled * (1.0 - compute.occlusion_depth_bias);
			}

			mat4 world_from(float m[12], float fade) {
				return mat4(
					vec4(m[0], m[4], m[8], fade),
					vec4(m[1], m[5], m[9], 0.0),
					vec4(m[2], m[6], m[10], 0.0),
					vec4(m[3], m[7], m[11], 1.0)
				);
			}

			void main() {
				uint slot = gl_GlobalInvocationID.x;

				if (slot >= uint(compute.count)) return;

				uint id = SlotArray(ARGS.slot_rows).r[slot];

				if (id == 0xFFFFFFFFu) return;

				raster_data raster = RasterArray(ARGS.raster).r[id];

				// 1 draws, 16 is a removed row (see instances.lua)
				if ((raster.flags & 1u) == 0u) return;

				instance_data inst = DataArray(ARGS.data).d[id];

				if ((inst.flags & 16u) != 0u) return;

				bool inside = all(greaterThanEqual(compute.camera_position, raster.box_min)) && all(lessThanEqual(compute.camera_position, raster.box_max));

				if (compute.culling_enabled != 0) {
					if (raster.cull_distance > 0.0) {
						vec3 nearest = clamp(compute.camera_position, raster.box_min, raster.box_max);
						vec3 d = compute.camera_position - nearest;

						if (dot(d, d) > raster.cull_distance * raster.cull_distance) return;
					}

					for (int i = 0; i < 6; i++) {
						vec4 plane = compute.frustum_planes[i];
						vec3 p = vec3(plane.x > 0.0 ? raster.box_max.x : raster.box_min.x, plane.y > 0.0 ? raster.box_max.y : raster.box_min.y, plane.z > 0.0 ? raster.box_max.z : raster.box_min.z);

						if (dot(plane.xyz, p) + plane.w < 0.0) return;
					}

					if (!inside && compute.viewport_height > 0.0 && inst.bounds.w > 0.0) {
						vec4 clip = compute.view_projection * vec4(inst.bounds.xyz, 1.0);

						if (clip.w > 0.0) {
							vec3 clip_y_row = vec3(compute.view_projection[0][1], compute.view_projection[1][1], compute.view_projection[2][1]);
							float projected_radius_px = length(clip_y_row) * inst.bounds.w * compute.viewport_height / max(clip.w * 2.0, 1e-5);

							if (projected_radius_px * 2.0 < 1.0) return;
						}
					}
				}

				float fade = 0.0;
				uint level = (inst.mask_lod >> 8u) & 0xFFu;
				uint last = (inst.mask_lod >> 16u) & 0xFFu;

				if (last > 0u) {
					float ratio = distance(compute.camera_position, inst.bounds.xyz) / (max(inst.bounds.w, 0.001) * compute.lod_scale);

					if (!select_lod(level, last, inst.lod.x, inst.lod.y, ratio, fade)) return;
				}

				mesh_row mesh = MeshArray(ARGS.meshes).m[inst.mesh_row];
				// the group is single or double sided, with the height map ones after them
				uint group = ((raster.flags >> 3u) & 1u) + ((raster.flags >> 2u) & 1u) * 2u;
				CommandArray(ARGS.commands).c[uint(compute.capacity) * group + slot] = draw_command(mesh.triangle_count * 3u, 1u, mesh.pool_first_index, 0, slot);
				tlas_instance t = TLASArray(ARGS.tlas).t[id];
				WorldArray(ARGS.worlds).w[slot] = world_from(t.m, fade);
				WorldArray(ARGS.prev_worlds).w[slot] = world_from(raster.prev, 0.0);
			}
		]],
	}
	return cull_pipeline
end

local buffers

local function ensure_buffers(capacity)
	if buffers and buffers.capacity >= capacity then return end

	if buffers then
		render.GetDevice():WaitIdle()
		buffers.commands:Remove()
		buffers.worlds:Remove()
		buffers.prev_worlds:Remove()
	end

	capacity = math.ceil(capacity * 1.5)
	local usage = {"storage_buffer", "shader_device_address", "indirect_buffer", "transfer_dst"}
	buffers = {
		capacity = capacity,
		commands = render.CreateBuffer{
			byte_size = capacity * GROUPS * COMMAND_SIZE,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = "scene_draw.commands",
		},
		worlds = render.CreateBuffer{
			byte_size = capacity * 64,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = "scene_draw.worlds",
		},
		prev_worlds = render.CreateBuffer{
			byte_size = capacity * 64,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = "scene_draw.prev_worlds",
		},
	}
	buffers.commands_address = buffers.commands:GetDeviceAddress()
	buffers.worlds_address = buffers.worlds:GetDeviceAddress()
	buffers.prev_worlds_address = buffers.prev_worlds:GetDeviceAddress()
end

local frame_state = {frame = -1}

-- records the pass that writes this frame's draws, outside of a render pass, after the instances were updated
function draw.Cull(cmd, view_projection, frustum_planes, camera_position, viewport_height, culling_enabled)
	local tlas_table, data_table = instances.GetTables()
	local raster_table = instances.GetRasterTable()
	-- only the rows that were given a mesh and a material can be drawn
	local count = #rows
	frame_state.frame = system.GetFrameNumber()
	frame_state.count = 0

	if count == 0 then return end

	ensure_buffers(count)
	local pipeline = get_cull_pipeline()
	args_ring = args_ring or {}
	local ring_slot = system.GetFrameNumber() % 4 + 1
	local args = args_ring[ring_slot]

	if not args then
		args = render.CreateBuffer{
			byte_size = 64,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_draw.args",
		}
		args_ring[ring_slot] = args
		args.pointer = ffi.cast("uint64_t *", args:Map())
		args.address = tonumber(args:GetDeviceAddress())
	end

	args.pointer[0] = tlas_table:GetAddress()
	args.pointer[1] = data_table:GetAddress()
	args.pointer[2] = raster_table:GetAddress()
	args.pointer[3] = meshes.GetTable():GetAddress()
	args.pointer[4] = buffers.commands_address
	args.pointer[5] = buffers.worlds_address
	args.pointer[6] = buffers.prev_worlds_address
	args.pointer[7] = slot_rows:GetAddress()
	state.args_address = args.address
	state.camera = camera_position
	state.count = count
	state.capacity = buffers.capacity
	state.planes = frustum_planes
	state.view_projection = view_projection
	state.viewport_height = viewport_height
	state.culling = culling_enabled
	local viewport_height = viewport_height
	local hiz, fallback_hiz, hiz_height = gpu_culling.GetMainViewHiZ()
	local bound = hiz or fallback_hiz

	state.occlusion_max_mip = hiz and hiz.max_mip or nil

	if bound then
		local descriptor_slot = system.GetFrameNumber() % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		pipeline:UpdateDescriptorSet("combined_image_sampler", descriptor_slot, 0, 0, bound.view, bound.sampler, nil, nil, "general")
		state.descriptor_slot = descriptor_slot
	end

	cmd:FillBuffer(buffers.commands, 0, buffers.commands.size, 0)
	cmd:PipelineBarrier{
		srcStage = {"host", "transfer", "compute"},
		dstStage = "compute",
		memoryBarrier = true,
	}
	pipeline:Dispatch(cmd, math.ceil(count / LOCAL_SIZE), 1, 1, state.descriptor_slot or 1)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"draw_indirect", "vertex_shader", "vertex_input"},
		memoryBarrier = true,
	}
	frame_state.count = count
end

local batch_tables = setmetatable({}, {__mode = "k"})

-- draws what Cull wrote in the gbuffer pass: every row of the pipelines' groups, the rows that are not in view have no
-- instances
function draw.Draw(gbuffer_instancing, pipelines)
	if frame_state.frame ~= system.GetFrameNumber() or frame_state.count == 0 then return false end

	local cmd = render.GetCommandBuffer()
	local stride = COMMAND_SIZE
	local group_size = buffers.capacity * stride
	-- the rows that were given a mesh and a material, past them nothing is drawn
	local count = frame_state.count

	if count == 0 then return false end

	gpu_culling.MarkMainViewDrawn()

	for i, pipeline in ipairs(pipelines) do
		local batch_table = batch_tables[pipeline]

		if not batch_table then
			batch_table = gbuffer_instancing.NewBatchTable(pipeline.name .. "_scene_rows")
			batch_tables[pipeline] = batch_table
		end

		pipeline.draw_batches_address = batch_table:Update(pipeline, rows, draw.serial, system.GetFrameNumber())
		pipeline.draw_instances_address = buffers.worlds_address
		pipeline.draw_prev_instances_address = buffers.prev_worlds_address
		pipeline:UploadConstants()
		cmd:SetCullMode(orientation.CULL_MODE)
		cmd:BindIndexBuffer(index_pool.GetBuffer(), 0, "uint32")
		cmd:DrawIndexedIndirect(buffers.commands, (i - 1) * 2 * group_size, count, stride)
		cmd:SetCullMode("none")
		cmd:DrawIndexedIndirect(buffers.commands, ((i - 1) * 2 + 1) * group_size, count, stride)
	end

	return true
end

return draw
