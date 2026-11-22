local T = import("test/environment.lua")
local pmtiles = import("goluwa/codecs/pmtiles.lua")

local function varint(n)
	local out = {}

	repeat
		local byte = n % 128
		n = math.floor(n / 128)
		out[#out + 1] = string.char(n > 0 and byte + 128 or byte)	
	until n == 0

	return table.concat(out)
end

-- entries {id, run, length, offset}, encoded as the spec says: delta ids, runs, lengths, then offsets (0 when contiguous)
local function encode_directory(entries)
	local parts = {varint(#entries)}
	local last = 0

	for _, e in ipairs(entries) do
		parts[#parts + 1] = varint(e[1] - last)
		last = e[1]
	end

	for _, e in ipairs(entries) do
		parts[#parts + 1] = varint(e[2])
	end

	for _, e in ipairs(entries) do
		parts[#parts + 1] = varint(e[3])
	end

	for i, e in ipairs(entries) do
		local previous = entries[i - 1]
		parts[#parts + 1] = varint((previous and previous[4] + previous[3] == e[4]) and 0 or e[4] + 1)
	end

	return table.concat(parts)
end

T.Test("pmtiles tile ids follow the hilbert curve per zoom", function()
	T(pmtiles.TileId(0, 0, 0))["=="](0)
	T(pmtiles.TileId(1, 0, 0))["=="](1)
	T(pmtiles.TileId(1, 0, 1))["=="](2)
	T(pmtiles.TileId(1, 1, 1))["=="](3)
	T(pmtiles.TileId(1, 1, 0))["=="](4)
	T(pmtiles.TileId(2, 0, 0))["=="](5)
	T(pmtiles.TileId(12, 0, 0))["=="]((4 ^ 12 - 1) / 3)
	local seen = {}

	for x = 0, 7 do
		for y = 0, 7 do
			local id = pmtiles.TileId(3, x, y) - (4 ^ 3 - 1) / 3
			T(id >= 0 and id < 64)["=="](true)
			T(seen[id])["=="](nil)
			seen[id] = true
		end
	end
end)

T.Test("pmtiles directories decode runs, contiguous offsets and leaves", function()
	local directory = pmtiles.DecodeDirectory(
		encode_directory{
			{10, 1, 100, 0},
			{11, 3, 50, 100},
			{20, 0, 300, 5000},
			{40, 1, 7, 150},
		},
		"none"
	)
	T(directory.count)["=="](4)
	T(directory.offsets[2])["=="](100)
	T(directory.offsets[3])["=="](5000)
	T(directory.offsets[4])["=="](150)
	T(pmtiles.FindEntry(directory, 10))["=="](1)
	T(pmtiles.FindEntry(directory, 13))["=="](2)
	T(pmtiles.FindEntry(directory, 14))["=="](nil)
	T(pmtiles.FindEntry(directory, 25))["=="](3)
	T(directory.runs[3])["=="](0)
	T(pmtiles.FindEntry(directory, 40))["=="](4)
	T(pmtiles.FindEntry(directory, 41))["=="](nil)
	T(pmtiles.FindEntry(directory, 5))["=="](nil)
end)
