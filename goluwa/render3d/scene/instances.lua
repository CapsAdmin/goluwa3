local ffi = require("ffi")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local lod = import("goluwa/render3d/lod.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local store = import("goluwa/render3d/scene/store.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local opacity_micromaps = import("goluwa/render3d/scene/opacity_micromaps.lua")
local deformed_copies, parts, tessellation
local accel = import("goluwa/render3d/scene/accel.lua")
local skinning = import("goluwa/render3d/skinning.lua")
local cluster_rt = import("goluwa/render3d/scene/cluster_rt.lua")
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
	float dynamic;
	float overlay;
}]])
instances.MASK_SOLID = 0x01
instances.MASK_SEE_THROUGH = 0x02
instances.MASK_DECAL = 0x04
instances.MASK_SELF = 0x08
instances.MASK_GI = 0x10
instances.MASK_GI_SOLID = 0x20
instances.MASK_GLASS = 0x40
instances.MASK_LIGHT_BODY = 0x80
instances.MASK_GI_BITS = 0x30
-- every instance kind but decals; the gi bits ride on decals too, so a mask that clears only MASK_DECAL still hits them
instances.MASK_SURFACES = bit.bor(
	instances.MASK_SOLID,
	instances.MASK_SEE_THROUGH,
	instances.MASK_SELF,
	instances.MASK_GLASS
)
instances.FLAG_DOUBLE_SIDED = 1
instances.FLAG_ALPHA_TEST = 2
instances.FLAG_EMISSIVE = 4
instances.FLAG_NO_OPAQUE = 8
instances.FLAG_REMOVED = 16
instances.FLAG_PRODUCED = 32
instances.FLAG_NO_SHADOW = 64
instances.FLAG_BILLBOARD = 128
instances.FLAG_BEFORE_BILLBOARD = 256
instances.FLAG_RT_LOD = 512
instances.FLAG_CLUSTERED = 1024
-- traced as a coarser mesh than the gbuffer draws it (streamed clusters traced as their fallback)
instances.FLAG_APPROXIMATE = 2048
local produced_ranges = {}
local UPDATE_LOCAL_SIZE = 64
local tlas_table, data_table, part_table, seen_table
local traced_tlas_buffer, traced_data_buffer
local traced_serial = 0
local added_serial = {}
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
instances.TLAS_INSTANCE_GLSL = [[
	struct tlas_instance {
		float m[12];
		uint custom_and_mask;
		uint flags;
		uint64_t blas;
	};
]]
instances.INSTANCE_DATA_GLSL = [[
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
]]
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
local rt_culled_lod_scale = pvars.Setup2{
	key = "r_rt_culled_lod_scale",
	default = 1,
	help = "scales the distances at which rays see the next level of detail for instances the camera did not see last frame (outside the view or occluded), above 1 they are traced coarser and bend sooner. they stay in the ray traced scene, only their detail drops. 1 is off",
}
pvars.EndGroup()
instances.SEEN_UNTESTED = 0x7FFFFFFF

local function mark_untested(self)
	for i = self.seen_filled or 0, self.capacity - 1 do
		self.ptr[i] = instances.SEEN_UNTESTED
	end

	self.seen_filled = self.capacity
end

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
				render.GetDevice().ray_tracing_supported and "acceleration_structure_build_input_read_only_khr" or nil,
			},
			staged = true,
		}
		data_table = store.CreateTable{name = "instance_data", ctype = InstanceData, capacity = 16384, staged = true}
		part_table = store.CreateTable{name = "instance_part", ctype = "uint32_t", capacity = 16384}
		seen_table = store.CreateTable{
			name = "instance_seen",
			ctype = "uint32_t",
			capacity = 16384,
			on_grow = mark_untested,
		}
		raster_table = store.CreateTable{name = "instance_raster", ctype = RasterData, capacity = 16384, staged = true}
	end

	return tlas_table, data_table
end

function instances.GetSeenTable()
	instances.GetTables()
	seen_table:Reserve(tlas_table.capacity)
	return seen_table
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

-- a table that grows after the tlas build gets a buffer the compute queue, already running, cannot wait for, so traces read the ones the tlas was built from
function instances.GetTracedBuffers()
	instances.GetTables()
	return traced_tlas_buffer or tlas_table:GetBuffer(),
	traced_data_buffer or data_table:GetBuffer()
end

