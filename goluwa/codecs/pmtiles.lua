local ffi = require("ffi")
local bit = require("bit")
local deflate = import("goluwa/codecs/deflate.lua")
local band, bxor, lshift = bit.band, bit.bxor, bit.lshift
-- reads PMTiles v3 archives: the header, directories and tile ids; fetching the bytes is the caller's
local pmtiles = {}
pmtiles.HEADER_SIZE = 127
-- the root directory is within this many bytes of the start of every archive
pmtiles.ROOT_READ_SIZE = 16384
pmtiles.COMPRESSION = {[0] = "unknown", "none", "gzip", "brotli", "zstd"}
pmtiles.TILE_TYPE = {[0] = "unknown", "mvt", "png", "jpeg", "webp", "avif"}

local function u64(data, offset)
	local lo = data[offset] + data[offset + 1] * 256 + data[offset + 2] * 65536 + data[offset + 3] * 16777216
	local hi = data[offset + 4] + data[offset + 5] * 256 + data[offset + 6] * 65536 + data[offset + 7] * 16777216
	return hi * 4294967296 + lo
end

local function i32(data, offset)
	local v = data[offset] + data[offset + 1] * 256 + data[offset + 2] * 65536 + data[offset + 3] * 16777216
	return v >= 2147483648 and v - 4294967296 or v
end

function pmtiles.ParseHeader(str)
	assert(#str >= pmtiles.HEADER_SIZE, "pmtiles: header is too short")
	assert(str:sub(1, 7) == "PMTiles", "pmtiles: not a pmtiles archive")
	local data = ffi.cast("const uint8_t *", str)
	assert(data[7] == 3, "pmtiles: only version 3 is supported")
	return {
		root_offset = u64(data, 8),
		root_length = u64(data, 16),
		metadata_offset = u64(data, 24),
		metadata_length = u64(data, 32),
		leaf_offset = u64(data, 40),
		leaf_length = u64(data, 48),
		data_offset = u64(data, 56),
		data_length = u64(data, 64),
		addressed_tiles = u64(data, 72),
		tile_entries = u64(data, 80),
		tile_contents = u64(data, 88),
		clustered = data[96] == 1,
		internal_compression = pmtiles.COMPRESSION[data[97]],
		tile_compression = pmtiles.COMPRESSION[data[98]],
		tile_type = pmtiles.TILE_TYPE[data[99]],
		min_zoom = data[100],
		max_zoom = data[101],
		min_lon = i32(data, 102) / 1e7,
		min_lat = i32(data, 106) / 1e7,
		max_lon = i32(data, 110) / 1e7,
		max_lat = i32(data, 114) / 1e7,
	}
end

-- the hilbert curve id of a tile, counting every tile of the lower zooms first
function pmtiles.TileId(z, x, y)
	local id = (4 ^ z - 1) / 3
	local s = z > 0 and 2 ^ (z - 1) or 0

	while s >= 1 do
		local rx = band(x, s) ~= 0 and 1 or 0
		local ry = band(y, s) ~= 0 and 1 or 0
		id = id + s * s * bxor(3 * rx, ry)
		x, y = band(x, s - 1), band(y, s - 1)

		if ry == 0 then
			if rx == 1 then x, y = s - 1 - x, s - 1 - y end

			x, y = y, x
		end

		s = s / 2
	end

	return id
end

-- the entries of a directory (decompressed with the header's internal compression) as parallel arrays
function pmtiles.DecodeDirectory(str, compression)
	if compression == "gzip" then
		local out, size = deflate.Decode(str, "gzip")
		str = ffi.string(out.Buffer, size)
	else
		assert(
			compression == "none",
			"pmtiles: unsupported directory compression " .. tostring(compression)
		)
	end

	local data = ffi.cast("const uint8_t *", str)
	local length = #str
	local pos = 0

	local function varint()
		local value, scale = 0, 1

		while true do
			assert(pos < length, "pmtiles: truncated directory")
			local byte = data[pos]
			pos = pos + 1
			value = value + band(byte, 0x7f) * scale

			if byte < 0x80 then return value end

			scale = scale * 128
		end
	end

	local count = varint()
	local ids, runs, lengths, offsets = {}, {}, {}, {}
	local last = 0

	for i = 1, count do
		last = last + varint()
		ids[i] = last
	end

	for i = 1, count do
		runs[i] = varint()
	end

	for i = 1, count do
		lengths[i] = varint()
	end

	for i = 1, count do
		local v = varint()
		offsets[i] = (v == 0 and i > 1) and offsets[i - 1] + lengths[i - 1] or v - 1
	end

	return {count = count, ids = ids, runs = runs, lengths = lengths, offsets = offsets}
end

-- the entry index of a tile id in a directory: a tile (run > 0) or a leaf directory (run == 0), nil when absent
function pmtiles.FindEntry(directory, id)
	local ids = directory.ids
	local low, high = 1, directory.count

	while low <= high do
		local mid = math.floor((low + high) / 2)

		if ids[mid] < id then
			low = mid + 1
		elseif ids[mid] > id then
			high = mid - 1
		else
			return mid
		end
	end

	if high >= 1 then
		local run = directory.runs[high]

		if run == 0 or id - ids[high] < run then return high end
	end
end

return pmtiles
