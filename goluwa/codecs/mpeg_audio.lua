local ffi = require("ffi")
local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local mpeg_audio = {}
mpeg_audio.file_extensions = {"mp2"}
mpeg_audio.returns_blob = true
mpeg_audio.thread_job = [[
	local input = ...
	local meta, pcm = import("goluwa/codecs/mpeg_audio.lua").Decode(input)

	if not meta then error(pcm, 0) end

	return meta, pcm
]]
local Bytes = ffi.typeof("uint8_t[?]")
local Floats = ffi.typeof("float[?]")
local Doubles = ffi.typeof("double[?]")
local BITRATES_V1 = {[0] = 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384}
local BITRATES_V2 = {[0] = 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160}
local SAMPLE_RATES = {[0] = 44100, 48000, 32000}
-- allocation codes: 0 nothing, 3 to 16 a plain quantizer of that many bits, 17, 18 and 19 grouped 3, 5 and 9 step quantizers
local ROW_A = {0, 17, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
local ROW_B = {0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16}
local ROW_C = {0, 17, 18, 3, 19, 4, 5, 16}
local ROW_D = {0, 17, 18, 16}
local ROW_LOW = {0, 17, 18, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
local ROW_LSF = {0, 17, 18, 3, 19, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14}
local GROUPED_STEPS = {[17] = 3, [18] = 5, [19] = 9}
local GROUPED_BITS = {[17] = 5, [18] = 7, [19] = 10}

local function build_table(groups)
	local nbal, rows = {}, {}

	for _, group in ipairs(groups) do
		for _ = 1, group[1] do
			nbal[#nbal + 1] = group[2]
			rows[#rows + 1] = group[3]
		end
	end

	return {nbal = nbal, rows = rows}
end

local TABLE_HIGH = build_table{{3, 4, ROW_A}, {8, 4, ROW_B}, {12, 3, ROW_C}, {7, 2, ROW_D}}
local TABLE_LOW = build_table{{2, 4, ROW_LOW}, {10, 3, ROW_LOW}}
local TABLE_LSF = build_table{{4, 4, ROW_LSF}, {7, 3, ROW_LOW}, {19, 2, ROW_LOW}}
local SCALE = Doubles(64)

for i = 0, 62 do
	SCALE[i] = 2 * 2 ^ (-i / 3)
end

-- the synthesis window of ISO 11172-3 table B.3, times 65536, the second half mirrors it
local WINDOW_HALF = {
	0,
	-1,
	-1,
	-1,
	-1,
	-1,
	-1,
	-2,
	-2,
	-2,
	-2,
	-3,
	-3,
	-4,
	-4,
	-5,
	-5,
	-6,
	-7,
	-7,
	-8,
	-9,
	-10,
	-11,
	-13,
	-14,
	-16,
	-17,
	-19,
	-21,
	-24,
	-26,
	-29,
	-31,
	-35,
	-38,
	-41,
	-45,
	-49,
	-53,
	-58,
	-63,
	-68,
	-73,
	-79,
	-85,
	-91,
	-97,
	-104,
	-111,
	-117,
	-125,
	-132,
	-139,
	-147,
	-154,
	-161,
	-169,
	-176,
	-183,
	-190,
	-196,
	-202,
	-208,
	213,
	218,
	222,
	225,
	227,
	228,
	228,
	227,
	224,
	221,
	215,
	208,
	200,
	189,
	177,
	163,
	146,
	127,
	106,
	83,
	57,
	29,
	-2,
	-36,
	-72,
	-111,
	-153,
	-197,
	-244,
	-294,
	-347,
	-401,
	-459,
	-519,
	-581,
	-645,
	-711,
	-779,
	-848,
	-919,
	-991,
	-1064,
	-1137,
	-1210,
	-1283,
	-1356,
	-1428,
	-1498,
	-1567,
	-1634,
	-1698,
	-1759,
	-1817,
	-1870,
	-1919,
	-1962,
	-2001,
	-2032,
	-2057,
	-2075,
	-2085,
	-2087,
	-2080,
	-2063,
	2037,
	2000,
	1952,
	1893,
	1822,
	1739,
	1644,
	1535,
	1414,
	1280,
	1131,
	970,
	794,
	605,
	402,
	185,
	-45,
	-288,
	-545,
	-814,
	-1095,
	-1388,
	-1692,
	-2006,
	-2330,
	-2663,
	-3004,
	-3351,
	-3705,
	-4063,
	-4425,
	-4788,
	-5153,
	-5517,
	-5879,
	-6237,
	-6589,
	-6935,
	-7271,
	-7597,
	-7910,
	-8209,
	-8491,
	-8755,
	-8998,
	-9219,
	-9416,
	-9585,
	-9727,
	-9838,
	-9916,
	-9959,
	-9966,
	-9935,
	-9863,
	-9750,
	-9592,
	-9389,
	-9139,
	-8840,
	-8492,
	-8092,
	-7640,
	-7134,
	6574,
	5959,
	5288,
	4561,
	3776,
	2935,
	2037,
	1082,
	70,
	-998,
	-2122,
	-3300,
	-4533,
	-5818,
	-7154,
	-8540,
	-9975,
	-11455,
	-12980,
	-14548,
	-16155,
	-17799,
	-19478,
	-21189,
	-22929,
	-24694,
	-26482,
	-28289,
	-30112,
	-31947,
	-33791,
	-35640,
	-37489,
	-39336,
	-41176,
	-43006,
	-44821,
	-46617,
	-48390,
	-50137,
	-51853,
	-53534,
	-55178,
	-56778,
	-58333,
	-59838,
	-61289,
	-62684,
	-64019,
	-65290,
	-66494,
	-67629,
	-68692,
	-69679,
	-70590,
	-71420,
	-72169,
	-72835,
	-73415,
	-73908,
	-74313,
	-74630,
	-74856,
	-74992,
	75038,
}
local WINDOW = Doubles(512)

for i = 0, 256 do
	local value = WINDOW_HALF[i + 1] / 65536
	WINDOW[i] = value

	if i ~= 0 then WINDOW[512 - i] = band(i, 63) ~= 0 and -value or value end
end

local MATRIX = Doubles(64 * 32)

for i = 0, 63 do
	for k = 0, 31 do
		MATRIX[i * 32 + k] = math.cos((16 + i) * (2 * k + 1) * math.pi / 64)
	end
end

local stream, bit_pos

local function get_bits(n)
	local at = rshift(bit_pos, 3)
	local word = bor(lshift(stream[at], 16), lshift(stream[at + 1], 8), stream[at + 2])
	bit_pos = bit_pos + n
	return band(rshift(word, 24 - band(bit_pos - n, 7) - n), lshift(1, n) - 1)
end

local function read_header(data, size, at)
	if at + 4 > size or data[at] ~= 0xFF or band(data[at + 1], 0xE0) ~= 0xE0 then
		return nil
	end

	local h1, h2, h3 = data[at + 1], data[at + 2], data[at + 3]
	local version = band(rshift(h1, 3), 3)
	local layer = 4 - band(rshift(h1, 1), 3)
	local bitrate_index = rshift(h2, 4)
	local rate_index = band(rshift(h2, 2), 3)

	if version == 1 or layer == 4 or bitrate_index == 15 or rate_index == 3 then
		return nil
	end

	if layer ~= 2 then
		error("only MPEG audio layer II is supported, this stream is layer " .. layer, 0)
	end

	if version == 0 then error("MPEG 2.5 audio is not supported", 0) end

	if bitrate_index == 0 then
		error("free format MPEG audio is not supported", 0)
	end

	local lsf = version == 2
	local bitrate = (lsf and BITRATES_V2 or BITRATES_V1)[bitrate_index] * 1000
	local sample_rate = SAMPLE_RATES[rate_index] / (lsf and 2 or 1)
	return {
		lsf = lsf,
		crc = band(h1, 1) == 0,
		bitrate = bitrate,
		rate_index = rate_index,
		sample_rate = sample_rate,
		mode = rshift(h3, 6),
		mode_extension = band(rshift(h3, 4), 3),
		size = math.floor(144 * bitrate / sample_rate) + band(rshift(h2, 1), 1),
	}
end

local allocation = {[0] = {}, {}}
local scfsi = {[0] = {}, {}}
local scalefactors = {[0] = {}, {}}
local samples = {[0] = Doubles(32 * 3), Doubles(32 * 3)}

for ch = 0, 1 do
	for sb = 0, 31 do
		scalefactors[ch][sb] = {[0] = 0, 0, 0}
	end
end

local function synthesize(subbands, v, state, ch, out, out_at, stride)
	local offset = band(state[ch] - 64, 1023)
	state[ch] = offset

	for i = 0, 63 do
		local sum = 0
		local row = i * 32

		for k = 0, 31 do
			sum = sum + MATRIX[row + k] * subbands[k]
		end

		v[offset + i] = sum
	end

	for j = 0, 31 do
		local sum = 0

		for m = 0, 7 do
			sum = sum + WINDOW[j + 64 * m] * v[band(offset + m * 128 + j, 1023)] + WINDOW[j + 64 * m + 32] * v[band(offset + m * 128 + 96 + j, 1023)]
		end

		out[out_at + j * stride] = sum
	end
end

function mpeg_audio.Decode(input)
	return mpeg_audio.DecodeMemory(input, #input)
end

function mpeg_audio.DecodeMemory(input, size)
	local data = Bytes(size + 4)
	ffi.copy(data, input, size)
	local first

	for at = 0, size - 4 do
		first = read_header(data, size, at)

		if first then
			first.at = at

			break
		end
	end

	if not first then return nil, "no MPEG audio frame found" end

	local channels = first.mode == 3 and 1 or 2
	local frame_count = 0
	local at = first.at

	while true do
		local header = read_header(data, size, at)

		if not header or at + header.size > size then break end

		frame_count = frame_count + 1
		at = at + header.size
	end

	local pcm = Floats(math.max(frame_count * 1152 * channels, 1))
	local v = {[0] = Doubles(1024), Doubles(1024)}
	local v_offsets = {[0] = 0, 0}
	local subbands = Doubles(32)
	stream = data
	at = first.at

	for frame = 0, frame_count - 1 do
		local header = read_header(data, size, at)
		local nch = header.mode == 3 and 1 or 2

		if nch ~= channels then
			error("MPEG audio channel count changes inside the stream", 0)
		end

		local tab, sblimit

		if header.lsf then
			tab, sblimit = TABLE_LSF, 30
		else
			local kbps = header.bitrate / 1000 / nch

			if kbps < 56 then
				tab, sblimit = TABLE_LOW, header.rate_index == 2 and 12 or 8
			else
				tab, sblimit = TABLE_HIGH, (kbps >= 96 and header.rate_index ~= 1) and 30 or 27
			end
		end

		local bound = header.mode == 1 and
			math.min((header.mode_extension + 1) * 4, sblimit) or
			sblimit
		bit_pos = (at + 4) * 8

		if header.crc then bit_pos = bit_pos + 16 end

		for sb = 0, sblimit - 1 do
			local nbal, row = tab.nbal[sb + 1], tab.rows[sb + 1]

			if sb < bound then
				for ch = 0, nch - 1 do
					allocation[ch][sb] = row[get_bits(nbal) + 1]
				end
			else
				local code = row[get_bits(nbal) + 1]
				allocation[0][sb], allocation[1][sb] = code, code
			end
		end

		for sb = 0, sblimit - 1 do
			for ch = 0, nch - 1 do
				if allocation[ch][sb] ~= 0 then scfsi[ch][sb] = get_bits(2) end
			end
		end

		for sb = 0, sblimit - 1 do
			for ch = 0, nch - 1 do
				if allocation[ch][sb] ~= 0 then
					local scf = scalefactors[ch][sb]
					local mode = scfsi[ch][sb]
					scf[0] = get_bits(6)

					if mode == 0 then
						scf[1], scf[2] = get_bits(6), get_bits(6)
					elseif mode == 1 then
						scf[1], scf[2] = scf[0], get_bits(6)
					elseif mode == 2 then
						scf[1], scf[2] = scf[0], scf[0]
					else
						scf[1] = get_bits(6)
						scf[2] = scf[1]
					end
				end
			end
		end

		for granule = 0, 11 do
			local part = rshift(granule, 2)

			for sb = 0, sblimit - 1 do
				for ch = 0, (sb < bound and nch or 1) - 1 do
					local code = allocation[ch][sb]
					local out = samples[ch]

					if code == 0 then
						out[sb * 3], out[sb * 3 + 1], out[sb * 3 + 2] = 0, 0, 0
					elseif code >= 17 then
						local steps = GROUPED_STEPS[code]
						local value = get_bits(GROUPED_BITS[code])

						for k = 0, 2 do
							local c = value % steps
							value = (value - c) / steps
							out[sb * 3 + k] = (2 * c - (steps - 1)) / steps
						end
					else
						local steps = lshift(1, code) - 1

						for k = 0, 2 do
							out[sb * 3 + k] = (2 * get_bits(code) - (steps - 1)) / steps
						end
					end

					if sb >= bound and nch == 2 then
						local other = samples[1]
						other[sb * 3], other[sb * 3 + 1], other[sb * 3 + 2] = out[sb * 3], out[sb * 3 + 1], out[sb * 3 + 2]
					end
				end
			end

			for k = 0, 2 do
				local out_at = ((frame * 12 + granule) * 3 + k) * 32 * nch

				for ch = 0, nch - 1 do
					local source = samples[ch]

					for sb = 0, 31 do
						subbands[sb] = sb < sblimit and
							allocation[ch][sb] ~= 0 and
							source[sb * 3 + k] * SCALE[scalefactors[ch][sb][part]] or
							0
					end

					synthesize(subbands, v[ch], v_offsets, ch, pcm, out_at + ch, nch)
				end
			end
		end

		at = at + header.size
	end

	stream = nil
	return {
		samples = frame_count * 1152,
		channels = channels,
		sample_rate = first.sample_rate,
		bits_per_sample = 32,
	},
	pcm
end

return mpeg_audio