-- an instance added since the last build is not in the traced buffers yet, so work reading them must skip it this frame
function instances.IsTraced(id)
	return added_serial[id] < traced_serial
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
	record.sbrtAndFlags = instances.GetRecordFlags(flags)
	data.flags = bit.band(data.flags, instances.FLAG_REMOVED) + flags
	data.mask_lod = bit.bor(bit.band(data.mask_lod, 0xFFFFFF00), mask)
end

function instances.Add(mesh_row, material_row, matrix, mask, flags, level, last, near, far)
	instances.GetTables()
	local id = tlas_table:Alloc()
	added_serial[id] = traced_serial
	instances.GetSeenTable():Get()[id] = instances.SEEN_UNTESTED
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

function instances.SetLOD(id, level, last, near, far)
	local data = data_table:Get()[id]
	data.mask_lod = bit.bor(bit.band(data.mask_lod, 0xFF), bit.lshift(level or 0, 8), bit.lshift(last or 0, 16))
	data.lod_near = near or 0
	data.lod_far = far or 0
	data_table:Touch(id)
	instances.version = instances.version + 1
end

function instances.Remove(id)
	if id < part_table.capacity then part_table:Get()[id] = 0 end

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
end

function instances.SetPart(id, part)
	part_table:Reserve(tlas_table.capacity)
	part_table:Get()[id] = part
end

function instances.IsLevelShown(id, camera_position)
	local data = data_table:Get()[id]
	local level = bit.band(bit.rshift(data.mask_lod, 8), 0xFF)
	local last = bit.band(bit.rshift(data.mask_lod, 16), 0xFF)
	local forced = lod.GetForcedLevel()

	if forced >= 0 then return level == math.min(forced, last) end

	local dx, dy, dz = camera_position.x - data.center_x,
	camera_position.y - data.center_y,
	camera_position.z - data.center_z
	local ratio = math.sqrt(dx * dx + dy * dy + dz * dz) / (
			math.max(data.radius, 0.001) * lod.GetScale() * rt_lod_scale:Get()
		)
	return (level == 0 or ratio >= data.lod_near) and (level == last or ratio < data.lod_far)
end

function instances.GetProducedAddresses()
	instances.GetTables()
	part_table:Reserve(tlas_table.capacity)
	return tlas_table:GetAddress(), data_table:GetAddress(), part_table:GetAddress()
end

function instances.SetBounds(id, x, y, z, radius)
	local data = data_table:Get()[id]
	data_table:Touch(id)
	data.center_x = x
	data.center_y = y
	data.center_z = z
	data.radius = radius
end

function instances.SetMaterial(id, material_row)
	local data = data_table:Get()[id]

	if data.material_row == material_row then return false end

	data.material_row = material_row
	data_table:Touch(id)
	instances.version = instances.version + 1
	return true
end

function instances.SetDynamic(id, dynamic)
	local data = data_table:Get()[id]

	if data.dynamic == dynamic then return end

	data.dynamic = dynamic
	data_table:Touch(id)
end

function instances.SetOverlay(id, slot)
	local data = data_table:Get()[id]

	if data.overlay == slot then return end

	data.overlay = slot
	data_table:Touch(id)
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
	part_table:Reserve(tlas_table.capacity)
	ffi.fill(part_table:Get() + base, n * 4)
	tlas_table:FreeRange(base, n, immediate)
	data_table.live = data_table.live - n
	instances.GetRasterTable()
	data_table.count = tlas_table.count
	instances.version = instances.version + 1
end

function instances.GetMaterialFlags(material)
	local flags = 0
	local see_through = material:GetAlphaTest() or material:IsSeeThrough()
	local mask = material:GetDecal() and
		instances.MASK_DECAL or
		see_through and
		instances.MASK_SEE_THROUGH or
		bit.bor(instances.MASK_SOLID, instances.MASK_GI_SOLID)
	mask = bit.bor(mask, instances.MASK_GI)

	if material:IsGlass() or material:GetMediumSlot() > 0 then
		mask = bit.bor(mask, instances.MASK_GLASS)
	end

	if material:GetIgnoredByLightOcclusion() then
		mask = bit.bor(mask, instances.MASK_LIGHT_BODY)
	end

	if material:GetDoubleSided() then
		flags = flags + instances.FLAG_DOUBLE_SIDED
	end

	if material:GetAlphaTest() then flags = flags + instances.FLAG_ALPHA_TEST end

	if
		material:GetAlphaTest() or
		material:IsTransparent() or
		material:GetMediumSlot() > 0 or
		material:GetRayShadowOpacity() < 1
	then
		flags = flags + instances.FLAG_NO_OPAQUE
	end

	return flags, mask
