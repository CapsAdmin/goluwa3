local ffi = require("ffi")
local bit = require("bit")
local protobuf = {}
local band = bit.band
local uint64_t = ffi.typeof("uint64_t")
local uint64_ptr_t = ffi.typeof("const uint64_t *")
local uint32_ptr_t = ffi.typeof("const uint32_t *")
local MAX_SAFE = uint64_t(2 ^ 53)
local scales = {}

for i = 7, 63, 7 do
	scales[i] = uint64_t(2) ^ i
end

protobuf.WIRE_VARINT = 0
protobuf.WIRE_FIXED64 = 1
protobuf.WIRE_LENGTH = 2
protobuf.WIRE_FIXED32 = 5

-- ptr is a uint8_t pointer and positions are 0 based. Returns a number, or a uint64_t above 2^53
local function read_varint(ptr, pos)
	local result = 0
	local scale = 1

	for _ = 1, 7 do
		local b = ptr[pos]
		pos = pos + 1
		result = result + band(b, 127) * scale

		if b < 128 then return result, pos end

		scale = scale * 128
	end

	local big = uint64_t(result)

	for shift = 49, 63, 7 do
		local b = ptr[pos]
		pos = pos + 1
		big = big + uint64_t(band(b, 127)) * scales[shift]

		if b < 128 then
			if big < MAX_SAFE then return tonumber(big), pos end

			return big, pos
		end
	end

	error("protobuf: varint too long", 2)
end

protobuf.ReadVarint = read_varint

-- returns a list of {number, wire, value, stop}. For length delimited fields value and stop are the
-- 0 based start and exclusive end of the payload
function protobuf.Decode(ptr, pos, stop)
	local fields = {}
	local count = 0

	while pos < stop do
		local key
		key, pos = read_varint(ptr, pos)
		local wire = band(key, 7)
		local number = (key - wire) / 8
		local value, value_stop

		if wire == 0 then
			value, pos = read_varint(ptr, pos)
		elseif wire == 2 then
			local len
			len, pos = read_varint(ptr, pos)
			value = pos
			value_stop = pos + len
			pos = value_stop
		elseif wire == 1 then
			value = ffi.cast(uint64_ptr_t, ptr + pos)[0]
			pos = pos + 8
		elseif wire == 5 then
			value = ffi.cast(uint32_ptr_t, ptr + pos)[0]
			pos = pos + 4
		else
			error("protobuf: unsupported wire type " .. wire, 2)
		end

		if pos > stop then error("protobuf: field runs past its message", 2) end

		count = count + 1
		fields[count] = {number, wire, value, value_stop}
	end

	return fields
end

function protobuf.Find(fields, number)
	for i = 1, #fields do
		if fields[i][1] == number then return fields[i] end
	end
end

function protobuf.FindAll(fields, number)
	local out = {}

	for i = 1, #fields do
		if fields[i][1] == number then out[#out + 1] = fields[i] end
	end

	return out
end

function protobuf.String(ptr, field)
	return ffi.string(ptr + field[3], field[4] - field[3])
end

return protobuf
