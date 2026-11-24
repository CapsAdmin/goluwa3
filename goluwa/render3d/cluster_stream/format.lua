local ffi = require("ffi")
local format = {}
format.MAGIC = 0x31434756
format.VERSION = 3
format.NO_ERROR = 1e30
format.NORMAL_BITS = 10
format.TANGENT_BITS = 7
format.GROUP_STORED = 1
format.GROUP_ROOT = 2
format.FALLBACK_RATIO = 1 / 128
format.FALLBACK_MIN_TRIANGLES = 256
format.Header = ffi.typeof([[struct {
	uint32_t magic;
	uint32_t version;
	uint32_t group_count;
	uint32_t cluster_count;
	uint32_t link_count;
	uint32_t min_level;
	uint32_t level_count;
	uint32_t source_triangles;
	uint32_t stored_triangles;
	uint32_t stored_vertices;
	uint32_t groups_offset;
	uint32_t links_offset;
	uint32_t pad0;
	uint32_t data_offset;
	uint32_t data_size;
	uint32_t chunk_count;
	double pos_min[3];
	double pos_step;
	double uv_step;
	float aabb_min[3];
	float aabb_max[3];
	float sphere[4];
}]])
format.Group = ffi.typeof([[struct {
	float sphere[4];
	float error;
	uint32_t cluster_count;
	uint32_t pad0;
	uint32_t data_offset;
	uint32_t data_size;
	uint32_t first_link;
	uint32_t link_count;
	uint32_t level;
	uint32_t flags;
	uint32_t triangle_count;
	uint32_t vertex_count;
	uint32_t pad;
}]])
format.Cluster = ffi.typeof([[struct {
	float bounds[4];
	float lod_sphere[4];
	float lod_error;
	int32_t gen;
	uint32_t group;
	uint32_t data_offset;
	uint16_t triangle_count;
	uint16_t vertex_count;
	int32_t pos_min[3];
	int32_t uv_min[2];
	uint8_t pos_bits[3];
	uint8_t uv_bits[2];
	uint8_t index_bits;
	uint8_t vertex_bits;
	uint8_t pad;
}]])
format.HEADER_SIZE = ffi.sizeof(format.Header)
format.GROUP_SIZE = ffi.sizeof(format.Group)
format.CLUSTER_SIZE = ffi.sizeof(format.Cluster)
format.HeaderPointer = ffi.typeof("$ *", format.Header)
format.GroupPointer = ffi.typeof("$ *", format.Group)
format.ClusterPointer = ffi.typeof("$ *", format.Cluster)
assert(format.GROUP_SIZE == 64)
assert(format.CLUSTER_SIZE == 80)

do
	local bit = require("bit")
	local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
	local abs, sqrt = math.abs, math.sqrt
	local u32_ptr_t = ffi.typeof("const uint32_t *")

	local function get_bits(words, at, count)
		if count == 0 then return 0 end

		local word = rshift(at, 5)
		local shift = band(at, 31)
		local v = rshift(words[word], shift)

		if shift + count > 32 then v = bor(v, lshift(words[word + 1], 32 - shift)) end

		v = band(v, lshift(1, count) - 1)
		return v < 0 and v + 4294967296 or v
	end

	format.GetBits = get_bits

	local function unfold(px, py)
		local x, y, z = px, py, 1 - abs(px) - abs(py)
		local t = math.max(-z, 0)
		x = x >= 0 and x - t or x + t
		y = y >= 0 and y - t or y + t
		local length = sqrt(x * x + y * y + z * z)
		return x / length, y / length, z / length
	end

	local NORMAL_MAX = 2 ^ format.NORMAL_BITS - 1
	local TANGENT_MAX = 2 ^ format.TANGENT_BITS - 1

	function format.DecodeCluster(header, page, cluster, out, out_first, corners)
		local words = ffi.cast(u32_ptr_t, ffi.cast("const uint8_t *", page) + cluster.data_offset)
		local bx, by, bz = cluster.pos_bits[0], cluster.pos_bits[1], cluster.pos_bits[2]
		local bu, bv = cluster.uv_bits[0], cluster.uv_bits[1]
		local step, uv_step = header.pos_step, header.uv_step
		local vertex_bits = cluster.vertex_bits

		for l = 0, cluster.vertex_count - 1 do
			local at = l * vertex_bits
			local qx = get_bits(words, at, bx) + cluster.pos_min[0]
			at = at + bx
			local qy = get_bits(words, at, by) + cluster.pos_min[1]
			at = at + by
			local qz = get_bits(words, at, bz) + cluster.pos_min[2]
			at = at + bz
			local qu = get_bits(words, at, bu) + cluster.uv_min[0]
			at = at + bu
			local qv = get_bits(words, at, bv) + cluster.uv_min[1]
			at = at + bv
			local nx = get_bits(words, at, format.NORMAL_BITS) / NORMAL_MAX * 2 - 1
			at = at + format.NORMAL_BITS
			local ny = get_bits(words, at, format.NORMAL_BITS) / NORMAL_MAX * 2 - 1
			at = at + format.NORMAL_BITS
			local tx = get_bits(words, at, format.TANGENT_BITS) / TANGENT_MAX * 2 - 1
			at = at + format.TANGENT_BITS
			local ty = get_bits(words, at, format.TANGENT_BITS) / TANGENT_MAX * 2 - 1
			at = at + format.TANGENT_BITS
			local sign = get_bits(words, at, 1)
			local v = out[out_first + l]
			v.position[0] = header.pos_min[0] + qx * step
			v.position[1] = header.pos_min[1] + qy * step
			v.position[2] = header.pos_min[2] + qz * step
			v.uv[0], v.uv[1] = qu * uv_step, qv * uv_step
			v.normal[0], v.normal[1], v.normal[2] = unfold(nx, ny)
			v.tangent[0], v.tangent[1], v.tangent[2] = unfold(tx, ty)
			v.tangent[3] = sign == 1 and -1 or 1
		end

		local index_words = words + math.ceil(cluster.vertex_count * vertex_bits / 32)
		local index_bits = cluster.index_bits

		for i = 0, cluster.triangle_count * 3 - 1 do
			corners[i] = get_bits(index_words, i * index_bits, index_bits)
		end
	end
end

function format.Read(blob, size)
	local p = ffi.cast("const uint8_t *", blob)
	local header = ffi.cast(format.HeaderPointer, p)

	if size < format.HEADER_SIZE or header.magic ~= format.MAGIC then
		return nil, "not a cluster stream file"
	end

	if header.version ~= format.VERSION then
		return nil,
		"cluster stream file version " .. header.version .. ", expected " .. format.VERSION
	end

	return {
		header = header,
		groups = ffi.cast(format.GroupPointer, p + header.groups_offset),
		links = ffi.cast("const uint32_t *", p + header.links_offset),
		data = p + header.data_offset,
	}
end

return format