end

-- every geometry is built non opaque; forcing that on the instance would also override the opaque state of its opacity micromap
function instances.GetRecordFlags(flags)
	if bit.band(flags, instances.FLAG_NO_OPAQUE) ~= 0 then
		return accel.INSTANCE_FACING_CULL_DISABLE
	end

	return accel.INSTANCE_FACING_CULL_DISABLE + accel.INSTANCE_FORCE_OPAQUE
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
			storage_buffers = {
				{binding_index = 0},
				{binding_index = 1},
				{binding_index = 2},
				{binding_index = 4},
				{binding_index = 5},
				{binding_index = 6},
				{binding_index = 7},
				{binding_index = 8},
				{binding_index = 9},
			},
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
						{"frame", "int"},
						{"culled_scale", "float"},
						{"seen_valid", "int"},
						{"cluster_capacity", "int"},
						{"cluster_job_of", "uint64_t"},
						{"cluster_blas", "uint64_t"},
						{"tessellation_capacity", "int"},
						{"tessellation_job_of", "uint64_t"},
						{"tessellation_blas", "uint64_t"},
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
						block.frame = system.GetFrameNumber()
						block.culled_scale = rt_culled_lod_scale:Get()
						block.seen_valid = gpu_culling.GetDrawnCullFrame() >= block.frame - 1 and 1 or 0
						block.cluster_job_of, block.cluster_blas, block.cluster_capacity = cluster_rt.GetTLASOverride()
						tessellation = tessellation or import("goluwa/render3d/scene/tessellation.lua")
						block.tessellation_job_of, block.tessellation_blas, block.tessellation_capacity = tessellation.GetTLASOverride()
						return block
					end,
				},
			},
			custom_declarations = [[
				#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

				]] .. instances.TLAS_INSTANCE_GLSL .. instances.INSTANCE_DATA_GLSL .. [[

				struct mesh_row {
					uint64_t vertex_address;
					uint64_t index_address;
					uint64_t blas;
					uint64_t extras_address;
					uint triangle_count;
					uint vertex_stride;
					uint flags;
					uint pad;
				};

				layout(scalar, set = 0, binding = 0) buffer TLASInstances { tlas_instance tlas[]; };
				layout(scalar, set = 0, binding = 1) readonly buffer InstanceData { instance_data data[]; };
				layout(scalar, set = 0, binding = 2) readonly buffer MeshRows { mesh_row meshes[]; };
				layout(scalar, set = 0, binding = 4) readonly buffer PartOfInstance { uint part_of_instance[]; };
				]] .. parts.GLSL .. [[
				layout(scalar, set = 0, binding = 8) readonly buffer Parts { scene_part parts[]; };
				layout(scalar, set = 0, binding = 9) readonly buffer Seen { uint seen[]; };
				layout(buffer_reference, scalar) readonly buffer ClusterJobOf { uint j[]; };
				layout(buffer_reference, scalar) readonly buffer ClusterBLAS { uint64_t a[]; };
				]] .. deformed_copies.GetAssignGLSL(5, 6, 7) .. [[
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

					bool produced = (inst.flags & 32u) != 0u;

					if ((inst.flags & 16u) == 0u && mask != 0u) {
						uint part_id = part_of_instance[id];
						scene_part part = parts[part_id];
						blas = meshes[part_id != 0u ? part.trace_row : inst.mesh_row].blas;
						bool clustered = false;

						// a cluster row numbers its triangles by cluster, only its cluster blas may be traced with it
						if ((inst.flags & ]] .. instances.FLAG_CLUSTERED .. [[u) != 0u) blas = 0ul;

						if (update_data.cluster_job_of != 0ul && id < uint(update_data.cluster_capacity)) {
							uint job = ClusterJobOf(update_data.cluster_job_of).j[id];

							if (job != 0xFFFFFFFFu) {
								blas = ClusterBLAS(update_data.cluster_blas).a[job];
								clustered = true;
							}
						}

						if (update_data.tessellation_job_of != 0ul && id < uint(update_data.tessellation_capacity)) {
							uint job = ClusterJobOf(update_data.tessellation_job_of).j[id];

							if (job != 0xFFFFFFFFu) {
								blas = ClusterBLAS(update_data.tessellation_blas).a[job];
								clustered = true;
							}
						}
						float bend_distance;
						bool shown;

						if (produced) {
							shown = update_data.frame == int(floatBitsToUint(inst.lod.x));
							bend_distance = distance(update_data.camera.xyz, vec3(tlas[id].m[3], tlas[id].m[7], tlas[id].m[11]));
						} else {
							float distance_to = distance(update_data.camera.xyz, inst.bounds.xyz);
							float ratio = distance_to / (max(inst.bounds.w, 0.001) * update_data.lod_scale);
							uint stamp = seen[id];
							float unseen = update_data.seen_valid != 0 && stamp != 0x7FFFFFFFu && update_data.frame - int(stamp) > 1 ? update_data.culled_scale : 1.0;
							ratio *= unseen;

							if (update_data.lod_forced >= 0) {
								shown = level == min(uint(update_data.lod_forced), last);
							} else {
								shown = (level == 0u || ratio >= inst.lod.x) && (level == last || ratio < inst.lod.y);
							}

							shown = shown && distance_to - inst.bounds.w <= update_data.max_distance;
							bend_distance = (distance_to - inst.bounds.w) * unseen;
						}

						if (!shown) blas = 0ul;

						if (blas != 0ul && !clustered) {
							uint64_t copy = bend_assign(part.bend_pool, bend_distance, tlas[id].m);

							if (copy != 0ul) blas = copy;
						}
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
		deformed_copies = deformed_copies or import("goluwa/render3d/scene/deformed_copies.lua")
		parts = parts or import("goluwa/render3d/scene/parts.lua")
		store.FlushStaged(cmd)
		traced_tlas_buffer, traced_data_buffer = tlas_table:GetBuffer(), data_table:GetBuffer()
		traced_serial = traced_serial + 1
		meshes.Build(cmd, skinning.updated)
		cluster_rt.Build(cmd)
		tessellation = tessellation or import("goluwa/render3d/scene/tessellation.lua")
		tessellation.BuildRT(cmd)
		opacity_micromaps.Build(cmd)
		parts.Update()
		deformed_copies.Prepare(cmd)
		row_count = tlas_table.count
		data_table.count = row_count
		raster_table.count = row_count

		if row_count == 0 then
			accel.FlushRefits(cmd)
			return nil
		end

		local pipeline = get_update_pipeline()
		local slot = (
				(
					render.GetCurrentFrame() or
					1
				) - 1
			) % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		local bound = bound_buffers[slot]
		part_table:Reserve(tlas_table.capacity)
		local pools_buffer, pools_size, slots_buffer, slots_size, counters_buffer, counters_size = deformed_copies.GetBindings()
		local parts_table = parts.GetTable()
		local seen = instances.GetSeenTable()
		local tlas_buffer, data_buffer, mesh_buffer, pool_buffer, parts_buffer, seen_buffer = tlas_table:GetBuffer(),
		data_table:GetBuffer(),
		meshes.GetTable():GetBuffer(),
		part_table:GetBuffer(),
		parts_table:GetBuffer(),
		seen:GetBuffer()

		if
			not bound or
			bound[1] ~= tlas_buffer or
			bound[2] ~= data_buffer or
			bound[3] ~= mesh_buffer or
			bound[4] ~= pool_buffer or
			bound[5] ~= pools_buffer or
			bound[6] ~= slots_buffer or
			bound[7] ~= counters_buffer or
			bound[8] ~= parts_buffer or
			bound[9] ~= seen_buffer
		then
			bound_buffers[slot] = {
				tlas_buffer,
				data_buffer,
				mesh_buffer,
				pool_buffer,
				pools_buffer,
				slots_buffer,
				counters_buffer,
				parts_buffer,
				seen_buffer,
			}
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 0, 0, tlas_buffer, tlas_table:GetSize())
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 1, 0, data_buffer, data_table:GetSize())
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 2, 0, mesh_buffer, meshes.GetTable():GetSize())
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 4, 0, pool_buffer, part_table:GetSize())
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 5, 0, pools_buffer, pools_size)
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 6, 0, slots_buffer, slots_size)
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 7, 0, counters_buffer, counters_size)
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 8, 0, parts_buffer, parts_table:GetSize())
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 9, 0, seen_buffer, seen:GetSize())
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
		deformed_copies.Dispatch(cmd)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = "acceleration_structure_build_khr",
			memoryBarrier = true,
		}
		accel.FlushRefits(cmd)
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
