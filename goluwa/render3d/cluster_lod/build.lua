local ffi = require("ffi")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local hierarchy = import("goluwa/render3d/cluster_lod/hierarchy.lua")
local format = import("goluwa/render3d/cluster_lod/format.lua")
local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min
local build = {}
local POSITION_RANGE = 200001
local POSITION_STEP = 5e-6
local NORMAL_SCALE = 500
local UV_SCALE = 20000
local POSITION = vertex_layout.GetFloatOffset("position")
local NORMAL = vertex_layout.GetFloatOffset("normal")
local UV = vertex_layout.GetFloatOffset("uv")
local COLOR = vertex_layout.GetFloatOffset("vertex_color")
local PIVOT = vertex_layout.GetFloatOffset("pivot")
local BEND_VALUES = 6
local PIVOT_SCALE = 10
local PIVOT_STEP = 1e-4
local COLOR_SCALE = 50
local FLOAT_STRIDE = vertex_layout.FloatStride
local FloatPointer = ffi.typeof("const float *")
local UInt16Pointer = ffi.typeof("const uint16_t *")
local UInt32Pointer = ffi.typeof("const uint32_t *")

function build.PrepareMesh(input)
	local vertex_count, index_count = input.vertex_count, input.index_count
	local floats = ffi.cast(FloatPointer, input.vertices)
	local indices = ffi.cast(input.index_size == 2 and UInt16Pointer or UInt32Pointer, input.indices)
	local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge

	for v = 0, vertex_count - 1 do
		local o = v * FLOAT_STRIDE + POSITION
		local x, y, z = floats[o], floats[o + 1], floats[o + 2]
		x0, x1 = min(x0, x), max(x1, x)
		y0, y1 = min(y0, y), max(y1, y)
		z0, z1 = min(z0, z), max(z1, z)
	end

	local diagonal = sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2 + (z1 - z0) ^ 2)

	if diagonal == 0 then return nil end

	local step = diagonal * POSITION_STEP
	local has_bend = false

	for v = 0, vertex_count - 1 do
		if floats[v * FLOAT_STRIDE + PIVOT + 3] > 0.5 then
			has_bend = true

			break
		end
	end

	local key_size = has_bend and 11 or 5
	local position_ids, position_of = {}, ffi.new("int32_t[?]", vertex_count)
	local px, py, pz = {}, {}, {}
	local position_count = 0

	for v = 0, vertex_count - 1 do
		local o = v * FLOAT_STRIDE + POSITION
		local x, y, z = floats[o], floats[o + 1], floats[o + 2]
		local key = (
				floor((x - x0) / step) * POSITION_RANGE + floor((y - y0) / step)
			) * POSITION_RANGE + floor((z - z0) / step)
		local id = position_ids[key]

		if not id then
			id = position_count
			position_count = position_count + 1
			position_ids[key] = id
			px[position_count], py[position_count], pz[position_count] = x, y, z
		end

		position_of[v] = id
	end

	local first_wedge = ffi.new("int32_t[?]", position_count)
	local next_wedge = ffi.new("int32_t[?]", vertex_count)
	local wedge_of = ffi.new("int32_t[?]", vertex_count)
	local wedge_rep = ffi.new("int32_t[?]", vertex_count)
	local nq = ffi.new("int32_t[?]", vertex_count * key_size)
	local wedge_count = 0

	for i = 0, position_count - 1 do
		first_wedge[i] = -1
	end

	for v = 0, vertex_count - 1 do
		local o = v * FLOAT_STRIDE
		local n1 = floor(floats[o + NORMAL] * NORMAL_SCALE + 0.5)
		local n2 = floor(floats[o + NORMAL + 1] * NORMAL_SCALE + 0.5)
		local n3 = floor(floats[o + NORMAL + 2] * NORMAL_SCALE + 0.5)
		local u1 = floor(floats[o + UV] * UV_SCALE + 0.5)
		local u2 = floor(floats[o + UV + 1] * UV_SCALE + 0.5)
		local p = position_of[v]
		local b1, b2, b3, b4, b5, b6 = 0, 0, 0, 0, 0, 0

		if has_bend then
			b1 = floor(floats[o + COLOR] * COLOR_SCALE + 0.5)
			b2 = floor(floats[o + COLOR + 1] * COLOR_SCALE + 0.5)
			b3 = floor(floats[o + COLOR + 2] * COLOR_SCALE + 0.5)
			b4 = floor(floats[o + PIVOT] / (diagonal * PIVOT_STEP) + 0.5)
			b5 = floor(floats[o + PIVOT + 1] / (diagonal * PIVOT_STEP) + 0.5)
			b6 = floor(floats[o + PIVOT + 2] / (diagonal * PIVOT_STEP) + 0.5)
		end

		local w = first_wedge[p]

		while w >= 0 do
			local q = w * key_size

			if
				nq[q] == n1 and
				nq[q + 1] == n2 and
				nq[q + 2] == n3 and
				nq[q + 3] == u1 and
				nq[q + 4] == u2 and
				(
					not has_bend or
					(
						nq[q + 5] == b1 and
						nq[q + 6] == b2 and
						nq[q + 7] == b3 and
						nq[q + 8] == b4 and
						nq[q + 9] == b5 and
						nq[q + 10] == b6
					)
				)
			then
				break
			end

			w = next_wedge[w]
		end

		if w < 0 then
			w = wedge_count
			wedge_count = wedge_count + 1
			local q = w * key_size
			nq[q], nq[q + 1], nq[q + 2], nq[q + 3], nq[q + 4] = n1, n2, n3, u1, u2

			if has_bend then
				nq[q + 5], nq[q + 6], nq[q + 7], nq[q + 8], nq[q + 9], nq[q + 10] = b1, b2, b3, b4, b5, b6
			end

			wedge_rep[w] = v
			next_wedge[w] = first_wedge[p]
			first_wedge[p] = w
		end

		wedge_of[v] = w
	end

	local triangles = index_count / 3
	local tri_position = ffi.new("uint32_t[?]", triangles * 3)
	local tri_wedge = ffi.new("int32_t[?]", triangles * 3)
	local kept = 0

	for t = 0, triangles - 1 do
		local v0, v1, v2 = indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]
		local a, b, c = position_of[v0], position_of[v1], position_of[v2]

		if a ~= b and b ~= c and c ~= a then
			tri_position[kept * 3], tri_position[kept * 3 + 1], tri_position[kept * 3 + 2] = a, b, c
			tri_wedge[kept * 3], tri_wedge[kept * 3 + 1], tri_wedge[kept * 3 + 2] = wedge_of[v0], wedge_of[v1], wedge_of[v2]
			kept = kept + 1
		end
	end

	if kept == 0 then return nil end

	local parent = ffi.new("int32_t[?]", kept)
	local first_tri = ffi.new("int32_t[?]", wedge_count)

	for t = 0, kept - 1 do
		parent[t] = t
	end

	for w = 0, wedge_count - 1 do
		first_tri[w] = -1
	end

	local function find(x)
		while parent[x] ~= x do
			parent[x] = parent[parent[x]]
			x = parent[x]
		end

		return x
	end

	for t = 0, kept - 1 do
		for k = 0, 2 do
			local w = tri_wedge[t * 3 + k]
			local f = first_tri[w]

			if f >= 0 then
				local ra, rb = find(f), find(t)

				if ra ~= rb then parent[ra] = rb end
			else
				first_tri[w] = t
			end
		end
	end

	local island_ids, island_count = {}, 0
	local island = ffi.new("uint32_t[?]", kept)

	for t = 0, kept - 1 do
		local r = find(t)
		local id = island_ids[r]

		if not id then
			id = island_count
			island_count = island_count + 1
			island_ids[r] = id
		end

		island[t] = id
	end

	local wlookup, lockpos = {}, {}

	for t = 0, kept - 1 do
		for k = 0, 2 do
			local p = tri_position[t * 3 + k]
			local key = p * island_count + island[t]
			local w = tri_wedge[t * 3 + k]
			local existing = wlookup[key]

			if existing and existing ~= w then lockpos[p] = true else wlookup[key] = w end
		end
	end

	local hardlock

	if input.locked_vertices then
		hardlock = ffi.new("uint8_t[?]", position_count)

		for v = 0, vertex_count - 1 do
			if input.locked_vertices[v] == 1 then hardlock[position_of[v]] = 1 end
		end
	end

	local mesh = {
		nv = position_count,
		hardlock = hardlock,
		nt = kept,
		x = ffi.new("double[?]", position_count),
		y = ffi.new("double[?]", position_count),
		z = ffi.new("double[?]", position_count),
		tris = tri_position,
		isl = island,
		nisl = island_count,
		wlookup = wlookup,
		lockpos = lockpos,
		wu = ffi.new("double[?]", wedge_count),
		wv = ffi.new("double[?]", wedge_count),
		wnx = ffi.new("double[?]", wedge_count),
		wny = ffi.new("double[?]", wedge_count),
		wnz = ffi.new("double[?]", wedge_count),
		wbend = has_bend and ffi.new("double[?]", wedge_count * BEND_VALUES) or nil,
	}

	for i = 1, position_count do
		mesh.x[i - 1], mesh.y[i - 1], mesh.z[i - 1] = px[i], py[i], pz[i]
	end

	for w = 0, wedge_count - 1 do
		local o = wedge_rep[w] * FLOAT_STRIDE
		local nx, ny, nz = floats[o + NORMAL], floats[o + NORMAL + 1], floats[o + NORMAL + 2]
		local l = sqrt(nx * nx + ny * ny + nz * nz)

		if l > 1e-9 then nx, ny, nz = nx / l, ny / l, nz / l end

		mesh.wu[w], mesh.wv[w] = floats[o + UV], floats[o + UV + 1]

		if has_bend then
			local q = w * BEND_VALUES
			mesh.wbend[q], mesh.wbend[q + 1], mesh.wbend[q + 2] = floats[o + COLOR], floats[o + COLOR + 1], floats[o + COLOR + 2]
			mesh.wbend[q + 3] = floats[o + PIVOT] / diagonal * PIVOT_SCALE
			mesh.wbend[q + 4] = floats[o + PIVOT + 1] / diagonal * PIVOT_SCALE
			mesh.wbend[q + 5] = floats[o + PIVOT + 2] / diagonal * PIVOT_SCALE
		end

		mesh.wnx[w], mesh.wny[w], mesh.wnz[w] = nx, ny, nz
	end

	return mesh,
	{
		wedge_rep = wedge_rep,
		first_wedge = first_wedge,
		island_count = island_count,
		has_bend = has_bend,
	}
