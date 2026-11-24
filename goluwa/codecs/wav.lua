local Buffer = import("goluwa/structs/buffer.lua")
local ffi = require("ffi")
local bit = require("bit")
local mpeg_audio = import("goluwa/codecs/mpeg_audio.lua")
local wav = {}
local WAVE_FORMAT_PCM = 0x0001
local WAVE_FORMAT_IEEE_FLOAT = 0x0003
local WAVE_FORMAT_IMA_ADPCM = 0x0011
local WAVE_FORMAT_MPEG = 0x0050
local WAVE_FORMAT_XBOX_ADPCM = 0x0069
local WAVE_FORMAT_EXTENSIBLE = 0xFFFE
wav.file_extensions = {"wav", "wave"}
wav.returns_blob = true
wav.thread_job = [[
	local input = ...
	local meta, pcm = import("goluwa/codecs/wav.lua").Decode(input)

	if not meta then error(pcm, 0) end

	return meta, pcm
]]

function wav.CanDecodeData(data)
	local container = data:sub(1, 4)
	return (container == "RIFF" or container == "RIFX") and data:sub(9, 12) == "WAVE"
end

local int16_ptr = ffi.typeof("const int16_t *")
local int32_ptr = ffi.typeof("const int32_t *")
local double_ptr = ffi.typeof("const double *")

do
	local STEPS = {
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		16,
		17,
		19,
		21,
		23,
		25,
		28,
		31,
		34,
		37,
		41,
		45,
		50,
		55,
		60,
		66,
		73,
		80,
		88,
		97,
		107,
		118,
		130,
		143,
		157,
		173,
		190,
		209,
		230,
		253,
		279,
		307,
		337,
		371,
		408,
		449,
		494,
		544,
		598,
		658,
		724,
		796,
		876,
		963,
		1060,
		1166,
		1282,
		1411,
		1552,
		1707,
		1878,
		2066,
		2272,
		2499,
		2749,
		3024,
		3327,
		3660,
		4026,
		4428,
		4871,
		5358,
		5894,
		6484,
		7132,
		7845,
		8630,
		9493,
		10442,
		11487,
		12635,
		13899,
		15289,
		16818,
		18500,
		20350,
		22385,
		24623,
		27086,
		29794,
		32767,
	}
	local INDEX_SHIFT = {[0] = -1, -1, -1, -1, 2, 4, 6, 8}
	local band, rshift = bit.band, bit.rshift

	-- each block starts with the predictor as a sample, the Xbox variant leaves the last nibble unused for an even count
	function wav.DecodeIMA(src, size, channels, block_align, xbox, sample_count)
		local channel_block = block_align / channels
		local nibbles = (channel_block - 4) * 2 - (xbox and 1 or 0)
		local per_block = nibbles + 1
		local blocks = math.floor(size / block_align)
		local frames = math.min(blocks * per_block, sample_count or math.huge)
		local pcm = ffi.new("float[?]", math.max(frames * channels, 1))

		for b = 0, blocks - 1 do
			local block = src + b * block_align

			for ch = 0, channels - 1 do
				local predictor = block[ch * 4] + block[ch * 4 + 1] * 256

				if predictor >= 32768 then predictor = predictor - 65536 end

				local index = math.min(block[ch * 4 + 2], 88)
				local frame = b * per_block

				if frame < frames then pcm[frame * channels + ch] = predictor / 32768 end

				frame = frame + 1

				for n = 0, nibbles - 1 do
					local byte = block[channels * 4 + rshift(n, 3) * 4 * channels + ch * 4 + band(rshift(n, 1), 3)]
					local nibble = band(n, 1) == 0 and band(byte, 15) or rshift(byte, 4)
					local step = STEPS[index + 1]
					local diff = rshift(step, 3)

					if band(nibble, 4) ~= 0 then diff = diff + step end

					if band(nibble, 2) ~= 0 then diff = diff + rshift(step, 1) end

					if band(nibble, 1) ~= 0 then diff = diff + rshift(step, 2) end

					if band(nibble, 8) ~= 0 then
						predictor = math.max(predictor - diff, -32768)
					else
						predictor = math.min(predictor + diff, 32767)
					end

					index = math.clamp(index + INDEX_SHIFT[band(nibble, 7)], 0, 88)

					if frame < frames then pcm[frame * channels + ch] = predictor / 32768 end

					frame = frame + 1
				end
			end
		end

		return pcm, frames
	end
end

