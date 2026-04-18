local fs = import("goluwa/fs.lua")
local png = import("goluwa/codecs/png.lua")
local profiler = import("goluwa/profiler.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local system = import("goluwa/system.lua")
local ROOT = "/home/caps/.steam/steam/steamapps/common/GarrysMod/garrysmod/materials/spawnicons/models"
local REPORT_PATH = "game/storage/logs/png_decode_bench_report.txt"
local PROFILE_ID = "png_decode_bench"

local function parse_args()
	local args = system.GetStartupArguments() or {}
	local out = {
		repeat_count = 1,
		limit = nil,
		profile = true,
		decoder_path = nil,
	}
	local i = 1

	while i <= #args do
		local arg = args[i]

		if arg == "run" or arg:match("png_decode%.lua$") then

		elseif arg == "--repeat" then
			i = i + 1
			out.repeat_count = math.max(1, math.floor(tonumber(args[i]) or 1))
		elseif arg == "--limit" then
			i = i + 1
			out.limit = math.max(1, math.floor(tonumber(args[i]) or 1))
		elseif arg == "--no-profile" then
			out.profile = false
		elseif arg == "--profile" then
			out.profile = true
		elseif arg == "--decoder" then
			i = i + 1
			out.decoder_path = args[i]
		end

		i = i + 1
	end

	return out
end

local function format_bytes(bytes)
	if bytes >= 1024 * 1024 then
		return string.format("%.2f MiB", bytes / (1024 * 1024))
	end

	if bytes >= 1024 then return string.format("%.2f KiB", bytes / 1024) end

	return string.format("%d B", bytes)
end

local function format_seconds(seconds)
	if seconds >= 1 then return string.format("%.3f s", seconds) end

	if seconds >= 0.001 then return string.format("%.3f ms", seconds * 1000) end

	return string.format("%.3f us", seconds * 1000000)
end

local function mean(values)
	local total = 0

	for i = 1, #values do
		total = total + values[i]
	end

	return total / math.max(1, #values)
end

local function median(values)
	local sorted = {}

	for i = 1, #values do
		sorted[i] = values[i]
	end

	table.sort(sorted)

	if #sorted == 0 then return 0 end

	if #sorted % 2 == 1 then return sorted[(#sorted + 1) / 2] end

	local hi = #sorted / 2 + 1
	local lo = hi - 1
	return (sorted[lo] + sorted[hi]) * 0.5
end

local function write_report(lines)
	local text = table.concat(lines, "\n") .. "\n"
	assert(fs.write_file(REPORT_PATH, text))
end

local function collect_png_paths(limit)
	local all_paths = assert(fs.get_files_recursive(ROOT))
	local paths = {}

	for i = 1, #all_paths do
		local path = all_paths[i]

		if path:lower():sub(-4) == ".png" then paths[#paths + 1] = path end
	end

	table.sort(paths)

	if limit and #paths > limit then
		local trimmed = {}

		for i = 1, limit do
			trimmed[i] = paths[i]
		end

		paths = trimmed
	end

	return paths
end

local function benchmark_decode(paths, repeat_count, enable_profile, decoder)
	local decode_times = {}
	local file_stats = {}
	local total_bytes = 0
	local total_pixels = 0
	local total_decode_time = 0
	local total_read_time = 0
	local checksum = 0

	for i = 1, #paths do
		file_stats[i] = {path = paths[i], total = 0, bytes = 0, width = 0, height = 0}
	end

	local warmup_count = math.min(#paths, 64)

	for i = 1, warmup_count do
		local data = assert(fs.read_file(paths[i]))
		local img = assert(decoder.DecodeBuffer(Buffer.New(data, #data)))
		checksum = checksum + img.width + img.height + img.buffer:GetByte(0)
	end

	collectgarbage("collect")

	if enable_profile then
		profiler.Start{
			id = PROFILE_ID,
			text_output = true,
			max_simple_sections = 8,
			max_frames = 20,
			max_depth = 5,
			max_children = 6,
		}
	end

	profiler.StartSection("decode_passes")

	for repeat_index = 1, repeat_count do
		profiler.StartSection("decode_pass_" .. repeat_index)

		for i = 1, #paths do
			local read_start = system.GetTime()
			local data = assert(fs.read_file(paths[i]))
			total_read_time = total_read_time + (system.GetTime() - read_start)
			local decode_start = system.GetTime()
			local img = assert(decoder.DecodeBuffer(Buffer.New(data, #data)))
			local elapsed = system.GetTime() - decode_start
			local stat = file_stats[i]
			decode_times[#decode_times + 1] = elapsed
			stat.total = stat.total + elapsed
			stat.bytes = #data
			stat.width = img.width
			stat.height = img.height
			total_bytes = total_bytes + #data
			total_pixels = total_pixels + img.width * img.height
			total_decode_time = total_decode_time + elapsed
			checksum = checksum + img.width * 3 + img.height * 5 + img.buffer:GetByte(0)
		end

		profiler.StopSection()
	end

	profiler.StopSection()
	local profile_summary = enable_profile and profiler.Stop() or nil

	table.sort(file_stats, function(a, b)
		if a.total ~= b.total then return a.total > b.total end

		return a.path < b.path
	end)

	return {
		decode_times = decode_times,
		file_stats = file_stats,
		total_bytes = total_bytes,
		total_pixels = total_pixels,
		total_decode_time = total_decode_time,
		total_read_time = total_read_time,
		checksum = checksum,
		profile_summary = profile_summary,
	}
end

local function main()
	local args = parse_args()
	local lines = {}
	local paths = collect_png_paths(args.limit)
	local decoder = args.decoder_path and dofile(args.decoder_path) or png
	assert(#paths > 0, "no png files found under " .. ROOT)
	local started = system.GetTime()
	local results = benchmark_decode(paths, args.repeat_count, args.profile, decoder)
	local wall_time = system.GetTime() - started
	lines[#lines + 1] = string.format("PNG decode benchmark over %d files", #paths)
	lines[#lines + 1] = "Root: " .. ROOT
	lines[#lines + 1] = "Repeat count: " .. args.repeat_count
	lines[#lines + 1] = "Profiling: " .. (args.profile and "enabled" or "disabled")
	lines[#lines + 1] = "Decoder: " .. (args.decoder_path or "workspace goluwa/codecs/png.lua")
	lines[#lines + 1] = "Warmup files: " .. math.min(#paths, 64)
	lines[#lines + 1] = "Total bytes decoded: " .. format_bytes(results.total_bytes)
	lines[#lines + 1] = "Total pixels decoded: " .. tostring(results.total_pixels)
	lines[#lines + 1] = "Total read time: " .. format_seconds(results.total_read_time)
	lines[#lines + 1] = "Total decode time: " .. format_seconds(results.total_decode_time)
	lines[#lines + 1] = "Wall time: " .. format_seconds(wall_time)
	lines[#lines + 1] = "Mean decode/file: " .. format_seconds(mean(results.decode_times))
	lines[#lines + 1] = "Median decode/file: " .. format_seconds(median(results.decode_times))
	lines[#lines + 1] = "Checksum: " .. tostring(results.checksum)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Slowest files:"

	for i = 1, math.min(15, #results.file_stats) do
		local stat = results.file_stats[i]
		lines[#lines + 1] = string.format(
			"%d. %s - %s total, %dx%d, %s",
			i,
			stat.path,
			format_seconds(stat.total),
			stat.width,
			stat.height,
			format_bytes(stat.bytes)
		)
	end

	if results.profile_summary then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Profile summary written to game/storage/logs/jit_profile_" .. PROFILE_ID .. ".txt"
	end

	write_report(lines)

	for i = 1, #lines do
		print(lines[i])
	end
end

main()
