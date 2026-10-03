local json = import("goluwa/codecs/json.lua")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local benchmark_results = library()
local MIN_RELATIVE_BAND = 0.02
local FINGERPRINT_TOLERANCE = 0.1
local META = {}
META.__index = META

local function sanitize(name)
	return (name:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

local function get_directory(name)
	return vfs.GetStorageDirectory("storage") .. "logs/bench/" .. sanitize(name) .. "/"
end

local function run_command(command)
	local pipe = io.popen(command .. " 2>/dev/null")

	if not pipe then return "" end

	local output = pipe:read("*a") or ""
	pipe:close()
	return (output:gsub("%s+$", ""))
end

local function read_json(path)
	local content = fs.read_file(path)

	if not content or content == "" then return nil end

	local ok, decoded = pcall(json.decode, content)
	return ok and decoded or nil
end

function benchmark_results.New(name)
	return setmetatable({name = name, entries = {}, fingerprints = {}}, META)
end

function META:Add(key, value, noise, unit)
	assert(value == value and math.abs(value) ~= math.huge, key .. " is not a finite number")
	self.entries[#self.entries + 1] = {key = key, value = value, noise = noise or 0, unit = unit or ""}
end

function META:AddFingerprint(key, value)
	self.fingerprints[#self.fingerprints + 1] = {key = key, value = value}
end

local function index_by_key(list)
	local out = {}

	for _, entry in ipairs(list or {}) do
		out[entry.key] = entry
	end

	return out
end

local function print_compare(self, baseline, label)
	local old = index_by_key(baseline.entries)
	local changed, slower = 0, 0
	print(
		string.format(
			"[COMPARE] against the %s from %s (commit %s%s)",
			label,
			baseline.date or "?",
			baseline.commit or "?",
			baseline.dirty and "+changes" or ""
		)
	)
	local old_fingerprints = index_by_key(baseline.fingerprints)

	for _, fingerprint in ipairs(self.fingerprints) do
		local previous = old_fingerprints[fingerprint.key]

		if
			previous and
			previous.value > 0 and
			math.abs(fingerprint.value - previous.value) / previous.value > FINGERPRINT_TOLERANCE
		then
			print(
				string.format(
					"[COMPARE] WARNING %s was %.1f, now %.1f: the scene was in a different state, timings are not comparable",
					fingerprint.key,
					previous.value,
					fingerprint.value
				)
			)
		end
	end

	for _, entry in ipairs(self.entries) do
		local previous = old[entry.key]

		if previous then
			local delta = entry.value - previous.value
			local band = math.max(
				2 * math.sqrt(entry.noise ^ 2 + previous.noise ^ 2),
				MIN_RELATIVE_BAND * math.abs(previous.value)
			)
			local verdict = "same"

			if delta > band then
				verdict = "SLOWER"
				slower = slower + 1
				changed = changed + 1
			elseif delta < -band then
				verdict = "faster"
				changed = changed + 1
			end

			if verdict ~= "same" then
				print(
					string.format(
						"[COMPARE] %-44s %10.3f -> %10.3f %s (%+.1f%%, band %.3f) %s",
						entry.key,
						previous.value,
						entry.value,
						entry.unit,
						previous.value ~= 0 and delta / previous.value * 100 or 0,
						band,
						verdict
					)
				)
			end
		end
	end

	print(
		string.format(
			"[COMPARE] %d of %d numbers changed beyond the noise, %d of them slower",
			changed,
			#self.entries,
			slower
		)
	)
end

function META:Finish()
	local directory = get_directory(self.name)
	fs.create_directory_recursive(directory)
	self.date = os.date("%Y-%m-%d %H:%M:%S")
	self.commit = run_command("git rev-parse --short HEAD")
	self.dirty = run_command("git status --porcelain goluwa addons test") ~= ""
	local baseline = read_json(directory .. "baseline.json")
	local label = "baseline"

	if not baseline then
		baseline = read_json(directory .. "latest.json")
		label = "previous run"
	end

	if baseline and os.getenv("GOLUWA_BENCH_COMPARE") ~= "0" then
		print_compare(self, baseline, label)
	elseif os.getenv("GOLUWA_BENCH_COMPARE") ~= "0" then
		print("[COMPARE] nothing saved to compare with yet")
	end

	local encoded = json.encode{
		name = self.name,
		date = self.date,
		commit = self.commit,
		dirty = self.dirty,
		entries = self.entries,
		fingerprints = self.fingerprints,
	}
	fs.write_file(directory .. "latest.json", encoded)

	if os.getenv("GOLUWA_BENCH_BASELINE") == "1" then
		fs.write_file(directory .. "baseline.json", encoded)
		print("[COMPARE] saved this run as the baseline")
	end
end

return benchmark_results
