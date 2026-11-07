local T = import("test/environment.lua")
local ffi = require("ffi")
local lz4 = import("goluwa/codecs/lz4.lua")
local protobuf = import("goluwa/codecs/protobuf.lua")
local ngfx_gputrace = import("goluwa/codecs/ngfx_gputrace.lua")
local crypto = import("goluwa/crypto.lua")
local uint8_ptr_t = ffi.typeof("const uint8_t *")

T.Test("lz4 decodes literals and overlapping matches", function()
	local src = "\x32abc\x03\x00"
	local out = lz4.DecodeBlock(ffi.cast(uint8_ptr_t, src), 0, #src, 9)
	T(ffi.string(out, 9))["=="]("abcabcabc")
	T(pcall(lz4.DecodeBlock, ffi.cast(uint8_ptr_t, src), 0, #src, 10))["=="](false)
	local bad_offset = "\x32abc\x09\x00"
	T(pcall(lz4.DecodeBlock, ffi.cast(uint8_ptr_t, bad_offset), 0, #bad_offset, 9))["=="](false)
end)

T.Test("lz4 encodes byte for byte like LZ4_compress_default", function()
	local function make(n, f)
		local t = {}

		for i = 0, n - 1 do
			t[i + 1] = string.char(f(i))
		end

		return table.concat(t)
	end

	-- expected sizes and crc32 come from liblz4 1.10 LZ4_compress_default
	local vectors = {
		{
			data = make(5000, function(i)
				return (i * i * 31 + math.floor(i / 7)) % 13 + 97
			end),
			size = 121,
			crc = 2439793446,
		},
		{
			data = make(200000, function(i)
				return (i * 2654435761 % 4294967296) % 7 + (math.floor(i / 1000) % 3) * 40
			end),
			size = 22250,
			crc = 2547350566,
		},
	}

	for _, vector in ipairs(vectors) do
		local out, size = lz4.EncodeBlock(ffi.cast(uint8_ptr_t, vector.data), #vector.data)
		T(size)["=="](vector.size)
		T(tonumber(crypto.CRC32(ffi.string(out, size))))["=="](vector.crc)
		T(ffi.string(lz4.DecodeBlock(out, 0, size, #vector.data), #vector.data) == vector.data)["=="](true)
	end

	local out, size = lz4.EncodeBlock(ffi.cast(uint8_ptr_t, "abc"), 3)
	T(ffi.string(out, size))["=="]("\x30abc")
end)

T.Test("protobuf decodes varints, strings and nested messages", function()
	local src = "\x08\x96\x01\x12\x05hello\x1a\x04\x08\xff\xff\x03\x20\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"
	local ptr = ffi.cast(uint8_ptr_t, src)
	local fields = protobuf.Decode(ptr, 0, #src)
	T(protobuf.Find(fields, 1)[3])["=="](150)
	T(protobuf.String(ptr, protobuf.Find(fields, 2)))["=="]("hello")
	local nested = protobuf.Find(fields, 3)
	T(protobuf.Decode(ptr, nested[3], nested[4])[1][3])["=="](65535)
	T(tostring(protobuf.Find(fields, 4)[3]))["=="]("18446744073709551615ULL")
end)

local sample = "/home/caps/Documents/NVIDIA Nsight Graphics/luajit-2.1.ROLLING_2026_11_07_10_42_46.ngfx-gputrace"

if io.open(sample, "rb") then
	T.Test("ngfx gputrace reads the report", function()
		local trace = ngfx_gputrace.Open(sample)
		T(trace:GetInfoValue("GPU", "Device Name"))["=="]("NVIDIA GeForce RTX 4090")
		T(trace:GetScreenshot().png:sub(2, 4))["=="]("PNG")
		T(trace:GetApiCallCounts().vkQueueSubmit)["=="](6)
		T(#trace:GetProcesses() > 0)["=="](true)
		local profile = trace:GetPipelineProfile()
		T(profile.sample_count)["=="](1960458)
		T(profile.profiles[1].samples > 0)["=="](true)
		local frames = trace:GetFrameTimings()
		T(#frames)["=="](3)
		local traced = trace:GetTracedFrame()
		T(traced.start_ns >= -100000 and traced.start_ns < 100000)["=="](true)
		T(math.abs((traced.end_ns - traced.start_ns) - profile.duration_ns) < 1e6)["=="](true)
		local timed_events = 0

		for _, bucket in ipairs(traced.buckets) do
			T(bucket.end_ns >= bucket.start_ns)["=="](true)
			timed_events = timed_events + #bucket.events
		end

		T(timed_events)["=="](94)

		if import("goluwa/codecs/ngfx_perfworks.lua").FindLibrary() then
			local counters = trace:GetCounters()
			T(counters.chip_name)["=="]("AD102")
			local names = {}

			for _, column in ipairs(counters.columns) do
				names[column.name] = true
			end

			T(names.sm and names.l2 and names.vram and names.rt)["=="](true)
			local averages = trace:GetCounterAverages(traced.start_ns, traced.end_ns)
			T(averages.sm > 1 and averages.sm < 100)["=="](true)
			T(counters.starts[1] > -1e6 and counters.starts[1] < 1e6)["=="](true)
		end

		T(trace:GetReport():find("pipelines by warp samples", 1, true) ~= nil)["=="](true)
	end)
end

local named_sample = "/home/caps/Documents/NVIDIA Nsight Graphics/luajit-2.1.ROLLING_2026_11_07_12_13_15.ngfx-gputrace"

if io.open(named_sample, "rb") and ngfx_gputrace.GetKeystream() then
	T.Test("ngfx gputrace decodes shader blobs and maps samples to glsl lines", function()
		local trace = ngfx_gputrace.Open(named_sample)
		local kinds = {}

		for i = 0, #trace:GetBlobs() - 1 do
			local kind = trace:GetBlobKind(i)
			kinds[kind] = (kinds[kind] or 0) + 1
		end

		T(kinds.spirv)["=="](75)
		T(kinds.cubin)["=="](178)
		local profile = trace:GetPipelineProfile()
		local pipeline = profile.profiles[1].pipeline
		local source = trace:GetSourceProfile(pipeline)
		T(source.unmapped < source.samples * 0.05)["=="](true)
		T(source.lines[1].file:find("^gbuffer_multi_draw") ~= nil)["=="](true)
		T(source.lines[1].text:find("plant_bound", 1, true) ~= nil)["=="](true)
		T(profile.unattributed.samples < profile.sample_count * 0.01)["=="](true)
		T(trace.internal_pipeline ~= nil)["=="](true)

		for _, entry in ipairs(profile.profiles) do
			local name = entry.pipeline and entry.pipeline.name

			if name == "ddgi_shade" then
				local rt = trace:GetSourceProfile(entry.pipeline)
				T(rt.lines[1].file)["=="]("ddgi_shade.rgen")
				T(rt.unmapped < rt.samples * 0.05)["=="](true)
			elseif name == "motion_blur" then
				local top, best = nil, 0

				for reason, n in pairs(entry.stalls) do
					if n > best then top, best = reason, n end
				end

				T(ngfx_gputrace.STALL_REASONS[top])["=="]("long_scoreboard")
			end
		end
	end)
end

local old_sample = "/home/caps/Documents/NVIDIA Nsight Graphics/luajit-2.1.ROLLING_2026_11_07_09_44_38.ngfx-gputrace"

if io.open(old_sample, "rb") and ngfx_gputrace.GetKeystream() then
	T.Test("ngfx gputrace decodes the blobs of Nsight 2026.3 (lz4 before the keystream)", function()
		local trace = ngfx_gputrace.Open(old_sample)
		T(trace.version)["=="](10)
		local kinds = {}

		for i = 0, #trace:GetBlobs() - 1 do
			local kind = trace:GetBlobKind(i)
			kinds[kind] = (kinds[kind] or 0) + 1
		end

		T(kinds.spirv)["=="](76)
		T(kinds.cubin)["=="](271)
	end)
end
