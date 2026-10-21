local ffi = require("ffi")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local render_stats = import("goluwa/render/stats.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local lod = import("goluwa/render3d/lod.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local store = import("goluwa/render3d/scene/store.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local render3d
local draw = {}
local LOCAL_SIZE = 64
local COMMAND_SIZE = 20
local GROUPS = 4
local DEAD_MESH = {
	IsValid = function()
		return false
	end,
}
local DEAD_ROW = {mesh = DEAD_MESH}
local ROW_META = {__mode = "v", __index = DEAD_ROW}
local rows = {}
local slot_of = {}
local free_slots = {}
local slot_rows
local translucent_ids = {}
local translucent_count = 0
draw.serial = 0
local CHANGE_LOG_SIZE = 65536
local changes = {log = {}, size = CHANGE_LOG_SIZE}
local MIN_GROUP_ROOM = 4
local GroupRecord = ffi.typeof("struct { uint32_t mesh_row, base, room, set; }")
local groups = {}
local group_lookup = {}
local free_group_ids = {}
local group_table
local slot_groups
local group_space = 0
local group_free_rooms = {}
draw.group_serial = 0
local group_changes = {log = {}, size = CHANGE_LOG_SIZE}

local function note_group_change(id)
	draw.group_serial = draw.group_serial + 1
	group_changes.log[draw.group_serial % CHANGE_LOG_SIZE] = id
end

local function write_group(group)
	local record = group_table:Get()[group.id - 1]
	record.mesh_row = group.mesh_row
	record.base = group.base
	record.room = group.room
	record.set = group.set
end

local function acquire_group(mesh, material, polygon3d, mesh_row, set)
	group_table = group_table or
		store.CreateTable{name = "draw_groups", ctype = GroupRecord, capacity = 1024}
	local by_mesh = group_lookup[set]

	if not by_mesh then
		by_mesh = table.weak("k")
		group_lookup[set] = by_mesh
	end

	local by_material = by_mesh[mesh]

	if not by_material then
		by_material = table.weak("k")
		by_mesh[mesh] = by_material
	end

	local by_polygon = by_material[material]

	if not by_polygon then
		by_polygon = table.weak("k")
		by_material[material] = by_polygon
	end

	local group = by_polygon[polygon3d]

	if not group then
		local id = table.remove(free_group_ids) or #groups + 1
		group = setmetatable(
			{
				id = id,
				mesh = mesh,
				material = material,
				first_polygon3d = polygon3d,
				mesh_row = mesh_row,
				set = set,
				rows = 0,
				room = 0,
				base = 0,
			},
			ROW_META
		)
		groups[id] = group
		by_polygon[polygon3d] = group
		group_table:Reserve(id)
		note_group_change(id)
	end

	group.rows = group.rows + 1

	if group.rows > group.room then
		if group.room > 0 then
			group_free_rooms[group.room] = group_free_rooms[group.room] or {}
			table.insert(group_free_rooms[group.room], group.base)
		end

		group.room = math.max(MIN_GROUP_ROOM, 2 ^ math.ceil(math.log(group.rows, 2)))
		local free = group_free_rooms[group.room]
		group.base = free and table.remove(free)

		if not group.base then
			group.base = group_space
			group_space = group_space + group.room
		end

		write_group(group)
	end

	return group
end

local function release_group(group)
	group.rows = group.rows - 1

	if group.rows > 0 then return end

	group_free_rooms[group.room] = group_free_rooms[group.room] or {}
	table.insert(group_free_rooms[group.room], group.base)
	group.room = 0
	write_group(group)
	group_lookup[group.set][group.mesh][group.material][group.first_polygon3d] = nil
	groups[group.id] = DEAD_ROW
	free_group_ids[#free_group_ids + 1] = group.id
	note_group_change(group.id)
end

function draw.SetRow(id, mesh, material, polygon3d, translucent, mesh_row)
	slot_rows = slot_rows or
		store.CreateTable{name = "draw_slot_rows", ctype = "uint32_t", capacity = 4096}
	slot_groups = slot_groups or
		store.CreateTable{name = "draw_slot_groups", ctype = "uint32_t", capacity = 4096}
	local slot = slot_of[id]
	local set = (material:GetDoubleSided() and 1 or 0) + (material:HasHeightMap() and 2 or 0)

	if (translucent_ids[id] or false) ~= (translucent or false) then
		translucent_ids[id] = translucent or nil
		translucent_count = translucent_count + (translucent and 1 or -1)
	end

	if slot then
		local row = rows[slot + 1]

		if row.mesh == mesh and row.material == material and row.set == set then
			return
		end

		if row.group then release_group(row.group) end
	else
		slot = table.remove(free_slots) or #rows
		slot_of[id] = slot
		slot_rows:Reserve(slot + 1)
		slot_groups:Reserve(slot + 1)
		slot_rows:Get()[slot] = id
	end

	local group = acquire_group(mesh, material, polygon3d, mesh_row, set)
	slot_groups:Get()[slot] = group.id - 1
	rows[slot + 1] = setmetatable(
		{
			mesh = mesh,
			material = material,
			first_polygon3d = polygon3d,
			set = set,
			group = group,
		},
		ROW_META
	)
	draw.serial = draw.serial + 1
	changes.log[draw.serial % CHANGE_LOG_SIZE] = slot + 1
end

function draw.ClearRow(id)
	local slot = slot_of[id]

	if not slot then return end

	if translucent_ids[id] then
		translucent_ids[id] = nil
		translucent_count = translucent_count - 1
	end

	local group = rows[slot + 1].group

	if group then release_group(group) end

	rows[slot + 1] = DEAD_ROW
	slot_rows:Get()[slot] = 0xFFFFFFFF
	slot_groups:Get()[slot] = 0xFFFFFFFF
	slot_of[id] = nil
	free_slots[#free_slots + 1] = slot
	draw.serial = draw.serial + 1
	changes.log[draw.serial % CHANGE_LOG_SIZE] = slot + 1
end

local DRAW_DECLARATIONS = [[
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

			]] .. instances.RASTER_DATA_GLSL .. [[

			struct mesh_row {
				uint64_t vertex_address;
				uint64_t index_address;
				uint64_t blas;
				uint triangle_count;
				uint vertex_stride;
				uint flags;
				uint pool_first_index;
			};

			struct group_record {
				uint mesh_row;
				uint base;
				uint room;
				uint set;
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
			layout(buffer_reference, scalar) buffer CountArray { uint n[]; };
			layout(buffer_reference, scalar) readonly buffer GroupArray { group_record g[]; };
			layout(buffer_reference, scalar) writeonly buffer BatchIdArray { uvec2 b[]; };
			layout(buffer_reference, std430) writeonly buffer WorldArray { mat4 w[]; };
			layout(buffer_reference, scalar) readonly buffer SlotArray { uint r[]; };
			layout(buffer_reference, scalar) writeonly buffer ThicknessArray { float t[]; };

			struct draw_args {
				uint64_t tlas;
				uint64_t data;
				uint64_t raster;
				uint64_t meshes;
				uint64_t commands;
				uint64_t worlds;
				uint64_t prev_worlds;
				uint64_t slot_rows;
				uint64_t thicknesses;
				uint64_t counts;
				uint64_t slot_groups;
				uint64_t group_table;
				uint64_t group_counts;
				uint64_t batch_ids;
			};

			layout(buffer_reference, scalar) readonly buffer ArgsRef { draw_args a; };
			#define ARGS ArgsRef(compute.args).a
]]
local cull_pipeline
local state = {}
local args_ring
local create_cull_pipeline

local function get_cull_pipeline()
	if cull_pipeline then return cull_pipeline end

	return create_cull_pipeline()
end

function create_cull_pipeline()
	cull_pipeline = EasyPipeline.Compute{
		name = "scene_draw_cull",
		DescriptorSetCount = math.max(render.GetSwapchainImageCount() or 1, 1),
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		descriptor_sets = {
			{
				type = "combined_image_sampler",
				binding_index = 0,
				stageFlags = "compute",
				set_index = 0,
			},
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
			{"kind", "int"},
		},
		write = function(self, block)
			block.kind = state.kind
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
			block.lod_fade_width = state.kind == 0 and lod.GetFadeWidth() or 0
			block.culling_enabled = state.culling and 1 or 0
			block.occlusion_enabled = state.occlusion_max_mip and 1 or 0
			block.occlusion_max_mip = state.occlusion_max_mip or 0
			block.occlusion_depth_bias = 0.0015
			return block
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0) uniform sampler2D source_depth_tex;
		]] .. DRAW_DECLARATIONS,
		shader = [[

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

				if ((raster.flags & (compute.kind == 0 ? 1u : 32u)) == 0u) return;

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

					if (!inside && is_occluded(raster)) return;
				}

				float fade = 0.0;
				uint level = (inst.mask_lod >> 8u) & 0xFFu;
				uint last = (inst.mask_lod >> 16u) & 0xFFu;

				if (last > 0u) {
					float ratio = distance(compute.camera_position, inst.bounds.xyz) / (max(inst.bounds.w, 0.001) * compute.lod_scale);

					if (!select_lod(level, last, inst.lod.x, inst.lod.y, ratio, fade)) return;
				}

				uint group_id = SlotArray(ARGS.slot_groups).r[slot];

				if (group_id == 0xFFFFFFFFu) return;

				group_record group = GroupArray(ARGS.group_table).g[group_id];
				uint place = atomicAdd(CountArray(ARGS.group_counts).n[group_id], 1u);

				if (place >= group.room) return;

				uint at = group.base + place;
				BatchIdArray(ARGS.batch_ids).b[at] = uvec2(group_id, slot);
				tlas_instance t = TLASArray(ARGS.tlas).t[id];

				if (compute.kind != 0) {
					float thickness = raster.thickness;

					if (thickness < 0.0) {
						thickness = min(
							raster.local_size.x * length(vec3(t.m[0], t.m[4], t.m[8])),
							min(raster.local_size.y * length(vec3(t.m[1], t.m[5], t.m[9])), raster.local_size.z * length(vec3(t.m[2], t.m[6], t.m[10])))
						);
					}

					ThicknessArray(ARGS.thicknesses).t[at] = thickness;
				}

				WorldArray(ARGS.worlds).w[at] = world_from(t.m, fade);
				WorldArray(ARGS.prev_worlds).w[at] = world_from(raster.prev, 0.0);
			}
		]],
	}
	return cull_pipeline