end

-- the original vertex a cluster triangle corner stands for
function build.CornerVertex(mesh, prepared, position, island)
	local w = mesh.wlookup[position * prepared.island_count + island] or
		prepared.first_wedge[position]
	return prepared.wedge_rep[w]
end

function build.Build(input)
	local mesh, prepared = build.PrepareMesh(input)

	if not mesh then return nil end

	local wedge_rep, first_wedge, island_count, has_bend = prepared.wedge_rep, prepared.first_wedge, prepared.island_count, prepared.has_bend
	local wlookup = mesh.wlookup
	local started = os.clock()
	local result = hierarchy.Build(mesh)
	local clusters = result.clusters
	local cluster_count = #clusters
	local total = 0

	for i = 1, cluster_count do
		total = total + clusters[i].n * 3
	end

	local record_bytes = cluster_count * format.RECORD_SIZE
	local blob = ffi.new("uint8_t[?]", record_bytes + total * 4)
	local records = ffi.cast(ffi.typeof("$ *", format.ClusterRecord), blob)
	local out = ffi.cast("uint32_t *", blob + record_bytes)
	local at = 0
	local leaf_count = 0

	for i = 1, cluster_count do
		local c = clusters[i]
		local r = records[i - 1]
		local lod, bounds = c.sph_self, hierarchy.BoundingSphere(mesh, c.tris, c.n)

		for k = 0, 3 do
			r.lod[k] = lod[k + 1]
			r.bounds[k] = bounds[k + 1]
		end

		if c.sph_parent then
			for k = 0, 3 do
				r.parent[k] = c.sph_parent[k + 1]
			end

			r.parent_error = c.err_parent
		else
			r.parent_error = format.NO_PARENT_ERROR
		end

		r.error = c.err_self
		r.first_index = at
		r.index_count = c.n * 3

		if c.level == 0 then leaf_count = leaf_count + 1 end

		for t = 0, c.n - 1 do
			local isl = c.isl[t]

			for k = 0, 2 do
				local p = c.tris[t * 3 + k]
				local w = wlookup[p * island_count + isl] or first_wedge[p]
				out[at] = wedge_rep[w]
				at = at + 1
			end
		end
	end

	return {
		cluster_count = cluster_count,
		index_count = total,
		leaf_count = leaf_count,
		levels = #result.levels,
		bend = has_bend,
		stuck_groups = result.stuck_groups,
		groups = result.groups,
		seconds = os.clock() - started,
	},
	blob
end

return build
