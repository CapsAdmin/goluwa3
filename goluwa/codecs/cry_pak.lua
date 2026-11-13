local ffi = require("ffi")
local bit = require("bit")
local cry_pak = {}
local BLOCK_SIZE = 64
local KEY_MASK = 0xcafebabe
local PERMUTATION = ffi.new(
	"uint8_t[64]",
	{
		23,
		50,
		38,
		42,
		11,
		52,
		4,
		41,
		63,
		3,
		18,
		8,
		16,
		22,
		6,
		48,
		21,
		19,
		40,
		61,
		17,
		9,
		55,
		14,
		34,
		36,
		37,
		0,
		59,
		51,
		53,
		47,
		54,
		56,
		27,
		7,
		10,
		29,
		20,
		33,
		35,
		44,
		62,
		13,
		25,
		58,
		60,
		15,
		39,
		28,
		30,
		5,
		12,
		43,
		1,
		45,
		46,
		24,
		32,
		26,
		31,
		49,
		57,
		2,
	}
)
local CRC_TABLE = ffi.new("uint32_t[256]")

for i = 0, 255 do
	local crc = i

	for _ = 1, 8 do
		if bit.band(crc, 1) == 1 then
			crc = bit.bxor(bit.rshift(crc, 1), 0xedb88320)
		else
			crc = bit.rshift(crc, 1)
		end
	end

	CRC_TABLE[i] = crc
end

local block = ffi.new("uint8_t[?]", BLOCK_SIZE)

function cry_pak.Decrypt(data, crc32)
	local size = #data
	local input = ffi.cast("const uint8_t *", data)
	local output = ffi.new("uint8_t[?]", size)
	local state = bit.bxor(crc32, KEY_MASK)

	for position = 0, size - 1, BLOCK_SIZE do
		local length = math.min(BLOCK_SIZE, size - position)
		local rotation = bit.band(bit.rshift(state, 16), 0x3f)

		for i = 0, length - 1 do
			local byte = input[position + i]
			block[i] = bit.bxor(byte, bit.band(state, 0xff))
			state = bit.bxor(bit.rshift(state, 8), CRC_TABLE[byte])
		end

		if length == BLOCK_SIZE then
			for i = 0, BLOCK_SIZE - 1 do
				output[position + i] = block[bit.band(PERMUTATION[i] + rotation, 0x3f)]
			end
		else
			ffi.copy(output + position, block, length)
		end
	end

	return ffi.string(output, size)
end

return cry_pak
