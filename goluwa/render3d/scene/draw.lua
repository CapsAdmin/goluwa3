local ffi = require("ffi")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local render_stats = import("goluwa/render/stats.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local lod = import("goluwa/render3d/lod.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local visibility = import("goluwa/render3d/visibility.lua")
local software_raster = import("goluwa/render3d/scene/software_raster.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local store = import("goluwa/render3d/scene/store.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local vk = import("goluwa/bindings/vk.lua")
local shader_features = import("goluwa/render3d/shader_features.lua")
local cluster_lod = import("goluwa/render3d/cluster_lod/cluster_lod.lua")
local cluster_format = import("goluwa/render3d/cluster_lod/format.lua")
local render3d
local surface_conditions
local draw = {}
local LOCAL_SIZE = 64
local COMMAND_SIZE = 20
draw.SHAPE_PLAIN = 0
draw.SHAPE_RELIEF = 1
draw.SHAPE_NEARER = 2
draw.SHAPE_IDS = 3
local SHAPES = 4
local VARIANTS = SHAPES * shader_features.COUNT
local GROUPS = VARIANTS * 2
local ARGS_REMAP = 23
local CLUSTER_COMMANDS = 32768
draw.VARIANTS = VARIANTS
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
local height_shell_ids = {}
local overlay_ids = {}
local variant_rows = {[0] = {}, [1] = {}}
local variant_kinds = {}

for variant = 0, VARIANTS - 1 do
	variant_rows[0][variant] = 0
	variant_rows[1][variant] = 0
end

function draw.GetVariant(shape, bits)
	return shape + SHAPES * bits
end

function draw.GetVariantShape(variant)
	return variant % SHAPES
end

function draw.GetVariantBits(variant)
	return math.floor(variant / SHAPES)
end

function draw.SetVariantKind(kind, names, features, shaped)
	variant_kinds[kind] = {
		names = names,
		features = features,
		shaped = shaped,
		full = (shaped and draw.SHAPE_NEARER or draw.SHAPE_PLAIN) + SHAPES * features,
	}
end

local function count_row(row, delta)
	if row.drawn then
		variant_rows[0][row.variant] = variant_rows[0][row.variant] + delta
	end

	if row.translucent then
		variant_rows[1][row.variant] = variant_rows[1][row.variant] + delta
	end
end

local CHANGE_LOG_SIZE = 65536
local MIN_GROUP_ROOM = 4
local GroupRecord = ffi.typeof(
	"struct { uint32_t mesh_row, base, room, set, shadow_base, shadow_room, pad[2]; }"
)
local groups = {}
local group_lookup = {}
local free_group_ids = {}
local group_table
local slot_groups
local group_space = 0
local group_free_rooms = {}
local stream_space = 0
local stream_shadow_space = 0
local stream_offset = 0
local stream_groups = {}
draw.group_serial = 0
local group_changes = {log = {}, size = CHANGE_LOG_SIZE}

local function note_group_change(id)
	draw.group_serial = draw.group_serial + 1
	group_changes.log[draw.group_serial % CHANGE_LOG_SIZE] = id
end

local SOFTWARE_RASTER = 0x80000000
local CLASSIC_ONLY = 0x40000000
local CLUSTERED = 0x20000000

local function is_software_rasterizable(material)
	return not (
		material:IsTransparent() or
		material.Dithered or
		material.AlphaTest or
		material.Decal or
		material.Billboard or
		material.SnowBackdrop or
		material:MarchesRelief() or
		material.HeightShell > 0 or
		material:HasVertexAnimation()
	)
end

local function write_group(group)
	local record = group_table:Get()[group.id - 1]
	record.mesh_row = group.mesh_row
	record.base = group.base + (group.stream and stream_offset or 0)
	record.room = group.room
	record.shadow_base = group.stream and group.shadow_base + stream_offset or group.base
	record.shadow_room = group.stream and group.shadow_room or group.room
	record.set = group.set + (
			group.mesh.vertex_buffer:GetVertexCount() > 2 ^ visibility.VERTEX_INDEX_BITS and
			CLASSIC_ONLY or
			0
		) + (
			group.cluster and
			CLUSTERED + (
				is_software_rasterizable(group.material) and
				SOFTWARE_RASTER or
				0
			)
			or
			0
		)
end

local function acquire_group(mesh, material, polygon3d, mesh_row, set, cluster)
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

	local group = by_polygon[cluster or polygon3d]

	if not group then
		local id = table.remove(free_group_ids) or #groups + 1
		group = setmetatable(
			{
				id = id,
				mesh = mesh,
				material = material,
				first_polygon3d = polygon3d,
				mesh_row = mesh_row,
				cluster = cluster,
				set = set,
				rows = 0,
				room = 0,
				base = 0,
			},
			ROW_META
		)
		groups[id] = group
		by_polygon[cluster or polygon3d] = group
		group_table:Reserve(id)
		note_group_change(id)
	end

	group.rows = group.rows + 1
	local needed = group.rows * (cluster and cluster.leaf_count or 1)

	if needed > group.room then
		if group.room > 0 then
			group_free_rooms[group.room] = group_free_rooms[group.room] or {}
			table.insert(group_free_rooms[group.room], group.base)
		end

		group.room = math.max(MIN_GROUP_ROOM, 2 ^ math.ceil(math.log(needed, 2)))
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
	group_lookup[group.set][group.mesh][group.material][group.cluster or
	group.first_polygon3d] = nil
	groups[group.id] = DEAD_ROW
	free_group_ids[#free_group_ids + 1] = group.id
	note_group_change(group.id)
end

local function acquire_stream_group(part)
	group_table = group_table or
		store.CreateTable{name = "draw_groups", ctype = GroupRecord, capacity = 1024}
	local id = table.remove(free_group_ids) or #groups + 1
	local group = setmetatable(
		{
			id = id,
			mesh = part.mesh,
			material = part.material,
			first_polygon3d = part.polygon3d,
			mesh_row = part.mesh_row,
			set = part.set,
			stream = true,
			rows = 0,
			room = 0,
			base = 0,
			shadow_room = 0,
			shadow_base = 0,
		},
		ROW_META
	)
	groups[id] = group
	stream_groups[group] = true
	group_table:Reserve(id)
	write_group(group)
	note_group_change(id)
	variant_rows[0][part.variant] = variant_rows[0][part.variant] + 1
	return group
end

local function release_stream_group(group, variant)
	group.room = 0
	group.shadow_room = 0
	write_group(group)
	stream_groups[group] = nil
	groups[group.id] = DEAD_ROW
	free_group_ids[#free_group_ids + 1] = group.id
	note_group_change(group.id)
	variant_rows[0][variant] = variant_rows[0][variant] - 1
end

-- stream groups sit past every row group, so the translucent buffers, which never hold streams, stay the size of the rows
local function fit_stream_offset()
	if stream_offset >= group_space or not next(stream_groups) then return end

	stream_offset = 2 ^ math.ceil(math.log(math.max(group_space, MIN_GROUP_ROOM) * 1.5, 2))

	for group in pairs(stream_groups) do
		write_group(group)
	end
end

local function get_slot_space(kind)
	if kind == 1 or not next(stream_groups) then return group_space end

	return stream_offset + stream_space
end

local function get_shadow_slot_space()
	if not next(stream_groups) then return group_space end

	return stream_offset + stream_shadow_space
end

local cluster_rows = {}
local cluster_serial = 0

local function get_cluster_state(material, polygon3d, drawn, translucent)
	if
		not drawn or
		translucent or
		not polygon3d or
		polygon3d.shell_grid or
		not cluster_lod.IsEnabled()
		or
		not cluster_lod.IsMaterialEligible(material)
	then
		return nil
	end

	local state = cluster_lod.Request(polygon3d)
	return state and state.ready and state or nil
end

local function get_set(material, overlay)
	local bits = material:GetSurfaceParamBits()

	if material:GetTerrainMaterialTexture() then
		bits = bits + shader_features.TERRAIN
	end

	if overlay then bits = bits + shader_features.OVERLAYS end

	local variant = draw.GetVariant(material:MarchesRelief() and draw.SHAPE_RELIEF or draw.SHAPE_PLAIN, bits)
	return (material:GetRasterBothFaces() and 1 or 0) + 2 * variant, variant
end

local function ensure_slot_tables()
	slot_rows = slot_rows or
		store.CreateTable{name = "draw_slot_rows", ctype = "uint32_t", capacity = 4096}
	slot_groups = slot_groups or
		store.CreateTable{name = "draw_slot_groups", ctype = "uint32_t", capacity = 4096}
end

function draw.SetRow(id, mesh, material, polygon3d, drawn, translucent, mesh_row, force)
	ensure_slot_tables()
	local slot = slot_of[id]
	local set, variant = get_set(material, overlay_ids[id])
	drawn = drawn or nil
	translucent = translucent or nil
	height_shell_ids[id] = polygon3d and polygon3d.shell_grid and true or nil

	if (translucent_ids[id] or false) ~= (translucent or false) then
		translucent_ids[id] = translucent or nil
		translucent_count = translucent_count + (translucent and 1 or -1)
	end

	local cluster = get_cluster_state(material, polygon3d, drawn, translucent)

	if slot then
		local row = rows[slot + 1]

		if
			not force and
			row.mesh == mesh and
			row.material == material and
			row.set == set and
			row.cluster == cluster
		then
			if row.drawn ~= drawn or row.translucent ~= translucent then
				count_row(row, -1)
				row.drawn = drawn
				row.translucent = translucent
				count_row(row, 1)
			end

			return
		end

		count_row(row, -1)

		if row.group then release_group(row.group) end

		if cluster_rows[slot] then
			cluster_rows[slot] = nil
			cluster_serial = cluster_serial + 1
		end
	else
		slot = table.remove(free_slots) or #rows
		slot_of[id] = slot
		slot_rows:Reserve(slot + 1)
		slot_groups:Reserve(slot + 1)
		slot_rows:Get()[slot] = id
	end

	local group = acquire_group(mesh, material, polygon3d, mesh_row, set, cluster)
	slot_groups:Get()[slot] = group.id - 1

	if cluster then
		cluster_rows[slot] = cluster
		cluster_serial = cluster_serial + 1
	end

	local row = setmetatable(
		{
			mesh = mesh,
			material = material,
			first_polygon3d = polygon3d,
			set = set,
			variant = variant,
			drawn = drawn,
			translucent = translucent,
			group = group,
			cluster = cluster,
		},
		ROW_META
	)
	rows[slot + 1] = row
	count_row(row, 1)
end

function draw.SetOverlay(id, slot)
	instances.SetOverlay(id, slot)

	if (overlay_ids[id] or false) == (slot > 0) then return end

	overlay_ids[id] = slot > 0 or nil
	local slot_index = slot_of[id]

	if not slot_index then return end

	local row = rows[slot_index + 1]
	draw.SetRow(
		id,
		row.mesh,
		row.material,
		row.first_polygon3d,
		row.drawn,
		row.translucent,
		row.group.mesh_row
	)
end

function draw.ClearRow(id)
	local slot = slot_of[id]

	if not slot then return end

	height_shell_ids[id] = nil
	overlay_ids[id] = nil

	if translucent_ids[id] then
		translucent_ids[id] = nil
		translucent_count = translucent_count - 1
	end

	local row = rows[slot + 1]
	count_row(row, -1)

	if row.group then release_group(row.group) end

	if cluster_rows[slot] then
		cluster_rows[slot] = nil
		cluster_serial = cluster_serial + 1
	end

	rows[slot + 1] = DEAD_ROW
	slot_rows:Get()[slot] = 0xFFFFFFFF
	slot_groups:Get()[slot] = 0xFFFFFFFF
	slot_of[id] = nil
	free_slots[#free_slots + 1] = slot
end

cluster_lod.OnDebugChanged(function()
	for slot = 0, #rows - 1 do
		local row = rows[slot + 1]

		if row.group and cluster_lod.GetStatus(row.first_polygon3d) then
			row.material:Touch()
		end
	end
end)

cluster_lod.OnReady(function(polygon3d)
	for slot = 0, #rows - 1 do
		local row = rows[slot + 1]

		if row.first_polygon3d == polygon3d and row.group then
			draw.SetRow(
				slot_rows:Get()[slot],
				row.mesh,
				row.material,
				polygon3d,
				row.drawn,
				row.translucent,
				row.group.mesh_row,
				true
			)
		end
	end
end)

-- Adreno indexes a constant block array with a loop counter wrongly, so planes are read with constant indices
local OUTSIDE_PLANE_DECLARATIONS = [[
			bool outside_plane(vec4 plane, raster_data raster) {
				vec3 p = vec3(plane.x > 0.0 ? raster.box_max.x : raster.box_min.x, plane.y > 0.0 ? raster.box_max.y : raster.box_min.y, plane.z > 0.0 ? raster.box_max.z : raster.box_min.z);
				return dot(plane.xyz, p) + plane.w < 0.0;
			}
]]
local TABLE_DECLARATIONS = [[
			#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
			#extension GL_EXT_buffer_reference : require
			#extension GL_EXT_scalar_block_layout : require

			]] .. instances.TLAS_INSTANCE_GLSL .. instances.INSTANCE_DATA_GLSL .. [[

			]] .. instances.RASTER_DATA_GLSL .. [[

			struct mesh_row {
				uint64_t vertex_address;
				uint64_t index_address;
				uint64_t blas;
				uint64_t extras_address;
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
				uint shadow_base;
				uint shadow_room;
				uvec2 pad;
			};

			#define GROUP_SOFTWARE_RASTER 0x80000000u
			#define GROUP_CLASSIC_ONLY 0x40000000u
			#define GROUP_CLUSTERED 0x20000000u
			#define GROUP_VARIANT(group) (((group).set & 0x1FFFFFFFu) >> 1u)

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
			layout(buffer_reference, scalar) buffer GroupIdArray { uint g[]; };
			layout(buffer_reference, std430) writeonly buffer WorldArray { mat4 w[]; };
			layout(buffer_reference, scalar) readonly buffer SlotArray { uint r[]; };
			layout(buffer_reference, scalar) writeonly buffer ThicknessArray { float t[]; };
			layout(buffer_reference, scalar) buffer SeenArray { uint s[]; };
]]
local DRAW_DECLARATIONS = TABLE_DECLARATIONS .. [[
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
				uint64_t draw_groups;
				uint64_t seen;
				uint64_t clusters;
				uint64_t cluster_pairs;
				uint64_t group_areas;
				float viewport_pixels;
				float ids_density;
				uint64_t software_records;
				uint64_t software_header;
				float software_density;
				float software_radius;
				uint64_t streams;
				uint remap[]] .. VARIANTS .. [[];
				uint ids_remap[]] .. VARIANTS .. [[];
			};

			]] .. cluster_format.CLUSTER_GLSL .. software_raster.RECORD_GLSL .. [[

			layout(buffer_reference, scalar) readonly buffer ClusterArray { cluster_record c[]; };
			layout(buffer_reference, scalar) readonly buffer PairArray { uvec2 p[]; };
			layout(buffer_reference, scalar) readonly buffer ArgsRef { draw_args a; };
			#define ARGS ArgsRef(compute.args).a
]]
local SELECT_LOD_GLSL = [[
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

]]
draw.WORLD_FROM_GLSL = [[
			mat4 world_from(float m[12], float fade, float dynamic, float overlay) {
				return mat4(
					vec4(m[0], m[4], m[8], fade),
					vec4(m[1], m[5], m[9], overlay),
					vec4(m[2], m[6], m[10], dynamic),
					vec4(m[3], m[7], m[11], 1.0)
				);
			}

]]
local OCCLUSION_GLSL = [[
			bool is_box_occluded(vec3 box_min, vec3 box_max) {
				if (compute.occlusion_max_mip < 0) return false;

				vec2 min_uv = vec2(1.0);
				vec2 max_uv = vec2(0.0);
				float nearest_depth = 0.0;

				for (int i = 0; i < 8; ++i) {
					vec3 corner = vec3((i & 1) != 0 ? box_max.x : box_min.x, (i & 2) != 0 ? box_max.y : box_min.y, (i & 4) != 0 ? box_max.z : box_min.z);
					vec4 clip = compute.hiz_view_projection * vec4(corner, 1.0);

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
]]
local cull_pipeline
local state = {}
local view_projection_scratch = ffi.new("float[16]")
local args_ring
local create_cull_pipeline

local function write_view(block)
	block.args = state.args_address
	block.camera_position[0] = state.camera.x
	block.camera_position[1] = state.camera.y
	block.camera_position[2] = state.camera.z
	ffi.copy(block.frustum_planes, state.planes, ffi.sizeof("float") * 24)
	state.view_projection:CopyToFloatPointer(view_projection_scratch)
	block.view_w_row[0] = view_projection_scratch[3]
	block.view_w_row[1] = view_projection_scratch[7]
	block.view_w_row[2] = view_projection_scratch[11]
	block.view_w_row[3] = view_projection_scratch[15]
	block.view_y_row[0] = view_projection_scratch[1]
	block.view_y_row[1] = view_projection_scratch[5]
	block.view_y_row[2] = view_projection_scratch[9]
	local hiz_vp = state.occlusion_view_projection or state.view_projection
	hiz_vp:CopyToFloatPointer(block.hiz_view_projection)
	block.viewport_height = state.viewport_height
	block.culling_enabled = state.culling and 1 or 0
	block.occlusion_max_mip = state.occlusion_max_mip or -1
	block.occlusion_depth_bias = 0.0015
end

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
			{"view_w_row", "vec4"},
			{"view_y_row", "vec4"},
			{"hiz_view_projection", "mat4"},
			{"viewport_height", "float"},
			{"lod_forced", "int"},
			{"lod_scale", "float"},
			{"lod_fade_width", "float"},
			{"culling_enabled", "int"},
			{"occlusion_max_mip", "int"},
			{"occlusion_depth_bias", "float"},
			{"kind", "int"},
			{"frame", "int"},
		},
		write = function(self, block)
			write_view(block)
			block.kind = state.kind
			block.frame = system.GetFrameNumber()
			block.count = state.count
			block.capacity = state.capacity
			block.lod_forced = lod.GetForcedLevel()
			block.lod_scale = lod.GetScale()
			block.lod_fade_width = state.kind == 0 and lod.GetFadeWidth() or 0
			return block
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0) uniform sampler2D source_depth_tex;
		]] .. DRAW_DECLARATIONS .. OUTSIDE_PLANE_DECLARATIONS,
		shader = [[

			]] .. SELECT_LOD_GLSL .. [[

			]] .. OCCLUSION_GLSL .. [[

			]] .. draw.WORLD_FROM_GLSL .. [[

			void main() {
				uint slot = gl_GlobalInvocationID.x;

				if (slot >= uint(compute.count)) return;

				uint id = SlotArray(ARGS.slot_rows).r[slot];

				if (id == 0xFFFFFFFFu) return;

				raster_data raster = RasterArray(ARGS.raster).r[id];

				if ((raster.flags & (compute.kind == 0 ? 1u : 32u)) == 0u) return;

				instance_data inst = DataArray(ARGS.data).d[id];

				if ((inst.flags & 16u) != 0u) return;

				if (SeenArray(ARGS.seen).s[id] == 0x7FFFFFFFu) SeenArray(ARGS.seen).s[id] = 0u;

				bool inside = all(greaterThanEqual(compute.camera_position, raster.box_min)) && all(lessThanEqual(compute.camera_position, raster.box_max));

				if (compute.culling_enabled != 0) {
					if (raster.cull_distance > 0.0) {
						vec3 nearest = clamp(compute.camera_position, raster.box_min, raster.box_max);
						vec3 d = compute.camera_position - nearest;

						if (dot(d, d) > raster.cull_distance * raster.cull_distance) return;
					}

					if (
						outside_plane(compute.frustum_planes[0], raster) ||
						outside_plane(compute.frustum_planes[1], raster) ||
						outside_plane(compute.frustum_planes[2], raster) ||
						outside_plane(compute.frustum_planes[3], raster) ||
						outside_plane(compute.frustum_planes[4], raster) ||
						outside_plane(compute.frustum_planes[5], raster)
					) return;

					if (!inside && compute.viewport_height > 0.0 && inst.bounds.w > 0.0) {
						float clip_w = dot(compute.view_w_row, vec4(inst.bounds.xyz, 1.0));

						if (clip_w > 0.0) {
							float projected_radius_px = length(compute.view_y_row.xyz) * inst.bounds.w * compute.viewport_height / max(clip_w * 2.0, 1e-5);

							if (projected_radius_px * 2.0 < 1.0) return;
						}
					}

					if (!inside && (raster.flags & 2u) != 0u && is_box_occluded(raster.box_min, raster.box_max)) return;
				}

				SeenArray(ARGS.seen).s[id] = uint(compute.frame);
				float fade = 0.0;
				uint level = (inst.mask_lod >> 8u) & 0xFFu;
				uint last = (inst.mask_lod >> 16u) & 0xFFu;

				if (last > 0u && (inst.flags & 512u) == 0u) {
					float ratio = distance(compute.camera_position, inst.bounds.xyz) / (max(inst.bounds.w, 0.001) * compute.lod_scale);

					if (!select_lod(level, last, inst.lod.x, inst.lod.y, ratio, fade)) return;
				}

				uint group_id = SlotArray(ARGS.slot_groups).r[slot];

				if (group_id == 0xFFFFFFFFu) return;

				group_record group = GroupArray(ARGS.group_table).g[group_id];

				if ((group.set & GROUP_CLUSTERED) != 0u) return;

				uint place = atomicAdd(CountArray(ARGS.group_counts).n[group_id], 1u);

				if (place >= group.room) return;

				if (compute.kind == 0) {
					float area = ARGS.viewport_pixels;
					float clip_w = dot(compute.view_w_row, vec4(inst.bounds.xyz, 1.0));

					if (!inside && clip_w > 0.0) {
						float radius_px = length(compute.view_y_row.xyz) * inst.bounds.w * compute.viewport_height / max(clip_w * 2.0, 1e-5);
						area = min(3.14159265 * radius_px * radius_px, ARGS.viewport_pixels);
					}

					atomicAdd(CountArray(ARGS.group_areas).n[group_id], uint(max(area, 1.0)));
				}

				uint at = group.base + place;
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

				WorldArray(ARGS.worlds).w[at] = world_from(t.m, fade, inst.dynamic, inst.overlay);
				// a previous world's [0][3] only reaches w, which the vertex stage drops, so it carries the slot for ReadBackCull
				WorldArray(ARGS.prev_worlds).w[at] = world_from(raster.prev, float(slot), inst.dynamic, inst.overlay);
			}
		]],
	}
	return cull_pipeline
end

local stream_cull_pipeline

local function get_stream_cull_pipeline()
	if stream_cull_pipeline then return stream_cull_pipeline end

	stream_cull_pipeline = EasyPipeline.Compute{
		name = "scene_stream_cull",
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
			{"culling_enabled", "int"},
			{"frustum_planes", "vec4", 6},
			{"view_w_row", "vec4"},
			{"view_y_row", "vec4"},
			{"hiz_view_projection", "mat4"},
			{"viewport_height", "float"},
			{"occlusion_max_mip", "int"},
			{"occlusion_depth_bias", "float"},
		},
		write = function(self, block)
			write_view(block)
			return block
		end,
		custom_declarations = [[
			layout(set = 0, binding = 0) uniform sampler2D source_depth_tex;
		]] .. DRAW_DECLARATIONS .. draw.STREAM_GLSL,
		shader = OCCLUSION_GLSL .. [[

			bool outside_sphere(vec4 plane, vec3 center, float radius) {
				return dot(plane.xyz, center) + plane.w < -radius;
			}

			void main() {
				scene_stream_header h = SceneStreamHeader(ARGS.streams).h;

				if (gl_WorkGroupID.x >= h.view_block_count) return;

				uvec2 b = SceneStreamBlocks(h.view_blocks).b[gl_WorkGroupID.x];
				scene_stream_record s = SceneStreamRecords(h.records).s[b.x];
				uint i = b.y + gl_LocalInvocationID.x;

				if (i >= min(SceneStreamCounts(h.counts).n[b.x * 2u], s.room)) return;

				mat4 world = SceneStreamInputs(h.inputs).w[s.first + i];
				vec3 center = mat3(world) * s.bounds.xyz + world[3].xyz;
				float radius = s.bounds.w * sqrt(max(dot(world[0].xyz, world[0].xyz), max(dot(world[1].xyz, world[1].xyz), dot(world[2].xyz, world[2].xyz))));
				vec3 to_camera = compute.camera_position - center;
				bool inside = dot(to_camera, to_camera) <= radius * radius;
				float clip_w = dot(compute.view_w_row, vec4(center, 1.0));
				float radius_px = !inside && clip_w > 0.0 ? length(compute.view_y_row.xyz) * radius * compute.viewport_height / max(clip_w * 2.0, 1e-5) : 1e18;

				if (compute.culling_enabled != 0) {
					if (
						outside_sphere(compute.frustum_planes[0], center, radius) ||
						outside_sphere(compute.frustum_planes[1], center, radius) ||
						outside_sphere(compute.frustum_planes[2], center, radius) ||
						outside_sphere(compute.frustum_planes[3], center, radius) ||
						outside_sphere(compute.frustum_planes[4], center, radius) ||
						outside_sphere(compute.frustum_planes[5], center, radius)
					) return;

					if (radius_px * 2.0 < 1.0) return;

					if (!inside && (s.flags & ]] .. draw.STREAM_OCCLUSION .. [[u) != 0u && is_box_occluded(center - radius, center + radius)) return;
				}

				uint area = uint(max(min(3.14159265 * radius_px * radius_px, ARGS.viewport_pixels), 1.0));
				world[1][3] = 0.0;
				world[2][3] = 0.0;
				mat4 prev = world;
				prev[0][3] = -1.0;

				for (uint p = 0u; p < s.part_count; p++) {
					uint group_id = SceneStreamParts(h.parts).p[s.first_part + p];
					group_record group = GroupArray(ARGS.group_table).g[group_id];
					uint place = atomicAdd(CountArray(ARGS.group_counts).n[group_id], 1u);

					if (place >= group.room) continue;

					atomicAdd(CountArray(ARGS.group_areas).n[group_id], area);
					uint at = group.base + place;
					WorldArray(ARGS.worlds).w[at] = world;
					WorldArray(ARGS.prev_worlds).w[at] = prev;
				}
			}
		]],
	}
	return stream_cull_pipeline
