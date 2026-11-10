local ffi = require("ffi")
local resource = import("goluwa/source_engine/source2/resource.lua")
local vsnd_c = {}
vsnd_c.file_extensions = {"vsnd_c"}
local u8_t = ffi.typeof("const uint8_t *")
local u32_t = ffi.typeof("const uint32_t *")
local i16_t = ffi.typeof("const int16_t *")

function vsnd_c.Decode(data)
	local res = resource.Parse(data)
	local block = res.blocks.DATA
	local src = ffi.cast(u8_t, data)
	local header = ffi.cast(u32_t, src + block.offset)
	local sample_rate = header[0] % 65536
	local bits = src[block.offset + 2] == 0 and 16 or 8
	local channels = src[block.offset + 3]
	local frames = header[2]
	local values = frames * channels
	local audio = src + block.offset + block.size
	local pcm = ffi.new("float[?]", values)

	if bits == 16 then
		local samples = ffi.cast(i16_t, audio)

		for i = 0, values - 1 do
			pcm[i] = samples[i] / 32768
		end
	else
		for i = 0, values - 1 do
			pcm[i] = (audio[i] - 128) / 128
		end
	end

	return {
		data = pcm,
		samples = frames,
		channels = channels,
		sample_rate = sample_rate,
		bits_per_sample = bits,
	}
end

return vsnd_c