end

local finalize_pipeline

local function get_finalize_pipeline()
	if finalize_pipeline then return finalize_pipeline end

	finalize_pipeline = EasyPipeline.Compute{
		name = "scene_draw_finalize",
		DescriptorSetCount = 1,
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		block = {
			{"args", "uint64_t"},
			{"count", "int"},
			{"capacity", "int"},
			{"kind", "int"},
		},
		write = function(self, block)
			block.args = state.args_address
			block.count = state.group_count
			block.capacity = state.group_capacity
			block.kind = state.kind
			return block
		end,
		custom_declarations = DRAW_DECLARATIONS,
		shader = [[

			void main() {
				uint group_id = gl_GlobalInvocationID.x;

				if (group_id >= uint(compute.count)) return;

				group_record group = GroupArray(ARGS.group_table).g[group_id];
				uint instance_count = min(CountArray(ARGS.group_counts).n[group_id], group.room);

				if (instance_count == 0u) return;

				mesh_row mesh = MeshArray(ARGS.meshes).m[group.mesh_row];
				uint set = compute.kind == 0 ? group.set : (group.set & 1u);
				uint packed_index = atomicAdd(CountArray(ARGS.counts).n[set], 1u);
				CommandArray(ARGS.commands).c[uint(compute.capacity) * set + packed_index] = draw_command(mesh.triangle_count * 3u, instance_count, mesh.pool_first_index, 0, group.base);
			}
		]],
	}
	return finalize_pipeline
