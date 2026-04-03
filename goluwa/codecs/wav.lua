local Buffer = import("goluwa/structs/buffer.lua")
local ffi = require("ffi")
local wav = library()
local WAVE_FORMAT_PCM = 0x0001
local WAVE_FORMAT_IEEE_FLOAT = 0x0003
local WAVE_FORMAT_EXTENSIBLE = 0xFFFE
wav.file_extensions = {"wav", "wave"}

local function read_s24le(buffer)
	local b1 = buffer:ReadByte()
	local b2 = buffer:ReadByte()
	local b3 = buffer:ReadByte()
	local value = b1 + (b2 * 0x100) + (b3 * 0x10000)

	if value >= 0x800000 then value = value - 0x1000000 end

	return value
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
		elseif chunk_id == "data" then
			data_offset = chunk_start
			data_size = chunk_size
		end

		buffer:SetPosition(next_chunk)

		if chunk_size % 2 == 1 and not buffer:TheEnd() then buffer:Advance(1) end

		if format_tag and data_offset then break end
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

	local sample_frames = math.floor(data_size / block_align)
	local sample_values = sample_frames * channels
	local pcm = ffi.new("float[?]", sample_values)
	buffer:SetPosition(data_offset)

	if format_tag == WAVE_FORMAT_PCM then
		if bits_per_sample == 8 then
			for i = 0, sample_values - 1 do
				pcm[i] = (buffer:ReadByte() - 128) / 128
			end
		elseif bits_per_sample == 16 then
			for i = 0, sample_values - 1 do
				pcm[i] = buffer:ReadI16LE() / 32768
			end
		elseif bits_per_sample == 24 then
			for i = 0, sample_values - 1 do
				pcm[i] = read_s24le(buffer) / 8388608
			end
		elseif bits_per_sample == 32 then
			for i = 0, sample_values - 1 do
				pcm[i] = buffer:ReadI32LE() / 2147483648
			end
		else
			return nil, "Unsupported PCM bit depth: " .. tostring(bits_per_sample)
		end
	elseif format_tag == WAVE_FORMAT_IEEE_FLOAT then
		if bits_per_sample == 32 then
			for i = 0, sample_values - 1 do
				pcm[i] = buffer:ReadFloatLE()
			end
		elseif bits_per_sample == 64 then
			for i = 0, sample_values - 1 do
				pcm[i] = buffer:ReadDoubleLE()
			end
		else
			return nil, "Unsupported floating-point bit depth: " .. tostring(bits_per_sample)
		end
	else
		return nil, "Unsupported WAVE format tag: " .. tostring(format_tag)
	end

	return {
		data = pcm,
		samples = sample_frames,
		channels = channels,
		sample_rate = sample_rate,
		bits_per_sample = bits_per_sample,
		format_tag = format_tag,
		block_align = block_align,
	}
end

return wav
