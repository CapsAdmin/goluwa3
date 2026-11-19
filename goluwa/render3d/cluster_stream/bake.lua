local ffi = require("ffi")
local bit = require("bit")
local build = import("goluwa/render3d/cluster_lod/build.lua")
local hierarchy = import("goluwa/render3d/cluster_lod/hierarchy.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local gltf_vertices = import("goluwa/render3d/gltf_vertices.lua")
local format = import("goluwa/render3d/cluster_stream/format.lua")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local floor, ceil, max, min, abs, sqrt = math.floor, math.ceil, math.max, math.min, math.abs, math.sqrt
local bake = {}
bake.CHUNK_TRIANGLES = 1000000
local POSITION_GRID_BITS = 18
local UV_MAX_BITS = 22
local UV_FINEST_STEP = 2 ^ -16
local NORMAL_MAX = 2 ^ format.NORMAL_BITS - 1
local TANGENT_MAX = 2 ^ format.TANGENT_BITS - 1
local int32_array_t = ffi.typeof("int32_t[?]")
local uint32_array_t = ffi.typeof("uint32_t[?]")
local double_array_t = ffi.typeof("double[?]")
local bytes_t = ffi.typeof("uint8_t[?]")

local function bits_for(v)
	local n = 0

	while v > 0 do
		v = floor(v / 2)
		n = n + 1
	end

	return n
end

local function oct(x, y, z)
	local s = abs(x) + abs(y) + abs(z)

	if s == 0 then return 0, 0 end

	x, y, z = x / s, y / s, z / s

	if z < 0 then
		x, y = (1 - abs(y)) * (x >= 0 and 1 or -1), (1 - abs(x)) * (y >= 0 and 1 or -1)
	end

	return x, y
end

local function unorm(v, maximum)
	return floor((min(max(v, -1), 1) * 0.5 + 0.5) * maximum + 0.5)
end

local ByteWriter = {}
ByteWriter.__index = ByteWriter

local function byte_writer(capacity)
	return setmetatable({buffer = bytes_t(capacity), size = 0, capacity = capacity}, ByteWriter)
end

function ByteWriter:Reserve(bytes)
	if self.size + bytes <= self.capacity then return end

	local capacity = self.capacity

	while self.size + bytes > capacity do
		capacity = capacity * 2
	end

	local buffer = bytes_t(capacity)
	ffi.copy(buffer, self.buffer, self.size)
	self.buffer, self.capacity = buffer, capacity
end

function ByteWriter:Append(ptr, bytes)
	self:Reserve(bytes)
	ffi.copy(self.buffer + self.size, ptr, bytes)
	self.size = self.size + bytes
end

-- writes `count` bits of `value` (count <= 24) at bit `at` of a zeroed word array
local function put_bits(words, at, value, count)
	if count == 0 then return end

	local word = rshift(at, 5)
	local shift = band(at, 31)
	words[word] = bor(words[word], lshift(value, shift))

	if shift + count > 32 then
		words[word + 1] = bor(words[word + 1], rshift(value, 32 - shift))
	end
end

local function encode_cluster(c, mesh, prepared, vertices, grid, out, scratch)
	local local_of, local_list = scratch.local_of, scratch.local_list
	local vertex_count = 0
	local n = c.n
	local corners = scratch.corners

	for t = 0, n - 1 do
		local isl = c.isl[t]

		for k = 0, 2 do
			local v = build.CornerVertex(mesh, prepared, c.tris[t * 3 + k], isl)
			local l = local_of[v]

			if l < 0 then
				l = vertex_count
				local_of[v] = l
				local_list[l] = v
				vertex_count = vertex_count + 1
			end

			corners[t * 3 + k] = l
		end
	end

	local qx, qy, qz, qu, qv = scratch.qx, scratch.qy, scratch.qz, scratch.qu, scratch.qv
	local x0, y0, z0, u0, v0 = math.huge, math.huge, math.huge, math.huge, math.huge
	local x1, y1, z1, u1, v1 = -math.huge, -math.huge, -math.huge, -math.huge, -math.huge
	local pos_min, pos_step, uv_step = grid.pos_min, grid.pos_step, grid.uv_step

	for l = 0, vertex_count - 1 do
		local vertex = vertices[local_list[l]]
		local p, uv = vertex.position, vertex.uv
		local x = floor((p[0] - pos_min[1]) / pos_step + 0.5)
		local y = floor((p[1] - pos_min[2]) / pos_step + 0.5)
		local z = floor((p[2] - pos_min[3]) / pos_step + 0.5)
		local u = floor(uv[0] / uv_step + 0.5)
		local v = floor(uv[1] / uv_step + 0.5)
		qx[l], qy[l], qz[l], qu[l], qv[l] = x, y, z, u, v
		x0, y0, z0, u0, v0 = min(x0, x), min(y0, y), min(z0, z), min(u0, u), min(v0, v)
		x1, y1, z1, u1, v1 = max(x1, x), max(y1, y), max(z1, z), max(u1, u), max(v1, v)
	end

	local bx, by, bz = bits_for(x1 - x0), bits_for(y1 - y0), bits_for(z1 - z0)
	local bu, bv = bits_for(u1 - u0), bits_for(v1 - v0)
	assert(
		bx <= 24 and by <= 24 and bz <= 24 and bu <= 24 and bv <= 24,
		"cluster spans too many grid steps"
	)
	local vertex_bits = bx + by + bz + bu + bv + format.NORMAL_BITS * 2 + format.TANGENT_BITS * 2 + 1
	local index_bits = max(bits_for(vertex_count - 1), 1)
	local vertex_words = ceil(vertex_count * vertex_bits / 32)
	local bytes = (vertex_words + ceil(n * 3 * index_bits / 32)) * 4
	out:Reserve(bytes)
	local data_offset = out.size
	ffi.fill(out.buffer + data_offset, bytes, 0)
	local words = ffi.cast("int32_t *", out.buffer + data_offset)

	for l = 0, vertex_count - 1 do
		local vertex = vertices[local_list[l]]
		local at = l * vertex_bits
		put_bits(words, at, qx[l] - x0, bx)
		at = at + bx
		put_bits(words, at, qy[l] - y0, by)
		at = at + by
		put_bits(words, at, qz[l] - z0, bz)
		at = at + bz
		put_bits(words, at, qu[l] - u0, bu)
		at = at + bu
		put_bits(words, at, qv[l] - v0, bv)
		at = at + bv
		local nrm, tan = vertex.normal, vertex.tangent
		local ox, oy = oct(nrm[0], nrm[1], nrm[2])
		put_bits(words, at, unorm(ox, NORMAL_MAX), format.NORMAL_BITS)
		at = at + format.NORMAL_BITS
		put_bits(words, at, unorm(oy, NORMAL_MAX), format.NORMAL_BITS)
		at = at + format.NORMAL_BITS
		ox, oy = oct(tan[0], tan[1], tan[2])
		put_bits(words, at, unorm(ox, TANGENT_MAX), format.TANGENT_BITS)
		at = at + format.TANGENT_BITS
		put_bits(words, at, unorm(oy, TANGENT_MAX), format.TANGENT_BITS)
		at = at + format.TANGENT_BITS
		put_bits(words, at, tan[3] < 0 and 1 or 0, 1)
	end

	local index_words = words + vertex_words

	for i = 0, n * 3 - 1 do
		put_bits(index_words, i * index_bits, corners[i], index_bits)
	end

	out.size = out.size + bytes

	for l = 0, vertex_count - 1 do
		local_of[local_list[l]] = -1
	end

	return {
		data_offset = data_offset,
		vertex_count = vertex_count,
		pos_min = {x0, y0, z0},
		uv_min = {u0, v0},
		pos_bits = {bx, by, bz},
		uv_bits = {bu, bv},
		index_bits = index_bits,
		vertex_bits = vertex_bits,
	}
end

local function chunk_triangles(input, chunk_size)
	local triangles = input.index_count / 3
	local indices = input.indices

	if triangles <= chunk_size then
		return {{first = 0, count = triangles, ids = nil}}
	end

	local pos = input.position
	local cx, cy, cz = double_array_t(triangles), double_array_t(triangles), double_array_t(triangles)
	local ids = int32_array_t(triangles)

	for t = 0, triangles - 1 do
		local a, b, c = indices[t * 3] * 3, indices[t * 3 + 1] * 3, indices[t * 3 + 2] * 3
		cx[t] = pos[a] + pos[b] + pos[c]
		cy[t] = pos[a + 1] + pos[b + 1] + pos[c + 1]
		cz[t] = pos[a + 2] + pos[b + 2] + pos[c + 2]
		ids[t] = t
	end

	local runs = {}
	hierarchy.KdSplit(ids, cx, cy, cz, 0, triangles, chunk_size, runs)
	local chunks = {}

	for r = 1, #runs, 2 do
		chunks[#chunks + 1] = {first = runs[r], count = runs[r + 1] - runs[r], ids = ids}
	end

	return chunks
end

-- vertices used by more than one chunk: each chunk builds alone, so they must never move
local function find_chunk_borders(input, chunks)
	if #chunks == 1 then return nil end

	local indices = input.indices
	local owner = int32_array_t(input.vertex_count)
	local shared = ffi.new("uint8_t[?]", input.vertex_count)
	ffi.fill(owner, input.vertex_count * 4, 0xFF)

	for chunk_index, chunk in ipairs(chunks) do
		for i = 0, chunk.count - 1 do
			local t = chunk.ids[chunk.first + i]

			for k = 0, 2 do
				local v = indices[t * 3 + k]

				if owner[v] < 0 then
					owner[v] = chunk_index
				elseif owner[v] ~= chunk_index then
					shared[v] = 1
				end
			end
		end
	end

	return shared
end

local function chunk_primitive(input, chunk, remap, vertex_list, borders)
	local indices = input.indices
	local count = chunk.count
	local chunk_indices = uint32_array_t(count * 3)
	local vertex_count = 0

	for i = 0, count - 1 do
		local t = chunk.ids and chunk.ids[chunk.first + i] or chunk.first + i

		for k = 0, 2 do
			local v = indices[t * 3 + (input.flip_winding and (k == 0 and 0 or 3 - k) or k)]
			local l = remap[v]

			if l < 0 then
				l = vertex_count
				remap[v] = l
				vertex_list[l] = v
				vertex_count = vertex_count + 1
			end

			chunk_indices[i * 3 + k] = l
		end
	end

	local function gather(source, components)
		if not source then return nil end

		local data = ffi.new("float[?]", vertex_count * components)

		for l = 0, vertex_count - 1 do
			local o, s = l * components, vertex_list[l] * components

			for k = 0, components - 1 do
				data[o + k] = source[s + k]
			end
		end

		return {data = data, count = vertex_count}
	end

	local primitive = {
		attributes = {
			POSITION = gather(input.position, 3),
			NORMAL = gather(input.normal, 3),
			TEXCOORD_0 = gather(input.uv, 2),
			TANGENT = gather(input.tangent, 4),
		},
		indices = {data = chunk_indices, count = count * 3},
	}
	local locked

	if borders then
		locked = ffi.new("uint8_t[?]", vertex_count)

		for l = 0, vertex_count - 1 do
			locked[l] = borders[vertex_list[l]]
		end
	end

	for l = 0, vertex_count - 1 do
		remap[vertex_list[l]] = -1
	end

	return primitive, vertex_count, locked
end

-- input: position, normal, uv, tangent (float pointers, normal, uv and tangent optional), vertex_count, indices
-- (uint32 or uint16 pointer), index_count, flip_v, flip_winding, min_level. Returns the file as a string and stats
function bake.Bake(input)
	local pos = input.position
	local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge

	for v = 0, input.vertex_count - 1 do
		local x, y, z = pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2]
		x0, y0, z0 = min(x0, x), min(y0, y), min(z0, z)
		x1, y1, z1 = max(x1, x), max(y1, y), max(z1, z)
	end

	local extent = max(x1 - x0, y1 - y0, z1 - z0, 1e-6)
	local uv_extent = 0

	if input.uv then
		local u0, v0, u1, v1 = math.huge, math.huge, -math.huge, -math.huge

		for v = 0, input.vertex_count - 1 do
			local u, w = input.uv[v * 2], input.uv[v * 2 + 1]
			u0, v0, u1, v1 = min(u0, u), min(v0, w), max(u1, u), max(v1, w)
		end

		uv_extent = max(u1 - u0, v1 - v0, abs(u0), abs(v0), abs(u1), abs(v1), 1 + abs(v0), 1 + abs(v1))
	end

	local grid = {
		pos_min = {x0, y0, z0},
		pos_step = 2 ^ ceil(math.log(extent / 2 ^ POSITION_GRID_BITS, 2)),
		uv_step = max(UV_FINEST_STEP, 2 ^ ceil(math.log(max(uv_extent, 1) / 2 ^ UV_MAX_BITS, 2))),
	}
	local min_level = input.min_level or 0
	local chunks = chunk_triangles(input, input.chunk_triangles or bake.CHUNK_TRIANGLES)
	local borders = find_chunk_borders(input, chunks)
	local remap = int32_array_t(input.vertex_count)
	local vertex_list = int32_array_t(input.vertex_count)

	for v = 0, input.vertex_count - 1 do
		remap[v] = -1
	end

	local payload = byte_writer(1024 * 1024)
	local groups, clusters, links = {}, {}, {}
	local stats = {levels = {}, stored_triangles = 0, stored_vertices = 0, chunks = #chunks}
	local level_count = 0
	local scratch = {
		local_list = int32_array_t(512),
		corners = int32_array_t(512 * 3),
		qx = double_array_t(512),
		qy = double_array_t(512),
		qz = double_array_t(512),
		qu = double_array_t(512),
		qv = double_array_t(512),
	}

	local function add_group(record, members)
		local group_index = #groups
		record.first_cluster = #clusters
		record.cluster_count = #members
		record.data_offset = payload.size
		record.triangle_count = 0
		record.vertex_count = 0
		groups[group_index + 1] = record

		for _, c in ipairs(members) do
			c.stored_index = #clusters
			c.stored_group = group_index
			clusters[#clusters + 1] = c
		end

		return group_index
	end

	for _, chunk in ipairs(chunks) do
		local primitive, vertex_count, locked = chunk_primitive(input, chunk, remap, vertex_list, borders)
		local vertices = gltf_vertices.Build(primitive, input.flip_v)
		local mesh, prepared = build.PrepareMesh{
			vertex_count = vertex_count,
			index_count = chunk.count * 3,
			vertices = vertices,
			indices = primitive.indices.data,
			index_size = 4,
			locked_vertices = locked,
		}

		if mesh then
			local result = hierarchy.Build(mesh)
			level_count = max(level_count, #result.levels)
			local chunk_clusters = {}

			for _, group in ipairs(result.group_list) do
				if group.level >= min_level or group.stuck then
					group.stored = true
					local record = {
						sphere = group.sphere,
						error = group.stuck and format.NO_ERROR or group.err,
						level = group.level,
						flags = format.GROUP_STORED + (group.stuck and format.GROUP_ROOT or 0),
					}
					group.index = add_group(record, group.members)

					for _, c in ipairs(group.members) do
						chunk_clusters[#chunk_clusters + 1] = c
					end
				end
			end

			for _, c in ipairs(result.clusters) do
				if not c.group and c.level >= min_level then
					local record = {
						sphere = c.sph_self,
						error = format.NO_ERROR,
						level = c.level,
						flags = format.GROUP_STORED + format.GROUP_ROOT,
					}
					add_group(record, {c})
					chunk_clusters[#chunk_clusters + 1] = c
				end
			end

			scratch.local_of = int32_array_t(vertex_count)

			for v = 0, vertex_count - 1 do
				scratch.local_of[v] = -1
			end

			for _, c in ipairs(chunk_clusters) do
				local record = groups[c.stored_group + 1]

				if not record.data_start then record.data_start = payload.size end

				c.encoded = encode_cluster(c, mesh, prepared, vertices, grid, payload, scratch)
				c.bounds = hierarchy.BoundingSphere(mesh, c.tris, c.n)
				c.gen_index = c.gen and c.gen.stored and c.gen.index or -1
				record.triangle_count = record.triangle_count + c.n
				record.vertex_count = record.vertex_count + c.encoded.vertex_count
				stats.stored_triangles = stats.stored_triangles + c.n
				stats.stored_vertices = stats.stored_vertices + c.encoded.vertex_count
				stats.levels[c.level + 1] = (stats.levels[c.level + 1] or 0) + c.n
				c.tris, c.isl = nil, nil
			end

			for _, group in ipairs(result.group_list) do
				group.members = nil
			end
		end
	end

	local parents = {}

	for _, c in ipairs(clusters) do
		if c.gen_index >= 0 then
			local set = parents[c.gen_index + 1]

			if not set then
				set = {}
				parents[c.gen_index + 1] = set
			end

			set[c.stored_group] = true
		end
	end

	for i, record in ipairs(groups) do
		record.first_link = #links
		local list = {}

		for g in pairs(parents[i] or {}) do
			list[#list + 1] = g
		end

		table.sort(list)

		for _, g in ipairs(list) do
			links[#links + 1] = g
		end

		record.link_count = #list
		record.data_offset = record.data_start or payload.size
	end

	local page_size = 0

	for i, record in ipairs(groups) do
		local next_start = groups[i + 1] and groups[i + 1].data_offset or payload.size
		record.payload_offset = record.data_offset
		record.payload_size = next_start - record.data_offset
		record.data_offset = page_size
		record.data_size = ceil((record.cluster_count * format.CLUSTER_SIZE + record.payload_size) / 16) * 16
		page_size = page_size + record.data_size
	end

	local groups_offset = format.HEADER_SIZE
	local links_offset = groups_offset + #groups * format.GROUP_SIZE
	local data_offset = ceil((links_offset + #links * 4) / 16) * 16
	local total = data_offset + page_size
	local file = bytes_t(total)
	local header = ffi.cast(format.HeaderPointer, file)
	header.magic = format.MAGIC
	header.version = format.VERSION
	header.group_count = #groups
	header.cluster_count = #clusters
	header.link_count = #links
	header.min_level = min_level
	header.level_count = level_count
	header.source_triangles = input.index_count / 3
	header.stored_triangles = stats.stored_triangles
	header.stored_vertices = stats.stored_vertices
	header.groups_offset = groups_offset
	header.links_offset = links_offset
	header.data_offset = data_offset
	header.data_size = page_size
	header.chunk_count = #chunks

	for k = 0, 2 do
		header.pos_min[k] = grid.pos_min[k + 1]
	end

	header.pos_step = grid.pos_step
	header.uv_step = grid.uv_step
	header.aabb_min[0], header.aabb_min[1], header.aabb_min[2] = x0, y0, z0
	header.aabb_max[0], header.aabb_max[1], header.aabb_max[2] = x1, y1, z1
	header.sphere[0], header.sphere[1], header.sphere[2] = (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2
	header.sphere[3] = sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2 + (z1 - z0) ^ 2) / 2
	local group_records = ffi.cast(format.GroupPointer, file + groups_offset)

	for i, record in ipairs(groups) do
		local g = group_records[i - 1]

		for k = 0, 3 do
			g.sphere[k] = record.sphere[k + 1]
		end

		g.error = record.error
		g.cluster_count = record.cluster_count
		g.data_offset = record.data_offset
		g.data_size = record.data_size
		g.first_link = record.first_link
		g.link_count = record.link_count
		g.level = record.level
		g.flags = record.flags
		g.triangle_count = record.triangle_count
		g.vertex_count = record.vertex_count
		local page = file + data_offset + record.data_offset
		local records_size = record.cluster_count * format.CLUSTER_SIZE
		ffi.copy(page + records_size, payload.buffer + record.payload_offset, record.payload_size)
		local cluster_records = ffi.cast(format.ClusterPointer, page)

		for j = 0, record.cluster_count - 1 do
			local c = clusters[record.first_cluster + j + 1]
			local r = cluster_records[j]
			local e = c.encoded
			local lod = c.sph_self or c.bounds

			for k = 0, 3 do
				r.bounds[k] = c.bounds[k + 1]
				r.lod_sphere[k] = lod[k + 1]
			end

			r.lod_error = c.err_self or 0
			r.gen = c.gen_index
			r.group = c.stored_group
			r.data_offset = records_size + e.data_offset - record.payload_offset
			r.triangle_count = c.n
			r.vertex_count = e.vertex_count

			for k = 0, 2 do
				r.pos_min[k] = e.pos_min[k + 1]
				r.pos_bits[k] = e.pos_bits[k + 1]
			end

			r.uv_min[0], r.uv_min[1] = e.uv_min[1], e.uv_min[2]
			r.uv_bits[0], r.uv_bits[1] = e.uv_bits[1], e.uv_bits[2]
			r.index_bits = e.index_bits
			r.vertex_bits = e.vertex_bits
		end
	end

	local link_words = ffi.cast("uint32_t *", file + links_offset)

	for i, g in ipairs(links) do
		link_words[i - 1] = g
	end

	stats.groups = #groups
	stats.clusters = #clusters
	stats.bytes = total
	stats.level_count = level_count
	return ffi.string(file, total), stats
end

return bake