end

local buffer_sets = {}

local function ensure_buffers(kind, instance_capacity, group_count)
	local buffers = buffer_sets[kind]

	if
		buffers and
		buffers.capacity >= instance_capacity and
		buffers.group_capacity >= group_count
	then
		return buffers
	end

	if buffers then
		render.GetDevice():WaitIdle()
		buffers.commands:Remove()
		buffers.counts:Remove()
		buffers.group_counts:Remove()
		buffers.batch_ids:Remove()
		buffers.worlds:Remove()
		buffers.prev_worlds:Remove()

		if buffers.thicknesses then buffers.thicknesses:Remove() end
	end

	local capacity = math.ceil(instance_capacity * 1.5)
	local group_capacity = math.ceil(group_count * 1.5)
	local usage = {
		"storage_buffer",
		"shader_device_address",
		"indirect_buffer",
		"transfer_dst",
		"transfer_src",
	}
	local name = kind == 0 and "scene_draw" or "scene_draw_translucent"
	buffers = {
		capacity = capacity,
		group_capacity = group_capacity,
		commands = render.CreateBuffer{
			byte_size = group_capacity * GROUPS * COMMAND_SIZE,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = name .. ".commands",
		},
		counts = render.CreateBuffer{
			byte_size = GROUPS * 4,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = name .. ".counts",
		},
		group_counts = render.CreateBuffer{
			byte_size = group_capacity * 4,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = name .. ".group_counts",
		},
		batch_ids = render.CreateBuffer{
			byte_size = capacity * 8,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = name .. ".batch_ids",
		},
		worlds = render.CreateBuffer{
			byte_size = capacity * 64,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = name .. ".worlds",
		},
		prev_worlds = render.CreateBuffer{
			byte_size = capacity * 64,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = name .. ".prev_worlds",
		},
	}

	if kind == 1 then
		buffers.thicknesses = render.CreateBuffer{
			byte_size = capacity * 4,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = name .. ".thicknesses",
		}
		buffers.thicknesses_address = buffers.thicknesses:GetDeviceAddress()
	end

	buffers.commands_address = buffers.commands:GetDeviceAddress()
	buffers.counts_address = buffers.counts:GetDeviceAddress()
	buffers.group_counts_address = buffers.group_counts:GetDeviceAddress()
	buffers.batch_ids_address = buffers.batch_ids:GetDeviceAddress()
	buffers.worlds_address = buffers.worlds:GetDeviceAddress()
	buffers.prev_worlds_address = buffers.prev_worlds:GetDeviceAddress()
	buffer_sets[kind] = buffers
	return buffers
