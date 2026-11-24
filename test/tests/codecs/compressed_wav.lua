local T = import("test/environment.lua")
local ffi = require("ffi")
local wav = import("goluwa/codecs/wav.lua")
local mpeg_audio = import("goluwa/codecs/mpeg_audio.lua")

local function u16(value)
	return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
	return u16(value % 65536) .. u16(math.floor(value / 65536))
end

local function wav_file(format_tag, channels, block_align, bits, samples, data)
	return "RIFF" .. u32(4 + 26 + 12 + 8 + #data) .. "WAVE" .. "fmt " .. u32(18) .. u16(format_tag) .. u16(channels) .. u32(44100) .. u32(44100 * block_align) .. u16(block_align) .. u16(bits) .. u16(0) .. "fact" .. u32(4) .. u32(samples) .. "data" .. u32(#data) .. data
end

local function ima_header(predictor, index)
	return u16(predictor % 65536) .. string.char(index, 0)
end

T.Test("Xbox IMA ADPCM blocks hold the header sample and 63 nibbles", function()
	-- nibble 4 adds the whole step: 7 at index 0, then 9 at index 2
	local data = ima_header(1000, 0) .. string.rep(string.char(0x44), 32)
	local meta, pcm = wav.Decode(wav_file(0x0069, 1, 36, 4, 64, data))
	T(meta.samples)["=="](64)
	T(meta.channels)["=="](1)
	T(math.floor(pcm[0] * 32768 + 0.5))["=="](1000)
	T(math.floor(pcm[1] * 32768 + 0.5))["=="](1007)
	T(math.floor(pcm[2] * 32768 + 0.5))["=="](1017)
end)

T.Test("Microsoft IMA ADPCM blocks hold the header sample and every nibble", function()
	local data = ima_header(0, 0) .. string.rep(string.char(0), 32)
	local meta = wav.Decode(wav_file(0x0011, 1, 36, 4, 65, data))
	T(meta.samples)["=="](65)
end)

T.Test("IMA ADPCM stereo channels alternate in 4 byte runs", function()
	local runs = {}

	for i = 1, 8 do
		runs[i] = string.rep(string.char(0x00), 4) .. string.rep(string.char(0x77), 4)
	end

	local data = ima_header(0, 0) .. ima_header(0, 0) .. table.concat(runs)
	local meta, pcm = wav.Decode(wav_file(0x0069, 2, 72, 4, 64, data))
	T(meta.samples)["=="](64)
	T(pcm[3])[">"](0)

	for i = 1, 63 do
		T(math.abs(pcm[i * 2]))["<"](0.001)
		T(pcm[i * 2 + 1])[">="](pcm[(i - 1) * 2 + 1])
	end
end)

T.Test("MPEG audio layer II frames are walked and decoded", function()
	-- mpeg 1 layer II, no crc, 160 kbit/s, 44.1 kHz, mono; all bit allocations zero is silence
	local frame = string.char(0xFF, 0xFD, 0x90, 0xC0) .. string.rep("\0", 522 - 4)
	local meta, pcm = mpeg_audio.Decode(frame .. frame .. string.rep("\0", 7))
	T(meta.samples)["=="](2304)
	T(meta.channels)["=="](1)
	T(meta.sample_rate)["=="](44100)

	for i = 0, 2303 do
		T(pcm[i])["=="](0)
	end

	local wav_meta = wav.Decode(wav_file(0x0050, 1, 1, 0, 2000, frame .. frame))
	T(wav_meta.samples)["=="](2000)
end)

T.Test("MPEG audio layer III is refused", function()
	local frame = string.char(0xFF, 0xFB, 0x90, 0xC0) .. string.rep("\0", 413)
	local ok, err = pcall(mpeg_audio.Decode, frame)
	T(ok)["=="](false)
	T(tostring(err):find("layer II", 1, true) ~= nil)["=="](true)
end)
