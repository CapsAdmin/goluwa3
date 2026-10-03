local commands = import("goluwa/cli/commands.lua")
local fs = import("goluwa/filesystem/fs.lua")
local process = import("goluwa/bindings/process.lua")
local system = import("goluwa/system.lua")
local DIRECTORY = "test/benchmarks/"

local function find_benchmarks()
	local benchmarks = {}
	local names = fs.get_files(fs.get_current_directory() .. "/" .. DIRECTORY) or {}
	table.sort(names)

	for _, file_name in ipairs(names) do
		if file_name:ends_with(".lua") then
			local path = DIRECTORY .. file_name
			local file = assert(io.open(path, "rb"))
			local flags = file:read("*l"):match("^%-%- glw:%s*(.-)%s*$")
			file:close()
			benchmarks[#benchmarks + 1] = {
				name = file_name:sub(1, -5),
				path = path,
				flags = flags,
			}
		end
	end

	return benchmarks
end

commands.Add({
	aliases = "bench",
	argtypes = "string|nil",
	flags = {
		baseline = {
			type = "boolean",
			description = "Also save each result as the baseline that later runs are compared with",
		},
		["no-compare"] = {
			type = "boolean",
			description = "Do not compare with the baseline or the previous run",
		},
	},
}, function(pattern, flags)
	local benchmarks = find_benchmarks()

	if not pattern then
		logn("benchmarks in ", DIRECTORY, ", run with: luajit glw bench <name part|all>")

		for _, benchmark in ipairs(benchmarks) do
			if benchmark.flags then
				logf("  %-32s %s\n", benchmark.name, benchmark.flags)
			else
				logf("  %-32s (no \"-- glw: <flags>\" first line, not run by bench)\n", benchmark.name)
			end
		end

		system.ShutDown(0)
		return
	end

	local selected = {}

	for _, benchmark in ipairs(benchmarks) do
		if benchmark.flags and (pattern == "all" or benchmark.name:find(pattern, nil, true)) then
			selected[#selected + 1] = benchmark
		end
	end

	if not selected[1] then error("no benchmark matches '" .. pattern .. "'", 0) end

	local failed = 0

	if flags.baseline then process.setenv("GOLUWA_BENCH_BASELINE", "1") end

	if flags["no-compare"] then process.setenv("GOLUWA_BENCH_COMPARE", "0") end

	for _, benchmark in ipairs(selected) do
		local args = {"glw"}

		for flag in benchmark.flags:gmatch("%S+") do
			args[#args + 1] = flag
		end

		args[#args + 1] = "lua"
		args[#args + 1] = benchmark.path
		logf("\n===== %s (luajit %s)\n", benchmark.name, table.concat(args, " "))
		io.stdout:flush()
		local start = system.GetTime()
		local child = assert(process.spawn{command = "luajit", args = args})
		benchmark.code = child:wait()
		benchmark.seconds = system.GetTime() - start
		failed = failed + (benchmark.code == 0 and 0 or 1)
	end

	logn("\nbenchmarks:")

	for _, benchmark in ipairs(selected) do
		logf(
			"  %-32s %s in %.0f s\n",
			benchmark.name,
			benchmark.code == 0 and
				"ok" or
				"FAILED (exit " .. tostring(benchmark.code) .. ")",
			benchmark.seconds
		)
	end

	system.ShutDown(failed == 0 and 0 or 1)
end)
