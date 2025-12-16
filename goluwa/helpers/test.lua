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
local event = require("event")
local test = {}
local total_test_count = 0
local running_tests = {}
local coroutine = _G.coroutine
-- Variables for tracking test execution timing
local current_test_name = ""
local tests_by_file = {}
local current_test_start_time = nil
local current_test_start_gc = nil
-- Callback for when a test file completes (set by logging system)
local on_test_file_complete = nil
-- Logging state (set by BeginTests)
local LOGGING = false
local IS_TERMINAL = true or system.IsTTY()
local completed_test_count = 0
local shown_running_line = false

local function traceback(msg)
	local sep = "\n  "
	local lines = callstack.format(callstack.traceback(""))
	-- Find the last instance of environment.lua or test.lua
	local last_env_index = nil

	for i = 1, #lines do
		if lines[i]:find("environment%.lua") or lines[i]:find("test%.lua") then
			last_env_index = i
		end
	end

	-- Remove everything up to and including the last environment.lua/test.lua
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

function test.Test(name, cb, start, stop)
	local unref = system.KeepAlive("test: " .. name)
	total_test_count = total_test_count + 1
	-- Track that this test belongs to the current file
	tests_by_file[current_test_name] = (tests_by_file[current_test_name] or 0) + 1

	-- Start timing for this file if this is the first test
	if tests_by_file[current_test_name] == 1 then
		current_test_start_time = system.GetTime()
		current_test_start_gc = memory.get_usage_kb()
	end

	-- Create coroutine for the test
	local co = coroutine.create(function()
		if start and stop then
			start()
			cb()
			stop()
		else
			cb()
		end

		unref()
	end)
	-- Capture start time when test is added to queue
	local test_start_time = system.GetTime()
	local test_start_gc = memory.get_usage_kb()
	-- Store the coroutine with metadata
	table.insert(
		running_tests,
		{
			name = name,
			coroutine = co,
			sleep_until = nil,
			test_file = current_test_name,
			test_file_start_time = current_test_start_time,
			test_file_start_gc = current_test_start_gc,
			test_start_time = test_start_time,
			test_start_gc = test_start_gc,
		}
	)

	if not event.IsListenerActive("Update", "test_runner") then
		event.AddListener("Update", "test_runner", test.UpdateTestCoroutines)
	end
end

function test.Pending(...) end

do
	-- Yield control from a test coroutine
	function test.Yield()
		coroutine.yield()
	end

	-- Sleep for a duration (in seconds) without blocking main thread
	function test.Sleep(duration)
		local wake_time = system.GetElapsedTime() + duration
		coroutine.yield(wake_time)
	end

	-- Wait until a condition is true, checking every interval, with optional timeout
	function test.WaitUntil(condition, timeout)
		timeout = timeout or 5.0
		local start_time = system.GetElapsedTime()
		local end_time = start_time + timeout

		while system.GetElapsedTime() < end_time do
			if condition() then return true end

			test.Yield()
		end

		error("WaitUntil: condition not met within timeout of " .. timeout .. " seconds", 2)
	end

	function test.UpdateTestCoroutines()
		local current_time = system.GetElapsedTime()
		local i = 1
		-- Manually update tasks system for faster test execution
		local tasks = package.loaded["tasks"]

		if tasks and tasks.enabled then tasks.Update() end

		while i <= #running_tests do
			local test_info = running_tests[i]

			if not test_info.shown_running then test_info.shown_running = true end

			local should_resume = false

			-- Check if the test is sleeping
			if test_info.sleep_until then
				if current_time >= test_info.sleep_until then
					test_info.sleep_until = nil
					should_resume = true
				end
			else
				should_resume = true
			end

			if should_resume then
				local co = test_info.coroutine

				if coroutine.status(co) ~= "dead" then
					local ok, result = coroutine.resume(co)

					if not ok then
						-- Error in test - format it nicely
						local err_msg = traceback(result)
						error(string.format("Test '%s' error:\n%s", test_info.name, err_msg), 0)
					end

					-- If result is a number, it's a sleep_until wake time
					if type(result) == "number" then test_info.sleep_until = result end
				end

				-- Remove completed tests
				if coroutine.status(co) == "dead" then
					-- Calculate individual test timing
					local test_time = system.GetTime() - test_info.test_start_time
					local test_gc = memory.get_usage_kb() - test_info.test_start_gc
					-- Decrement the counter for this file
					local file = test_info.test_file

					if file and tests_by_file[file] then
						tests_by_file[file] = tests_by_file[file] - 1

						-- Record individual test result
						if on_test_file_complete then
							on_test_file_complete(
								file,
								test_info.name,
								test_time,
								test_gc,
								tests_by_file[file] == 0,
								test_info.test_file_start_time -- Pass file start time
							)
						end
					end

					table.remove(running_tests, i)
					-- Show progress indication
					completed_test_count = completed_test_count + 1

					if LOGGING and IS_TERMINAL then
						-- Clear the RUNNING line if it's still there
						if shown_running_line then
							io_write("\r" .. string.rep(" ", 80) .. "\r")
							shown_running_line = false
						end

						io_write(".")
						io.flush()

						-- Line break every 50 tests, or show progress counter
						if completed_test_count % 50 == 0 then
							io_write(string.format(" %d/%d\n", completed_test_count, total_test_count))
							io.flush()
						end
					end
				else
					i = i + 1
				end
			else
				i = i + 1
			end
		end

		-- Check if all tests are done after the loop
		if #running_tests == 0 then system.ShutDown() end
	end
end