end

local cluster_pipeline
local pair_cpu, pair_cpu_capacity = nil, 0
local pair_built_serial, pair_total = -1, 0
local pair_ring = {}

local function get_cluster_pairs()
	if not next(cluster_rows) then return 0, 0 end

	if pair_built_serial ~= cluster_serial then
		local total = 0

		for _, cluster in pairs(cluster_rows) do
			total = total + cluster.count
		end

		if total > pair_cpu_capacity then
			pair_cpu_capacity = math.ceil(total * 1.5)
			pair_cpu = ffi.new("uint32_t[?]", pair_cpu_capacity * 2)
		end

		local at = 0

		for slot, cluster in pairs(cluster_rows) do
			for k = 0, cluster.count - 1 do
				pair_cpu[at] = slot
				pair_cpu[at + 1] = cluster.base + k
				at = at + 2
			end
		end

		pair_built_serial = cluster_serial
		pair_total = total
	end

	local ring_slot = render.frame_serial % 4 + 1
	local entry = pair_ring[ring_slot]

	if not entry or entry.capacity < pair_total then
		if entry then entry.buffer:Remove() end

		local capacity = math.max(math.ceil(pair_total * 1.5), 1024)
		local buffer = render.CreateBuffer{
			byte_size = capacity * 8,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_draw.cluster_pairs",
		}
		entry = {
			buffer = buffer,
			capacity = capacity,
			pointer = buffer:Map(),
			address = tonumber(buffer:GetDeviceAddress()),
			serial = -1,
		}
		pair_ring[ring_slot] = entry
	end

	if entry.serial ~= pair_built_serial then
		ffi.copy(entry.pointer, pair_cpu, pair_total * 8)
		entry.serial = pair_built_serial
	end

	return pair_total, entry.address
