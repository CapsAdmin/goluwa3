local io = require("io")
local io_write = io.write
local diff = require("helpers.diff")
local fs = require("fs")
local debug = require("debug")
local pcall = _G.pcall
local type = _G.type
local ipairs = _G.ipairs
local xpcall = _G.xpcall
local assert = _G.assert
local loadfile = _G.loadfile
local profiler = require("profiler")
local jit = _G.jit
local table = _G.table
local memory = require("bindings.memory")
local colors = require("helpers.colors")
local callstack = require("helpers.callstack")
local system = require("system")
local total_test_count = 0

local function traceback(msg)
	local sep = "\n  "
	local lines = callstack.format(callstack.traceback(""))
	-- Find the last instance of environment.lua
	local last_env_index = nil

	for i = 1, #lines do
		if lines[i]:find("environment%.lua") then last_env_index = i end
	end

	-- Remove everything up to and including the last environment.lua
	if last_env_index then
		for _ = 1, last_env_index do
			table.remove(lines, 1)
		end
	end

	for i = #lines, 1, -1 do
		local line = lines[i]

		if line:starts_with("@0x") or line:starts_with("test/run.lua") then
			table.remove(lines, i)
		end
	end

	if not lines[1] then return msg end

	return msg .. sep .. table.concat(lines, sep)
end

function _G.test(name, cb, start, stop)
	total_test_count = total_test_count + 1

	if start and stop then
		local ok_start, err_start = xpcall(start, traceback)
		local ok_cb, err_cb = xpcall(cb, traceback)
		local ok_stop, err_stop = xpcall(stop, traceback)

		-- Report errors in priority order, but only after all functions have run
		if not ok_start then
			error(string.format("Test '%s' setup failed: %s", name, err_start), 2)
		elseif not ok_cb then
			error(string.format("Test '%s' failed: %s", name, err_cb), 2)
		elseif not ok_stop then
			error(string.format("Test '%s' teardown failed: %s", name, err_stop), 2)
		end
	else
		-- If setup/teardown not provided, just run the test
		local ok_cb, err_cb = xpcall(cb, traceback)

		if not ok_cb then
			error(string.format("Test '%s' failed: %s", name, err_cb), 2)
		end
	end
end

function _G.pending(...) end

function _G.find_tests(filter)
	local test_directory = fs.get_current_directory() .. "/test/tests/"
	local filtered = {}
	local files = fs.get_files_recursive(test_directory)

	if not filter or filter == "all" then
		filtered = files
	else
		for _, path in ipairs(files) do
			if path:find(filter, nil, true) then table.insert(filtered, path) end
		end
	end

	local other = {}

	for _, path in pairs(filtered) do
		if fs.is_file(path) then table.insert(other, path) end
	end

	local expanded = {}

	for i, path in ipairs(other) do
		local name = path:gsub(test_directory, "")
		table.insert(expanded, {
			path = path,
			name = name,
		})
	end

	return expanded
end