end

local frame_state = {frame = -1, counts = {[0] = 0, 0}, group_counts = {[0] = 0, 0}}

function draw.Cull(
	cmd,
	view_projection,
	frustum_planes,
	camera_position,
	viewport_height,
	culling_enabled
)
	local tlas_table, data_table = instances.GetTables()
	local raster_table = instances.GetRasterTable()
	local count = #rows
	frame_state.frame = system.GetFrameNumber()
	frame_state.counts[0] = 0
	frame_state.counts[1] = 0
	frame_state.group_counts[0] = 0
	frame_state.group_counts[1] = 0

	if count == 0 then return end

	store.FlushStaged(cmd)
	local pipeline = get_cull_pipeline()
	local finalize = get_finalize_pipeline()
	local group_count = #groups
	args_ring = args_ring or {}
	local hiz, fallback_hiz = gpu_culling.GetMainViewHiZ()
	local bound = hiz or fallback_hiz
	local descriptor_slot

	if bound then
		descriptor_slot = render.frame_serial % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		pipeline:UpdateDescriptorSet(
			"combined_image_sampler",
			descriptor_slot,
			0,
			0,
			bound.view,
			bound.sampler,
			nil,
			nil,
			"general"
		)
	end

	for kind = 0, translucent_count > 0 and 1 or 0 do
		local buffers = ensure_buffers(kind, group_space, group_count)
		local ring_slot = render.frame_serial % 4 + 1
		local ring = args_ring[kind]

		if not ring then
			ring = {}
			args_ring[kind] = ring
		end

		local args = ring[ring_slot]

		if not args then
			args = render.CreateBuffer{
				byte_size = 128,
				buffer_usage = {"storage_buffer", "shader_device_address"},
				memory_property = {"host_visible", "host_coherent"},
				label = "scene_draw.args",
			}
			ring[ring_slot] = args
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
		args.pointer[8] = buffers.thicknesses_address or 0
		args.pointer[9] = buffers.counts_address
		args.pointer[10] = slot_groups:GetAddress()
		args.pointer[11] = group_table:GetAddress()
		args.pointer[12] = buffers.group_counts_address
		args.pointer[13] = buffers.batch_ids_address
		state.kind = kind
		state.args_address = args.address
		state.camera = camera_position
		state.count = count
		state.capacity = buffers.group_capacity
		state.group_count = group_count
		state.group_capacity = buffers.group_capacity
		state.planes = frustum_planes
		state.view_projection = view_projection
		state.viewport_height = viewport_height
		state.culling = culling_enabled
		state.occlusion_max_mip = hiz and hiz.max_mip or nil
		cmd:FillBuffer(buffers.counts, 0, buffers.counts.size, 0)
		cmd:FillBuffer(buffers.group_counts, 0, buffers.group_counts.size, 0)
		cmd:PipelineBarrier{
			srcStage = {"host", "transfer", "compute"},
			dstStage = "compute",
			memoryBarrier = true,
		}
		pipeline:Dispatch(cmd, math.ceil(count / LOCAL_SIZE), 1, 1, descriptor_slot or 1)
		cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
		finalize:Dispatch(cmd, math.ceil(group_count / LOCAL_SIZE), 1, 1, 1)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = {"draw_indirect", "vertex_shader", "vertex_input"},
			memoryBarrier = true,
		}
		frame_state.counts[kind] = count
		frame_state.group_counts[kind] = group_count
	end