function test.FindTests(filter)
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
	local PROFILING = false
	local max_path_width = 0

	local function format_time(seconds)
		if seconds < 1 then
			return string.format("%4d%s", math.floor(seconds * 1000), colors.dim(" ms"))
		end

		return string.format("%.2f%s", seconds, colors.dim(" s"))
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
			shown_running_line = true
		elseif status == "DONE" then
			io_write(string.format("%s%s %s  %s\n", cr, padded_name, time_str, gc_str))
			shown_running_line = false
		end

		io.flush()
	end

	function test.LoadingIndicator()
		if not LOGGING then return end

		if not IS_TERMINAL then return end

		-- Advance spinner and update line
		spinner_index = (spinner_index % #spinner_chars) + 1
		update_test_line("RUNNING")
	end

	-- Call this before running tests to calculate max width
	function test.SetTestPaths(tests)
		max_path_width = 0

		for _, test_item in ipairs(tests) do
			max_path_width = math.max(max_path_width, #test_item.name)
		end

		-- Add some padding for clean alignment
		max_path_width = max_path_width + 2
	end

	local total_gc = 0
	local test_file_count = 0
	local test_results = {} -- Store results for each test file
	local test_order = {} -- Track the order tests were loaded
	function test.BeginTests(logging, profiling, profiling_mode)
		LOGGING = logging or false
		PROFILING = profiling or false
		completed_test_count = 0
		shown_running_line = false

		if _G.STARTUP_PROFILE then profiler.StopSection() end

		if PROFILING and not _G.STARTUP_PROFILE then
			profiler.Start(profiling_mode)
		end

		-- Set up the callback for test completion
		on_test_file_complete = function(test_file_name, test_name, time, gc, is_last, file_start_time)
			-- Initialize file results if needed
			if not test_results[test_file_name] then
				test_results[test_file_name] = {
					tests = {},
					total_time = 0,
					total_gc = 0,
					file_start_time = file_start_time,
				}
			end

			local file_result = test_results[test_file_name]
			-- Store individual test result
			table.insert(file_result.tests, {
				name = test_name,
				time = time,
				gc = gc,
			})
			-- Update GC total
			file_result.total_gc = file_result.total_gc + gc
			total_gc = total_gc + gc

			-- If this is the last test, calculate actual elapsed time for the file
			if is_last and file_result.file_start_time then
				file_result.total_time = system.GetTime() - file_result.file_start_time
			end
		end
	end

	local function run_func(func, ...)
		local ok, err = xpcall(func, traceback, ...)

		if not ok then return false, err end

		return true
	end

	function test.RunSingleTestSet(test_item)
		current_test_name = test_item.name
		-- Track the order for display later
		table.insert(test_order, test_item.name)

		-- You'll need to pass the expected test count somehow, or estimate it
		-- For now, setting to 0 means no progress counter shown
		if LOGGING then update_test_line("RUNNING") end

		local func, err = loadfile(test_item.path)

		if not func then
			error("failed to load " .. test_item.name .. ":\n" .. err, 2)
		end

		local ok, err = run_func(func)

		if not ok then error("failed to run " .. test_item.name .. ":\n" .. err, 2) end

		test_file_count = test_file_count + 1
	end

	function test.EndTests()
		local luajit_startup_time = _G.EARLY_STARTUP_TIME or 0
		local actual_total = os.clock() - luajit_startup_time

		if PROFILING then profiler.Stop() end

		if test_file_count > 0 then
			-- Display results for each test file that has completed, in order
			if LOGGING then
				-- Add newline after progress dots if needed
				if IS_TERMINAL and completed_test_count > 0 then io_write("\n") end

				for _, file_name in ipairs(test_order) do
					local result = test_results[file_name]

					if result then
						-- Print file name
						io_write(colors.bold(file_name) .. "\n")

						-- Print individual tests
						for _, test in ipairs(result.tests) do
							local time_str = ""
							local gc_str = ""

							-- Only show time if >= 100ms
							if test.time >= 0.1 then
								time_str = " " .. format_time(test.time)
							end

							-- Only show GC if >= 1MB
							local gc_mb = math.floor(test.gc / 1024)

							if math.abs(gc_mb) >= 1 then gc_str = "  " .. format_gc(test.gc) end

							io_write(string.format("  %s%s%s\n", test.name, time_str, gc_str))
						end -- Print file total
						io_write(
							colors.dim(
								string.format(
									"  - total %s  %s\n",
									format_time(result.total_time),
									format_gc(result.total_gc)
								)
							)
						)
					end
				end
			end

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

-- Run the event loop for a specific duration
function test.RunFor(duration)
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
		system.Sleep(0.001)
	end
end

-- Run event loop until condition is met or timeout
function test.RunUntil(condition, timeout)
	timeout = timeout or 5.0
	local start_time = system.GetElapsedTime()
	local end_time = start_time + timeout

	while system.GetElapsedTime() < end_time do
		if condition() then return true end

		local dt = 0.016 -- ~60fps simulation
		system.SetElapsedTime(system.GetElapsedTime() + dt)
		event.Call("Update", dt)
		system.Sleep(0.001)
	end

	return false -- timeout
end

-- Run event loop until condition is met or timeout
function test.RunUntil2(condition, timeout)
	timeout = timeout or 5.0
	local start_time = system.GetTime()
	local end_time = start_time + timeout

	while system.GetTime() < end_time do
		if condition() then return true end

		system.Sleep(0.001)
	end

	return false -- timeout
end

local attest = require("helpers.attest")
setmetatable(test, {
	__call = function(_, val)
		return attest.AssertHelper(val)
	end,
})
return test
