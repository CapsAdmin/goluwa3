local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local store = import("goluwa/render3d/scene/store.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local vegetation_bend = import("goluwa/render3d/scene/vegetation_bend.lua")
local scatter_rt = {}
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
	uint32_t bend_first;
	uint32_t bend_count;
	float bend_distance;
}]])
local BendSlot = ffi.typeof([[struct {
	float m[12];
	uint64_t blas;
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
local bend_triangles = pvars.Setup2{
	key = "r_scatter_rt_bend_triangles",
	default = 262144,
	integer = true,
	help = "triangles of bent copies each bending scatter mesh may have in the ray traced scene (a small mesh gets more copies than a large one), given to its instances within r_rt_bend_distance in no particular order. instances past the copies are traced at rest. copies are made as instances ask for them, and as many as asked are bent and refit every frame",
}
pvars.EndGroup()
local segments_table, parts_table, slots_table
local counters_buffer, readback_buffer, readback
local READBACK_RING = 4
local bending = {}
local BufferCopy = ffi.typeof("$[1]", vulkan.vk.VkBufferCopy)
local readback_copy = BufferCopy()
local pipeline
local built_version = -1
local bound_buffers = {}
local range_base, range_count = nil, 0
local segment_count = 0

local function get_tables()
	if not segments_table then
		segments_table = store.CreateTable{name = "scatter_rt_segments", ctype = Segment, capacity = 1024}
		parts_table = store.CreateTable{name = "scatter_rt_parts", ctype = Part, capacity = 4096}
		slots_table = store.CreateTable{name = "scatter_rt_bend_slots", ctype = BendSlot, capacity = 256}
	end

	return segments_table, parts_table, slots_table
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
			{binding_index = 7},
			{binding_index = 9},
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
				float dynamic;
				float overlay;
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
				uint bend_first;
				uint bend_count;
				float bend_distance;
			};

			struct bend_slot {
				float m[12];
				uint64_t blas;
			};

			layout(scalar, set = 0, binding = 0) buffer TLASInstances { tlas_instance tlas[]; };
			layout(scalar, set = 0, binding = 1) buffer InstanceData { instance_data data[]; };
			layout(scalar, set = 0, binding = 2) readonly buffer MeshRows { mesh_row meshes[]; };
			layout(scalar, set = 0, binding = 3) readonly buffer Segments { segment segments[]; };
			layout(scalar, set = 0, binding = 4) readonly buffer Parts { part parts[]; };
			layout(std430, set = 0, binding = 5) readonly buffer ScatterLists { mat4 lists[]; };
			layout(std430, set = 0, binding = 6) readonly buffer ScatterCounts { uint counts[]; };
			layout(scalar, set = 0, binding = 7) buffer BendSlots { bend_slot slots[]; };
			layout(std430, set = 0, binding = 9) buffer BendCounters { uint bend_counters[]; };
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

				// the first instances in range to ask get the bent copies, in whatever order the threads run
				if (p.bend_count > 0u && distance(world[3].xyz, produce_data.camera.xyz) <= p.bend_distance) {
					uint k = atomicAdd(bend_counters[s.parts_first + j], 1u);

					if (k < p.bend_count) {
						uint b = p.bend_first + k;

						for (uint c = 0u; c < 12u; c++) {
							slots[b].m[c] = tlas[row].m[c];
						}

						if (slots[b].blas != 0ul) tlas[row].blas = slots[b].blas;
					}
				}

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

local function get_signature(sources)
	local signature = {}

	for i, source in ipairs(sources) do
		signature[i] = tostring(source.counter) .. ":" .. #source.parts .. (
				source.billboard_part and
				"b" or
				""
			)
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

local function rebuild(segment_list)
	scatter_rt.rebuilds = (scatter_rt.rebuilds or 0) + 1
	local segments, parts, slots = get_tables()
	render.GetDevice():WaitIdle()
	segments:Clear()
	parts:Clear()
	slots:Clear()

	for _, entry in ipairs(bending) do
		for _, record in ipairs(entry.records) do
			vegetation_bend.ReleaseRecord(record)
		end
	end

	bending = {}

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
				local index = parts:Alloc()
				local entry = parts:Get()[index]
				entry.mesh_row = row
				entry.material_row = materials.GetID(part.material)
				entry.record_flags = instances.GetRecordFlags(flags)
				entry.mask_flags = mask + flags * 256
				entry.bend_first = 0
				entry.bend_count = 0
				entry.bend_distance = 0
				count = count + 1

				if part.material:HasVertexAnimation() and part.polygon then
					local mesh = meshes.GetRecord(row)
					local copies = math.max(math.floor(bend_triangles:Get() / mesh.triangle_count), 1)
					local first_slot = slots:AllocRange(copies)
					entry.bend_first = first_slot

					for k = 0, copies - 1 do
						local slot = slots:Get()[first_slot + k]
						ffi.fill(slot.m, ffi.sizeof(slot.m))
						slot.m[0], slot.m[5], slot.m[10] = 1, 1, 1
						slot.blas = 0
					end

					bending[#bending + 1] = {
						index = index,
						part = part,
						row = row,
						mesh = mesh,
						first = entry.bend_first,
						copies = copies,
						records = {},
					}
				end
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

local function refresh(segment_list)
	local index = 0

	for _, source in ipairs(segment_list) do
		local definition

		for i = index + 1, #definitions do
			local candidate = definitions[i]

			if
				candidate.segment.counter == source.counter and
				candidate.segment.parts_count == #source.parts
			then
				definition = candidate
				index = i

				break
			end
		end

		if not definition then return true end

		if
			source.room * definition.count > definition.reserved or
			(
				definition.reserved > MIN_RESERVED * 4 and
				source.room * definition.count * 4 < definition.reserved
			)
		then
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

	if not enabled:Get() or not render.GetDevice().ray_tracing_supported then
		return
	end

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

	local segments, parts, slots = get_tables()
	local tlas_table, data_table = instances.GetTables()
	local animating = vegetation_bend.IsEnabled()
	local part_rows = parts:Get()
	local frame = system.GetFrameNumber()

	if not counters_buffer or counters_buffer:GetSize() < parts.capacity * 4 then
		if counters_buffer then
			counters_buffer:Remove()
			readback_buffer:Remove()
		end

		counters_buffer = render.CreateBuffer{
			byte_size = parts.capacity * 4,
			buffer_usage = {"storage_buffer", "transfer_dst", "transfer_src"},
			memory_property = {"device_local"},
			label = "scatter_rt_bend_counters",
		}
		readback_buffer = render.CreateBuffer{
			byte_size = parts.capacity * 4 * READBACK_RING,
			buffer_usage = {"transfer_dst"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scatter_rt_bend_readback",
		}
		readback = ffi.cast("uint32_t *", readback_buffer:Map())
		ffi.fill(readback, parts.capacity * 4 * READBACK_RING)
	end

	-- how many instances asked for a copy a few frames ago (the oldest copy in the ring, which the gpu has finished): only that many and a few more are bent and refit
	local asked = readback + ((frame + 1) % READBACK_RING) * parts.capacity

	for _, entry in ipairs(bending) do
		local range = animating and
			vegetation_bend.GetRange(entry.part.material, entry.part.polygon) or
			0
		local wanted = asked[entry.index]
		entry.used = range > 0 and
			math.min(entry.copies, wanted > 0 and wanted + 2 + math.floor(wanted / 4) or 1) or
			0

		for k = #entry.records + 1, entry.used do
			entry.records[k] = vegetation_bend.NewRecord(entry.mesh)
		end

		part_rows[entry.index].bend_count = entry.used
		part_rows[entry.index].bend_distance = range
	end

	local pipe = get_pipeline()
	local slot = (
			(
				render.GetCurrentFrame() or
				1
			) - 1
		) % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
	local bound = bound_buffers[slot]
	local tlas_buffer, data_buffer, mesh_buffer = tlas_table:GetBuffer(), data_table:GetBuffer(), meshes.GetTable():GetBuffer()
	local segments_buffer, parts_buffer, slots_buffer = segments:GetBuffer(), parts:GetBuffer(), slots:GetBuffer()

	if
		not bound or
		bound[1] ~= tlas_buffer or
		bound[2] ~= data_buffer or
		bound[3] ~= mesh_buffer or
		bound[4] ~= segments_buffer or
		bound[5] ~= parts_buffer or
		bound[6] ~= list_buffer or
		bound[7] ~= counts_buffer or
		bound[8] ~= slots_buffer or
		bound[9] ~= counters_buffer
	then
		bound_buffers[slot] = {
			tlas_buffer,
			data_buffer,
			mesh_buffer,
			segments_buffer,
			parts_buffer,
			list_buffer,
			counts_buffer,
			slots_buffer,
			counters_buffer,
		}
		pipe:UpdateDescriptorSet("storage_buffer", slot, 0, 0, tlas_buffer, tlas_table:GetSize())
		pipe:UpdateDescriptorSet("storage_buffer", slot, 1, 0, data_buffer, data_table:GetSize())
		pipe:UpdateDescriptorSet("storage_buffer", slot, 2, 0, mesh_buffer, meshes.GetTable():GetSize())
		pipe:UpdateDescriptorSet("storage_buffer", slot, 3, 0, segments_buffer, segments:GetSize())
		pipe:UpdateDescriptorSet("storage_buffer", slot, 4, 0, parts_buffer, parts:GetSize())
		pipe:UpdateDescriptorSet("storage_buffer", slot, 5, 0, list_buffer, list_buffer.size)
		pipe:UpdateDescriptorSet("storage_buffer", slot, 6, 0, counts_buffer, counts_buffer.size)
		pipe:UpdateDescriptorSet("storage_buffer", slot, 7, 0, slots_buffer, slots:GetSize())
		pipe:UpdateDescriptorSet("storage_buffer", slot, 9, 0, counters_buffer, counters_buffer:GetSize())
	end

	pipe:UploadConstants()
	cmd:FillBuffer(counters_buffer, 0, counters_buffer:GetSize(), 0)
	cmd:PipelineBarrier{
		srcStage = {"host", "transfer", "compute", "acceleration_structure_build_khr"},
		dstStage = "compute",
		memoryBarrier = true,
	}
	pipe.pipeline:Dispatch(cmd, math.ceil(range_count / LOCAL_SIZE), 1, 1, slot, pipe.dynamic_offsets)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = {"compute", "transfer"}, memoryBarrier = true}

	if not bending[1] then return end

	readback_copy[0].srcOffset = 0
	readback_copy[0].dstOffset = (frame % READBACK_RING) * parts.capacity * 4
	readback_copy[0].size = parts.capacity * 4
	cmd:CopyBuffer(counters_buffer, readback_buffer, readback_copy, 1)
	local mesh_rows = meshes.GetTable():Get()
	local slots_address = slots:GetAddress()

	for _, entry in ipairs(bending) do
		for k = 1, entry.used do
			vegetation_bend.Queue(
				entry.records[k],
				mesh_rows[entry.row].vertex_address,
				slots_address + (entry.first + k - 1) * ffi.sizeof(BendSlot),
				entry.part.material,
				entry.part.polygon
			)
		end
	end

	vegetation_bend.Dispatch(cmd)
	local slot_rows = slots:Get()

	for _, entry in ipairs(bending) do
		for k = 1, entry.used do
			slot_rows[entry.first + k - 1].blas = entry.records[k].blas_record.address
		end
	end
end

function scatter_rt.GetBendDemand()
	local out = {}
	local frame = system.GetFrameNumber()

	for _, entry in ipairs(bending) do
		out[#out + 1] = {
			mesh = entry.mesh.triangle_count,
			asked = readback and
				readback[(
					(
						frame + 1
					) % READBACK_RING
				) * parts_table.capacity + entry.index] or
				0,
			used = entry.used or 0,
			copies = entry.copies,
			range = parts_table:Get()[entry.index].bend_distance,
		}
	end

	return out
end

instances.AddProducer("scatter", produce, prepare)
return scatter_rt
