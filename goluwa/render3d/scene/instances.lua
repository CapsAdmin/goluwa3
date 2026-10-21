local ffi = require("ffi")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local lod = import("goluwa/render3d/lod.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local store = import("goluwa/render3d/scene/store.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
local skinning = import("goluwa/render3d/skinning.lua")
local instances = {}
local TLASInstance = vulkan.vk.VkAccelerationStructureInstanceKHR
local InstanceData = ffi.typeof([[struct {
	uint32_t mesh_row;
	uint32_t material_row;
	uint32_t flags;
	uint32_t mask_lod;
	float center_x;
	float center_y;
	float center_z;
	float radius;
	float lod_near;
	float lod_far;
	float pad0;
	float pad1;
}]])
instances.MASK_SOLID = 0x01
instances.MASK_SEE_THROUGH = 0x02
instances.FLAG_DOUBLE_SIDED = 1
instances.FLAG_ALPHA_TEST = 2
instances.FLAG_EMISSIVE = 4
instances.FLAG_NO_OPAQUE = 8
instances.FLAG_REMOVED = 16
instances.FLAG_PRODUCED = 32
instances.FLAG_NO_SHADOW = 64
instances.FLAG_BILLBOARD = 128
instances.FLAG_BEFORE_BILLBOARD = 256
local produced_ranges = {}
local UPDATE_LOCAL_SIZE = 64
local tlas_table, data_table
local RasterData = ffi.typeof([[struct {
	float min_x;
	float min_y;
	float min_z;
	float max_x;
	float max_y;
	float max_z;
	float cull_distance;
	uint32_t flags;
	float prev[12];
	float local_size_x;
	float local_size_y;
	float local_size_z;
	float thickness;
}]])
instances.RASTER_DATA_GLSL = [[
	struct raster_data {
		vec3 box_min;
		vec3 box_max;
		float cull_distance;
		uint flags;
		float prev[12];
		vec3 local_size;
		float thickness;
	};
]]
instances.RASTER_DRAW = 1
instances.RASTER_OCCLUSION = 2
instances.RASTER_HEIGHT_MAP = 4
instances.RASTER_DOUBLE_SIDED = 8
instances.RASTER_SHADOW = 16
instances.RASTER_TRANSLUCENT = 32
local raster_table
instances.version = 0
pvars.StartGroup("Rendering", "Ray tracing", {store = false})
local rt_distance = pvars.Setup2{
	key = "r_rt_distance",
	default = 20000,
	min = 0,
	help = "how far from the camera instances are in the ray traced scene, in meters, past it they are hidden from rays",
}
local rt_lod_scale = pvars.Setup2{
	key = "r_rt_lod_scale",
	default = 1,
	min = 0.01,
	help = "scales the distances at which rays see the next level of detail, above 1 the levels switch farther away than they do for the camera, below 1 sooner. every level of a model is in the ray traced scene, billboards included",
}
pvars.EndGroup()

function instances.GetTables()
	if not tlas_table then
		tlas_table = store.CreateTable{
			name = "tlas_instances",
			ctype = TLASInstance,
			capacity = 16384,
			usage = {
				"shader_device_address",
				"storage_buffer",
				"transfer_src",
				"acceleration_structure_build_input_read_only_khr",
			},
			staged = true,
		}
		data_table = store.CreateTable{name = "instance_data", ctype = InstanceData, capacity = 16384, staged = true}
		raster_table = store.CreateTable{name = "instance_raster", ctype = RasterData, capacity = 16384, staged = true}
	end

	return tlas_table, data_table
end

function instances.GetRasterTable()
	instances.GetTables()
	raster_table:Reserve(tlas_table.capacity)
	raster_table.count = tlas_table.count
	return raster_table
end

function instances.SetRaster(id, aabb, cull_distance, flags, prev, local_aabb, thickness)
	local row = instances.GetRasterTable():Get()[id]
	raster_table:Touch(id)

	if aabb then
		row.min_x, row.min_y, row.min_z = aabb.min_x, aabb.min_y, aabb.min_z
		row.max_x, row.max_y, row.max_z = aabb.max_x, aabb.max_y, aabb.max_z
	end

	row.cull_distance = cull_distance
	row.flags = flags
	row.thickness = thickness

	if local_aabb then
		row.local_size_x = local_aabb.max_x - local_aabb.min_x
		row.local_size_y = local_aabb.max_y - local_aabb.min_y
		row.local_size_z = local_aabb.max_z - local_aabb.min_z
	end

	instances.SetPrevMatrix(id, prev)
end

function instances.SetRasterBox(id, aabb)
	local row = instances.GetRasterTable():Get()[id]
	raster_table:Touch(id)
	row.min_x, row.min_y, row.min_z = aabb.min_x, aabb.min_y, aabb.min_z
	row.max_x, row.max_y, row.max_z = aabb.max_x, aabb.max_y, aabb.max_z
end

function instances.SetPrevMatrix(id, m)
	local t = instances.GetRasterTable():Get()[id].prev
	raster_table:Touch(id)
	t[0], t[1], t[2], t[3] = m.m00, m.m10, m.m20, m.m30
	t[4], t[5], t[6], t[7] = m.m01, m.m11, m.m21, m.m31
	t[8], t[9], t[10], t[11] = m.m02, m.m12, m.m22, m.m32
end

function instances.GetDataTable()
	return select(2, instances.GetTables())
end

local function write_matrix(record, m)
	local t = record.transform.matrix
	t[0][0], t[0][1], t[0][2], t[0][3] = m.m00, m.m10, m.m20, m.m30
	t[1][0], t[1][1], t[1][2], t[1][3] = m.m01, m.m11, m.m21, m.m31
	t[2][0], t[2][1], t[2][2], t[2][3] = m.m02, m.m12, m.m22, m.m32
end

local function write_flags(record, data, mask, flags)
	record.sbrtAndFlags = accel.INSTANCE_FACING_CULL_DISABLE + (
			bit.band(flags, instances.FLAG_NO_OPAQUE) ~= 0 and
			accel.INSTANCE_FORCE_NO_OPAQUE or
			accel.INSTANCE_FORCE_OPAQUE
		)
	data.flags = bit.band(data.flags, instances.FLAG_REMOVED) + flags
	data.mask_lod = bit.bor(bit.band(data.mask_lod, 0xFFFFFF00), mask)
end

function instances.Add(mesh_row, material_row, matrix, mask, flags, level, last, near, far)
	instances.GetTables()
	local id = tlas_table:Alloc()
	data_table:Reserve(tlas_table.capacity)
	data_table.count = tlas_table.count
	data_table.live = data_table.live + 1
	instances.GetRasterTable():Get()[id].flags = 0
	raster_table:Touch(id)
	tlas_table:Touch(id)
	data_table:Touch(id)
	local record = tlas_table:Get()[id]
	local data = data_table:Get()[id]
	record.customAndMask = id
	record.accelerationStructureReference = 0
	data.mesh_row = mesh_row
	data.material_row = material_row
	data.flags = 0
	data.mask_lod = bit.bor(bit.lshift(level or 0, 8), bit.lshift(last or 0, 16))
	data.lod_near = near or 0
	data.lod_far = far or 0
	data.radius = 0
	write_matrix(record, matrix)
	write_flags(record, data, mask, flags)
	instances.version = instances.version + 1
	return id
end

function instances.Remove(id)
	local record = tlas_table:Get()[id]
	record.accelerationStructureReference = 0
	local data = data_table:Get()[id]
	data.flags = bit.bor(data.flags, instances.FLAG_REMOVED)
	tlas_table:Touch(id)
	data_table:Touch(id)
	tlas_table:Free(id)
	data_table.live = data_table.live - 1
	instances.version = instances.version + 1
end

function instances.SetMatrix(id, matrix)
	write_matrix(tlas_table:Get()[id], matrix)
	tlas_table:Touch(id)
	instances.version = instances.version + 1
end

function instances.SetBounds(id, x, y, z, radius)
	local data = data_table:Get()[id]
	data_table:Touch(id)
	data.center_x = x
	data.center_y = y
	data.center_z = z
	data.radius = radius
end

function instances.SetMesh(id, mesh_row)
	data_table:Get()[id].mesh_row = mesh_row
	data_table:Touch(id)
	instances.version = instances.version + 1
end

function instances.SetMaterial(id, material_row)
	local data = data_table:Get()[id]

	if data.material_row == material_row then return false end

	data.material_row = material_row
	data_table:Touch(id)
	instances.version = instances.version + 1
	return true
end

function instances.SetMask(id, mask, flags)
	local record = tlas_table:Get()[id]
	local data = data_table:Get()[id]

	if
		bit.band(data.mask_lod, 0xFF) == mask and
		bit.band(data.flags, bit.bnot(instances.FLAG_REMOVED)) == flags
	then
		return false
	end

	write_flags(record, data, mask, flags)
	tlas_table:Touch(id)
	data_table:Touch(id)
	instances.version = instances.version + 1
	return true
end

function instances.AllocRange(n)
	instances.GetTables()
	local base = tlas_table:AllocRange(n)
	produced_ranges[base] = n
	data_table:Reserve(tlas_table.capacity)
	instances.GetRasterTable()
	data_table.count = tlas_table.count
	data_table.live = data_table.live + n
	instances.version = instances.version + 1
	return base
end

function instances.FreeRange(base, n, immediate)
	produced_ranges[base] = nil
	tlas_table:FreeRange(base, n, immediate)
	data_table.live = data_table.live - n
	instances.GetRasterTable()
	data_table.count = tlas_table.count
	instances.version = instances.version + 1
end

function instances.GetMaterialFlags(material)
	local flags = 0
	local see_through = material:GetAlphaTest() or material:IsSeeThrough()

	if material:GetDoubleSided() then flags = flags + instances.FLAG_DOUBLE_SIDED end

	if material:GetAlphaTest() then flags = flags + instances.FLAG_ALPHA_TEST end

	if
		material:GetAlphaTest() or
		material:IsTransparent() or
		material:GetRayShadowOpacity() < 1
	then
		flags = flags + instances.FLAG_NO_OPAQUE
	end

	return flags, see_through and instances.MASK_SEE_THROUGH or instances.MASK_SOLID
end

function instances.GetRecordFlags(flags)
	return accel.INSTANCE_FACING_CULL_DISABLE + (
			bit.band(flags, instances.FLAG_NO_OPAQUE) ~= 0 and
			accel.INSTANCE_FORCE_NO_OPAQUE or
			accel.INSTANCE_FORCE_OPAQUE
		)
end

local producers = {}
local preparers = {}

function instances.AddProducer(name, produce, prepare)
	producers[name] = produce
	preparers[name] = prepare
end

function instances.GetVisualRows()
	local bases = {}

	for base in pairs(produced_ranges) do
		bases[#bases + 1] = base
	end

	table.sort(bases)
	local runs = {}
	local first = 0

	for _, base in ipairs(bases) do
		if base > first then
			runs[#runs + 1] = first
			runs[#runs + 1] = base - first
		end

		first = base + produced_ranges[base]
	end

	local top = tlas_table and tlas_table.count or 0

	if top > first then
		runs[#runs + 1] = first
		runs[#runs + 1] = top - first
	end

	return runs
end

function instances.GetCount()
	return tlas_table and tlas_table.live or 0
end

function instances.IsAlive()
	return tlas_table ~= nil and tlas_table.buffer:IsValid()
end

do
	local update_pipeline
	local row_count = 0
	local spans = {}
	local bound_buffers = {}
	local create_update_pipeline

	local function get_update_pipeline()
		if update_pipeline then return update_pipeline end

		return create_update_pipeline()
	end

	function create_update_pipeline()
		update_pipeline = EasyPipeline.Compute{
			name = "scene_instance_update",
			DescriptorSetCount = math.max(render.GetSwapchainImageCount() or 1, 1),
			LocalSize = {x = UPDATE_LOCAL_SIZE, y = 1, z = 1},
			storage_buffers = {{binding_index = 0}, {binding_index = 1}, {binding_index = 2}},
			uniform_buffers = {
				{
					name = "update_data",
					binding_index = 3,
					block = {
						{"camera", "vec4"},
						{"count", "int"},
						{"lod_scale", "float"},
						{"lod_forced", "int"},
						{"max_distance", "float"},
					},
					write = function(self, block)
						local position = import("goluwa/render3d/render3d.lua").GetCamera():GetPosition()
						block.camera[0] = position.x
						block.camera[1] = position.y
						block.camera[2] = position.z
						block.count = row_count
						block.lod_scale = lod.GetScale() * rt_lod_scale:Get()
						block.lod_forced = lod.GetForcedLevel()
						block.max_distance = rt_distance:Get()
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

				layout(scalar, set = 0, binding = 0) buffer TLASInstances { tlas_instance tlas[]; };
				layout(scalar, set = 0, binding = 1) readonly buffer InstanceData { instance_data data[]; };
				layout(scalar, set = 0, binding = 2) readonly buffer MeshRows { mesh_row meshes[]; };
			]],
			shader = [[
				void main() {
					uint id = gl_GlobalInvocationID.x;

					if (id >= uint(update_data.count)) return;

					instance_data inst = data[id];
					uint mask = inst.mask_lod & 0xFFu;
					uint level = (inst.mask_lod >> 8u) & 0xFFu;
					uint last = (inst.mask_lod >> 16u) & 0xFFu;
					uint64_t blas = 0ul;

					if ((inst.flags & 32u) != 0u) return;

					if ((inst.flags & 16u) == 0u && mask != 0u) {
						blas = meshes[inst.mesh_row].blas;
						float distance_to = distance(update_data.camera.xyz, inst.bounds.xyz);
						float ratio = distance_to / (max(inst.bounds.w, 0.001) * update_data.lod_scale);
						bool shown;

						if (update_data.lod_forced >= 0) {
							shown = level == min(uint(update_data.lod_forced), last);
						} else {
							shown = (level == 0u || ratio >= inst.lod.x) && (level == last || ratio < inst.lod.y);
						}

						if (!shown || distance_to - inst.bounds.w > update_data.max_distance) blas = 0ul;
					}

					tlas[id].blas = blas;
					tlas[id].custom_and_mask = id | (blas != 0ul ? mask << 24u : 0u);
				}
			]],
		}
		return update_pipeline
	end

	function instances.Build(cmd)
		instances.GetTables()

		for _, prepare in pairs(preparers) do
			prepare()
		end

		store.FlushStaged(cmd)
		meshes.Build(cmd, skinning.updated)

		for _, produce in pairs(producers) do
			produce(cmd)
		end

		row_count = tlas_table.count
		data_table.count = row_count
		raster_table.count = row_count

		if row_count == 0 then return nil end

		local pipeline = get_update_pipeline()
		local slot = (
				(
					render.GetCurrentFrame() or
					1
				) - 1
			) % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		local bound = bound_buffers[slot]
		local tlas_buffer, data_buffer, mesh_buffer = tlas_table:GetBuffer(), data_table:GetBuffer(), meshes.GetTable():GetBuffer()

		if
			not bound or
			bound[1] ~= tlas_buffer or
			bound[2] ~= data_buffer or
			bound[3] ~= mesh_buffer
		then
			bound_buffers[slot] = {tlas_buffer, data_buffer, mesh_buffer}
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 0, 0, tlas_buffer, tlas_table:GetSize())
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 1, 0, data_buffer, data_table:GetSize())
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 2, 0, mesh_buffer, meshes.GetTable():GetSize())
		end

		pipeline:UploadConstants()
		cmd:PipelineBarrier{
			srcStage = {"host", "compute", "acceleration_structure_build_khr"},
			dstStage = "compute",
			memoryBarrier = true,
		}
		pipeline.pipeline:Dispatch(
			cmd,
			math.ceil(row_count / UPDATE_LOCAL_SIZE),
			1,
			1,
			slot,
			pipeline.dynamic_offsets
		)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = "acceleration_structure_build_khr",
			memoryBarrier = true,
		}
		local instance_buffer, instance_count = tlas_buffer, row_count
		local used, span_count = tlas_table:GetSpans(spans)

		if row_count - used >= 4096 and used * 4 <= row_count * 3 then
			instance_buffer = accel.CompactInstances(cmd, tlas_buffer, spans, span_count, used)
			instance_count = used
		end

		instances.tlas = accel.BuildTLAS(cmd, instance_buffer, instance_count)
		return instances.tlas
	end
end

return instances