end

local batch_tables = setmetatable({}, {__mode = "k"})

function draw.IsCulled()
	return frame_state.frame == system.GetFrameNumber()
end

function draw.Draw(gbuffer_instancing, pipelines)
	if frame_state.frame ~= system.GetFrameNumber() or frame_state.counts[0] == 0 then
		return false
	end

	local buffers = buffer_sets[0]
	local cmd = render.GetCommandBuffer()
	local stride = COMMAND_SIZE
	local group_size = buffers.group_capacity * stride
	local count = frame_state.group_counts[0]
	gpu_culling.MarkMainViewDrawn()

	for i, pipeline in ipairs(pipelines) do
		local batch_table = batch_tables[pipeline]

		if not batch_table then
			batch_table = gbuffer_instancing.NewBatchTable(pipeline.name .. "_scene_groups", group_changes)
			batch_tables[pipeline] = batch_table
		end

		pipeline.draw_batches_address = batch_table:Update(pipeline, groups, draw.group_serial, system.GetFrameNumber())
		pipeline.draw_instances_address = buffers.worlds_address
		pipeline.draw_prev_instances_address = buffers.prev_worlds_address
		pipeline.draw_batch_ids_address = buffers.batch_ids_address
		pipeline:UploadConstants()
		cmd:SetCullMode(orientation.CULL_MODE)
		cmd:BindIndexBuffer(index_pool.GetBuffer(), 0, "uint32")
		cmd:DrawIndexedIndirectCount(
			buffers.commands,
			(i - 1) * 2 * group_size,
			buffers.counts,
			(i - 1) * 2 * 4,
			count,
			stride
		)
		cmd:SetCullMode("none")
		cmd:DrawIndexedIndirectCount(
			buffers.commands,
			((i - 1) * 2 + 1) * group_size,
			buffers.counts,
			((i - 1) * 2 + 1) * 4,
			count,
			stride
		)
	end

	return true
end

function draw.DrawTranslucent(gbuffer_instancing, pipeline)
	if frame_state.frame ~= system.GetFrameNumber() or frame_state.counts[1] == 0 then
		return false
	end

	local buffers = buffer_sets[1]
	local cmd = render.GetCommandBuffer()
	local group_size = buffers.group_capacity * COMMAND_SIZE
	local count = frame_state.group_counts[1]
	render3d = render3d or import("goluwa/render3d/render3d.lua")
	gpu_timing.SetInfo(render3d.translucent_scope, "store_slots", frame_state.counts[1])
	local batch_table = batch_tables[pipeline]

	if not batch_table then
		batch_table = gbuffer_instancing.NewBatchTable(pipeline.name .. "_scene_groups", group_changes)
		batch_tables[pipeline] = batch_table
	end

	pipeline.draw_batches_address = batch_table:Update(pipeline, groups, draw.group_serial, system.GetFrameNumber())
	pipeline.draw_instances_address = buffers.worlds_address
	pipeline.draw_prev_instances_address = buffers.prev_worlds_address
	pipeline.draw_thicknesses_address = buffers.thicknesses_address
	pipeline.draw_batch_ids_address = buffers.batch_ids_address
	pipeline:UploadConstants()
	cmd:SetCullMode(orientation.CULL_MODE)
	cmd:BindIndexBuffer(index_pool.GetBuffer(), 0, "uint32")
	cmd:DrawIndexedIndirectCount(buffers.commands, 0, buffers.counts, 0, count, COMMAND_SIZE)
	cmd:SetCullMode("none")
	cmd:DrawIndexedIndirectCount(buffers.commands, group_size, buffers.counts, 4, count, COMMAND_SIZE)
	return true
end

local SHADOW_COMMAND_SIZE = COMMAND_SIZE
local shadow_pipeline
local create_shadow_pipeline

local function get_shadow_pipeline()
	if shadow_pipeline then return shadow_pipeline end

	return create_shadow_pipeline()
end

