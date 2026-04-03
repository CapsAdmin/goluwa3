local fs = import("goluwa/fs.lua")
local ogg = import("goluwa/codecs/ogg.lua")
local JitProfiler = import("goluwa/helpers/jit_profiler.lua")
local system = import("goluwa/system.lua")
local report_lines = {}
local report_path = "game/storage/logs/ogg_decode_bench_report.txt"
local profile_summary_path = "game/storage/logs/ogg_decode_bench_flamegraph_summary.txt"

do
	local file = assert(io.open(report_path, "wb"))
	file:close()
end

local function log(line)
	report_lines[#report_lines + 1] = line
	print(line)
	local file = assert(io.open(report_path, "ab"))
	file:write(line)
	file:write("\n")
	file:close()
end

local function write_report()
	local file = assert(io.open(report_path, "wb"))
	file:write(table.concat(report_lines, "\n"))
	file:write("\n")
	file:close()
end

local function write_text_file(path, text)
	local file = assert(io.open(path, "wb"))
	file:write(text)
	file:write("\n")
	file:close()
end

local function format_bytes(bytes)
	if bytes >= 1024 * 1024 then
		return string.format("%.2f MiB", bytes / (1024 * 1024))
	end

	if bytes >= 1024 then return string.format("%.2f KiB", bytes / 1024) end

	return string.format("%d B", bytes)
end

local function format_duration_ns(ns)
	ns = tonumber(ns) or ns

	if ns >= 1000000000 then return string.format("%.3f s", ns / 1000000000) end

	if ns >= 1000000 then return string.format("%.3f ms", ns / 1000000) end

	if ns >= 1000 then return string.format("%.3f us", ns / 1000) end

	return string.format("%d ns", ns)
end

local function basename(path)
	return path:match("[^/]+$") or path
end

local function elapsed_ns_since(start_ns)
	return tonumber(system.GetTimeNS() - start_ns) or 0
end

local function parse_cli_args()
	local raw_args = system.GetStartupArguments() or {}
	local selected_files = {}
	local enable_profile = true
	local repeat_count = 1
	local i = 1

	while i <= #raw_args do
		local arg = raw_args[i]

		if
			arg == "run" or
			arg == "ogg_decode_bench.lua" or
			basename(arg) == "ogg_decode_bench.lua"
		then

		-- bootstrap args
		elseif arg == "--profile" then
			enable_profile = true
		elseif arg == "--no-profile" then
			enable_profile = false
		elseif arg == "--file" then
			i = i + 1
			assert(raw_args[i], "missing value after --file")
			selected_files[#selected_files + 1] = raw_args[i]
		elseif arg == "--repeat" then
			i = i + 1
			repeat_count = tonumber(raw_args[i]) or 1
			assert(repeat_count >= 1, "--repeat must be >= 1")
		else
			selected_files[#selected_files + 1] = arg
		end

		i = i + 1
	end

	return {
		selected_files = selected_files,
		enable_profile = enable_profile,
		repeat_count = math.floor(repeat_count),
	}
end

local function matches_selected_file(path, patterns)
	if #patterns == 0 then return true end

	local name = basename(path)
	local stem = name:gsub("%.ogg$", "")

	for i = 1, #patterns do
		local pattern = patterns[i]

		if path == pattern or name == pattern or stem == pattern then return true end

		if name:find(pattern, 1, true) or path:find(pattern, 1, true) then
			return true
		end
	end

	return false
end

local function copy_sorted_numbers(values)
	local out = {}

	for i = 1, #values do
		out[i] = values[i]
	end

	table.sort(out)
	return out
end

local function mean(values)
	local total = 0

	for i = 1, #values do
		total = total + values[i]
	end

	return total / math.max(#values, 1)
end

local function median(values)
	local sorted = copy_sorted_numbers(values)
	local count = #sorted

	if count == 0 then return 0 end

	if count % 2 == 1 then return sorted[(count + 1) / 2] end

	local hi = count / 2 + 1
	local lo = hi - 1
	return (sorted[lo] + sorted[hi]) / 2
end

local cli = parse_cli_args()
local corpus = {}

for _, path in ipairs(fs.glob("love_games/mrrescue/data/sfx/*.ogg")) do
	if matches_selected_file(path, cli.selected_files) then
		local data, err = fs.read_file(path)
		assert(data, string.format("failed to read %s: %s", path, tostring(err)))
		corpus[#corpus + 1] = {
			path = path,
			data = data,
			bytes = #data,
		}
	end
end

table.sort(corpus, function(a, b)
	return a.path < b.path
end)

local ok, err = xpcall(
	function()
		local profiler = nil

		if cli.enable_profile then
			profiler = JitProfiler.New{
				id = "ogg_decode_bench",
				path = "game/storage/logs/ogg_decode_bench_profile.html",
				get_time = system.GetTime,
				sampling_rate = 1,
				mode = "line",
				flush_interval = 1,
			}
		end

		assert(#corpus > 0, "no ogg files matched love_games/mrrescue/data/sfx/*.ogg")
		log(string.format("Loaded %d Ogg files from love_games/mrrescue/data/sfx/*.ogg", #corpus))

		if #cli.selected_files > 0 then
			log("Selected files: " .. table.concat(cli.selected_files, ", "))
		end

		log("Profiling: " .. (cli.enable_profile and "enabled" or "disabled"))
		log("Repeat count: " .. cli.repeat_count)
		local total_bytes = 0

		for i = 1, #corpus do
			total_bytes = total_bytes + corpus[i].bytes
		end

		log(string.format("Corpus size: %s", format_bytes(total_bytes)))
		log("")
		local total_decode_ns = 0
		local total_samples = 0
		local results_by_path = {}
		local total_runs = {}
		local wall_start_ns = system.GetTimeNS()

		for repeat_idx = 1, cli.repeat_count do
			if cli.repeat_count > 1 then
				log(string.format("Iteration %d/%d", repeat_idx, cli.repeat_count))
			end

			if profiler and repeat_idx == 1 then profiler:StartSection("decode_corpus") end

			local run_total_decode_ns = 0

			for i = 1, #corpus do
				local item = corpus[i]
				log(string.format("Decoding %s", item.path))

				if profiler and repeat_idx == 1 then profiler:StartSection(item.path) end

				collectgarbage("collect")
				local start_ns = system.GetTimeNS()
				local decoded, decode_err = ogg.Decode(item.data)
				local elapsed_ns = elapsed_ns_since(start_ns)

				if profiler and repeat_idx == 1 then profiler:StopSection() end

				assert(
					decoded,
					string.format("failed to decode %s: %s", item.path, tostring(decode_err))
				)
				assert(decoded.data ~= nil, string.format("decoded data missing for %s", item.path))
				assert(
					(decoded.packets_decoded or 0) > 0,
					string.format("no audio packets decoded for %s", item.path)
				)
				run_total_decode_ns = run_total_decode_ns + elapsed_ns
				local result = results_by_path[item.path]

				if not result then
					result = {
						path = item.path,
						name = basename(item.path),
						bytes = item.bytes,
						times = {},
						samples = tonumber(decoded.samples) or 0,
						channels = decoded.channels or 0,
						sample_rate = decoded.sample_rate or 0,
					}
					results_by_path[item.path] = result
				end

				result.times[#result.times + 1] = elapsed_ns

				if repeat_idx == 1 then
					total_samples = total_samples + (tonumber(decoded.samples) or 0)
				end
			end

			if profiler and repeat_idx == 1 then profiler:StopSection() end

			total_runs[#total_runs + 1] = run_total_decode_ns
			total_decode_ns = total_decode_ns + run_total_decode_ns
		end

		local wall_elapsed_ns = elapsed_ns_since(wall_start_ns)
		local results = {}

		for _, result in pairs(results_by_path) do
			result.decode_ns = cli.repeat_count == 1 and result.times[1] or median(result.times)
			result.best_ns = copy_sorted_numbers(result.times)[1]
			result.mean_ns = mean(result.times)
			results[#results + 1] = result
		end

		table.sort(results, function(a, b)
			return a.decode_ns > b.decode_ns
		end)

		log("Per-file decode times:")

		for i = 1, #results do
			local result = results[i]
			local mib_per_sec = result.bytes > 0 and
				(
					result.bytes / 1024 / 1024
				) / (
					result.decode_ns / 1000000000
				)
				or
				0

			if cli.repeat_count == 1 then
				log(
					string.format(
						"%-18s  %10s  %10s  %8.2f MiB/s  %7d Hz  %d ch  %8d samples",
						result.name,
						format_bytes(result.bytes),
						format_duration_ns(result.decode_ns),
						mib_per_sec,
						result.sample_rate,
						result.channels,
						result.samples
					)
				)
			else
				log(
					string.format(
						"%-18s  %10s  median %10s  best %10s  mean %10s  %8.2f MiB/s",
						result.name,
						format_bytes(result.bytes),
						format_duration_ns(result.decode_ns),
						format_duration_ns(result.best_ns),
						format_duration_ns(result.mean_ns),
						mib_per_sec
					)
				)
			end
		end

		log("")
		log("Summary:")
		log(string.format("  Files decoded: %d", #results))

		if cli.repeat_count == 1 then
			log(string.format("  Total decode time: %s", format_duration_ns(total_decode_ns)))
		else
			log(string.format("  Total decode time sum: %s", format_duration_ns(total_decode_ns)))
			log(string.format("  Total decode median:   %s", format_duration_ns(median(total_runs))))
			log(
				string.format(
					"  Total decode best:     %s",
					format_duration_ns(copy_sorted_numbers(total_runs)[1])
				)
			)
			log(string.format("  Total decode mean:     %s", format_duration_ns(mean(total_runs))))
		end

		log(string.format("  Total wall time:   %s", format_duration_ns(wall_elapsed_ns)))
		log(string.format("  Total input size:  %s", format_bytes(total_bytes)))
		log(string.format("  Total PCM samples: %d", total_samples))
		local throughput_basis = cli.repeat_count == 1 and total_decode_ns or median(total_runs)
		local aggregate_mib_per_sec = total_bytes > 0 and
			(
				total_bytes / 1024 / 1024
			) / (
				throughput_basis / 1000000000
			)
			or
			0
		log(string.format("  Aggregate throughput: %.2f MiB/s", aggregate_mib_per_sec))

		if profiler then
			profiler:Stop()
			local flamegraph_summary = profiler:GetFlamegraphSummary{
				include_sections = true,
				max_frames = 20,
				max_depth = 6,
				max_children = 6,
			}
			log("")
			log(flamegraph_summary)
			write_text_file(profile_summary_path, flamegraph_summary)
		end
	end,
	debug.traceback
)

if not ok then log(err) end

write_report()
system.ShutDown(ok and 0 or 1)
