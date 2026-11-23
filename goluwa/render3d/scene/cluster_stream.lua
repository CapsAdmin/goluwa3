local ffi = require("ffi")
local bit = require("bit")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local threads = import("goluwa/bindings/threads.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local draw = import("goluwa/render3d/scene/draw.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local shader_features = import("goluwa/render3d/shader_features.lua")
local vertex_math = import("goluwa/render3d/vertex_math.lua")
local OffsetAllocator = import("goluwa/render3d/offset_allocator.lua")
local format = import("goluwa/render3d/cluster_stream/format.lua")
local band, bor = bit.band, bit.bor
local sqrt, max, min, floor = math.sqrt, math.max, math.min, math.floor
local cluster_stream = {}
cluster_stream.name = "gbuffer_cluster_stream"
local CLUSTER_VERTICES = 128 * 3
local CANDIDATE_BYTES = 48
local RING = 4
local PAGE_UNIT = 16
local NONE = 0xFFFFFFFF
local CPU_MARGIN = 0.75
local EVICT_AFTER_FRAMES = 30
local LOADER_THREADS = 4
local LOADS_PER_JOB = 16
local UPDATE_BUFFER_LIMIT = 65536
local READBACK_BYTES = 64
-- draws: one per cull mode, mirrored instances (negative determinant) wind the other way
local SET_FRONT = 0
local SET_DOUBLE_SIDED = 1
local SET_MIRRORED = 2
local SET_COUNT = 3
local readback_copy = ffi.typeof("$[1]", import("goluwa/render/vulkan/internal/vulkan.lua").vk.VkBufferCopy)()
pvars.StartGroup("Rendering", "Cluster streaming", {store = false})
local enabled = pvars.Setup2{
	key = "r_cluster_stream",
	default = true,
	help = "draw meshes baked into cluster stream files from their streamed cluster hierarchy instead of their fallback mesh",
}
local pool_megabytes = pvars.Setup2{
	key = "r_cluster_stream_pool_megabytes",
	default = 4096,
	help = "size of the gpu pool streamed cluster groups live in, set before loading",
}
local loads_per_frame = pvars.Setup2{
	key = "r_cluster_stream_loads",
	default = 512,
	help = "cluster groups requested from disk per frame at most",
}
local fallback_ratio = pvars.Setup2{
	key = "r_cluster_stream_fallback_ratio",
	default = format.FALLBACK_RATIO,
	help = "triangles of the mesh rays and shadow maps see for streamed meshes, as a fraction of the source mesh, set before loading",
}
local max_visible_clusters = pvars.Setup2{
	key = "r_cluster_stream_max_clusters",
	default = 2 ^ 18,
	help = "clusters drawn per frame at most, set before loading",
}
pvars.EndGroup()
pvars.StartGroup("Rendering", "Cluster streaming")
local cache_root = pvars.Setup2{
	key = "r_cluster_stream_cache",
	default = "storage/cache/cluster_stream/",
	help = "directory baked cluster stream files are written to and read from, one folder per scene",
}
pvars.EndGroup()

function cluster_stream.GetCacheDirectory(name)
	local root = cache_root:Get()

	if not root:ends_with("/") then root = root .. "/" end

	return root .. name .. "/"
end

local stats = {
	geometries = 0,
	rows = 0,
	candidates = 0,
	resident_groups = 0,
	resident_bytes = 0,
	loading = 0,
	requested = 0,
	loaded = 0,
	evicted = 0,
	traverse_ms = 0,
}
cluster_stream.stats = stats
local state = {
	geometries = {},
	rows = {},
	row_serial = 0,
	residency_count = 0,
	residency_version = 0,
	pending_residency = {},
	pending_free = {},
	resident_list = {},
	jobs = {},
	frame = 0,
	ready = false,
}

function cluster_stream.IsAvailable()
	if state.available == nil then
		local features = render.GetPhysicalDevice():GetFeatures()
		state.available = features.multiDrawIndirect == 1 and features.drawIndirectFirstInstance == 1
	end

	return state.available and enabled:Get()
end

local function create_device_buffer(byte_size, usage, label)
	return render.CreateBuffer{
		byte_size = byte_size,
		buffer_usage = usage,
		memory_property = {"device_local"},
		label = label,
	}
end

local function create_host_buffer(byte_size, usage, label)
	local buffer = render.CreateBuffer{byte_size = byte_size, buffer_usage = usage, label = label}
	return buffer, buffer:Map()
end

local function ensure_pool()
	if state.pool then return end

	local bytes = pool_megabytes:Get() * 1024 * 1024
	state.pool, state.pool_ptr = create_host_buffer(bytes, {"storage_buffer", "shader_device_address"}, "cluster_stream_pool")
	state.pool_address = state.pool:GetDeviceAddress()
	state.allocator = OffsetAllocator.New(bytes / PAGE_UNIT)
	state.pool_units = bytes / PAGE_UNIT
	state.used_units = 0
	state.max_visible = max_visible_clusters:Get()
	local usage = {"storage_buffer", "indirect_buffer", "shader_device_address", "transfer_dst"}
	state.state_buffer = create_device_buffer(
		64,
		{
			"storage_buffer",
			"indirect_buffer",
			"shader_device_address",
			"transfer_dst",
			"transfer_src",
		},
		"cluster_stream_state"
	)
	state.state_address = state.state_buffer:GetDeviceAddress()
	state.visible_buffer = create_device_buffer(state.max_visible * SET_COUNT * 8, usage, "cluster_stream_visible")
	state.visible_address = state.visible_buffer:GetDeviceAddress()
	state.readback_buffer = render.CreateBuffer{
		byte_size = READBACK_BYTES * RING,
		buffer_usage = {"transfer_dst"},
		memory_property = {"host_visible", "host_coherent"},
		label = "cluster_stream_readback",
	}
	state.readback_ptr = ffi.cast("uint8_t *", state.readback_buffer:Map())
	ffi.fill(state.readback_ptr, READBACK_BYTES * RING)
	state.error_scale = 1
end

local function ensure_residency_capacity(count)
	if state.residency_buffer and count <= state.residency_capacity then return end

	local capacity = max(65536, 2 ^ math.ceil(math.log(count) / math.log(2)))

	if state.residency_buffer then
		render.GetDevice():WaitIdle()
		state.residency_buffer:Remove()
	end

	state.residency_buffer = create_device_buffer(
		capacity * 4,
		{"storage_buffer", "shader_device_address", "transfer_dst"},
		"cluster_stream_residency"
	)
	state.residency_address = state.residency_buffer:GetDeviceAddress()
	state.residency_capacity = capacity
	state.residency_full_upload = true
end

local function ensure_geometry_capacity(count)
	if state.geometry_buffer and count <= state.geometry_capacity then return end

	local capacity = max(1024, 2 ^ math.ceil(math.log(count) / math.log(2)))

	if state.geometry_buffer then
		render.GetDevice():WaitIdle()
		state.geometry_buffer:Remove()
	end

	state.geometry_buffer = create_device_buffer(
		capacity * 32,
		{"storage_buffer", "shader_device_address", "transfer_dst"},
		"cluster_stream_geometries"
	)
	state.geometry_address = state.geometry_buffer:GetDeviceAddress()
	state.geometry_capacity = capacity
	state.geometry_full_upload = true
end

local GeometryRecord = ffi.typeof([[struct {
	float pos_min[3];
	float pos_step;
	float uv_step;
	uint32_t residency_base;
	uint32_t pad[2];
}]])
local GeometryRecordArray = ffi.typeof("$[?]", GeometryRecord)
local double_array_t = ffi.typeof("double[?]")
local int32_array_t = ffi.typeof("int32_t[?]")
local uint32_array_t = ffi.typeof("uint32_t[?]")
local uint8_array_t = ffi.typeof("uint8_t[?]")

local function read_file_range(path, offset, size)
	local file = assert(io.open(path, "rb"))
	file:seek("set", offset)
	local data = file:read(size)
	file:close()
	assert(data and #data == size, "short read from " .. path)
	return data
end

-- the node tree is the groups split into spatial leaves of up to 8; a node's sphere bounds its groups' spheres and
-- its error is their largest, so a node whose error projects under the budget has no group whose members draw
local function build_nodes(geometry)
	local cx, cy, cz, r, err = geometry.cx, geometry.cy, geometry.cz, geometry.r, geometry.err
	local roots = {}
	local n = 0

	for g = 0, geometry.group_count - 1 do
		if err[g] >= format.NO_ERROR * 0.5 then roots[#roots + 1] = g else n = n + 1 end
	end

	geometry.root_count = #roots
	geometry.roots = int32_array_t(math.max(#roots, 1))

	for i, g in ipairs(roots) do
		geometry.roots[i - 1] = g
	end

	if n == 0 then return end

	local ids = int32_array_t(n)
	local at = 0

	for g = 0, geometry.group_count - 1 do
		if err[g] < format.NO_ERROR * 0.5 then
			ids[at] = g
			at = at + 1
		end
	end

	local hierarchy = import("goluwa/render3d/cluster_lod/hierarchy.lua")
	local runs = {}
	hierarchy.KdSplit(ids, cx, cy, cz, 0, n, 8, runs)
	local leaves = {}

	for i = 1, #runs, 2 do
		leaves[#leaves + 1] = {first = runs[i], last = runs[i + 1] - 1}
	end

	local node_x, node_y, node_z, node_r, node_err = {}, {}, {}, {}, {}
	local node_first, node_count, node_leaf = {}, {}, {}
	local children = {}

	local function bound(list_first, list_count, sphere_of)
		local x, y, z = 0, 0, 0

		for i = list_first, list_first + list_count - 1 do
			local sx, sy, sz = sphere_of(i)
			x, y, z = x + sx, y + sy, z + sz
		end

		x, y, z = x / list_count, y / list_count, z / list_count
		local radius, e = 0, 0

		for i = list_first, list_first + list_count - 1 do
			local sx, sy, sz, sr, se = sphere_of(i)
			radius = max(radius, sqrt((sx - x) ^ 2 + (sy - y) ^ 2 + (sz - z) ^ 2) + sr)
			e = max(e, se)
		end

		return x, y, z, radius, e
	end

	local level = {}

	for _, leaf in ipairs(leaves) do
		local id = #node_x + 1
		node_x[id], node_y[id], node_z[id], node_r[id], node_err[id] = bound(leaf.first, leaf.last - leaf.first + 1, function(i)
			local g = ids[i]
			return cx[g], cy[g], cz[g], r[g], err[g]
		end)
		node_first[id], node_count[id], node_leaf[id] = leaf.first, leaf.last - leaf.first + 1, true
		level[#level + 1] = id
	end

	while #level > 1 do
		local next_level = {}

		for i = 1, #level, 8 do
			local id = #node_x + 1
			local first = #children

			for k = i, min(i + 7, #level) do
				children[#children + 1] = level[k]
			end

			local count = #children - first
			node_x[id], node_y[id], node_z[id], node_r[id], node_err[id] = bound(first + 1, count, function(k)
				local c = children[k]
				return node_x[c], node_y[c], node_z[c], node_r[c], node_err[c]
			end)
			node_first[id], node_count[id], node_leaf[id] = first + 1, count, false
			next_level[#next_level + 1] = id
		end

		level = next_level
	end

	local count = #node_x
	geometry.node_count = count
	geometry.root_node = level[1]
	geometry.nx, geometry.ny, geometry.nz = double_array_t(count + 1), double_array_t(count + 1), double_array_t(count + 1)
	geometry.nr, geometry.nerr = double_array_t(count + 1), double_array_t(count + 1)
	geometry.nfirst, geometry.ncount = int32_array_t(count + 1), int32_array_t(count + 1)
	geometry.nleaf = uint8_array_t(count + 1)
	geometry.children = int32_array_t(#children + 1)
	geometry.leaf_groups = ids

	for i = 1, count do
		geometry.nx[i], geometry.ny[i], geometry.nz[i], geometry.nr[i], geometry.nerr[i] = node_x[i], node_y[i], node_z[i], node_r[i], node_err[i]
		geometry.nfirst[i], geometry.ncount[i], geometry.nleaf[i] = node_first[i], node_count[i], node_leaf[i] and 1 or 0
	end

	for i = 1, #children do
		geometry.children[i] = children[i]
	end
end

local geometry_cache = {}

function cluster_stream.LoadGeometry(path)
	if geometry_cache[path] then return geometry_cache[path] end

	local head = read_file_range(path, 0, format.HEADER_SIZE)
	local header = ffi.new(format.Header)
	ffi.copy(header, head, format.HEADER_SIZE)
	assert(header.magic == format.MAGIC, path .. " is not a cluster stream file")
	assert(
		header.version == format.VERSION,
		path .. " has an old cluster stream version, bake it again"
	)
	local table_size = header.data_offset - header.groups_offset
	local tables = read_file_range(path, header.groups_offset, table_size)
	local tables_ptr = ffi.cast("const uint8_t *", tables)
	local groups = ffi.cast(format.GroupPointer, tables_ptr)
	local n = header.group_count
	local geometry = {
		path = path,
		header = header,
		group_count = n,
		data_offset = header.data_offset,
		cx = double_array_t(n),
		cy = double_array_t(n),
		cz = double_array_t(n),
		r = double_array_t(n),
		err = double_array_t(n),
		page_offset = uint32_array_t(n),
		page_size = uint32_array_t(n),
		cluster_count = uint8_array_t(n),
		flags = uint8_array_t(n),
		link_first = uint32_array_t(n),
		link_count = uint32_array_t(n),
		links = uint32_array_t(math.max(header.link_count, 1)),
		resident = uint32_array_t(n),
		allocation = {},
		loading = uint8_array_t(n),
		last_used = int32_array_t(n),
		requested = int32_array_t(n),
		resident_children = int32_array_t(n),
		level = uint8_array_t(n),
		triangle_count = uint32_array_t(n),
	}
	local links = ffi.cast("const uint32_t *", tables_ptr + header.links_offset - header.groups_offset)

	for i = 0, header.link_count - 1 do
		geometry.links[i] = links[i]
	end

	for g = 0, n - 1 do
		local record = groups[g]
		geometry.cx[g], geometry.cy[g], geometry.cz[g], geometry.r[g] = record.sphere[0], record.sphere[1], record.sphere[2], record.sphere[3]
		geometry.err[g] = record.error
		geometry.page_offset[g] = record.data_offset
		geometry.page_size[g] = record.data_size
		geometry.cluster_count[g] = record.cluster_count
		geometry.flags[g] = record.flags
		geometry.link_first[g] = record.first_link
		geometry.link_count[g] = record.link_count
		geometry.level[g] = record.level
		geometry.triangle_count[g] = record.triangle_count
		geometry.resident[g] = NONE
	end

	build_nodes(geometry)
	geometry.id = #state.geometries
	state.geometries[#state.geometries + 1] = geometry
	geometry.residency_base = state.residency_count
	state.residency_count = state.residency_count + n
	state.geometries_dirty = true
	stats.geometries = #state.geometries
	geometry_cache[path] = geometry
	return geometry
end

local function in_level_cut(geometry, g, level)
	local group_level = geometry.level[g]
	return group_level == level or
		(
			group_level < level and
			band(geometry.flags[g], format.GROUP_ROOT) ~= 0
		)
end

-- the finest level whose whole mesh (its groups and the root groups below it) fits in the fallback budget
function cluster_stream.GetFallbackLevel(geometry)
	local budget = math.max(format.FALLBACK_MIN_TRIANGLES, geometry.header.source_triangles * fallback_ratio:Get())

	for level = geometry.header.min_level, geometry.header.level_count - 1 do
		local sum = 0

		for g = 0, geometry.group_count - 1 do
			if in_level_cut(geometry, g, level) then
				sum = sum + geometry.triangle_count[g]
			end
		end

		if sum <= budget then return level end
	end

	return geometry.header.level_count - 1
end

-- the mesh rays and shadow maps see: a level cut decoded to the engine's vertex layout
function cluster_stream.BuildFallback(geometry, level)
	local header = geometry.header
	local vertex_total, index_total = 0, 0
	local records = {}

	for g = 0, geometry.group_count - 1 do
		if in_level_cut(geometry, g, level) then
			local page = read_file_range(geometry.path, geometry.data_offset + geometry.page_offset[g], geometry.page_size[g])
			local clusters = ffi.cast(format.ClusterPointer, page)

			for i = 0, geometry.cluster_count[g] - 1 do
				local cluster = clusters + i
				records[#records + 1] = {page = page, cluster = cluster}
				vertex_total = vertex_total + cluster.vertex_count
				index_total = index_total + cluster.triangle_count * 3
			end
		end
	end

	local vertices = vertex_math.VertexType(math.max(vertex_total, 1))
	local indices = uint32_array_t(math.max(index_total, 3))
	local corners = int32_array_t(128 * 3)
	local v_at, i_at = 0, 0

	for _, record in ipairs(records) do
		local c = record.cluster
		format.DecodeCluster(header, record.page, c, vertices, v_at, corners)

		for k = 0, c.triangle_count * 3 - 1 do
			indices[i_at + k] = v_at + corners[k]
		end

		for k = v_at, v_at + c.vertex_count - 1 do
			local v = vertices[k]
			v.vertex_color[0], v.vertex_color[1], v.vertex_color[2], v.vertex_color[3] = 1, 1, 1, 1
		end

		v_at = v_at + c.vertex_count
		i_at = i_at + c.triangle_count * 3
	end

	return vertices, v_at, indices, i_at
end

function cluster_stream.SetRow(id, mesh, material, polygon3d, matrix, double_sided)
	local geometry = polygon3d.cluster_geometry
	local row = state.rows[id]

	if not row then
		row = {id = id, m = double_array_t(12)}
		state.rows[id] = row
		state.row_serial = state.row_serial + 1
	end

	if row.material ~= material or row.mesh ~= mesh or row.geometry ~= geometry then
		state.row_serial = state.row_serial + 1
	end

	row.geometry, row.mesh, row.material, row.polygon3d = geometry, mesh, material, polygon3d
	local m = row.m
	m[0], m[1], m[2], m[3] = matrix.m00, matrix.m01, matrix.m02, matrix.m03
	m[4], m[5], m[6], m[7] = matrix.m10, matrix.m11, matrix.m12, matrix.m13
	m[8], m[9], m[10], m[11] = matrix.m20, matrix.m21, matrix.m22, matrix.m23
	row.tx, row.ty, row.tz = matrix.m30, matrix.m31, matrix.m32
	row.scale = max(
		sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]),
		sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]),
		sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10])
	)
	local det = m[0] * (
			m[5] * m[10] - m[6] * m[9]
		) - m[1] * (
			m[4] * m[10] - m[6] * m[8]
		) + m[2] * (
			m[4] * m[9] - m[5] * m[8]
		)
	local draw_set = double_sided and SET_DOUBLE_SIDED or (det < 0 and SET_MIRRORED or SET_FRONT)

	if row.draw_set ~= draw_set then
		row.draw_set = draw_set
		state.row_serial = state.row_serial + 1
	end
end

function cluster_stream.ClearRow(id)
	if state.rows[id] then
		state.rows[id] = nil
		state.row_serial = state.row_serial + 1
	end
end

local function mark_resident(geometry, g, units, allocation)
	state.residency_version = state.residency_version + 1
	geometry.resident[g] = units
	geometry.allocation[g] = allocation
	geometry.loading[g] = 0
	geometry.last_used[g] = state.frame

	for i = geometry.link_first[g], geometry.link_first[g] + geometry.link_count[g] - 1 do
		local p = geometry.links[i]
		geometry.resident_children[p] = geometry.resident_children[p] + 1
	end

	state.resident_list[#state.resident_list + 1] = {geometry, g}
	local pending = state.pending_residency
	pending[#pending + 1] = geometry.residency_base + g
	pending[#pending + 1] = units
	stats.resident_groups = stats.resident_groups + 1
	stats.resident_bytes = stats.resident_bytes + geometry.page_size[g]
	stats.loaded = stats.loaded + 1
end

local function evict(geometry, g)
	state.residency_version = state.residency_version + 1
	local pending = state.pending_residency
	pending[#pending + 1] = geometry.residency_base + g
	pending[#pending + 1] = NONE
	geometry.resident[g] = NONE

	for i = geometry.link_first[g], geometry.link_first[g] + geometry.link_count[g] - 1 do
		local p = geometry.links[i]
		geometry.resident_children[p] = geometry.resident_children[p] - 1
	end

	state.pending_free[#state.pending_free + 1] = {
		frame = state.frame + RING + 1,
		allocation = geometry.allocation[g],
		units = math.ceil(geometry.page_size[g] / PAGE_UNIT),
	}
	geometry.allocation[g] = nil
	stats.resident_groups = stats.resident_groups - 1
	stats.resident_bytes = stats.resident_bytes - geometry.page_size[g]
	stats.evicted = stats.evicted + 1
end

local function free_retired()
	local list = state.pending_free
	local kept = {}

	for _, item in ipairs(list) do
		if item.frame <= state.frame then
			state.allocator:Free(item.allocation)
			state.used_units = state.used_units - item.units
		else
			kept[#kept + 1] = item
		end
	end

	state.pending_free = kept
end

-- evicts groups nothing needed for a while, oldest first, until the pool has room for `units`
local function make_room(units)
	local list = state.resident_list
	local evictable = {}
	local frame = state.frame

	for i = 1, #list do
		local item = list[i]
		local geometry, g = item[1], item[2]

		if
			geometry.resident[g] ~= NONE and
			geometry.link_count[g] > 0 and
			geometry.resident_children[g] == 0 and
			frame - geometry.last_used[g] > EVICT_AFTER_FRAMES
		then
			evictable[#evictable + 1] = item
		end
	end

	table.sort(evictable, function(a, b)
		return a[1].last_used[a[2]] < b[1].last_used[b[2]]
	end)

	local freed = 0
	local target = units + state.pool_units * 0.05

	for _, item in ipairs(evictable) do
		if freed >= target then break end

		local geometry, g = item[1], item[2]

		if geometry.resident_children[g] == 0 then
			freed = freed + math.ceil(geometry.page_size[g] / PAGE_UNIT)
			evict(geometry, g)
		end
	end

	local kept = {}

	for i = 1, #list do
		local item = list[i]

		if item[1].resident[item[2]] ~= NONE then kept[#kept + 1] = item end
	end

	state.resident_list = kept
	return freed > 0
end

local LOADER = [[
	local work = ...
	local ffi = require("ffi")
	local cache = _G.cluster_stream_files

	if not cache then
		cache = {count = 0, files = {}}
		_G.cluster_stream_files = cache
	end

	local file = cache.files[work.path]

	if not file then
		if cache.count > 128 then
			for _, f in pairs(cache.files) do f:close() end
			cache.files, cache.count = {}, 0
		end

		file = assert(io.open(work.path, "rb"))
		cache.files[work.path] = file
		cache.count = cache.count + 1
	end

	for i = 1, #work.loads, 3 do
		file:seek("set", work.loads[i])
		local size = work.loads[i + 1]
		local data = file:read(size)
		assert(data and #data == size, "short read")
		ffi.copy(ffi.cast("uint8_t *", work.loads[i + 2]), data, size)
	end

	return true
]]

local function ensure_loader()
	if state.loader then return end

	state.loader = threads.new_pool(
		[[
		local work = ...
		return assert(load(work.source, "=cluster_stream_loader"))(work.input)
	]],
		LOADER_THREADS
	)
	state.loader_jobs = {}
	state.loader_queue = {}
end

local function poll_loader()
	local pool = state.loader

	for thread_id = 1, pool.num_threads do
		local job = state.loader_jobs[thread_id]

		if job and pool:is_done(thread_id) then
			state.loader_jobs[thread_id] = nil
			local ok, err = pool:wait(thread_id)

			for _, load in ipairs(job.items) do
				if ok then
					mark_resident(load.geometry, load.group, load.units, load.allocation)
				else
					load.geometry.loading[load.group] = 0
					state.allocator:Free(load.allocation)
					state.used_units = state.used_units - math.ceil(load.geometry.page_size[load.group] / PAGE_UNIT)
				end
			end

			if not ok then wlog("cluster stream load failed: %s", tostring(err)) end

			stats.loading = stats.loading - #job.items
		end

		if not state.loader_jobs[thread_id] and #state.loader_queue > 0 then
			local job = table.remove(state.loader_queue, 1)
			state.loader_jobs[thread_id] = job
			pool:submit(thread_id, {source = LOADER, input = job.work})
		end
	end
end

local function start_load(geometry, g)
	local size = geometry.page_size[g]
	local units = math.ceil(size / PAGE_UNIT)
	local offset, allocation = state.allocator:Alloc(units)

	if not offset then
		if not make_room(units) then return false end

		free_retired()
		offset, allocation = state.allocator:Alloc(units)

		if not offset then return false end
	end

	state.used_units = state.used_units + units
	geometry.loading[g] = 1
	local batch = state.load_batches[geometry]

	if not batch or #batch.items >= LOADS_PER_JOB then
		batch = {items = {}, work = {path = geometry.path, loads = {}}}
		state.load_batches[geometry] = batch
		state.loader_queue[#state.loader_queue + 1] = batch
	end

	batch.items[#batch.items + 1] = {geometry = geometry, group = g, units = offset, allocation = allocation}
	local loads = batch.work.loads
	loads[#loads + 1] = geometry.data_offset + geometry.page_offset[g]
	loads[#loads + 1] = size
	loads[#loads + 1] = tonumber(ffi.cast("uintptr_t", state.pool_ptr + offset * PAGE_UNIT))
	stats.loading = stats.loading + 1
	return true
end

local Candidate = ffi.typeof([[struct {
	uint32_t row;
	uint32_t geometry;
	uint32_t page;
	uint32_t cluster_count;
	float sphere[4];
	float error;
	uint32_t batch;
	uint32_t draw_set;
	uint32_t pad;
}]])
local CandidatePointer = ffi.typeof("$ *", Candidate)
assert(ffi.sizeof(Candidate) == CANDIDATE_BYTES)

local function ensure_candidates(count)
	if state.candidate_buffer and count <= state.candidate_capacity then return end

	local capacity = max(16384, 2 ^ math.ceil(math.log(count) / math.log(2)))

	if state.candidate_buffer then
		render.GetDevice():WaitIdle()
		state.candidate_buffer:Remove()
	end

	state.candidate_buffer, state.candidate_ptr = create_host_buffer(
		capacity * CANDIDATE_BYTES * RING,
		{"storage_buffer", "shader_device_address"},
		"cluster_stream_candidates"
	)
	state.candidate_address = state.candidate_buffer:GetDeviceAddress()
	state.candidate_capacity = capacity
end

local requests = {}
local request_count = 0

-- walks every row's node tree with the camera: resident groups whose coarser replacement is not good enough are
-- candidates (a superset, the cull pass decides exactly), missing ones whose parents are resident are requested
local function emit(out, count, capacity, row, geometry, g)
	if count < capacity then
		local c = out[count]
		c.row = row.id
		c.geometry = geometry.id
		c.page = geometry.resident[g]
		c.cluster_count = geometry.cluster_count[g]
		c.sphere[0], c.sphere[1], c.sphere[2], c.sphere[3] = geometry.cx[g], geometry.cy[g], geometry.cz[g], geometry.r[g]
		c.error = min(geometry.err[g], 1e30)
		c.batch = row.batch
		c.draw_set = row.draw_set
	end

	return count + 1
end

local function traverse(focal, threshold, cam_x, cam_y, cam_z)
	local out = ffi.cast(CandidatePointer, state.candidate_ptr) + state.ring_slot * state.candidate_capacity
	local count = 0
	local capacity = state.candidate_capacity
	local frame = state.frame
	local cpu_threshold = threshold * CPU_MARGIN
	request_count = 0
	local stack = state.stack or int32_array_t(4096)
	state.stack = stack

	for _, row in pairs(state.rows) do
		local geometry = row.geometry
		local m, s = row.m, row.scale
		local m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11 = m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]
		local tx, ty, tz = row.tx, row.ty, row.tz
		local k = focal * s / cpu_threshold
		local nx, ny, nz, nr, nerr = geometry.nx, geometry.ny, geometry.nz, geometry.nr, geometry.nerr
		local nfirst, ncount, nleaf, children, leaf_groups = geometry.nfirst, geometry.ncount, geometry.nleaf, geometry.children, geometry.leaf_groups
		local gx, gy, gz, gr, gerr = geometry.cx, geometry.cy, geometry.cz, geometry.r, geometry.err
		local resident, loading, last_used, requested = geometry.resident, geometry.loading, geometry.last_used, geometry.requested

		for i = 0, geometry.root_count - 1 do
			local g = geometry.roots[i]

			if resident[g] ~= NONE then
				last_used[g] = frame
				count = emit(out, count, capacity, row, geometry, g)
			end
		end

		local top = 0

		if geometry.root_node then
			stack[0] = geometry.root_node
			top = 1
		end

		while top > 0 do
			top = top - 1
			local node = stack[top]
			local x, y, z = nx[node], ny[node], nz[node]
			local wx = m0 * x + m4 * y + m8 * z + tx - cam_x
			local wy = m1 * x + m5 * y + m9 * z + ty - cam_y
			local wz = m2 * x + m6 * y + m10 * z + tz - cam_z
			local d = sqrt(wx * wx + wy * wy + wz * wz) - nr[node] * s

			if nerr[node] * k > max(d, 1e-4) then
				if nleaf[node] == 1 then
					for i = nfirst[node], nfirst[node] + ncount[node] - 1 do
						local g = leaf_groups[i]
						x, y, z = gx[g], gy[g], gz[g]
						wx = m0 * x + m4 * y + m8 * z + tx - cam_x
						wy = m1 * x + m5 * y + m9 * z + ty - cam_y
						wz = m2 * x + m6 * y + m10 * z + tz - cam_z
						d = sqrt(wx * wx + wy * wy + wz * wz) - gr[g] * s
						local priority = gerr[g] * k / max(d, 1e-4)

						if priority > 1 then
							local page = resident[g]

							if page ~= NONE then
								last_used[g] = frame
								count = emit(out, count, capacity, row, geometry, g)
							elseif loading[g] == 0 and requested[g] ~= frame then
								requested[g] = frame
								request_count = request_count + 1
								local r = requests[request_count]

								if not r then
									r = {}
									requests[request_count] = r
								end

								r[1], r[2], r[3] = geometry, g, priority
							end
						end
					end
				else
					for i = nfirst[node], nfirst[node] + ncount[node] - 1 do
						stack[top] = children[i]
						top = top + 1
					end
				end
			end
		end
	end

	return count
end

local function sort_requests(a, b)
	return a[3] > b[3]
end

local function issue_requests()
	if request_count == 0 then return end

	local list = {}

	for i = 1, request_count do
		list[i] = requests[i]
	end

	table.sort(list, sort_requests)
	local budget = loads_per_frame:Get()
	state.load_batches = {}
	local issued = 0

	for _, r in ipairs(list) do
		if issued >= budget or stats.loading >= budget * 4 then break end

		local geometry, g = r[1], r[2]

		if geometry.loading[g] == 0 and geometry.resident[g] == NONE then
			local parents_ready = true

			for i = geometry.link_first[g], geometry.link_first[g] + geometry.link_count[g] - 1 do
				if geometry.resident[geometry.links[i]] == NONE then
					parents_ready = false

					break
				end
			end

			if parents_ready then
				if not start_load(geometry, g) then break end

				issued = issued + 1
			end
		end
	end

	stats.requested = request_count
end

local function load_roots(geometry)
	state.load_batches = {}

	for g = 0, geometry.group_count - 1 do
		if geometry.link_count[g] == 0 then
			assert(
				start_load(geometry, g),
				"cluster stream pool too small for the roots of " .. geometry.path
			)
		end
	end
end

local function upload(cmd, buffer, source, bytes, destination)
	local data = ffi.cast("uint8_t *", source)
	destination = destination or 0

	for offset = 0, bytes - 1, UPDATE_BUFFER_LIMIT do
		cmd:UpdateBuffer(
			buffer,
			destination + offset,
			math.min(UPDATE_BUFFER_LIMIT, bytes - offset),
			data + offset
		)
	end
end

local function flush_tables(cmd)
	ensure_residency_capacity(math.max(state.residency_count, 1))
	ensure_geometry_capacity(math.max(#state.geometries, 1))

	if state.residency_full_upload then
		state.residency_full_upload = false
		local all = uint32_array_t(state.residency_capacity)
		ffi.fill(all, state.residency_capacity * 4, 0xFF)

		for _, geometry in ipairs(state.geometries) do
			ffi.copy(all + geometry.residency_base, geometry.resident, geometry.group_count * 4)
		end

		upload(cmd, state.residency_buffer, all, state.residency_count * 4)
		state.pending_residency = {}
	elseif #state.pending_residency > 0 then
		local pending = state.pending_residency
		local word = ffi.new("uint32_t[1]")

		for i = 1, #pending, 2 do
			word[0] = pending[i + 1]
			cmd:UpdateBuffer(state.residency_buffer, pending[i] * 4, 4, word)
		end

		state.pending_residency = {}
	end

	if state.geometries_dirty or state.geometry_full_upload then
		state.geometries_dirty = false
		state.geometry_full_upload = false
		local records = GeometryRecordArray(#state.geometries)

		for i, geometry in ipairs(state.geometries) do
			local r = records[i - 1]
			local h = geometry.header
			r.pos_min[0], r.pos_min[1], r.pos_min[2] = h.pos_min[0], h.pos_min[1], h.pos_min[2]
			r.pos_step = h.pos_step
			r.uv_step = h.uv_step
			r.residency_base = geometry.residency_base
		end

		upload(cmd, state.geometry_buffer, records, #state.geometries * 32)
	end
end

local GLSL = [[
	#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
	struct cs_candidate {
		uint row;
		uint geometry;
		uint page;
		uint cluster_count;
		vec4 sphere;
		float error;
		uint batch;
		uint draw_set;
		uint pad;
	};
	struct cs_cluster {
		vec4 bounds;
		vec4 lod_sphere;
		float lod_error;
		int gen;
		uint group_index;
		uint data_offset;
		uint counts;
		ivec3 pos_min;
		ivec2 uv_min;
		uint bits;
		uint bits2;
	};
	struct cs_geometry {
		vec3 pos_min;
		float pos_step;
		float uv_step;
		uint residency_base;
		uint pad0;
		uint pad1;
	};
	layout(buffer_reference, scalar) readonly buffer CSCandidates { cs_candidate c[]; };
	layout(buffer_reference, scalar) readonly buffer CSClusters { cs_cluster c[]; };
	layout(buffer_reference, scalar) readonly buffer CSWords { uint w[]; };
	layout(buffer_reference, scalar) readonly buffer CSGeometries { cs_geometry g[]; };
	layout(buffer_reference, scalar) buffer CSVisible { uvec2 v[]; };
	layout(buffer_reference, scalar) buffer CSState { uint w[]; };
	]] .. instances.TLAS_INSTANCE_GLSL .. instances.RASTER_DATA_GLSL .. instances.INSTANCE_DATA_GLSL .. [[
	layout(buffer_reference, scalar) readonly buffer CSTLAS { tlas_instance t[]; };
	layout(buffer_reference, scalar) readonly buffer CSRaster { raster_data r[]; };
	layout(buffer_reference, scalar) readonly buffer CSInstanceData { instance_data d[]; };

	vec3 cs_transform(float m[12], vec3 p) {
		return vec3(
			m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
			m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
			m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11]
		);
	}

	float cs_scale(float m[12]) {
		return max(length(vec3(m[0], m[4], m[8])), max(length(vec3(m[1], m[5], m[9])), length(vec3(m[2], m[6], m[10]))));
	}

	uint cs_bits(uint64_t words, uint at, uint count) {
		if (count == 0u) return 0u;

		CSWords data = CSWords(words);
		uint word = at >> 5u;
		uint shift = at & 31u;
		uint v = data.w[word] >> shift;

		if (shift + count > 32u) v |= data.w[word + 1u] << (32u - shift);

		return count == 32u ? v : v & ((1u << count) - 1u);
	}
]]
local CULL_GLSL = GLSL .. [[
	float cs_projected(float error, vec3 center, float radius) {
		float d = max(distance(center, compute.camera_position) - radius, 0.0001);
		return error * compute.focal / d;
	}

	bool cs_outside(vec4 plane, vec3 center, float radius) {
		return dot(plane.xyz, center) + plane.w < -radius;
	}

	void main() {
		uint candidate_index = gl_GlobalInvocationID.x >> 4u;
		uint lane = gl_GlobalInvocationID.x & 15u;

		if (candidate_index >= uint(compute.candidate_count)) return;

		cs_candidate cand = CSCandidates(compute.candidates).c[candidate_index];

		if (lane >= cand.cluster_count) return;

		if ((CSInstanceData(compute.instance_data).d[cand.row].flags & 16u) != 0u) return;

		uint64_t page = compute.pool + uint64_t(cand.page) * 16ul;
		cs_cluster c = CSClusters(page).c[lane];
		tlas_instance t = CSTLAS(compute.tlas).t[cand.row];
		float scale = cs_scale(t.m);

		if (cand.error < 1e29 && cs_projected(cand.error * scale, cs_transform(t.m, cand.sphere.xyz), cand.sphere.w * scale) <= compute.pixel_error) return;

		if (c.gen >= 0) {
			cs_geometry geometry = CSGeometries(compute.geometries).g[cand.geometry];
			bool finer_resident = CSWords(compute.residency).w[geometry.residency_base + uint(c.gen)] != 0xFFFFFFFFu;

			if (finer_resident && cs_projected(c.lod_error * scale, cs_transform(t.m, c.lod_sphere.xyz), c.lod_sphere.w * scale) > compute.pixel_error) return;
		}

		vec3 center = cs_transform(t.m, c.bounds.xyz);
		float radius = c.bounds.w * scale;

		for (int i = 0; i < 6; i++) {
			if (cs_outside(compute.frustum[i], center, radius)) return;
		}

		uint set = cand.draw_set;
		uint index = atomicAdd(CSState(compute.state).w[set * 4u + 1u], 1u);

		if (index >= uint(compute.max_visible)) {
			atomicAdd(CSState(compute.state).w[set * 4u + 1u], 0xFFFFFFFFu);
			atomicAdd(CSState(compute.state).w[12], 1u);
			return;
		}

		CSVisible(compute.visible).v[set * uint(compute.max_visible) + index] = uvec2(candidate_index, lane);
	}
]]
local compute_block = {
	{"frustum", "vec4", 6},
	{"camera_position", "vec3"},
	{"focal", "float"},
	{"pixel_error", "float"},
	{"candidate_count", "int"},
	{"max_visible", "int"},
	{"pad", "int"},
	{"candidates", "uint64_t"},
	{"pool", "uint64_t"},
	{"geometries", "uint64_t"},
	{"residency", "uint64_t"},
	{"visible", "uint64_t"},
	{"state", "uint64_t"},
	{"tlas", "uint64_t"},
	{"instance_data", "uint64_t"},
}

local function write_compute_block(self, block)
	for i = 0, 5 do
		local p = state.frustum[i + 1]
		block.frustum[i][0], block.frustum[i][1], block.frustum[i][2], block.frustum[i][3] = p[1], p[2], p[3], p[4]
	end

	local position = state.camera_position
	block.camera_position[0], block.camera_position[1], block.camera_position[2] = position.x, position.y, position.z
	block.focal = state.focal
	block.pixel_error = state.pixel_error
	block.candidate_count = state.candidate_count
	block.max_visible = state.max_visible
	block.candidates = state.candidate_address + state.ring_slot * state.candidate_capacity * CANDIDATE_BYTES
	block.pool = state.pool_address
	block.geometries = state.geometry_address
	block.residency = state.residency_address
	block.visible = state.visible_address
	block.state = state.state_address
	block.tlas = state.tlas_address
	block.instance_data = state.instance_data_address
	return block
end

local cull_pipeline

local function get_cull_pipeline()
	cull_pipeline = cull_pipeline or
		EasyPipeline.Compute{
			name = "cluster_stream_cull",
			LocalSize = {x = 64, y = 1, z = 1},
			block = compute_block,
			write = write_compute_block,
			shader = CULL_GLSL,
		}
	return cull_pipeline
end

local function frustum_planes(m)
	-- rows of the view projection, column major storage
	local function row(i)
		return m[i], m[4 + i], m[8 + i], m[12 + i]
	end

	local x1, x2, x3, x4 = row(0)
	local y1, y2, y3, y4 = row(1)
	local z1, z2, z3, z4 = row(2)
	local w1, w2, w3, w4 = row(3)
	local planes = {
		{w1 + x1, w2 + x2, w3 + x3, w4 + x4},
		{w1 - x1, w2 - x2, w3 - x3, w4 - x4},
		{w1 + y1, w2 + y2, w3 + y3, w4 + y4},
		{w1 - y1, w2 - y2, w3 - y3, w4 - y4},
		{z1, z2, z3, z4},
		{w1 - z1, w2 - z2, w3 - z3, w4 - z4},
	}

	for _, p in ipairs(planes) do
		local l = sqrt(p[1] * p[1] + p[2] * p[2] + p[3] * p[3])

		if l > 0 then p[1], p[2], p[3], p[4] = p[1] / l, p[2] / l, p[3] / l, p[4] / l end
	end

	-- a reversed or infinite far plane bounds nothing
	planes[5] = {0, 0, 0, 1}
	planes[6] = {0, 0, 0, 1}
	return planes
end

local batch_table
local batch_list = {}
local batch_serial = 0
local built_serial = -1

local function build_batches()
	if built_serial == state.row_serial then return end

	built_serial = state.row_serial
	batch_list = {}
	local index_of = {}

	for _, row in pairs(state.rows) do
		local key = row.mesh

		if not index_of[key] or batch_list[index_of[key] + 1].material ~= row.material then
			index_of[key] = #batch_list
			batch_list[#batch_list + 1] = {mesh = row.mesh, material = row.material, first_polygon3d = row.polygon3d}
		end

		row.batch = index_of[key]
	end

	batch_serial = batch_serial + 1
	stats.rows = 0

	for _ in pairs(state.rows) do
		stats.rows = stats.rows + 1
	end
end

local function get_pipeline()
	local pipeline = render3d.GetPipelineVariant(
		cluster_stream.name,
		draw.GetVariant(draw.SHAPE_PLAIN, bit.bor(draw.GetGlobalBits(0), shader_features.PARAMS))
	)

	if render3d.IsPipelineReady(pipeline) then return pipeline end

	pipeline = render3d.GetPipelineVariant(cluster_stream.name, draw.GetVariant(draw.SHAPE_PLAIN, shader_features.PARAMS))

	if render3d.IsPipelineReady(pipeline) then return pipeline end
end

function cluster_stream.PreDraw(cmd)
	state.ready = false
	state.candidate_count = state.candidate_count or 0

	if not cluster_stream.IsAvailable() or next(state.rows) == nil then return end

	if not get_pipeline() then return end

	ensure_pool()
	ensure_loader()
	state.frame = state.frame + 1
	state.ring_slot = state.ring_slot or 0
	free_retired()
	poll_loader()

	for _, geometry in ipairs(state.geometries) do
		if not geometry.roots_requested then
			geometry.roots_requested = true
			load_roots(geometry)
		end
	end

	build_batches()
	local camera = render3d.GetCamera()
	local projection = camera:BuildUnjitteredProjectionMatrix()
	local view_projection = camera:BuildViewMatrix() * projection
	local m = ffi.new("float[16]")
	view_projection:CopyToFloatPointer(m)
	state.frustum = frustum_planes(m)
	state.camera_position = camera:GetPosition()
	local resolution = render3d.GetRenderSize()
	state.focal = 0.5 * resolution.y * math.abs(projection.m11)

	if state.frame > RING then
		local counts = ffi.cast(
			"const uint32_t *",
			state.readback_ptr + ((state.frame + 1) % RING) * READBACK_BYTES
		)
		local visible = counts[1] + counts[5] + counts[9]
		local wanted = visible + counts[12]
		stats.visible_clusters = visible
		stats.dropped_clusters = counts[12]

		-- like RTXMG's adaptive error: a view that needs more clusters than the budget coarsens instead of dropping some
		if wanted > state.max_visible * 0.9 then
			state.error_scale = state.error_scale * 1.1
		elseif wanted < state.max_visible * 0.6 then
			state.error_scale = math.max(1, state.error_scale / 1.02)
		end
	end

	stats.error_scale = state.error_scale
	state.pixel_error = pvars.Get("r_cluster_lod_error") * state.error_scale
	local position = state.camera_position
	local signature = string.format(
		"%.6f %.6f %.6f %.6f %.6f %d %d",
		position.x,
		position.y,
		position.z,
		state.focal,
		state.pixel_error,
		state.row_serial,
		state.residency_version
	)

	if signature ~= state.signature or request_count > 0 then
		state.signature = signature
		state.ring_slot = (state.ring_slot + 1) % RING
		ensure_candidates(state.candidate_capacity and state.candidate_capacity or 16384)
		local started = system.GetTimeNS()
		local count = traverse(
			state.focal,
			state.pixel_error,
			state.camera_position.x,
			state.camera_position.y,
			state.camera_position.z
		)

		if count > state.candidate_capacity then
			ensure_candidates(count)
			count = traverse(
				state.focal,
				state.pixel_error,
				state.camera_position.x,
				state.camera_position.y,
				state.camera_position.z
			)
		end

		stats.traverse_ms = tonumber(system.GetTimeNS() - started) / 1e6
		stats.candidates = count
		state.candidate_count = count
		issue_requests()
	end

	local tlas_table, data_table = instances.GetTables()
	state.tlas_address = tlas_table:GetAddress()
	state.instance_data_address = data_table:GetAddress()
	state.raster_address = instances.GetRasterTable():GetAddress()
	cmd:PipelineBarrier{
		srcStage = {"draw_indirect", "vertex_shader", "compute", "transfer"},
		dstStage = "transfer",
		memoryBarrier = true,
	}
	flush_tables(cmd)
	local commands = ffi.new(
		"uint32_t[13]",
		CLUSTER_VERTICES,
		0,
		0,
		0,
		CLUSTER_VERTICES,
		0,
		0,
		state.max_visible,
		CLUSTER_VERTICES,
		0,
		0,
		state.max_visible * 2
	)
	cmd:UpdateBuffer(state.state_buffer, 0, 52, commands)
	cmd:PipelineBarrier{srcStage = {"host", "transfer"}, dstStage = "compute", memoryBarrier = true}

	if state.candidate_count > 0 then
		get_cull_pipeline():Dispatch(cmd, math.ceil(state.candidate_count * 16 / 64), 1, 1, 1)
	end

	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"draw_indirect", "vertex_shader", "transfer"},
		memoryBarrier = true,
	}
	readback_copy[0].srcOffset = 0
	readback_copy[0].dstOffset = (state.frame % RING) * READBACK_BYTES
	readback_copy[0].size = READBACK_BYTES
	cmd:CopyBuffer(state.state_buffer, state.readback_buffer, readback_copy, 1)
	state.ready = true
end

local draw_block = {
	name = "cs_draw",
	block = {
		{"candidates", "uint64_t"},
		{"pool", "uint64_t"},
		{"geometries", "uint64_t"},
		{"visible", "uint64_t"},
		{"tlas", "uint64_t"},
		{"raster", "uint64_t"},
		{"instance_data", "uint64_t"},
	},
	write = function(self, block)
		block.candidates = state.candidate_address and
			state.candidate_address + state.ring_slot * state.candidate_capacity * CANDIDATE_BYTES or
			0
		block.pool = state.pool_address or 0
		block.geometries = state.geometry_address or 0
		block.visible = state.visible_address or 0
		block.tlas = state.tlas_address or 0
		block.raster = state.raster_address or 0
		block.instance_data = state.instance_data_address or 0
		return block
	end,
}
local VERTEX_MAIN = [=[
	vec3 cs_unfold(vec2 p) {
		vec3 n = vec3(p, 1.0 - abs(p.x) - abs(p.y));
		float t = max(-n.z, 0.0);
		n.xy += vec2(n.x >= 0.0 ? -t : t, n.y >= 0.0 ? -t : t);
		return normalize(n);
	}

	void main() {
		uvec2 entry = CSVisible(cs_draw.visible).v[gl_InstanceIndex];
		cs_candidate cand = CSCandidates(cs_draw.candidates).c[entry.x];
		uint64_t page = cs_draw.pool + uint64_t(cand.page) * 16ul;
		cs_cluster c = CSClusters(page).c[entry.y];
		uint triangle = uint(gl_VertexIndex) / 3u;
		uint triangle_count = c.counts & 0xFFFFu;
		out_batch = cand.batch;
		out_instance = cand.row;
		out_triangle = triangle;

		if (triangle >= triangle_count) {
			gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
			return;
		}

		uint vertex_count = c.counts >> 16u;
		uint bx = c.bits & 0xFFu;
		uint by = (c.bits >> 8u) & 0xFFu;
		uint bz = (c.bits >> 16u) & 0xFFu;
		uint bu = c.bits >> 24u;
		uint bv = c.bits2 & 0xFFu;
		uint index_bits = (c.bits2 >> 8u) & 0xFFu;
		uint vertex_bits = (c.bits2 >> 16u) & 0xFFu;
		uint64_t words = page + uint64_t(c.data_offset);
		uint64_t index_words = words + uint64_t(((vertex_count * vertex_bits + 31u) >> 5u) * 4u);
		uint local_vertex = cs_bits(index_words, uint(gl_VertexIndex) * index_bits, index_bits);
		uint at = local_vertex * vertex_bits;
		ivec3 q;
		q.x = int(cs_bits(words, at, bx)) + c.pos_min.x;
		at += bx;
		q.y = int(cs_bits(words, at, by)) + c.pos_min.y;
		at += by;
		q.z = int(cs_bits(words, at, bz)) + c.pos_min.z;
		at += bz;
		ivec2 quv;
		quv.x = int(cs_bits(words, at, bu)) + c.uv_min.x;
		at += bu;
		quv.y = int(cs_bits(words, at, bv)) + c.uv_min.y;
		at += bv;
		vec2 n;
		n.x = float(cs_bits(words, at, ]=] .. format.NORMAL_BITS .. [=[u)) / ]=] .. (
		2 ^ format.NORMAL_BITS - 1
	) .. [=[.0 * 2.0 - 1.0;
		at += ]=] .. format.NORMAL_BITS .. [=[u;
		n.y = float(cs_bits(words, at, ]=] .. format.NORMAL_BITS .. [=[u)) / ]=] .. (
		2 ^ format.NORMAL_BITS - 1
	) .. [=[.0 * 2.0 - 1.0;
		at += ]=] .. format.NORMAL_BITS .. [=[u;
		vec2 tn;
		tn.x = float(cs_bits(words, at, ]=] .. format.TANGENT_BITS .. [=[u)) / ]=] .. (
		2 ^ format.TANGENT_BITS - 1
	) .. [=[.0 * 2.0 - 1.0;
		at += ]=] .. format.TANGENT_BITS .. [=[u;
		tn.y = float(cs_bits(words, at, ]=] .. format.TANGENT_BITS .. [=[u)) / ]=] .. (
		2 ^ format.TANGENT_BITS - 1
	) .. [=[.0 * 2.0 - 1.0;
		at += ]=] .. format.TANGENT_BITS .. [=[u;
		float tangent_sign = cs_bits(words, at, 1u) == 1u ? -1.0 : 1.0;
		cs_geometry geometry = CSGeometries(cs_draw.geometries).g[cand.geometry];
		vec3 local_position = geometry.pos_min + vec3(q) * geometry.pos_step;
		vec2 uv = vec2(quv) * geometry.uv_step;
		vec3 normal = cs_unfold(n);
		vec4 tangent = vec4(cs_unfold(tn), tangent_sign);
		tlas_instance t = CSTLAS(cs_draw.tlas).t[cand.row];
		instance_data inst = CSInstanceData(cs_draw.instance_data).d[cand.row];
		mat4 world = world_from(t.m, 0.0, inst.dynamic, inst.overlay);
		mat4 prev_world = world_from(CSRaster(cs_draw.raster).r[cand.row].prev, 0.0, inst.dynamic, inst.overlay);
		vec4 world_position = world * vec4(local_position, 1.0);
		vec4 prev_world_position = prev_world * vec4(local_position, 1.0);
		mat3 normal_matrix = transpose(inverse(mat3(world)));
		vec3 world_normal = normalize(normal_matrix * normal);
		out_position = world_position.xyz;
		out_normal = world_normal;
		out_tangent = vec4(normalize(mat3(world) * tangent.xyz), determinant(mat3(world)) < 0.0 ? -tangent.w : tangent.w);
		out_uv = uv;
		out_texture_blend = 0.0;
		out_vertex_color = vec4(1.0);
		out_prev_position = prev_world_position.xyz;
		out_lod_fade = 0.0;
		out_instance_overlay = world[1][3];
		out_instance_dynamic = world[2][3];
		bool local_effect = world[1][3] > 0.0;
		out_effect_position = local_effect ? local_position : world_position.xyz;
		out_effect_normal = local_effect ? normalize(normal) : world_normal;
		gl_Position = gbuffer_data.projection * gbuffer_data.view * vec4(world_position.xyz, 1.0);
	}
]=]

function cluster_stream.CreateVertexStage(uniform_buffers, bits)
	local outputs = model_pipeline.GetVertexStageOutputs{
		normal = true,
		tangent = true,
		uv = true,
		texture_blend = true,
		vertex_color = true,
		velocity = true,
		lod_fade = true,
		instance_overlay = true,
		instance_dynamic = true,
		effect_space = true,
	}
	local batch_location = #outputs
	local buffers = table.copy(uniform_buffers)
	buffers[#buffers + 1] = draw_block
	return {
		outputs = outputs,
		batch_location = batch_location,
		uniform_buffers = buffers,
		custom_declarations = model_pipeline.BuildPBRBatchRecordGlsl() .. GLSL .. draw.WORLD_FROM_GLSL .. shader_features.GetDefines(bits) .. string.format(
				"layout(location = %d) flat out uint out_batch;\nlayout(location = %d) flat out uint out_instance;\nlayout(location = %d) flat out uint out_triangle;\n",
				batch_location,
				batch_location + 1,
				batch_location + 2
			),
		shader = VERTEX_MAIN,
	}
end

function cluster_stream.Draw(pipeline, cmd)
	if not state.ready or not render3d.IsPipelineReady(pipeline) then return end

	batch_table = batch_table or gbuffer_instancing.NewBatchTable("cluster_stream_batches")
	pipeline.draw_batches_address = batch_table:Update(pipeline, batch_list, batch_serial, system.GetFrameNumber())
	pipeline.draw_instances_address = 0
	pipeline.draw_prev_instances_address = 0
	pipeline.draw_groups_address = 0
	pipeline:UploadConstants()
	cmd:SetCullMode(orientation.CULL_MODE)
	cmd:DrawIndirect(state.state_buffer, SET_FRONT * 16, 1, 16)
	cmd:SetCullMode("none")
	cmd:DrawIndirect(state.state_buffer, SET_DOUBLE_SIDED * 16, 1, 16)
	cmd:SetCullMode(orientation.CULL_MODE == "front" and "back" or "front")
	cmd:DrawIndirect(state.state_buffer, SET_MIRRORED * 16, 1, 16)
	cmd:SetCullMode(orientation.CULL_MODE)
end

function cluster_stream.GetStats()
	stats.pool_used = state.used_units and state.used_units * PAGE_UNIT or 0
	stats.pool_size = state.pool_units and state.pool_units * PAGE_UNIT or 0
	return stats
end

return cluster_stream