function create_shadow_pipeline()
	shadow_pipeline = EasyPipeline.Compute{
		name = "scene_shadow_cull",
		DescriptorSetCount = 1,
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		block = {
			{"args", "uint64_t"},
			{"camera_position", "vec3"},
			{"count", "int"},
			{"planes", "vec4", 5},
			{"light_axis_x", "vec3"},
			{"min_caster_extent", "float"},
			{"light_axis_y", "vec3"},
			{"lod_forced", "int"},
			{"lod_scale", "float"},
			{"culling_enabled", "int"},
		},
		write = function(self, block)
			local v = self.shadow_state
			block.args = v.args_address
			block.camera_position[0], block.camera_position[1], block.camera_position[2] = v.camera.x, v.camera.y, v.camera.z
			block.count = v.count

			for i = 0, 4 do
				for k = 0, 3 do
					block.planes[i][k] = v.planes[i * 4 + k]
				end
			end

			block.light_axis_x[0], block.light_axis_x[1], block.light_axis_x[2] = v.axis_x[1], v.axis_x[2], v.axis_x[3]
			block.light_axis_y[0], block.light_axis_y[1], block.light_axis_y[2] = v.axis_y[1], v.axis_y[2], v.axis_y[3]
			block.min_caster_extent = v.min_caster_extent
			block.lod_forced = lod.GetForcedLevel()
			block.lod_scale = lod.GetScale()
			block.culling_enabled = gpu_culling.culling_enabled and 1 or 0
			return block
		end,
		custom_declarations = [[
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

			]] .. instances.RASTER_DATA_GLSL .. [[

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

			struct shadow_args {
				uint64_t tlas;
				uint64_t data;
				uint64_t raster;
				uint64_t meshes;
				uint64_t commands;
				uint64_t worlds;
				uint64_t slot_rows;
				uint64_t counts;
			};

			layout(buffer_reference, scalar) readonly buffer TLASArray { tlas_instance t[]; };
			layout(buffer_reference, scalar) readonly buffer DataArray { instance_data d[]; };
			layout(buffer_reference, scalar) readonly buffer RasterArray { raster_data r[]; };
			layout(buffer_reference, scalar) readonly buffer MeshArray { mesh_row m[]; };
			layout(buffer_reference, scalar) writeonly buffer CommandArray { draw_command c[]; };
			layout(buffer_reference, scalar) buffer CountArray { uint n[]; };
			layout(buffer_reference, std430) writeonly buffer WorldArray { mat4 w[]; };
			layout(buffer_reference, scalar) readonly buffer SlotArray { uint r[]; };
			layout(buffer_reference, scalar) readonly buffer ArgsRef { shadow_args a; };
			#define ARGS ArgsRef(compute.args).a
		]],
		shader = [[

			bool select_shadow_lod(uint flags, uint level, uint last, float near_ratio, float far_ratio, float ratio) {
				if ((flags & 128u) != 0u) return false;

				bool before_billboard = (flags & 256u) != 0u;

				if (compute.lod_forced >= 0) {
					uint target = min(uint(compute.lod_forced), last);
					return level == target || (before_billboard && target > level);
				}

				if (level > 0u && ratio < near_ratio) return false;
				if (!before_billboard && level < last && ratio >= far_ratio) return false;

				return true;
			}

			void main() {
				uint slot = gl_GlobalInvocationID.x;

				if (slot >= uint(compute.count)) return;

				uint id = SlotArray(ARGS.slot_rows).r[slot];
				bool casts = id != 0xFFFFFFFFu;
				raster_data raster;
				instance_data inst;

				if (casts) {
					raster = RasterArray(ARGS.raster).r[id];
					inst = DataArray(ARGS.data).d[id];
					casts = (raster.flags & 16u) != 0u && (inst.flags & 48u) == 0u;
				}

				if (casts && compute.culling_enabled != 0) {
					for (int i = 0; i < 5; i++) {
						vec4 plane = compute.planes[i];
						vec3 p = vec3(plane.x > 0.0 ? raster.box_max.x : raster.box_min.x, plane.y > 0.0 ? raster.box_max.y : raster.box_min.y, plane.z > 0.0 ? raster.box_max.z : raster.box_min.z);

						if (dot(plane.xyz, p) + plane.w < 0.0) casts = false;
					}

					if (casts && compute.min_caster_extent > 0.0) {
						vec3 half_size = 0.5 * (raster.box_max - raster.box_min);
						float extent_x = dot(abs(compute.light_axis_x), half_size) * 2.0;
						float extent_y = dot(abs(compute.light_axis_y), half_size) * 2.0;

						if (extent_x < compute.min_caster_extent && extent_y < compute.min_caster_extent) casts = false;
					}
				}

				if (casts) {
					uint level = (inst.mask_lod >> 8u) & 0xFFu;
					uint last = (inst.mask_lod >> 16u) & 0xFFu;
					float ratio = distance(compute.camera_position, inst.bounds.xyz) / (max(inst.bounds.w, 0.001) * compute.lod_scale);

					if (last > 0u || (inst.flags & 128u) != 0u) casts = select_shadow_lod(inst.flags, level, last, inst.lod.x, inst.lod.y, ratio);
				}

				if (!casts) return;

				mesh_row mesh = MeshArray(ARGS.meshes).m[inst.mesh_row];
				tlas_instance t = TLASArray(ARGS.tlas).t[id];
				CommandArray(ARGS.commands).c[atomicAdd(CountArray(ARGS.counts).n[0], 1u)] = draw_command(mesh.triangle_count * 3u, 1u, mesh.pool_first_index, 0, slot);
				WorldArray(ARGS.worlds).w[slot] = mat4(
					vec4(t.m[0], t.m[4], t.m[8], 0.0),
					vec4(t.m[1], t.m[5], t.m[9], 0.0),
					vec4(t.m[2], t.m[6], t.m[10], 0.0),
					vec4(t.m[3], t.m[7], t.m[11], 1.0)
				);
			}
		]],
	}
	return shadow_pipeline
