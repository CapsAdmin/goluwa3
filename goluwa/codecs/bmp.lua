local ffi = require("ffi")
local Buffer = import("goluwa/structs/buffer.lua")
local bmp = {}
bmp.file_extensions = {"bmp"}
bmp.magic_headers = {"BM"}
local header_type = ffi.typeof(
	"struct { uint16_t magic; uint32_t size; uint32_t reserved; uint32_t offset; uint32_t header_size; int32_t width; int32_t height; uint16_t planes; uint16_t bpp; uint32_t compression; } __attribute__((packed))"
)
local header_ptr = ffi.typeof("$ *", header_type)

-- uncompressed 24 and 32 bit bitmaps, the alpha of a 32 bit one is ignored. rows come out in file order, bottom row first like the png decoder
function bmp.Decode(data)
	local header = ffi.cast(header_ptr, data)
	assert(header.magic == 0x4D42, "not a bmp")
	assert(
		header.compression == 0 or header.compression == 3,
		"compressed bmp is not supported"
	)
	assert(header.bpp == 24 or header.bpp == 32, "only 24 and 32 bit bmp is supported")
	local width = header.width
	local height = math.abs(header.height)
	local top_down = header.height < 0
	local bytes = header.bpp / 8
	local stride = math.ceil(width * header.bpp / 32) * 4
	local source = ffi.cast("const uint8_t *", data) + header.offset
	local output = ffi.new("uint8_t[?]", width * height * 4)

	for y = 0, height - 1 do
		local row = source + (top_down and height - 1 - y or y) * stride
		local out = output + y * width * 4

		for x = 0, width - 1 do
			local pixel = row + x * bytes
			out[x * 4] = pixel[2]
			out[x * 4 + 1] = pixel[1]
			out[x * 4 + 2] = pixel[0]
			out[x * 4 + 3] = 255
		end
	end

	return {
		width = width,
		height = height,
		vulkan_format = "r8g8b8a8_unorm",
		data = output,
		buffer = Buffer.New(output, width * height * 4),
	}
end

return bmp
