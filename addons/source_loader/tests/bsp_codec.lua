local T = import("test/environment.lua")
local ffi = require("ffi")
local buffer = require("string.buffer")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local bsp = import("goluwa/codecs/bsp.lua")
local mounted = steam.FindSourceGame("gmod") and steam.MountSourceGame("gmod")

local function from_hex(hex)
	return (hex:gsub("%x%x", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

local compressed_lump = from_hex(
	"4c5a4d4129000000270000005d000001000036984aeeeec66516f1867ffe93ad824fde716325a65271f317eb31f50b5ed3ee7fff2db94000"
)
local lump_text = from_hex(
	"6d6174657269616c732f746573742f627269636b006d6174657269616c732f746573742f77616c6c00"
)

local function build_bsp(lumps)
	local out = ffi.new("uint8_t[?]", 8 + 64 * 16 + 4)
	ffi.copy(out, "VBSP", 4)
	ffi.cast("int32_t *", out)[1] = 20
	local body = {}
	local offset = 8 + 64 * 16 + 4

	for index, lump in pairs(lumps) do
		local entry = ffi.cast("int32_t *", out + 8 + (index - 1) * 16)
		entry[0] = offset
		entry[1] = #lump.data
		entry[2] = 0
		entry[3] = lump.uncompressed or 0
		body[#body + 1] = lump.data
		offset = offset + #lump.data
	end

	return ffi.string(out, 8 + 64 * 16 + 4) .. table.concat(body)
end

local function int32(values)
	return ffi.string(ffi.new("int32_t[?]", #values, values), #values * 4)
end

T.Test("bsp codec decodes lzma compressed lumps", function()
	local empty_game_lump = int32{0}
	local string_table = int32{0, 21}
	local data = build_bsp{
		[1] = {data = ""},
		[36] = {data = empty_game_lump},
		[44] = {data = compressed_lump, uncompressed = #lump_text},
		[45] = {data = string_table},
	}
	local header = assert(bsp.Decode(data))
	T(header.texdatastringdata[1])["=="]("materials/test/brick")
	T(header.texdatastringdata[2])["=="]("materials/test/wall")
	T(#header.entities)["=="](0)
end)

T.Test("bsp codec rejects bad input", function()
	T(bsp.Decode("nope"))["=="](nil)
	local data = build_bsp{[1] = {data = ""}, [36] = {data = int32{0}}}
	T(bsp.Decode(data) ~= nil)["=="](true)
	local broken = build_bsp{[1] = {data = ""}, [36] = {data = int32{0}}, [20] = {data = "abc"}}
	local copy = ffi.new("uint8_t[?]", #broken)
	ffi.copy(copy, broken, #broken)
	ffi.cast("int32_t *", copy + 8 + 19 * 16)[0] = #broken + 1000
	ffi.cast("int32_t *", copy + 8 + 19 * 16)[1] = 8
	local ok = pcall(bsp.Decode, ffi.string(copy, #broken))
	T(ok)["=="](false)
end)

T.Test("bsp codec replaces floats that read back as nil with zero", function()
	local count = 3000
	local planes = ffi.new("uint32_t[?]", count * 5)
	local one = ffi.new("float[1]", 1)
	local one_bits = ffi.cast("uint32_t *", one)[0]

	for i = 0, count - 1 do
		local bad = i % 3 == 0
		planes[i * 5] = bad and 0xFFFFFFFF or one_bits
		planes[i * 5 + 1] = one_bits
		planes[i * 5 + 2] = bad and 0xFFFFFFFE or one_bits
		planes[i * 5 + 3] = bad and 0xFFFFFFFF or one_bits
		planes[i * 5 + 4] = 0
	end

	local header = assert(
		bsp.Decode(
			build_bsp{
				[1] = {data = ""},
				[2] = {data = ffi.string(planes, count * 20)},
				[36] = {data = int32{0}},
			}
		)
	)
	T(#header.planes)["=="](count)

	for i, plane in ipairs(header.planes) do
		local bad = (i - 1) % 3 == 0
		T(plane.normal[1])["=="](bad and 0 or 1)
		T(plane.normal[2])["=="](1)
		T(plane.normal[3])["=="](bad and 0 or 1)
		T(plane.dist)["=="](bad and 0 or 1)
	end
end)

local function read_map(path)
	local file = vfs.Open(vfs.GetAbsolutePath(path))

	if not file then return nil end

	local data = file:ReadBytes(file:GetSize())
	file:Close()
	return data
end

T.Test("bsp codec decodes a map into plain serializable data", function()
	if not mounted then return end

	local data = read_map("maps/gm_flatgrass.bsp")

	if not data then return end

	local header = assert(bsp.Decode(data, {cubemaps = true}))
	T(#header.entities)[">"](0)
	T(#header.planes)[">"](0)
	T(#header.vertices)[">"](0)
	T(#header.faces)[">"](0)
	T(header.version)["=="](20)
	T(header.pakfile_length)[">="](0)
	T(table.equal(buffer.decode(buffer.encode(header)), header))["=="](true)
end)

T.Test("bsp codec job gives the same result on a worker as inline", function()
	if not mounted then return end

	local data = read_map("maps/gm_flatgrass.bsp")

	if not data then return end

	local thread_pool = import("goluwa/thread_pool.lua")
	local job_source = [=[
		local input = ...
		return assert(import("goluwa/codecs/bsp.lua").Decode(input.data, {cubemaps = true}))
	]=]
	local worker = thread_pool.Run(job_source, {data = data}, 1e9):Await()
	local inline = assert(bsp.Decode(data, {cubemaps = true}))
	T(table.equal(worker, inline))["=="](true)
end)

T.Test("bsp codec reports malformed data as errors instead of crashing", function()
	if not mounted then return end

	local data = read_map("maps/gm_flatgrass.bsp")

	if not data then return end

	for _, length in ipairs{0, 7, 1035, 1036, 5000, 100000, math.floor(#data / 2), #data - 1} do
		pcall(bsp.Decode, data:sub(1, length))
	end

	math.randomseed(23)

	for _ = 1, 40 do
		local position = math.random(1, 2000)
		local corrupt = data:sub(1, position - 1) .. string.char(math.random(0, 255)) .. data:sub(position + 1)
		pcall(bsp.Decode, corrupt)
	end
end)