end

function draw.NewShadowBuffers()
	return {capacity = 0}
end

function draw.RemoveShadowBuffers(buffers)
	if buffers.commands then
		buffers.commands:Remove()
		buffers.counts:Remove()
		buffers.worlds:Remove()
		buffers.args:Remove()
	end
end

function draw.CullShadow(cmd, buffers, planes, camera_position, min_caster_extent, light_view)
	local tlas_table, data_table = instances.GetTables()
	local count = #rows

	if count == 0 or not slot_rows then return nil end

	store.FlushStaged(cmd)

	if buffers.capacity < count then
		draw.RemoveShadowBuffers(buffers)
		buffers.capacity = math.ceil(count * 1.5)
		local usage = {"storage_buffer", "shader_device_address", "indirect_buffer", "transfer_src"}
		buffers.commands = render.CreateBuffer{
			byte_size = buffers.capacity * SHADOW_COMMAND_SIZE,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = "scene_draw.shadow_commands",
		}
		buffers.counts = render.CreateBuffer{
			byte_size = 4,
			buffer_usage = {
				"storage_buffer",
				"shader_device_address",
				"indirect_buffer",
				"transfer_dst",
				"transfer_src",
			},
			memory_property = {"device_local"},
			label = "scene_draw.shadow_counts",
		}
		buffers.worlds = render.CreateBuffer{
			byte_size = buffers.capacity * 64,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = "scene_draw.shadow_worlds",
		}
		buffers.args = render.CreateBuffer{
			byte_size = 64,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_draw.shadow_args",
		}
		buffers.args_pointer = ffi.cast("uint64_t *", buffers.args:Map())
		buffers.commands_address = buffers.commands:GetDeviceAddress()
		buffers.counts_address = buffers.counts:GetDeviceAddress()
		buffers.worlds_address = buffers.worlds:GetDeviceAddress()
		buffers.args_address = tonumber(buffers.args:GetDeviceAddress())
	end

	local pointer = buffers.args_pointer
	pointer[0] = tlas_table:GetAddress()
	pointer[1] = data_table:GetAddress()
	pointer[2] = instances.GetRasterTable():GetAddress()
	pointer[3] = meshes.GetTable():GetAddress()
	pointer[4] = buffers.commands_address
	pointer[5] = buffers.worlds_address
	pointer[6] = slot_rows:GetAddress()
	pointer[7] = buffers.counts_address
	local pipeline = get_shadow_pipeline()
	local v = pipeline.shadow_state or {axis_x = {0, 0, 0}, axis_y = {0, 0, 0}, planes = {}}
	pipeline.shadow_state = v
	v.args_address = buffers.args_address
	v.camera = camera_position
	v.count = count

	for i = 0, 3 do
		for k = 0, 3 do
			v.planes[i * 4 + k] = planes[i * 4 + k]
		end
	end

	for k = 0, 3 do
		v.planes[16 + k] = planes[20 + k]
	end

	v.min_caster_extent = min_caster_extent or 0

	if light_view then
		v.axis_x[1], v.axis_x[2], v.axis_x[3] = light_view.m00, light_view.m10, light_view.m20
		v.axis_y[1], v.axis_y[2], v.axis_y[3] = light_view.m01, light_view.m11, light_view.m21
	end

	cmd:FillBuffer(buffers.counts, 0, 4, 0)
	cmd:PipelineBarrier{
		srcStage = {"host", "transfer", "compute"},
		dstStage = "compute",
		memoryBarrier = true,
	}
	pipeline:Dispatch(cmd, math.ceil(count / LOCAL_SIZE), 1, 1, 1)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"draw_indirect", "vertex_shader"},
		memoryBarrier = true,
	}
	return count