end

local function get_cluster_pipeline()
	if cluster_pipeline then return cluster_pipeline end

	cluster_pipeline = EasyPipeline.Compute{
		name = "scene_cluster_cull",
		DescriptorSetCount = 1,
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		block = {
			{"args", "uint64_t"},
			{"camera_position", "vec3"},
			{"count", "int"},
			{"capacity", "int"},
			{"cluster_capacity", "int"},
			{"frustum_planes", "vec4", 6},
			{"view_w_row", "vec4"},
			{"view_y_row", "vec4"},
			{"viewport_height", "float"},
			{"lod_forced", "int"},
			{"lod_scale", "float"},
			{"lod_fade_width", "float"},
			{"culling_enabled", "int"},
			{"pixel_error", "float"},
			{"frame", "int"},
		},
		write = function(self, block)
			block.frame = system.GetFrameNumber()
			block.args = state.args_address
			block.camera_position[0] = state.camera.x
			block.camera_position[1] = state.camera.y
			block.camera_position[2] = state.camera.z
			block.count = state.cluster_pairs
			block.capacity = state.command_capacity
			block.cluster_capacity = CLUSTER_COMMANDS
			ffi.copy(block.frustum_planes, state.planes, ffi.sizeof("float") * 24)
			state.view_projection:CopyToFloatPointer(view_projection_scratch)
			block.view_w_row[0] = view_projection_scratch[3]
			block.view_w_row[1] = view_projection_scratch[7]
			block.view_w_row[2] = view_projection_scratch[11]
			block.view_w_row[3] = view_projection_scratch[15]
			block.view_y_row[0] = view_projection_scratch[1]
			block.view_y_row[1] = view_projection_scratch[5]
			block.view_y_row[2] = view_projection_scratch[9]
			block.viewport_height = state.viewport_height
			block.lod_forced = lod.GetForcedLevel()
			block.lod_scale = lod.GetScale()
			block.lod_fade_width = lod.GetFadeWidth()
			block.culling_enabled = state.culling and 1 or 0
			block.pixel_error = cluster_lod.GetPixelError()
			return block
		end,
		custom_declarations = DRAW_DECLARATIONS,
		shader = [[

			]] .. SELECT_LOD_GLSL .. [[

			]] .. draw.WORLD_FROM_GLSL .. [[

			vec3 transform_point(float m[12], vec3 p) {
				return vec3(
					m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
					m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
					m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11]
				);
			}

			float projected_error(float error, vec3 center, float radius) {
				float depth = dot(compute.view_w_row, vec4(center, 1.0)) - radius;
				return error * length(compute.view_y_row.xyz) * compute.viewport_height * 0.5 / max(depth, 0.0001);
			}

			bool outside_sphere(vec4 plane, vec3 center, float radius) {
				return dot(plane.xyz, center) + plane.w < -radius;
			}

			void main() {
				uint pair = gl_GlobalInvocationID.x;

				if (pair >= uint(compute.count)) return;

				uvec2 p = PairArray(ARGS.cluster_pairs).p[pair];
				uint slot = p.x;
				uint id = SlotArray(ARGS.slot_rows).r[slot];

				if (id == 0xFFFFFFFFu) return;
				if (SeenArray(ARGS.seen).s[id] != uint(compute.frame)) return;

				uint group_id = SlotArray(ARGS.slot_groups).r[slot];

				if (group_id == 0xFFFFFFFFu) return;

				instance_data inst = DataArray(ARGS.data).d[id];
				cluster_record c = ClusterArray(ARGS.clusters).c[p.y];
				tlas_instance t = TLASArray(ARGS.tlas).t[id];
				float scale = max(length(vec3(t.m[0], t.m[4], t.m[8])), max(length(vec3(t.m[1], t.m[5], t.m[9])), length(vec3(t.m[2], t.m[6], t.m[10]))));

				if (compute.culling_enabled != 0) {
					vec3 bounds_center = transform_point(t.m, c.bounds.xyz);
					float bounds_radius = c.bounds.w * scale;

					if (
						outside_sphere(compute.frustum_planes[0], bounds_center, bounds_radius) ||
						outside_sphere(compute.frustum_planes[1], bounds_center, bounds_radius) ||
						outside_sphere(compute.frustum_planes[2], bounds_center, bounds_radius) ||
						outside_sphere(compute.frustum_planes[3], bounds_center, bounds_radius) ||
						outside_sphere(compute.frustum_planes[4], bounds_center, bounds_radius) ||
						outside_sphere(compute.frustum_planes[5], bounds_center, bounds_radius)
					) return;
				}

				if (projected_error(c.error * scale, transform_point(t.m, c.lod.xyz), c.lod.w * scale) > compute.pixel_error) return;

				if (
					c.parent_error < 1e29 &&
					projected_error(c.parent_error * scale, transform_point(t.m, c.parent.xyz), c.parent.w * scale) <= compute.pixel_error
				) return;

				float fade = 0.0;
				uint level = (inst.mask_lod >> 8u) & 0xFFu;
				uint last = (inst.mask_lod >> 16u) & 0xFFu;

				if (last > 0u && (inst.flags & 512u) == 0u) {
					float ratio = distance(compute.camera_position, inst.bounds.xyz) / (max(inst.bounds.w, 0.001) * compute.lod_scale);

					if (!select_lod(level, last, inst.lod.x, inst.lod.y, ratio, fade)) return;
				}

				group_record group = GroupArray(ARGS.group_table).g[group_id];
				uint place = atomicAdd(CountArray(ARGS.group_counts).n[group_id], 1u);

				if (place >= group.room) return;

				vec3 cluster_center = transform_point(t.m, c.bounds.xyz);
				float cluster_radius = c.bounds.w * scale;
				float clip_w = dot(compute.view_w_row, vec4(cluster_center, 1.0));
				float area = ARGS.viewport_pixels;
				float radius_px = 1e30;

				if (clip_w > cluster_radius) {
					radius_px = length(compute.view_y_row.xyz) * cluster_radius * compute.viewport_height / (clip_w * 2.0);
					area = min(3.14159265 * radius_px * radius_px, ARGS.viewport_pixels);
				}

				float density = float(c.index_count / 3u) / max(area, 1.0);
				uint variant = density >= ARGS.ids_density && (group.set & GROUP_CLASSIC_ONLY) == 0u ? ARGS.ids_remap[GROUP_VARIANT(group)] : ARGS.remap[GROUP_VARIANT(group)];
				uint set = variant * 2u + (group.set & 1u);
				uint index = atomicAdd(CountArray(ARGS.counts).n[set], 1u);

				if (index >= uint(compute.cluster_capacity)) {
					atomicAdd(CountArray(ARGS.counts).n[set], 0xFFFFFFFFu);
					return;
				}

				uint at = group.base + place;
				WorldArray(ARGS.worlds).w[at] = world_from(t.m, fade, inst.dynamic, inst.overlay);
				WorldArray(ARGS.prev_worlds).w[at] = world_from(RasterArray(ARGS.raster).r[id].prev, float(slot), inst.dynamic, inst.overlay);
				bool software = false;

				if (
					ARGS.software_records != 0ul &&
					(group.set & GROUP_SOFTWARE_RASTER) != 0u &&
					variant != ARGS.remap[GROUP_VARIANT(group)] &&
					fade == 0.0 &&
					density >= ARGS.software_density &&
					radius_px < ARGS.software_radius &&
					clip_w - cluster_radius > 0.01
				) {
					uint record = atomicAdd(SoftwareHeader(ARGS.software_header).count, 1u);
					software = record < ]] .. software_raster.CAPACITY .. [[u;

					if (software) {
						SoftwareRecords(ARGS.software_records).r[record] = software_record(
							uvec4(c.first_index, (c.index_count / 3u) | (set << 8u), at, index),
							uvec4(inst.mesh_row, 0u, 0u, 0u)
						);
					}
				}

				CommandArray(ARGS.commands).c[uint(compute.capacity) * set + index] = draw_command(c.index_count, software ? 0u : 1u, c.first_index, 0, at);
				GroupIdArray(ARGS.draw_groups).g[uint(compute.capacity) * set + index] = group_id;
			}
		]],
	}
	return cluster_pipeline
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
		},
		write = function(self, block)
			block.args = state.args_address
			block.count = state.group_count
			block.capacity = state.command_capacity
			return block
		end,
		custom_declarations = DRAW_DECLARATIONS,
		shader = [[

			void main() {
				uint group_id = gl_GlobalInvocationID.x;

				if (group_id >= uint(compute.count)) return;

				group_record group = GroupArray(ARGS.group_table).g[group_id];

				if ((group.set & GROUP_CLUSTERED) != 0u) return;

				uint instance_count = min(CountArray(ARGS.group_counts).n[group_id], group.room);

				if (instance_count == 0u) return;

				mesh_row mesh = MeshArray(ARGS.meshes).m[group.mesh_row];
				float density = float(instance_count) * float(mesh.triangle_count) / max(float(CountArray(ARGS.group_areas).n[group_id]), 1.0);
				uint variant = density >= ARGS.ids_density && (group.set & GROUP_CLASSIC_ONLY) == 0u ? ARGS.ids_remap[GROUP_VARIANT(group)] : ARGS.remap[GROUP_VARIANT(group)];
				uint set = variant * 2u + (group.set & 1u);
				uint packed_index = atomicAdd(CountArray(ARGS.counts).n[set], 1u);
				CommandArray(ARGS.commands).c[uint(compute.capacity) * set + packed_index] = draw_command(mesh.triangle_count * 3u, instance_count, mesh.pool_first_index, 0, group.base);
				GroupIdArray(ARGS.draw_groups).g[uint(compute.capacity) * set + packed_index] = group_id;
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
		buffers.group_areas:Remove()
		buffers.draw_groups:Remove()
		buffers.worlds:Remove()
		buffers.prev_worlds:Remove()

		if buffers.thicknesses then buffers.thicknesses:Remove() end
	end

	local capacity = math.ceil(instance_capacity * 1.5)
	local group_capacity = math.ceil(group_count * 1.5)
	local command_capacity = group_capacity + (kind == 0 and CLUSTER_COMMANDS or 0)
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
		command_capacity = command_capacity,
		commands = render.CreateBuffer{
			byte_size = command_capacity * GROUPS * COMMAND_SIZE,
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
		group_areas = render.CreateBuffer{
			byte_size = group_capacity * 4,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = name .. ".group_areas",
		},
		draw_groups = render.CreateBuffer{
			byte_size = command_capacity * GROUPS * 4,
			buffer_usage = usage,
			memory_property = {"device_local"},
			label = name .. ".draw_groups",
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
	buffers.group_areas_address = buffers.group_areas:GetDeviceAddress()
	buffers.draw_groups_address = buffers.draw_groups:GetDeviceAddress()
	buffers.worlds_address = buffers.worlds:GetDeviceAddress()
	buffers.prev_worlds_address = buffers.prev_worlds:GetDeviceAddress()
	buffer_sets[kind] = buffers
	return buffers
end

local frame_state = {
	frame = -1,
	counts = {[0] = 0, 0},
	group_counts = {[0] = 0, 0},
	drawn = {[0] = {}, {}},
	global_bits = {[0] = 0, 0},
}

local function is_variant_ready(kind, variant)
	if variant == kind.full then return true end

	local ready = true

	for _, name in ipairs(kind.names) do
		if not render3d.IsPipelineReady(render3d.GetPipelineVariant(name, variant)) then
			ready = false
		end
	end

	return ready
end

local function resolve_variants(kind_index, remap, ids_remap)
	local kind = variant_kinds[kind_index]
	local counts = variant_rows[kind_index]
	local drawn = frame_state.drawn[kind_index]
	local available = render3d.HasPipelineVariants(kind.names[1])
	local nearer = kind.shaped and surface_weather.snow_map and surface_weather.snow_depth > 0
	local global_bits = kind_index == 0 and
		surface_conditions.IsFieldActive() and
		shader_features.CONDITIONS or
		0
	frame_state.global_bits[kind_index] = global_bits

	for variant = 0, VARIANTS - 1 do
		local target = kind.full

		if counts[variant] > 0 then
			if available then
				local shape = kind.shaped and
					(
						nearer and
						draw.SHAPE_NEARER or
						draw.GetVariantShape(variant)
					)
					or
					draw.SHAPE_PLAIN
				local wanted = draw.GetVariant(
					shape,
					bit.band(bit.bor(draw.GetVariantBits(variant), global_bits), kind.features)
				)

				if is_variant_ready(kind, wanted) then target = wanted end
			end

			drawn[target] = true
		end

		remap[variant] = target
		ids_remap[variant] = target

		if
			visibility.enabled and
			kind_index == 0 and
			counts[variant] > 0 and
			draw.GetVariantShape(target) == draw.SHAPE_PLAIN
		then
			local ids = draw.GetVariant(draw.SHAPE_IDS, draw.GetVariantBits(target))

			if
				is_variant_ready(kind, ids) and
				visibility.IsResolveReady(visibility.KIND_MULTI_DRAW, draw.GetVariantBits(target))
			then
				ids_remap[variant] = ids
				drawn[ids] = true
			end
		end
	end
end

function draw.GetDrawnVariants(kind)
	return frame_state.drawn[kind]
end

function draw.GetGlobalBits(kind)
	return frame_state.global_bits[kind]
end

draw.STREAM_OCCLUSION = 1
local MAX_STREAMS = 4096
local MAX_STREAM_PARTS = 16384
local STREAM_RING = 4
local NO_SLOT = 0xFFFFFFFF
local StreamHeader = ffi.typeof([[struct {
	uint64_t inputs, counts, records, parts, view_blocks, shadow_blocks, ray_parts;
	uint32_t view_block_count, shadow_block_count, pad[4];
}]])
local StreamRecord = ffi.typeof([[struct {
	uint32_t first, room, shadow_first, shadow_room, first_part, part_count, flags, rows, pad[4];
	float bounds[4];
}]])
local RayPart = ffi.typeof([[struct {
	uint32_t mesh_row, material_row, record_flags, mask_flags, part;
}]])
local STREAM_RING_BYTES = ffi.sizeof(StreamHeader) + ffi.sizeof(StreamRecord) * MAX_STREAMS + 4 * MAX_STREAM_PARTS + ffi.sizeof(RayPart) * MAX_STREAM_PARTS
pvars.StartGroup("Rendering", "Ray traced scene", {store = false})
local rays_enabled = pvars.Setup2{
	key = "r_rt_streams",
	default = true,
	help = "what draw streams draw (scatter) is in the ray traced scene (global illumination, reflections, fog), each instance a row written on the gpu every frame",
}
local ray_distance = pvars.Setup2{
	key = "r_rt_stream_distance",
	default = 1500,
	min = 0,
	help = "how far from the camera what draw streams draw is in the ray traced scene, in meters",
}
pvars.EndGroup()
draw.STREAM_GLSL = [[
	struct scene_stream_header {
		uint64_t inputs;
		uint64_t counts;
		uint64_t records;
		uint64_t parts;
		uint64_t view_blocks;
		uint64_t shadow_blocks;
		uint64_t ray_parts;
		uint view_block_count;
		uint shadow_block_count;
		uvec4 pad;
	};

	struct scene_stream_record {
		uint first;
		uint room;
		uint shadow_first;
		uint shadow_room;
		uint first_part;
		uint part_count;
		uint flags;
		uint rows;
		uvec4 pad;
		vec4 bounds;
	};

	layout(buffer_reference, scalar) readonly buffer SceneStreamHeader { scene_stream_header h; };
	layout(buffer_reference, scalar) readonly buffer SceneStreamRecords { scene_stream_record s[]; };
	layout(buffer_reference, scalar) readonly buffer SceneStreamParts { uint p[]; };
	layout(buffer_reference, scalar) readonly buffer SceneStreamBlocks { uvec2 b[]; };
	layout(buffer_reference, std430) buffer SceneStreamInputs { mat4 w[]; };
	layout(buffer_reference, scalar) buffer SceneStreamCounts { uint n[]; };

	uint scene_stream_append(uint64_t streams, uint stream, uint list, mat4 world) {
		scene_stream_header header = SceneStreamHeader(streams).h;
		scene_stream_record s = SceneStreamRecords(header.records).s[stream];
		uint slot = atomicAdd(SceneStreamCounts(header.counts).n[stream * 2u + list], 1u);

		if (slot < (list == 0u ? s.room : s.shadow_room)) {
			SceneStreamInputs(header.inputs).w[(list == 0u ? s.first : s.shadow_first) + slot] = world;
		}

		return slot;
	}
]]
local streams = {}
local traced_count = 0
local free_stream_indices = {}
local stream_count = 0
local input_space = 0
local input_buffer
local counts_buffer
local stream_ring = {}
local demand_ring = {}
local stream_layout_serial = 0
local packed_serial = -1
local stream_frame = -1
local last_snapshot
local view_blocks = {}
local shadow_blocks = {}

local function build_blocks()
	list.clear(view_blocks)
	list.clear(shadow_blocks)

	for _, stream in pairs(streams) do
		for first = 0, stream.room - 1, LOCAL_SIZE do
			view_blocks[#view_blocks + 1] = stream.index
			view_blocks[#view_blocks + 1] = first
		end
	end

	local view_block_count = #view_blocks / 2

	-- buffer references assume 16 byte aligned bases, so the shadow blocks start on one
	if #view_blocks % 4 ~= 0 then
		view_blocks[#view_blocks + 1] = 0
		view_blocks[#view_blocks + 1] = 0
	end

	for _, stream in pairs(streams) do
		for first = 0, stream.shadow_room - 1, LOCAL_SIZE do
			shadow_blocks[#shadow_blocks + 1] = stream.index
			shadow_blocks[#shadow_blocks + 1] = first
		end
	end

	return view_block_count
end

local function layout_changed()
	assert(
		stream_frame ~= render.frame_serial,
		"streams change before draw.BeginStreams in a frame"
	)
	stream_layout_serial = stream_layout_serial + 1
end

-- stream inputs and slots are rewritten every frame, so a layout change packs them all again instead of keeping free rooms
-- a freed produced range is zeroed by the next flush, so it is only freed once this frame's ranges are taken
local ray_frees = {}

local function free_ray_rows(stream)
	if not stream.rows then return end

	ray_frees[#ray_frees + 1] = {stream.rows, stream.row_count}
	stream.rows = nil
	stream.row_count = 0
end

local scene_parts, materials

local function pack_streams()
	if packed_serial == stream_layout_serial then return end

	input_space, stream_space, stream_shadow_space = 0, 0, 0

	for _, stream in pairs(streams) do
		stream.first = input_space
		stream.shadow_first = input_space + stream.room
		input_space = input_space + stream.room + stream.shadow_room

		for _, part in ipairs(stream.parts) do
			local group = part.group
			group.base, group.room = stream_space, stream.room
			group.shadow_base, group.shadow_room = stream_shadow_space, stream.shadow_room
			stream_space = stream_space + stream.room
			stream_shadow_space = stream_shadow_space + stream.shadow_room
			write_group(group)
		end

		if stream.traced and stream.row_count ~= stream.shadow_room * #stream.parts then
			free_ray_rows(stream)
			stream.row_count = stream.shadow_room * #stream.parts

			if stream.row_count > 0 then
				stream.rows = instances.AllocRange(stream.row_count)
			end
		end
	end

	packed_serial = stream_layout_serial
end

function draw.CreateStream(config)
	layout_changed()
	assert(stream_count < MAX_STREAMS, "too many draw streams")
	local index = table.remove(free_stream_indices) or stream_count
	stream_count = stream_count + 1
	local stream = {
		index = index,
		parts = {},
		bounds = config.bounds,
		flags = config.occlusion and draw.STREAM_OCCLUSION or 0,
		room = config.room,
		shadow_room = config.shadow_room or 0,
		traced = config.traced and render.GetDevice().ray_tracing_supported or nil,
		row_count = 0,
	}

	for i, part in ipairs(config.parts) do
		assert(
			part.mesh.vertex_buffer:GetVertexCount() <= 2 ^ visibility.VERTEX_INDEX_BITS,
			"stream meshes are limited to " .. 2 ^ visibility.VERTEX_INDEX_BITS .. " vertices"
		)
		local set, variant = get_set(part.material)
		stream.parts[i] = {
			mesh = part.mesh,
			material = part.material,
			polygon3d = part.polygon3d,
			mesh_row = part.mesh_row,
			set = set,
			variant = variant,
		}
		stream.parts[i].group = acquire_stream_group(stream.parts[i])

		if stream.traced then
			scene_parts = scene_parts or import("goluwa/render3d/scene/parts.lua")
			materials = materials or import("goluwa/render3d/scene/materials.lua")
			local flags, mask = instances.GetMaterialFlags(part.material)
			stream.parts[i].scene_part = scene_parts.Acquire(part.mesh_row, part.material, part.polygon3d)
			stream.parts[i].material_row = materials.GetID(part.material)
			stream.parts[i].record_flags = instances.GetRecordFlags(flags)
			stream.parts[i].mask_flags = mask + flags * 256
		end
	end

	if stream.traced then traced_count = traced_count + 1 end

	streams[index] = stream
	return stream
end

function draw.ResizeStream(stream, room, shadow_room)
	if room == stream.room and shadow_room == stream.shadow_room then return end

	layout_changed()
	stream.room = room
	stream.shadow_room = shadow_room
end

function draw.RemoveStream(stream)
	layout_changed()

	for _, part in ipairs(stream.parts) do
		release_stream_group(part.group, part.variant)
		part.group = nil

		if part.scene_part then scene_parts.Release(part.scene_part) end
	end

	free_ray_rows(stream)

	if stream.traced then traced_count = traced_count - 1 end

	streams[stream.index] = nil
	free_stream_indices[#free_stream_indices + 1] = stream.index
	stream_count = stream_count - 1
end

local function refresh_stream_sets()
	for _, stream in pairs(streams) do
		for _, part in ipairs(stream.parts) do
			local set, variant = get_set(part.material)

			if set ~= part.set then
				release_stream_group(part.group, part.variant)
				part.set, part.variant = set, variant
				part.group = acquire_stream_group(part)
				stream_layout_serial = stream_layout_serial + 1
			end
		end
	end
end

local function ensure_stream_buffers()
	if not counts_buffer then
		counts_buffer = render.CreateBuffer{
			byte_size = MAX_STREAMS * 8,
			buffer_usage = {"storage_buffer", "shader_device_address", "transfer_dst", "transfer_src"},
			memory_property = {"device_local"},
			label = "scene_draw.stream_counts",
		}
	end

	if not input_buffer or input_buffer.size < input_space * 64 then
		if input_buffer then input_buffer:Remove() end

		input_buffer = render.CreateBuffer{
			byte_size = math.max(math.ceil(input_space * 1.5), 1024) * 64,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"device_local"},
			label = "scene_draw.stream_inputs",
		}
	end
end

function draw.BeginStreams(cmd)
	if stream_frame == render.frame_serial then return last_snapshot.address end

	refresh_stream_sets()
	pack_streams()

	for i = #ray_frees, 1, -1 do
		instances.FreeRange(ray_frees[i][1], ray_frees[i][2], true)
		ray_frees[i] = nil
	end

	ensure_stream_buffers()
	local slot = render.frame_serial % STREAM_RING + 1
	local ring = stream_ring[slot]

	if not ring then
		local buffer = render.CreateBuffer{
			byte_size = STREAM_RING_BYTES,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_draw.streams",
		}
		local pointer = ffi.cast("uint8_t *", buffer:Map())
		ring = {
			buffer = buffer,
			address = tonumber(buffer:GetDeviceAddress()),
			header = ffi.cast(ffi.typeof("$ *", StreamHeader), pointer),
			records = ffi.cast(ffi.typeof("$ *", StreamRecord), pointer + ffi.sizeof(StreamHeader)),
			parts = ffi.cast(
				"uint32_t *",
				pointer + ffi.sizeof(StreamHeader) + ffi.sizeof(StreamRecord) * MAX_STREAMS
			),
			ray_parts = ffi.cast(
				ffi.typeof("$ *", RayPart),
				pointer + ffi.sizeof(StreamHeader) + ffi.sizeof(StreamRecord) * MAX_STREAMS + 4 * MAX_STREAM_PARTS
			),
			serial = -1,
		}
		stream_ring[slot] = ring
	end

	if ring.serial ~= stream_layout_serial or ring.inputs ~= input_buffer then
		local view_block_count = build_blocks()
		local part_at = 0

		for index, stream in pairs(streams) do
			local record = ring.records[index]
			record.first = stream.first
			record.room = stream.room
			record.shadow_first = stream.shadow_first
			record.shadow_room = stream.shadow_room
			record.first_part = part_at
			record.part_count = #stream.parts
			record.flags = stream.flags
			record.rows = stream.rows or NO_SLOT

			for k = 0, 3 do
				record.bounds[k] = stream.bounds[k + 1]
			end

			for _, part in ipairs(stream.parts) do
				assert(part_at < MAX_STREAM_PARTS, "too many draw stream parts")
				ring.parts[part_at] = part.group.id - 1

				if part.scene_part then
					local ray_part = ring.ray_parts[part_at]
					ray_part.mesh_row = part.mesh_row
					ray_part.material_row = part.material_row
					ray_part.record_flags = part.record_flags
					ray_part.mask_flags = part.mask_flags
					ray_part.part = part.scene_part.id
				end

				part_at = part_at + 1
			end
		end

		local blocks = math.floor((#view_blocks + #shadow_blocks) / 2)

		if not ring.blocks or ring.blocks.size < blocks * 8 then
			if ring.blocks then ring.blocks:Remove() end

			ring.blocks = render.CreateBuffer{
				byte_size = math.max(math.ceil(blocks * 1.5), 1024) * 8,
				buffer_usage = {"storage_buffer", "shader_device_address"},
				memory_property = {"host_visible", "host_coherent"},
				label = "scene_draw.stream_blocks",
			}
			ring.blocks_pointer = ffi.cast("uint32_t *", ring.blocks:Map())
			ring.blocks_address = tonumber(ring.blocks:GetDeviceAddress())
		end

		for i = 1, #view_blocks do
			ring.blocks_pointer[i - 1] = view_blocks[i]
		end

		for i = 1, #shadow_blocks do
			ring.blocks_pointer[#view_blocks + i - 1] = shadow_blocks[i]
		end

		local header = ring.header
		header.inputs = input_buffer:GetDeviceAddress()
		header.counts = counts_buffer:GetDeviceAddress()
		header.records = ring.address + ffi.sizeof(StreamHeader)
		header.parts = header.records + ffi.sizeof(StreamRecord) * MAX_STREAMS
		header.ray_parts = header.parts + 4 * MAX_STREAM_PARTS
		header.view_blocks = ring.blocks_address
		header.shadow_blocks = ring.blocks_address + #view_blocks * 4
		header.view_block_count = view_block_count
		header.shadow_block_count = #shadow_blocks / 2
		ring.serial = stream_layout_serial
		ring.inputs = input_buffer
	end

	cmd:PipelineBarrier{
		srcStage = {"compute", "transfer", "draw_indirect", "vertex_shader"},
		dstStage = {"transfer", "compute"},
		memoryBarrier = true,
	}
	cmd:FillBuffer(counts_buffer, 0, MAX_STREAMS * 8, 0)
	cmd:PipelineBarrier{srcStage = "transfer", dstStage = "compute", memoryBarrier = true}
	stream_frame = render.frame_serial
	last_snapshot = {
		serial = render.frame_serial,
		address = ring.address,
		view_block_count = ring.header.view_block_count,
		shadow_block_count = ring.header.shadow_block_count,
	}
	return ring.address
end

function draw.GetStreamStats()
	return {
		streams = stream_count,
		inputs = input_space,
		input_bytes = input_buffer and input_buffer.size or 0,
		slots = stream_space,
		shadow_slots = stream_shadow_space,
		row_slots = group_space,
		slot_offset = stream_offset,
	}
end

function draw.GetStreamDemand(stream)
	local entry = demand_ring[render.frame_serial % STREAM_RING + 1]

	if not entry or entry.serial ~= stream_layout_serial then return nil end

	return entry.counts[stream.index * 2], entry.counts[stream.index * 2 + 1]
end

local ray_pipeline

local function get_ray_pipeline()
	if ray_pipeline then return ray_pipeline end

	ray_pipeline = EasyPipeline.Compute{
		name = "scene_stream_rt",
		DescriptorSetCount = 1,
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		block = {
			{"streams", "uint64_t"},
			{"tlas", "uint64_t"},
			{"data", "uint64_t"},
			{"part_of", "uint64_t"},
			{"camera_position", "vec3"},
			{"distance", "float"},
			{"frame", "int"},
		},
		write = function(self, block)
			block.streams = last_snapshot.address
			block.tlas, block.data, block.part_of = instances.GetProducedAddresses()
			local camera = render3d.GetCamera():GetPosition()
			block.camera_position[0] = camera.x
			block.camera_position[1] = camera.y
			block.camera_position[2] = camera.z
			block.distance = ray_distance:Get()
			block.frame = system.GetFrameNumber()
			return block
		end,
		custom_declarations = [[
			#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
			#extension GL_EXT_buffer_reference : require
			#extension GL_EXT_scalar_block_layout : require
		]] .. draw.STREAM_GLSL,
		shader = [[
			struct ray_tlas_row {
				float m[12];
				uint custom_and_mask;
				uint flags;
				uint64_t blas;
			};

			struct ray_data_row {
				uint mesh_row;
				uint material_row;
				uint flags;
				uint mask_lod;
				vec4 bounds;
				vec2 lod;
				float dynamic;
				float overlay;
			};

			struct ray_part {
				uint mesh_row;
				uint material_row;
				uint record_flags;
				uint mask_flags;
				uint part;
			};

			layout(buffer_reference, scalar) buffer RayTlasRows { ray_tlas_row t[]; };
			layout(buffer_reference, scalar) buffer RayDataRows { ray_data_row d[]; };
			layout(buffer_reference, scalar) buffer RayPartOf { uint p[]; };
			layout(buffer_reference, scalar) readonly buffer RayParts { ray_part p[]; };

			void main() {
				scene_stream_header h = SceneStreamHeader(compute.streams).h;

				if (gl_WorkGroupID.x >= h.shadow_block_count) return;

				uvec2 b = SceneStreamBlocks(h.shadow_blocks).b[gl_WorkGroupID.x];
				scene_stream_record s = SceneStreamRecords(h.records).s[b.x];
				uint i = b.y + gl_LocalInvocationID.x;

				if (s.rows == 0xFFFFFFFFu || i >= min(SceneStreamCounts(h.counts).n[b.x * 2u + 1u], s.shadow_room)) return;

				mat4 world = SceneStreamInputs(h.inputs).w[s.shadow_first + i];

				if (distance(world[3].xyz, compute.camera_position) > compute.distance) return;

				RayTlasRows tlas = RayTlasRows(compute.tlas);
				RayDataRows data = RayDataRows(compute.data);
				RayPartOf part_of = RayPartOf(compute.part_of);

				for (uint j = 0u; j < s.part_count; j++) {
					ray_part p = RayParts(h.ray_parts).p[s.first_part + j];
					uint row = s.rows + i * s.part_count + j;
					uint mask = p.mask_flags & 0xFFu;

					for (uint k = 0u; k < 4u; k++) {
						tlas.t[row].m[k] = world[k][0];
						tlas.t[row].m[4u + k] = world[k][1];
						tlas.t[row].m[8u + k] = world[k][2];
					}

					tlas.t[row].custom_and_mask = row | (mask << 24u);
					tlas.t[row].flags = p.record_flags;
					data.d[row].mesh_row = p.mesh_row;
					data.d[row].material_row = p.material_row;
					data.d[row].flags = (p.mask_flags >> 8u) | 32u;
					data.d[row].mask_lod = mask;
					data.d[row].lod = vec2(uintBitsToFloat(uint(compute.frame)), 0.0);
					part_of.p[row] = p.part;
				}
			}
		]],
	}
	return ray_pipeline
end

-- the producer calls this once it has appended: produced rows are shown only in the frame they are written, before the scene build
function draw.EndStreams(cmd)
	if stream_frame ~= render.frame_serial or traced_count == 0 or not rays_enabled:Get() then
		return
	end

	render3d = render3d or import("goluwa/render3d/render3d.lua")
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	get_ray_pipeline():Dispatch(cmd, last_snapshot.shadow_block_count, 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
end

local function is_streaming()
	return stream_frame == render.frame_serial and stream_count > 0
end

local copy_stream_demand

do
	local BufferCopy = ffi.typeof("$[1]", vk.VkBufferCopy)
	local copy = BufferCopy()

	function copy_stream_demand(cmd)
		local slot = render.frame_serial % STREAM_RING + 1
		local entry = demand_ring[slot]

		if not entry then
			local buffer = render.CreateBuffer{
				byte_size = MAX_STREAMS * 8,
				buffer_usage = {"transfer_dst"},
				memory_property = {"host_visible", "host_coherent"},
				label = "scene_draw.stream_demand",
			}
			entry = {buffer = buffer, counts = ffi.cast("uint32_t *", buffer:Map())}
			demand_ring[slot] = entry
		end

		cmd:PipelineBarrier{srcStage = "compute", dstStage = "transfer", memoryBarrier = true}
		copy[0].size = MAX_STREAMS * 8
		cmd:CopyBuffer(counts_buffer, entry.buffer, copy, 1)
		entry.serial = stream_layout_serial
	end
end

local function get_shadow_snapshot()
	if
		last_snapshot and
		render.frame_serial - last_snapshot.serial <= 1 and
		stream_count > 0
	then
		return last_snapshot
	end

	return nil
end

-- without a depth pyramid the culls never sample it (occlusion_max_mip is -1), but the descriptor must still be valid
local function bind_depth_pyramid(pipeline, slot, bound)
	if bound then
		pipeline:UpdateDescriptorSet(
			"combined_image_sampler",
			slot,
			0,
			0,
			bound.view,
			bound.sampler,
			nil,
			nil,
			"general"
		)
	else
		pipeline:UpdateDescriptorSet("combined_image_sampler", slot, 0, 0, render.GetErrorTexture())
	end
end

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

	for variant = 0, VARIANTS - 1 do
		frame_state.drawn[0][variant] = false
		frame_state.drawn[1][variant] = false
	end

	local streaming = is_streaming()
	frame_state.streaming = streaming

	if count == 0 and not streaming then return end

	ensure_slot_tables()
	fit_stream_offset()
	store.FlushStaged(cmd)
	render3d = render3d or import("goluwa/render3d/render3d.lua")
	surface_conditions = surface_conditions or import("goluwa/render3d/surface_conditions.lua")
	local pipeline = get_cull_pipeline()
	local finalize = get_finalize_pipeline()
	local group_count = #groups
	args_ring = args_ring or {}
	local hiz, fallback_hiz = gpu_culling.GetMainViewHiZ()
	local bound = hiz or fallback_hiz
	local descriptor_slot = render.frame_serial % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
	bind_depth_pyramid(pipeline, descriptor_slot, bound)

	if streaming then
		bind_depth_pyramid(get_stream_cull_pipeline(), descriptor_slot, bound)
	end

	local seen_address = instances.GetSeenTable():GetAddress()
	local pair_total, pair_address = get_cluster_pairs()
	gpu_timing.BeginScope(cmd, "scene_cull")

	for kind = 0, translucent_count > 0 and 1 or 0 do
		local buffers = ensure_buffers(kind, get_slot_space(kind), group_count)
		local ring_slot = render.frame_serial % 4 + 1
		local ring = args_ring[kind]

		if not ring then
			ring = {}
			args_ring[kind] = ring
		end

		local args = ring[ring_slot]

		if not args then
			args = render.CreateBuffer{
				byte_size = ARGS_REMAP * 8 + VARIANTS * 8,
				buffer_usage = {"storage_buffer", "shader_device_address"},
				memory_property = {"host_visible", "host_coherent"},
				label = "scene_draw.args",
			}
			ring[ring_slot] = args
			args.pointer = ffi.cast("uint64_t *", args:Map())
			args.remap = ffi.cast("uint32_t *", args.pointer + ARGS_REMAP)
			args.ids_remap = args.remap + VARIANTS
			args.viewport_pixels = ffi.cast("float *", args.pointer + 18)
			args.software = ffi.cast("float *", args.pointer + 21)
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
		args.pointer[13] = buffers.draw_groups_address
		args.pointer[14] = seen_address
		args.pointer[15] = cluster_lod.GetTable():GetAddress()
		args.pointer[16] = pair_address
		args.pointer[17] = buffers.group_areas_address
		local render_size = render3d.GetInternalRenderSize()
		args.viewport_pixels[0] = render_size.x * render_size.y
		args.viewport_pixels[1] = visibility.GetDensity()
		local software_records, software_header, software_density, software_radius = software_raster.GetCullArgs()
		args.pointer[19] = kind == 0 and software_records or 0
		args.pointer[20] = software_header
		args.software[0] = software_density
		args.software[1] = software_radius
		args.pointer[22] = kind == 0 and streaming and last_snapshot.address or 0
		resolve_variants(kind, args.remap, args.ids_remap)
		state.kind = kind
		state.args_address = args.address
		state.camera = camera_position
		state.count = count
		state.capacity = buffers.group_capacity
		state.group_count = group_count
		state.group_capacity = buffers.group_capacity
		state.command_capacity = buffers.command_capacity
		state.planes = frustum_planes
		state.view_projection = view_projection
		state.viewport_height = viewport_height
		state.culling = culling_enabled
		state.occlusion_max_mip = hiz and hiz.max_mip or nil
		state.occlusion_view_projection = hiz and hiz.view_projection or nil
		cmd:FillBuffer(buffers.counts, 0, buffers.counts.size, 0)
		cmd:FillBuffer(buffers.group_counts, 0, buffers.group_counts.size, 0)
		cmd:FillBuffer(buffers.group_areas, 0, buffers.group_areas.size, 0)

		if kind == 0 then software_raster.Reset(cmd, buffers.worlds_address) end

		cmd:PipelineBarrier{
			srcStage = {"host", "transfer", "compute"},
			dstStage = "compute",
			memoryBarrier = true,
		}

		if count > 0 then
			pipeline:Dispatch(cmd, math.ceil(count / LOCAL_SIZE), 1, 1, descriptor_slot)
		end

		if kind == 0 and streaming and last_snapshot.view_block_count > 0 then
			get_stream_cull_pipeline():Dispatch(cmd, last_snapshot.view_block_count, 1, 1, descriptor_slot)
		end

		cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}

		if kind == 0 and pair_total > 0 then
			state.cluster_pairs = pair_total
			get_cluster_pipeline():Dispatch(cmd, math.ceil(pair_total / LOCAL_SIZE), 1, 1, 1)
			cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
		end

		finalize:Dispatch(cmd, math.ceil(group_count / LOCAL_SIZE), 1, 1, 1)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = {"draw_indirect", "vertex_shader", "vertex_input"},
			memoryBarrier = true,
		}
		frame_state.counts[kind] = count
		frame_state.group_counts[kind] = group_count
	end

	if streaming then copy_stream_demand(cmd) end

	gpu_timing.EndScope(cmd, "scene_cull")
end

local function describe_row(row)
	if row.cluster then return "clustered" end

	local material, polygon3d = row.material, row.first_polygon3d

	if not row.drawn then
		return "not drawn by the gbuffer (rays only, hidden or hidden from the view)"
	end

	if row.translucent then return "drawn by the translucent pass" end

	if not polygon3d then return "no polygon" end

	if polygon3d.shell_grid then return "height shell mesh" end

	if not cluster_lod.IsEnabled() then return "r_cluster_lod is off" end

	if material:IsTransparent() then return "transparent material" end

	if material:MarchesRelief() then return "relief or height map material" end

	if material.Decal then return "decal material" end

	return cluster_lod.DescribePolygon(polygon3d)
end

function draw.GetClusterReport()
	local report, by_key = {}, {}

	for slot = 0, #rows - 1 do
		local row = rows[slot + 1]
		local polygon3d = row.first_polygon3d

		if row.group and polygon3d then
			local reason = describe_row(row)
			local key = tostring(polygon3d) .. reason
			local entry = by_key[key]

			if not entry then
				local packed = polygon3d.packed
				local mesh = polygon3d.mesh
				entry = {
					name = polygon3d.Name or tostring(polygon3d),
					reason = reason,
					rows = 0,
					triangles = packed and
						packed.index_count / 3 or
						(
							mesh and
							mesh.index_buffer and
							mesh.index_buffer:GetIndexCount() / 3
						)
						or
						0,
				}
				by_key[key] = entry
				report[#report + 1] = entry
			end

			entry.rows = entry.rows + 1
		end
	end

	return report
end

function draw.GetClusterStats()
	local row_count = 0

	for _ in pairs(cluster_rows) do
		row_count = row_count + 1
	end

	return {rows = row_count, pairs = pair_total}
end

function draw.IsEyeNearHeightShell(eye)
	local tlas = instances.GetTables():Get()

	for id in pairs(height_shell_ids) do
		local row = rows[slot_of[id] + 1]
		local m = tlas[id].transform.matrix
		local a, b, c = m[0][0], m[0][1], m[0][2]
		local d, e, f = m[1][0], m[1][1], m[1][2]
		local g, h, i = m[2][0], m[2][1], m[2][2]
		local x, y, z = eye.x - m[0][3], eye.y - m[1][3], eye.z - m[2][3]
		local det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
		local min_scale = math.sqrt(math.min(a * a + d * d + g * g, b * b + e * e + h * h, c * c + f * f + i * i))

		if
			row.first_polygon3d:IsNearHeightShell(
				((e * i - f * h) * x + (c * h - b * i) * y + (b * f - c * e) * z) / det,
				((f * g - d * i) * x + (a * i - c * g) * y + (c * d - a * f) * z) / det,
				((d * h - e * g) * x + (b * g - a * h) * y + (a * e - b * d) * z) / det,
				row.material:GetHeightShell() * 2 / min_scale
			)
		then
			return true
		end
	end

	return false
end

local batch_tables = setmetatable({}, {__mode = "k"})

function draw.IsCulled()
	return frame_state.frame == system.GetFrameNumber()
end

local function draw_variants(gbuffer_instancing, kind, name, displaced)
	local buffers = buffer_sets[kind]
	local cmd = render.GetCommandBuffer()
	local group_size = buffers.command_capacity * COMMAND_SIZE
	local count = frame_state.group_counts[kind] + (kind == 0 and CLUSTER_COMMANDS or 0)
	local drawn = frame_state.drawn[kind]

	for variant = 0, VARIANTS - 1 do
		if
			drawn[variant] and
			(
				displaced == nil or
				(
					(
						draw.GetVariantShape(variant) ~= draw.SHAPE_PLAIN and
						draw.GetVariantShape(variant) ~= draw.SHAPE_IDS
					)
					or
					bit.band(draw.GetVariantBits(variant), shader_features.TERRAIN) ~= 0
				) == displaced
			)
		then
			local pipeline = render3d.GetPipelineVariant(name, variant)
			local batch_table = batch_tables[pipeline]

			if not batch_table then
				batch_table = gbuffer_instancing.NewBatchTable(pipeline.name .. "_scene_groups", group_changes)
				batch_tables[pipeline] = batch_table
			end

			pipeline.draw_batches_address = batch_table:Update(pipeline, groups, draw.group_serial, system.GetFrameNumber())
			pipeline.draw_instances_address = buffers.worlds_address
			pipeline.draw_prev_instances_address = buffers.prev_worlds_address
			pipeline.draw_thicknesses_address = buffers.thicknesses_address
			cmd:BindIndexBuffer(index_pool.GetBuffer(), 0, "uint32")

			for sided = 0, 1 do
				local set = variant * 2 + sided
				pipeline.draw_groups_address = buffers.draw_groups_address + set * buffers.command_capacity * 4

				if pipeline.config.visibility then
					visibility.AddContext(pipeline, buffers.commands_address + set * group_size, set)
				end

				pipeline:UploadConstants()
				cmd:SetCullMode(sided == 0 and orientation.CULL_MODE or "none")
				cmd:DrawIndexedIndirectCount(buffers.commands, set * group_size, buffers.counts, set * 4, count, COMMAND_SIZE)
			end
		end
	end
end

function draw.Draw(gbuffer_instancing, name, displaced)
	if
		frame_state.frame ~= system.GetFrameNumber() or
		(
			frame_state.counts[0] == 0 and
			not frame_state.streaming
		)
	then
		return false
	end

	gpu_culling.MarkMainViewDrawn()
	draw_variants(gbuffer_instancing, 0, name, displaced)
	return true
end

function draw.DrawTranslucent(gbuffer_instancing, name)
	if frame_state.frame ~= system.GetFrameNumber() or frame_state.counts[1] == 0 then
		return false
	end

	gpu_timing.SetInfo(render3d.translucent_scope, "store_slots", frame_state.counts[1])
	draw_variants(gbuffer_instancing, 1, name, nil)
	return true
end

local SHADOW_DECLARATIONS = TABLE_DECLARATIONS .. [[
			struct shadow_args {
				uint64_t tlas;
				uint64_t data;
				uint64_t raster;
				uint64_t meshes;
				uint64_t commands;
				uint64_t worlds;
				uint64_t slot_rows;
				uint64_t counts;
				uint64_t slot_groups;
				uint64_t group_table;
				uint64_t group_counts;
				uint64_t draw_groups;
				uint64_t streams;
			};

			layout(buffer_reference, scalar) readonly buffer ArgsRef { shadow_args a; };
			#define ARGS ArgsRef(compute.args).a
]]
local shadow_pipeline
local shadow_finalize_pipeline
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
		custom_declarations = SHADOW_DECLARATIONS .. OUTSIDE_PLANE_DECLARATIONS,
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

				if (id == 0xFFFFFFFFu) return;

				raster_data raster = RasterArray(ARGS.raster).r[id];
				instance_data inst = DataArray(ARGS.data).d[id];

				if ((raster.flags & 16u) == 0u || (inst.flags & 48u) != 0u) return;

				if (compute.culling_enabled != 0) {
					if (
						outside_plane(compute.planes[0], raster) ||
						outside_plane(compute.planes[1], raster) ||
						outside_plane(compute.planes[2], raster) ||
						outside_plane(compute.planes[3], raster) ||
						outside_plane(compute.planes[4], raster)
					) return;

					if (compute.min_caster_extent > 0.0) {
						vec3 half_size = 0.5 * (raster.box_max - raster.box_min);
						float extent_x = dot(abs(compute.light_axis_x), half_size) * 2.0;
						float extent_y = dot(abs(compute.light_axis_y), half_size) * 2.0;

						if (extent_x < compute.min_caster_extent && extent_y < compute.min_caster_extent) return;
					}
				}

				uint level = (inst.mask_lod >> 8u) & 0xFFu;
				uint last = (inst.mask_lod >> 16u) & 0xFFu;
				float ratio = distance(compute.camera_position, inst.bounds.xyz) / (max(inst.bounds.w, 0.001) * compute.lod_scale);

				if (((last > 0u && (inst.flags & 512u) == 0u) || (inst.flags & 128u) != 0u) && !select_shadow_lod(inst.flags, level, last, inst.lod.x, inst.lod.y, ratio)) return;

				uint group_id = SlotArray(ARGS.slot_groups).r[slot];

				if (group_id == 0xFFFFFFFFu) return;

				group_record group = GroupArray(ARGS.group_table).g[group_id];
				uint place = atomicAdd(CountArray(ARGS.group_counts).n[group_id], 1u);

				if (place >= group.shadow_room) return;

				tlas_instance t = TLASArray(ARGS.tlas).t[id];
				// the shadow vertex stage reads only xyz of a world position, so [1][3] carries the slot for ReadBackShadowCull
				WorldArray(ARGS.worlds).w[group.shadow_base + place] = mat4(
					vec4(t.m[0], t.m[4], t.m[8], 0.0),
					vec4(t.m[1], t.m[5], t.m[9], float(slot)),
					vec4(t.m[2], t.m[6], t.m[10], 0.0),
					vec4(t.m[3], t.m[7], t.m[11], 1.0)
				);
			}
		]],
	}
	return shadow_pipeline
end

local shadow_stream_pipeline

local function get_shadow_stream_pipeline()
	if shadow_stream_pipeline then return shadow_stream_pipeline end

	shadow_stream_pipeline = EasyPipeline.Compute{
		name = "scene_shadow_stream_cull",
		DescriptorSetCount = 1,
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		block = {
			{"args", "uint64_t"},
			{"planes", "vec4", 5},
			{"min_caster_extent", "float"},
			{"culling_enabled", "int"},
		},
		write = function(self, block)
			local v = self.shadow_state
			block.args = v.args_address

			for i = 0, 4 do
				for k = 0, 3 do
					block.planes[i][k] = v.planes[i * 4 + k]
				end
			end

			block.min_caster_extent = v.min_caster_extent
			block.culling_enabled = gpu_culling.culling_enabled and 1 or 0
			return block
		end,
		custom_declarations = SHADOW_DECLARATIONS .. draw.STREAM_GLSL,
		shader = [[
			void main() {
				scene_stream_header h = SceneStreamHeader(ARGS.streams).h;

				if (gl_WorkGroupID.x >= h.shadow_block_count) return;

				uvec2 b = SceneStreamBlocks(h.shadow_blocks).b[gl_WorkGroupID.x];
				scene_stream_record s = SceneStreamRecords(h.records).s[b.x];
				uint i = b.y + gl_LocalInvocationID.x;

				if (i >= min(SceneStreamCounts(h.counts).n[b.x * 2u + 1u], s.shadow_room)) return;

				mat4 world = SceneStreamInputs(h.inputs).w[s.shadow_first + i];
				vec3 center = mat3(world) * s.bounds.xyz + world[3].xyz;
				float radius = s.bounds.w * sqrt(max(dot(world[0].xyz, world[0].xyz), max(dot(world[1].xyz, world[1].xyz), dot(world[2].xyz, world[2].xyz))));

				if (compute.culling_enabled != 0) {
					if (compute.min_caster_extent > 0.0 && radius * 2.0 < compute.min_caster_extent) return;

					// vertex animation moves leaves past the bounds
					float reach = radius * 1.25 + 0.25;

					if (
						dot(compute.planes[0].xyz, center) + compute.planes[0].w < -reach ||
						dot(compute.planes[1].xyz, center) + compute.planes[1].w < -reach ||
						dot(compute.planes[2].xyz, center) + compute.planes[2].w < -reach ||
						dot(compute.planes[3].xyz, center) + compute.planes[3].w < -reach ||
						dot(compute.planes[4].xyz, center) + compute.planes[4].w < -reach
					) return;
				}

				world[0][3] = 0.0;
				world[1][3] = -1.0;
				world[2][3] = 0.0;

				for (uint p = 0u; p < s.part_count; p++) {
					uint group_id = SceneStreamParts(h.parts).p[s.first_part + p];
					group_record group = GroupArray(ARGS.group_table).g[group_id];
					uint place = atomicAdd(CountArray(ARGS.group_counts).n[group_id], 1u);

					if (place < group.shadow_room) WorldArray(ARGS.worlds).w[group.shadow_base + place] = world;
				}
			}
		]],
	}
	return shadow_stream_pipeline
end

local function get_shadow_finalize_pipeline()
	if shadow_finalize_pipeline then return shadow_finalize_pipeline end

	shadow_finalize_pipeline = EasyPipeline.Compute{
		name = "scene_shadow_finalize",
		DescriptorSetCount = 1,
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		block = {
			{"args", "uint64_t"},
			{"count", "int"},
		},
		write = function(self, block)
			block.args = self.shadow_state.args_address
			block.count = self.shadow_state.group_count
			return block
		end,
		custom_declarations = SHADOW_DECLARATIONS,
		shader = [[
			void main() {
				uint group_id = gl_GlobalInvocationID.x;

				if (group_id >= uint(compute.count)) return;

				group_record group = GroupArray(ARGS.group_table).g[group_id];
				uint instance_count = min(CountArray(ARGS.group_counts).n[group_id], group.shadow_room);

				if (instance_count == 0u) return;

				mesh_row mesh = MeshArray(ARGS.meshes).m[group.mesh_row];
				uint index = atomicAdd(CountArray(ARGS.counts).n[0], 1u);
				CommandArray(ARGS.commands).c[index] = draw_command(mesh.triangle_count * 3u, instance_count, mesh.pool_first_index, 0, group.shadow_base);
				GroupIdArray(ARGS.draw_groups).g[index] = group_id;
			}
		]],
	}
	return shadow_finalize_pipeline
end

local SHADOW_BUFFERS = {"commands", "counts", "group_counts", "draw_groups", "worlds", "args"}

function draw.NewShadowBuffers()
	return {capacity = 0, group_capacity = 0}
end

function draw.RemoveShadowBuffers(buffers)
	if not buffers.commands then return end

	for _, name in ipairs(SHADOW_BUFFERS) do
		buffers[name]:Remove()
		buffers[name] = nil
	end
end

-- a grown buffer may still be drawn from by an earlier cascade in a shadow command buffer that is not submitted yet
local retired_shadow_buffers = {}
local SHADOW_RETIRE_FRAMES = 4

local function retire_shadow_buffers(buffers)
	if not buffers.commands then return end

	for _, name in ipairs(SHADOW_BUFFERS) do
		list.insert(retired_shadow_buffers, {buffer = buffers[name], frame = system.GetFrameNumber()})
		buffers[name] = nil
	end
end

function draw.CullShadow(cmd, buffers, planes, camera_position, min_caster_extent, light_view)
	local tlas_table, data_table = instances.GetTables()
	local count = #rows
	local snapshot = get_shadow_snapshot()

	if count == 0 and not snapshot then return nil end

	ensure_slot_tables()
	fit_stream_offset()
	store.FlushStaged(cmd)
	local group_count = #groups
	local slot_space = get_shadow_slot_space()

	for i = #retired_shadow_buffers, 1, -1 do
		if system.GetFrameNumber() - retired_shadow_buffers[i].frame > SHADOW_RETIRE_FRAMES then
			retired_shadow_buffers[i].buffer:Remove()
			list.remove(retired_shadow_buffers, i)
		end
	end

	if buffers.capacity < slot_space or buffers.group_capacity < group_count then
		retire_shadow_buffers(buffers)
		buffers.capacity = math.ceil(slot_space * 1.5)
		buffers.group_capacity = math.ceil(group_count * 1.5)
		local usage = {
			"storage_buffer",
			"shader_device_address",
			"indirect_buffer",
			"transfer_dst",
			"transfer_src",
		}
		local sizes = {
			commands = buffers.group_capacity * COMMAND_SIZE,
			counts = 4,
			group_counts = buffers.group_capacity * 4,
			draw_groups = buffers.group_capacity * 4,
			worlds = buffers.capacity * 64,
		}

		for name, size in pairs(sizes) do
			buffers[name] = render.CreateBuffer{
				byte_size = size,
				buffer_usage = usage,
				memory_property = {"device_local"},
				label = "scene_draw.shadow_" .. name,
			}
			buffers[name .. "_address"] = buffers[name]:GetDeviceAddress()
		end

		buffers.args = render.CreateBuffer{
			byte_size = 13 * 8,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_draw.shadow_args",
		}
		buffers.args_pointer = ffi.cast("uint64_t *", buffers.args:Map())
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
	pointer[8] = slot_groups:GetAddress()
	pointer[9] = group_table:GetAddress()
	pointer[10] = buffers.group_counts_address
	pointer[11] = buffers.draw_groups_address
	pointer[12] = snapshot and snapshot.address or 0
	local pipeline = get_shadow_pipeline()
	local finalize = get_shadow_finalize_pipeline()
	local v = pipeline.shadow_state or {axis_x = {0, 0, 0}, axis_y = {0, 0, 0}, planes = {}}
	pipeline.shadow_state = v
	finalize.shadow_state = v
	v.args_address = buffers.args_address
	v.camera = camera_position
	v.count = count
	v.group_count = group_count

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

	cmd:PipelineBarrier{
		srcStage = {"compute", "draw_indirect", "vertex_shader"},
		dstStage = {"transfer", "compute"},
		memoryBarrier = true,
	}
	cmd:FillBuffer(buffers.counts, 0, 4, 0)
	cmd:FillBuffer(buffers.group_counts, 0, group_count * 4, 0)
	cmd:PipelineBarrier{
		srcStage = {"host", "transfer"},
		dstStage = "compute",
		memoryBarrier = true,
	}

	if count > 0 then
		pipeline:Dispatch(cmd, math.ceil(count / LOCAL_SIZE), 1, 1, 1)
	end

	if snapshot and snapshot.shadow_block_count > 0 then
		local streams_pipeline = get_shadow_stream_pipeline()
		streams_pipeline.shadow_state = v
		streams_pipeline:Dispatch(cmd, snapshot.shadow_block_count, 1, 1, 1)
	end

	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	finalize:Dispatch(cmd, math.ceil(group_count / LOCAL_SIZE), 1, 1, 1)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"draw_indirect", "vertex_shader"},
		memoryBarrier = true,
	}
	buffers.group_count = group_count
	return count
end

function draw.GetGroups()
	return groups, draw.group_serial, group_changes
end

do
	local download = store.Download

	function draw.GetRowId(slot)
		return slot_rows:Get()[slot]
	end

	function draw.ReadBackCull(kind)
		kind = kind or 0
		local result = {
			by_id = {},
			by_group = {},
			count = 0,
			streamed = 0,
			slots = frame_state.counts[kind],
		}
		local buffers = buffer_sets[kind]

		if not buffers or (result.slots == 0 and not frame_state.streaming) then
			return result
		end

		local group_capacity = buffers.command_capacity
		-- the downloads are kept in locals, a pointer cast from them alone lets them be collected
		local commands_data = download(buffers.commands, group_capacity * GROUPS * COMMAND_SIZE)
		local counts_data = download(buffers.counts, GROUPS * 4)
		local worlds_data = download(buffers.worlds, buffers.capacity * 64)
		local prev_worlds_data = download(buffers.prev_worlds, buffers.capacity * 64)
		local draw_groups_data = download(buffers.draw_groups, group_capacity * GROUPS * 4)
		local commands = ffi.cast("uint32_t *", commands_data)
		local counts = ffi.cast("uint32_t *", counts_data)
		local worlds = ffi.cast("float *", worlds_data)
		local prev_worlds = ffi.cast("float *", prev_worlds_data)
		local draw_groups = ffi.cast("uint32_t *", draw_groups_data)
		local ids = slot_rows:Get()

		for set = 0, GROUPS - 1 do
			for packed_index = 0, counts[set] - 1 do
				local command = commands + (set * group_capacity + packed_index) * (COMMAND_SIZE / 4)
				local instance_count = math.max(command[1], 1)
				result.commands = (result.commands or 0) + 1
				result.triangles = (result.triangles or 0) + command[0] / 3 * instance_count

				for place = 0, instance_count - 1 do
					local at = command[4] + place
					local slot = prev_worlds[at * 16 + 3]
					local world = {}

					for i = 0, 11 do
						world[i + 1] = worlds[at * 16 + (i % 4) * 4 + math.floor(i / 4)]
					end

					local entry = {
						slot = slot,
						group = set,
						group_id = draw_groups[set * group_capacity + packed_index] + 1,
						fade = worlds[at * 16 + 3],
						world = world,
						index_count = command[0],
						first_index = command[2],
					}

					if slot < 0 then
						result.by_group[entry.group_id] = result.by_group[entry.group_id] or {}
						list.insert(result.by_group[entry.group_id], entry)
						result.streamed = result.streamed + 1
					else
						result.by_id[ids[slot]] = entry
					end

					result.count = result.count + 1
				end
			end
		end

		return result
	end

	function draw.ReadBackShadowCull(buffers, count)
		local result = {by_id = {}, count = 0, streamed = 0, slots = count or 0}

		if not buffers.commands then return result end

		local drawn = ffi.cast("uint32_t *", download(buffers.counts, 4))[0]
		local commands_data = download(buffers.commands, buffers.group_capacity * COMMAND_SIZE)
		local worlds_data = download(buffers.worlds, buffers.capacity * 64)
		local commands = ffi.cast("uint32_t *", commands_data)
		local worlds = ffi.cast("float *", worlds_data)
		local ids = slot_rows:Get()

		for packed_index = 0, drawn - 1 do
			local command = commands + packed_index * (COMMAND_SIZE / 4)

			for place = 0, command[1] - 1 do
				local slot = worlds[(command[4] + place) * 16 + 7]

				if slot < 0 then
					result.streamed = result.streamed + 1
				else
					result.by_id[ids[slot]] = {slot = slot, index_count = command[0]}
				end

				result.count = result.count + 1
			end
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
return draw