function wav.Decode(data)
	local buffer = type(data) == "string" and Buffer.New(data) or data

	if not buffer or buffer:TheEnd() then return nil, "Empty buffer" end

	local riff = buffer:ReadBytes(4)

	if riff ~= "RIFF" then
		if riff == "RIFX" then return nil, "Big-endian WAVE files are not supported" end

		return nil, "Not a RIFF/WAVE file"
	end

	buffer:ReadU32LE()

	if buffer:ReadBytes(4) ~= "WAVE" then
		return nil, "RIFF container is not a WAVE file"
	end

	local format_tag
	local channels
	local sample_rate
	local bits_per_sample
	local block_align
	local data_offset
	local data_size
	local fact_samples

	while buffer:GetPosition() + 8 <= buffer:GetSize() do
		local chunk_id = buffer:ReadBytes(4)
		local chunk_size = buffer:ReadU32LE()
		local chunk_start = buffer:GetPosition()
		local next_chunk = chunk_start + chunk_size

		if next_chunk > buffer:GetSize() then
			return nil, "WAVE chunk extends past end of file"
		end

		if chunk_id == "fmt " then
			if chunk_size < 16 then return nil, "Invalid WAVE fmt chunk" end

			format_tag = buffer:ReadU16LE()
			channels = buffer:ReadU16LE()
			sample_rate = buffer:ReadU32LE()
			buffer:ReadU32LE()
			block_align = buffer:ReadU16LE()
			bits_per_sample = buffer:ReadU16LE()

			if chunk_size > 16 then
				local extra_size = buffer:ReadU16LE()
				local extra_end = math.min(buffer:GetPosition() + extra_size, next_chunk)

				if format_tag == WAVE_FORMAT_EXTENSIBLE then
					if extra_end - buffer:GetPosition() < 22 then
						return nil, "Invalid WAVE extensible fmt chunk"
					end

					local valid_bits_per_sample = buffer:ReadU16LE()
					buffer:ReadU32LE()
					format_tag = buffer:ReadU16LE()
					buffer:Advance(14)

					if valid_bits_per_sample > 0 then bits_per_sample = valid_bits_per_sample end
				end
			end
		elseif chunk_id == "fact" and chunk_size >= 4 then
			fact_samples = buffer:ReadU32LE()
		elseif chunk_id == "data" then
			data_offset = chunk_start
			data_size = chunk_size
		end

		buffer:SetPosition(next_chunk)

		if chunk_size % 2 == 1 and not buffer:TheEnd() then buffer:Advance(1) end
	end

	if not format_tag then return nil, "WAVE file is missing a fmt chunk" end

	if not data_offset or not data_size then
		return nil, "WAVE file is missing a data chunk"
	end

	if not channels or channels <= 0 then
		return nil, "Invalid WAVE channel count"
	end

	if not sample_rate or sample_rate <= 0 then
		return nil, "Invalid WAVE sample rate"
	end

	block_align = block_align or (channels * math.max(1, math.floor((bits_per_sample or 0) / 8)))

	if block_align <= 0 then return nil, "Invalid WAVE block align" end

	local src = buffer.Buffer + data_offset

	if format_tag == WAVE_FORMAT_MPEG then
		local meta, pcm = mpeg_audio.DecodeMemory(src, data_size)

		if not meta then return nil, pcm end

		meta.samples = math.min(meta.samples, fact_samples or meta.samples)
		meta.format_tag = format_tag
		return meta, pcm
	end

	if format_tag == WAVE_FORMAT_IMA_ADPCM or format_tag == WAVE_FORMAT_XBOX_ADPCM then
		local pcm, frames = wav.DecodeIMA(
			src,
			data_size,
			channels,
			block_align,
			format_tag == WAVE_FORMAT_XBOX_ADPCM,
			fact_samples
		)
		return {
			samples = frames,
			channels = channels,
			sample_rate = sample_rate,
			bits_per_sample = 16,
			format_tag = format_tag,
			block_align = block_align,
		},
		pcm
	end

	local sample_frames = math.floor(data_size / block_align)
	local sample_values = sample_frames * channels
	local pcm = ffi.new("float[?]", sample_values)

	if format_tag == WAVE_FORMAT_PCM then
		if bits_per_sample == 8 then
			for i = 0, sample_values - 1 do
				pcm[i] = (src[i] - 128) / 128
			end
		elseif bits_per_sample == 16 then
			local samples = ffi.cast(int16_ptr, src)

			for i = 0, sample_values - 1 do
				pcm[i] = samples[i] / 32768
			end
		elseif bits_per_sample == 24 then
			for i = 0, sample_values - 1 do
				local at = i * 3
				local value = src[at] + src[at + 1] * 0x100 + src[at + 2] * 0x10000

				if value >= 0x800000 then value = value - 0x1000000 end

				pcm[i] = value / 8388608
			end
		elseif bits_per_sample == 32 then
			local samples = ffi.cast(int32_ptr, src)

			for i = 0, sample_values - 1 do
				pcm[i] = samples[i] / 2147483648
			end
		else
			return nil, "Unsupported PCM bit depth: " .. tostring(bits_per_sample)
		end
	elseif format_tag == WAVE_FORMAT_IEEE_FLOAT then
		if bits_per_sample == 32 then
			ffi.copy(pcm, src, sample_values * 4)
		elseif bits_per_sample == 64 then
			local samples = ffi.cast(double_ptr, src)

			for i = 0, sample_values - 1 do
				pcm[i] = samples[i]
			end
		else
			return nil, "Unsupported floating-point bit depth: " .. tostring(bits_per_sample)
		end
	else
		return nil, "Unsupported WAVE format tag: " .. tostring(format_tag)
	end

	return {
		samples = sample_frames,
		channels = channels,
		sample_rate = sample_rate,
		bits_per_sample = bits_per_sample,
		format_tag = format_tag,
		block_align = block_align,
	},
	pcm
end

return wav
