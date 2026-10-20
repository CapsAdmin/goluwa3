local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local store = import("goluwa/render3d/scene/store.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local scatter_rt = {}
-- scatter in the ray traced scene: the lists scatter keeps for the shadow maps (what is baked and in range, in view or not,
-- the model near and its billboard beyond the billboard's distance) are turned into instances of the top level structure
-- on the gpu every frame, so what the rays see is what the real scene draws and there is nothing to copy to the host
local Segment = ffi.typeof([[struct {
	uint32_t first_record;
	uint32_t record_count;
	uint32_t list_base;
	uint32_t room;
	uint32_t counter;
	uint32_t parts_first;
	uint32_t parts_count;
	uint32_t pad;
}]])
local Part = ffi.typeof([[struct {
	uint32_t mesh_row;
	uint32_t material_row;
	uint32_t record_flags;
	uint32_t mask_flags;
}]])
local LOCAL_SIZE = 64
pvars.StartGroup("Rendering", "Scatter ray tracing", {store = false})
local enabled = pvars.Setup2{
	key = "r_scatter_rt",
	default = true,
	help = "what scatter grows is in the ray traced scene (global illumination, reflections, fog), as the model near the camera and the billboard beyond its distance, like the real scene draws it",
}
local max_distance = pvars.Setup2{
	key = "r_scatter_rt_distance",
	default = 1500,
	min = 0,
	help = "how far from the camera what scatter grows is in the ray traced scene, in meters",
}
pvars.EndGroup()
local segments_table, parts_table
local pipeline
local built_version = -1
local bound_buffers = {}
local range_base, range_count = nil, 0
local segment_count = 0

local function get_tables()
	if not segments_table then
		segments_table = store.CreateTable{name = "scatter_rt_segments", ctype = Segment, capacity = 1024}
		parts_table = store.CreateTable{name = "scatter_rt_parts", ctype = Part, capacity = 4096}
	end

	return segments_table, parts_table
end

local create_pipeline

local function get_pipeline()
	if pipeline then return pipeline end

	return create_pipeline()
end

function create_pipeline()
	pipeline = EasyPipeline.Compute{
		name = "scatter_rt_instances",
		DescriptorSetCount = math.max(render.GetSwapchainImageCount() or 1, 1),
		LocalSize = {x = LOCAL_SIZE, y = 1, z = 1},
		storage_buffers = {
			{binding_index = 0},
			{binding_index = 1},
			{binding_index = 2},
			{binding_index = 3},
			{binding_index = 4},
			{binding_index = 5},
			{binding_index = 6},
		},
		uniform_buffers = {
			{
				name = "produce_data",
				binding_index = 8,
				block = {
					{"region_base", "int"},
					{"record_count", "int"},
					{"segment_count", "int"},
					{"counter_base", "int"},
					{"camera", "vec4"},
					{"max_distance", "float"},
				},
				write = function(self, block)
					block.region_base = range_base or 0
					block.record_count = range_count
					block.segment_count = segment_count
					block.counter_base = 4
					local position = import("goluwa/render3d/render3d.lua").GetCamera():GetPosition()
					block.camera[0] = position.x
					block.camera[1] = position.y
					block.camera[2] = position.z
					block.max_distance = max_distance:Get()
					return block
				end,
			},
		},
		custom_declarations = [[
			#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

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

			struct mesh_row {
				uint64_t vertex_address;
				uint64_t index_address;
				uint64_t blas;
				uint triangle_count;
				uint vertex_stride;
				uint flags;
				uint pad;
			};

			struct segment {
				uint first_record;
				uint record_count;
				uint list_base;
				uint room;
				uint counter;
				uint parts_first;
				uint parts_count;
				uint pad;
			};

			struct part {
				uint mesh_row;
				uint material_row;
				uint record_flags;
				uint mask_flags;
			};

			layout(scalar, set = 0, binding = 0) buffer TLASInstances { tlas_instance tlas[]; };
			layout(scalar, set = 0, binding = 1) buffer InstanceData { instance_data data[]; };
			layout(scalar, set = 0, binding = 2) readonly buffer MeshRows { mesh_row meshes[]; };
			layout(scalar, set = 0, binding = 3) readonly buffer Segments { segment segments[]; };
			layout(scalar, set = 0, binding = 4) readonly buffer Parts { part parts[]; };
			layout(std430, set = 0, binding = 5) readonly buffer ScatterLists { mat4 lists[]; };
			layout(std430, set = 0, binding = 6) readonly buffer ScatterCounts { uint counts[]; };
		]],
		shader = [[
			void main() {
				uint r = gl_GlobalInvocationID.x;

				if (r >= uint(produce_data.record_count)) return;

				uint lo = 0u;
				uint hi = uint(produce_data.segment_count) - 1u;

				while (lo < hi) {
					uint mid = (lo + hi + 1u) / 2u;

					if (segments[mid].first_record <= r) lo = mid; else hi = mid - 1u;
				}

				segment s = segments[lo];
				uint row = uint(produce_data.region_base) + r;
				uint local = r - s.first_record;
				uint i = local / s.parts_count;
				uint j = local - i * s.parts_count;

				if (local >= s.record_count || i >= min(counts[uint(produce_data.counter_base) + s.counter], s.room)) {
					tlas[row].blas = 0ul;
					return;
				}

				mat4 world = lists[s.list_base + i];

				if (distance(world[3].xyz, produce_data.camera.xyz) > produce_data.max_distance) {
					tlas[row].blas = 0ul;
					return;
				}

				part p = parts[s.parts_first + j];
				uint mask = p.mask_flags & 0xFFu;

				for (uint k = 0u; k < 4u; k++) {
					tlas[row].m[k] = world[k][0];
					tlas[row].m[4u + k] = world[k][1];
					tlas[row].m[8u + k] = world[k][2];
				}

				tlas[row].custom_and_mask = row | (mask << 24u);
				tlas[row].flags = p.record_flags;
				tlas[row].blas = meshes[p.mesh_row].blas;
				data[row].mesh_row = p.mesh_row;
				data[row].material_row = p.material_row;
				data[row].flags = (p.mask_flags >> 8u) | 32u;
				data[row].mask_lod = mask;
			}
		]],
	}
	return pipeline
end

local signature
local definitions = {}
local MIN_RESERVED = 256
local RESERVE_MARGIN = 1.5

-- what the sources are: the prototypes that are in and the parts of their models, which decides how the structure's
-- rows are laid out. how many instances their lists have room for changes all the time, so the rows are reserved with
-- a margin and only laid out again when a list outgrows them
local function get_signature(sources)
	local signature = {}

	for i, source in ipairs(sources) do
		signature[i] = tostring(source.counter) .. ":" .. #source.parts .. (source.billboard_part and "b" or "")
	end

	return table.concat(signature, ",")
end

local function get_segments(sources)
	local list = {}

	for _, source in ipairs(sources) do
		list[#list + 1] = {
			parts = source.parts,
			base = source.model_base,
			room = source.model_room,
			counter = source.counter + 2,
		}

		if source.billboard_part then
			list[#list + 1] = {
				parts = {source.billboard_part},
				base = source.billboard_base,
				room = source.billboard_room,
				counter = source.counter + 3,
			}
		end
	end

	return list
end

-- the parts of the models, the segments and the rows of the structure for all of them
local function rebuild(segment_list)
	scatter_rt.rebuilds = (scatter_rt.rebuilds or 0) + 1
	local segments, parts = get_tables()
	render.GetDevice():WaitIdle()
	segments:Clear()
	parts:Clear()

	if range_base then instances.FreeRange(range_base, range_count, true) end

	local total = 0
	definitions = {}

	for _, source in ipairs(segment_list) do
		local first = parts.count
		local count = 0

		for _, part in ipairs(source.parts) do
			local row = meshes.Get(part.mesh)

			if row then
				local flags, mask = instances.GetMaterialFlags(part.material)
				local entry = parts:Get()[parts:Alloc()]
				entry.mesh_row = row
				entry.material_row = materials.GetID(part.material)
				entry.record_flags = instances.GetRecordFlags(flags)
				entry.mask_flags = mask + flags * 256
				count = count + 1
			end
		end

		if count > 0 then
			local reserved = math.max(math.ceil(source.room * count * RESERVE_MARGIN), MIN_RESERVED)
			reserved = math.ceil(reserved / count) * count
			local segment = segments:Get()[segments:Alloc()]
			segment.first_record = total
			segment.record_count = reserved
			segment.list_base = source.base
			segment.room = source.room
			segment.counter = source.counter
			segment.parts_first = first
			segment.parts_count = count
			definitions[segments.count] = {count = count, reserved = reserved, segment = segment}
			total = total + reserved
		end
	end

	segment_count = segments.count
	range_count = total
	range_base = total > 0 and instances.AllocRange(total) or nil
end

-- true when a list has outgrown what is reserved for it
local function refresh(segment_list)
	local index = 0

	for _, source in ipairs(segment_list) do
		local definition

		for i = index + 1, #definitions do
			local candidate = definitions[i]

			if candidate.segment.counter == source.counter and candidate.segment.parts_count == #source.parts then
				definition = candidate
				index = i

				break
			end
		end

		if not definition then return true end

		if source.room * definition.count > definition.reserved or (definition.reserved > MIN_RESERVED * 4 and source.room * definition.count * 4 < definition.reserved) then
			return true
		end

		definition.segment.list_base = source.base
		definition.segment.room = source.room
	end

	return false
end

local sources, list_buffer, counts_buffer

local function prepare()
	sources = nil

	if not enabled:Get() or not render.GetDevice().ray_tracing_supported then return end

	local version
	sources, list_buffer, counts_buffer, version = import("goluwa/render3d/scatter.lua").GetRTSources()

	if not sources then return end

	if version ~= built_version then
		built_version = version
		local segment_list = get_segments(sources)
		local new_signature = get_signature(sources)

		if new_signature ~= signature or refresh(segment_list) then
			signature = new_signature
			rebuild(segment_list)
		end
	end
end

local function produce(cmd)
	if not sources then return end

	if not range_base then return end

	local segments, parts = get_tables()
	local tlas_table, data_table = instances.GetTables()
	local pipe = get_pipeline()
	local slot = ((render.GetCurrentFrame() or 1) - 1) % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		local bound = bound_buffers[slot]
		local tlas_buffer, data_buffer, mesh_buffer = tlas_table:GetBuffer(), data_table:GetBuffer(), meshes.GetTable():GetBuffer()
		local segments_buffer, parts_buffer = segments:GetBuffer(), parts:GetBuffer()

		-- the descriptors only change when a buffer was replaced, a set that a frame in flight uses cannot be written
		if
			not bound or
			bound[1] ~= tlas_buffer or
			bound[2] ~= data_buffer or
			bound[3] ~= mesh_buffer or
			bound[4] ~= segments_buffer or
			bound[5] ~= parts_buffer or
			bound[6] ~= list_buffer or
			bound[7] ~= counts_buffer
		then
			bound_buffers[slot] = {tlas_buffer, data_buffer, mesh_buffer, segments_buffer, parts_buffer, list_buffer, counts_buffer}
			pipe:UpdateDescriptorSet("storage_buffer", slot, 0, 0, tlas_buffer, tlas_table:GetSize())
			pipe:UpdateDescriptorSet("storage_buffer", slot, 1, 0, data_buffer, data_table:GetSize())
			pipe:UpdateDescriptorSet("storage_buffer", slot, 2, 0, mesh_buffer, meshes.GetTable():GetSize())
			pipe:UpdateDescriptorSet("storage_buffer", slot, 3, 0, segments_buffer, segments:GetSize())
			pipe:UpdateDescriptorSet("storage_buffer", slot, 4, 0, parts_buffer, parts:GetSize())
			pipe:UpdateDescriptorSet("storage_buffer", slot, 5, 0, list_buffer, list_buffer.size)
			pipe:UpdateDescriptorSet("storage_buffer", slot, 6, 0, counts_buffer, counts_buffer.size)
		end

	pipe:UploadConstants()
	cmd:PipelineBarrier{
		srcStage = {"host", "compute", "acceleration_structure_build_khr"},
		dstStage = "compute",
		memoryBarrier = true,
	}
	pipe.pipeline:Dispatch(cmd, math.ceil(range_count / LOCAL_SIZE), 1, 1, slot, pipe.dynamic_offsets)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
end

instances.AddProducer("scatter", produce, prepare)
return scatter_rt