do
	local LOGGING = false
	local PROFILING = false
	local IS_TERMINAL = system.IsTTY()
	local max_path_width = 0
	local current_test_name = ""

	local function format_time(seconds)
		if seconds < 1 then
			return string.format("%4d%s", math.floor(seconds * 1000), colors.dim(" ms"))
		end

		return string.format("%4f%s", seconds, colors.dim(" s"))
	end

	local function format_gc(kb)
		return string.format("%4d%s", math.floor(kb / 1024), colors.dim(" mb"))
	end

	local spinner_chars = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"}
	local spinner_index = 1

	local function update_test_line(status, time_str, gc_str)
		if not LOGGING then return end

		local padded_name = current_test_name .. string.rep(" ", max_path_width - #current_test_name)
		local cr = IS_TERMINAL and "\r" or ""

		if status == "RUNNING" and IS_TERMINAL then
			local spinner = spinner_chars[spinner_index]
			io_write(string.format("%s%s %s RUNNING...", cr, padded_name, spinner))
		elseif status == "DONE" then
			io_write(string.format("%s%s %s  %s\n", cr, padded_name, time_str, gc_str))
		end

		io.flush()
	end

	function _G.loading_indicator()
		if not LOGGING then return end

		if not IS_TERMINAL then return end

		-- Advance spinner and update line
		spinner_index = (spinner_index % #spinner_chars) + 1
		update_test_line("RUNNING")
	end

	-- Call this before running tests to calculate max width
	function _G.set_test_paths(tests)
		max_path_width = 0

		for _, test in ipairs(tests) do
			max_path_width = math.max(max_path_width, #test.name)
		end

		-- Add some padding for clean alignment
		max_path_width = max_path_width + 2
	end

	local total_gc = 0
	local test_file_count = 0

	function _G.begin_tests(logging, profiling, profiling_mode)
		LOGGING = logging or false
		PROFILING = profiling or false

		if _G.STARTUP_PROFILE then profiler.StopSection() end

		if PROFILING and not _G.STARTUP_PROFILE then
			profiler.Start(profiling_mode)
		end
	end

	local function run_func(func, ...)
		local gc = memory.get_usage_kb()
		local time = system.GetTime()
		local ok, err = xpcall(func, traceback, ...)
		time = system.GetTime() - time
		gc = memory.get_usage_kb() - gc
		-- Update final result
		update_test_line("DONE", format_time(time), format_gc(gc))
		total_gc = total_gc + gc
		return ok, err
	end

	function _G.run_single_test(test)
		current_test_name = test.name

		-- You'll need to pass the expected test count somehow, or estimate it
		-- For now, setting to 0 means no progress counter shown
		if LOGGING then update_test_line("RUNNING") end

		local func, err = loadfile(test.path)

		if not func then error("failed to load " .. test.name .. ":\n" .. err, 2) end

		local ok, err = run_func(func)

		if not ok then error("failed to run " .. test.name .. ":\n" .. err, 2) end

		test_file_count = test_file_count + 1
	end

	function _G.end_tests()
		local luajit_startup_time = _G.EARLY_STARTUP_TIME or 0
		local actual_total = os.clock() - luajit_startup_time

		if PROFILING then profiler.Stop() end

		if test_file_count > 0 then
			local times = profiler.GetSimpleSections()

			-- base environment time is included in startup time, so remove it
			if times["startup"] then
				times["startup"].total = times["startup"].total - times["base environment"].total
			end

			local sorted = {}
			local sections_total = 0

			for name, data in pairs(times) do
				table.insert(sorted, {name = name, total = data.total})
				sections_total = sections_total + data.total
			end

			table.insert(sorted, {name = "luajit", total = luajit_startup_time})
			table.insert(sorted, {name = "untracked", total = actual_total - sections_total})

			table.sort(sorted, function(a, b)
				return a.total > b.total
			end)

			local details = {}

			for _, data in ipairs(sorted) do
				table.insert(details, colors.dim(string.format("%s: %s", data.name, format_time(data.total))))
			end

			io_write(
				"\n",
				"ran ",
				total_test_count,
				" tests in ",
				test_file_count,
				" files",
				"\n\n"
			)
			io_write(table.concat(details, colors.dim(" +\n")), "\n")
			io_write(string.format("total: %s", format_time(actual_total)), "\n")
			io_write(string.format("memory allocated: %s\n", format_gc(total_gc)))
		end
	end
end

do
	local attest = require("goluwa.helpers.attest")
	_G.attest = attest

	do -- backwards compatibility
		_G.eq = attest.equal
		_G.equal = attest.equal
		_G.ok = attest.ok
	end
end

do -- async test helpers
	local event = require("event")
	local system = require("system")

	-- Run the event loop for a specific duration
	function _G.run_for(duration)
		local start_time = system.GetElapsedTime()
		local end_time = start_time + duration

		while system.GetElapsedTime() < end_time do
			local current_time = system.GetTime()
			local dt = 0.016 -- ~60fps simulation
			-- Advance elapsed time
			system.SetElapsedTime(system.GetElapsedTime() + dt)
			-- Call update event which triggers timers, sockets, etc.
			event.Call("Update", dt)

			-- Small sleep to prevent busy loop (optional)
			-- In real tests you might want to remove this for speed
			if system.Sleep then system.Sleep(0.001) end
		end
	end

	-- Run event loop until condition is met or timeout
	function _G.run_until(condition, timeout)
		timeout = timeout or 5.0
		local start_time = system.GetElapsedTime()
		local end_time = start_time + timeout

		while system.GetElapsedTime() < end_time do
			if condition() then return true end

			local dt = 0.016 -- ~60fps simulation
			system.SetElapsedTime(system.GetElapsedTime() + dt)
			event.Call("Update", dt)

			if system.Sleep then system.Sleep(0.001) end
		end

		return false -- timeout
	end
end