end

do
	local download = store.Download

	function draw.GetRowId(slot)
		return slot_rows:Get()[slot]
	end

	function draw.ReadBackCull(kind)
		kind = kind or 0
		local result = {by_id = {}, count = 0, slots = frame_state.counts[kind]}
		local buffers = buffer_sets[kind]

		if not buffers or result.slots == 0 then return result end

		local group_capacity = buffers.group_capacity
		local commands = ffi.cast("uint32_t *", download(buffers.commands, group_capacity * GROUPS * COMMAND_SIZE))
		local counts = ffi.cast("uint32_t *", download(buffers.counts, GROUPS * 4))
		local worlds = ffi.cast("float *", download(buffers.worlds, buffers.capacity * 64))
		local batch_ids = ffi.cast("uint32_t *", download(buffers.batch_ids, buffers.capacity * 8))
		local ids = slot_rows:Get()

		for set = 0, GROUPS - 1 do
			for packed_index = 0, counts[set] - 1 do
				local command = commands + (set * group_capacity + packed_index) * (COMMAND_SIZE / 4)

				for place = 0, command[1] - 1 do
					local at = command[4] + place
					local slot = batch_ids[at * 2 + 1]
					local id = ids[slot]
					local world = {}
					local fade = worlds[at * 16 + 3]

					for i = 0, 11 do
						world[i + 1] = worlds[at * 16 + (i % 4) * 4 + math.floor(i / 4)]
					end

					result.by_id[id] = {
						slot = slot,
						group = set,
						fade = fade,
						world = world,
						index_count = command[0],
						first_index = command[2],
					}
					result.count = result.count + 1
				end
			end
		end

		return result
	end

	function draw.ReadBackShadowCull(buffers, count)
		local result = {by_id = {}, count = 0, slots = count or 0}

		if not buffers.commands or result.slots == 0 then return result end

		local commands = ffi.cast("uint32_t *", download(buffers.commands, result.slots * SHADOW_COMMAND_SIZE))
		local drawn = ffi.cast("uint32_t *", download(buffers.counts, 4))[0]
		local ids = slot_rows:Get()

		for packed_index = 0, drawn - 1 do
			local slot = commands[packed_index * 5 + 4]
			result.by_id[ids[slot]] = {slot = slot, index_count = commands[packed_index * 5]}
			result.count = result.count + 1
		end

		return result
	end
end

pvars.StartGroup("Rendering", "Scene draw", {store = false})
local debug_mode = pvars.Setup2{
	key = "r_scene_draw_debug",
	default = false,
	help = "reads the main view's culling back about once a second (a stall) and keeps what it drew in draw.debug_result, the culling debug boxes and the stats show it",
}
pvars.EndGroup()
draw.debug_result = nil

event.AddListener("Update", "scene_draw_debug", function()
	if
		not debug_mode:Get() or
		system.GetFrameNumber() % 30 ~= 0 or
		frame_state.frame < 0
	then
		return
	end

	local opaque = draw.ReadBackCull(0)
	local translucent = draw.ReadBackCull(1)
	draw.debug_result = {
		frame = frame_state.frame,
		opaque = opaque,
		translucent = translucent,
		slots = frame_state.counts[0],
	}
end)

render_stats.RegisterGroup{id = "render3d_scene_draw", label = "RENDER3D SCENE DRAW"}
render_stats.RegisterField{
	id = "r3d_scene_draw_rows",
	label = "R3D CULL ROWS",
	group = "render3d_scene_draw",
	getter = function()
		return draw.debug_result and draw.debug_result.slots or 0
	end,
}
render_stats.RegisterField{
	id = "r3d_scene_draw_visible",
	label = "R3D CULL VISIBLE",
	group = "render3d_scene_draw",
	getter = function()
		return draw.debug_result and draw.debug_result.opaque.count or 0
	end,
}
render_stats.RegisterField{
	id = "r3d_scene_draw_translucent",
	label = "R3D CULL TRANSLUCENT",
	group = "render3d_scene_draw",
	getter = function()
		return draw.debug_result and draw.debug_result.translucent.count or 0
	end,
}

function draw.GetRows()
	return rows, draw.serial
end

return draw
