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
local tasks = require("tasks")
local test = {}
local total_test_count = 0
local coroutine = _G.coroutine
local TEST_TIMEOUT = 10 -- Hard timeout for each test in seconds
-- Variables for tracking test execution timing
local current_test_name = ""
local tests_by_file = {}
local current_test_start_time = nil
local current_test_start_gc = nil
-- Callback for when a test file completes (set by logging system)
local on_test_file_complete = nil
-- Logging state (set by BeginTests)
local LOGGING = false
local VERBOSE = false
local NESTING = false
local IS_TERMINAL = true -- or system.IsTTY()
local NO_SUMMARY = false
local completed_test_count = 0
local shown_running_line = false
local has_failed_tests = false

local function traceback(msg, co_lines)
	local sep = "\n  "
	local lines

	if co_lines then
		lines = co_lines
		lines = lines:replace("stack traceback:"):split("\n")

		for i, line in ipairs(lines) do
			lines[i] = line:trim()
		end

		table.remove(lines, 1)
	else
		lines = callstack.format(callstack.traceback(""))

		for i, line in ipairs(lines) do
			lines[i] = line:trim()
		end
	end

	-- Find the last instance of atttest.lua
	local last_env_index = nil

	for i = 1, #lines do
		if lines[i]:find("attest.lua", 1, true) then last_env_index = i end
	end

	if last_env_index then
		for _ = 1, last_env_index do
			table.remove(lines, 1)
		end
	end

	for i = #lines, 1, -1 do
		local line = lines[i]

		if not line:find(".lua", 1, true) then
			-- remove non actionable lines
			table.remove(lines, i)
		end
	end

	if not lines[1] then return msg end

	local test_location

	for i = #lines, 1, -1 do
		local line = lines[i]
		local path = line:match("(test/.-:%d+):")

		if path then
			test_location = path

			break
		end
	end

	if test_location then msg = test_location .. "\n\n" .. msg end

	return msg .. sep .. table.concat(lines, sep)
end

function test.RunTestsWithFilter(filter, config)
	test.BeginTests(
		config.logging,
		config.profiling,
		config.profiling_mode,
		config.verbose,
		config.no_summary
	)
	local tests = test.FindTests(filter)
	test.SetTestPaths(tests)

	for _, test_item in ipairs(tests) do
		test.RunSingleTestSet(test_item)
	end

	if config.logging and not config.no_summary then
		local filter_str = (filter and (" with filter '" .. filter .. "'") or "")

		if #tests == 0 then
			logn("no tests found" .. filter_str)
		else
			logn("running ", #tests, #tests == 1 and " test" or " tests", filter_str)
		end
	end
end

local tasks = require("tasks")
local active_test_tasks = {}
-- Create a marker object for unavailable tests
local unavailable_marker = {}

function test.Test(name, cb, start, stop)
	-- Check if we're inside another test task (nested test)
	local current_task = tasks.GetActiveTask()

	if current_task and active_test_tasks[current_task] then
		-- We're nested - create inner task directly without recursion
		local inner_task = test._CreateTestTask(name, cb, start, stop)
		local ok, err = tasks.WaitForNestedTask(inner_task)

		if not ok then
			error("nested test failed: " .. name .. ": " .. tostring(err), 0)
		end

		return inner_task
	end

	return test._CreateTestTask(name, cb, start, stop)
end

function test._CreateTestTask(name, cb, start, stop)
	local unref = system.KeepAlive("test: " .. name)
	total_test_count = total_test_count + 1
	-- Track that this test belongs to the current file
	tests_by_file[current_test_name] = (tests_by_file[current_test_name] or 0) + 1

	-- Start timing for this file if this is the first test
	if tests_by_file[current_test_name] == 1 then
		current_test_start_time = system.GetTime()
		current_test_start_gc = memory.get_usage_kb()
	end

	-- Capture start time when test is added to queue
	local test_start_time = system.GetTime()
	local test_start_gc = memory.get_usage_kb()
	local test_timeout_time = system.GetTime() + TEST_TIMEOUT
	-- Need to capture task info before closure
	local task_failed = false
	local task_error = nil
	local task = tasks.CreateTask(
		function(task_self)
			task_self.is_test_task = true

			-- Check for timeout at start
			if system.GetTime() > test_timeout_time then
				error(string.format("Test timeout: exceeded %d second limit", TEST_TIMEOUT), 0)
			end

			local result

			if start and stop then
				start()
				result = cb()
				stop()
			else
				result = cb()
			end

			-- Check if test returned an unavailable marker
			if
				type(result) == "table" and
				getmetatable(result) and
				getmetatable(result).__index == unavailable_marker
			then
				task_self.unavailable = true
				task_self.unavailable_reason = result.reason or "Test unavailable"
			end

			unref()
		end,
		function(self, res)
			-- OnFinish
			local test_time = system.GetTime() - test_start_time
			local test_gc = memory.get_usage_kb() - test_start_gc
			local file = current_test_name

			if file and tests_by_file[file] then
				tests_by_file[file] = tests_by_file[file] - 1

				-- Record individual test result
				if on_test_file_complete then
					on_test_file_complete(
						file,
						name,
						test_time,
						test_gc,
						tests_by_file[file] == 0,
						current_test_start_time,
						not self.failed and not self.unavailable,
						self.error,
						false,
						self.unavailable and self.unavailable_reason or nil
					)
				end
			end

			-- Show progress indication
			completed_test_count = completed_test_count + 1

			if LOGGING and IS_TERMINAL and not NO_SUMMARY then
				-- Clear the RUNNING line if it's still there
				if shown_running_line then
					io_write("\r" .. string.rep(" ", 80) .. "\r")
					shown_running_line = false
				end

				if VERBOSE then
					-- Show full test name in verbose mode
					io_write(string.format("[%d/%d] %s\n", completed_test_count, total_test_count, name))
					io.flush()
				else
					-- Show appropriate marker
					if self.unavailable then
						io_write(colors.dim("-"))
					else
						io_write(".")
					end

					io.flush()

					-- Line break every 50 tests, or show progress counter
					if completed_test_count % 50 == 0 then
						io_write(string.format(" %d/%d\n", completed_test_count, total_test_count))
						io.flush()
					end
				end
			end

			active_test_tasks[self] = nil

			-- Check if all tests are done
			if not tasks.IsBusy() then
				system.ShutDown(has_failed_tests and 1 or 0)
			end
		end,
		true,
		function(self, err, co)
			-- OnError
			has_failed_tests = true
			self.failed = true
			local tb = debug.traceback(co)
			local current_dir = fs.get_current_directory() .. "/"
			err = tostring(err):gsub(current_dir, ""):gsub("^%.%.%.[^/]*", ""):gsub("^.-/projects/goluwa3/", "")
			tb = tb:gsub(current_dir, ""):gsub("[\n ]+%.%.%.[^/]*", ""):gsub("^.-/projects/goluwa3/", "")
			self.error = traceback(err, tb)
			local test_location = self.error:match("^(test/.-:%d+)\n\n")

			if test_location then
				local err_msg = self.error:sub(#test_location + 3)
				err_msg = err_msg:gsub("\n  ", "\n")
				err_msg = err_msg:indent(1)
				logn(colors.red("Test '" .. name .. "' failed:\n" .. test_location .. "\n" .. err_msg))
			else
				logn(colors.red("Test '" .. name .. "' failed:\n" .. self.error))
			end

			-- Record test completion even on failure
			local test_time = system.GetTime() - test_start_time
			local test_gc = memory.get_usage_kb() - test_start_gc
			local file = current_test_name

			if file and tests_by_file[file] then
				tests_by_file[file] = tests_by_file[file] - 1

				-- Record individual test result
				if on_test_file_complete then
					on_test_file_complete(
						file,
						name,
						test_time,
						test_gc,
						tests_by_file[file] == 0,
						current_test_start_time,
						false, -- success = false
						self.error,
						false,
						nil
					)
				end
			end

			-- Show progress indication
			completed_test_count = completed_test_count + 1

			if LOGGING and IS_TERMINAL and not NO_SUMMARY then
				-- Clear the RUNNING line if it's still there
				if shown_running_line then
					io_write("\r" .. string.rep(" ", 80) .. "\r")
					shown_running_line = false
				end

				-- Show progress dot
				if not NESTING then
					io_write(colors.red("✗"))

					-- Line break every 50 tests, or show progress counter
					if completed_test_count % 50 == 0 then
						io_write(string.format(" %d/%d\n", completed_test_count, total_test_count))
						io.flush()
					end
				end
			end

			active_test_tasks[self] = nil

			-- Check if all tests are done
			if not tasks.IsBusy() then
				system.ShutDown(has_failed_tests and 1 or 0)
			end
		end
	)
	task:SetName(name)
	task:SetIterationsPerTick(10)
	task.is_test_task = true -- Mark as test task to prevent auto-waiting in callbacks
	task.test_timeout_time = test_timeout_time -- Store timeout for checking
	active_test_tasks[task] = true

	if not event.IsListenerActive("Update", "test_runner") then
		event.AddListener("Update", "test_runner", test.UpdateTestCoroutines)
	end

	return task
end

function test.Pending(name)
	total_test_count = total_test_count + 1
	-- Track that this test belongs to the current file
	tests_by_file[current_test_name] = (tests_by_file[current_test_name] or 0) + 1

	-- Start timing for this file if this is the first test
	if tests_by_file[current_test_name] == 1 then
		current_test_start_time = system.GetTime()
		current_test_start_gc = memory.get_usage_kb()
	end

	local task = tasks.CreateTask(
		function() end,
		function()
			local file = current_test_name

			if file and tests_by_file[file] then
				tests_by_file[file] = tests_by_file[file] - 1

				-- Record individual test result
				if on_test_file_complete then
					on_test_file_complete(
						file,
						name,
						0,
						0,
						tests_by_file[file] == 0,
						current_test_start_time,
						true,
						nil,
						true,
						nil
					)
				end
			end

			-- Show progress indication
			completed_test_count = completed_test_count + 1

			if LOGGING and IS_TERMINAL and not NO_SUMMARY then
				-- Clear the RUNNING line if it's still there
				if shown_running_line then
					io_write("\r" .. string.rep(" ", 80) .. "\r")
					shown_running_line = false
				end

				io_write(colors.yellow("?"))
				io.flush()

				-- Line break every 50 tests, or show progress counter
				if completed_test_count % 50 == 0 then
					io_write(string.format(" %d/%d\n", completed_test_count, total_test_count))
					io.flush()
				end
			end

			-- Check if all tests are done
			if not tasks.IsBusy() then
				system.ShutDown(has_failed_tests and 1 or 0)
			end
		end,
		true
	)
	task:SetName(name)

	if not event.IsListenerActive("Update", "test_runner") then
		event.AddListener("Update", "test_runner", test.UpdateTestCoroutines)
	end
end

function test.Unavailable(reason)
	return setmetatable({reason = reason}, {__index = unavailable_marker})
end

do
	-- Yield control from a test coroutine
	function test.Yield()
		-- Sleep for a small amount to avoid tight spinning
		-- This ensures the main loop actually advances time
		tasks.Wait(0.001)
	end

	-- Sleep for a duration (in seconds) without blocking main thread
	function test.Sleep(duration)
		local start_time = system.GetElapsedTime()
		local end_time = start_time + duration

		while system.GetElapsedTime() < end_time do
			local dt = 0.016 -- ~60fps simulation
			system.SetElapsedTime(system.GetElapsedTime() + dt)
			event.Call("Update", dt)
			system.Sleep(0.001) -- Sleep CPU, not coroutine
		end
	end

	-- Wait until a condition is true, checking every interval, with optional timeout
	function test.WaitUntil(condition, timeout)
		timeout = timeout or 10
		local start_time = system.GetElapsedTime()
		local end_time = start_time + timeout

		while system.GetElapsedTime() < end_time do
			if condition() then return true end

			test.Yield()
		end

		error("WaitUntil: condition not met within timeout of " .. timeout .. " seconds", 2)
	end

	function test.UpdateTestCoroutines()
		-- Manually update tasks system for faster test execution
		if tasks and tasks.IsEnabled() then tasks.Update() end
	end
end

function test.FindTests(filter)
	local test_directory_full = fs.get_current_directory() .. "/test/tests/"
	local test_directory_rel = "test/tests/"
	local filtered = {}
	local files = fs.get_files_recursive(test_directory_full)

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
		local name = path:gsub(test_directory_full, "")
		local relative_path = path:gsub(fs.get_current_directory() .. "/", "")
		table.insert(expanded, {
			path = relative_path,
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
		if not LOGGING or NO_SUMMARY then return end

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
		if not LOGGING or NO_SUMMARY then return end

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
	function test.BeginTests(logging, profiling, profiling_mode, verbose, no_summary)
		LOGGING = logging or false
		VERBOSE = verbose or false
		PROFILING = profiling or false
		NO_SUMMARY = no_summary or false
		completed_test_count = 0
		shown_running_line = false
		has_failed_tests = false

		if _G.STARTUP_PROFILE then profiler.StopSection() end

		if PROFILING and not _G.STARTUP_PROFILE then
			profiler.Start(profiling_mode)
		end

		-- Set up the callback for test completion
		on_test_file_complete = function(
			test_file_name,
			test_name,
			time,
			gc,
			is_last,
			file_start_time,
			success,
			err,
			pending,
			unavailable_reason
		)
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
			table.insert(
				file_result.tests,
				{
					name = test_name,
					time = time,
					gc = gc,
					success = success,
					error = err,
					pending = pending,
					unavailable_reason = unavailable_reason,
				}
			)
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
		if VERBOSE then logn("loading test: " .. test_item.path) end

		current_test_name = test_item.name
		-- Track the order for display later
		table.insert(test_order, test_item.name)

		-- You'll need to pass the expected test count somehow, or estimate it
		-- For now, setting to 0 means no progress counter shown
		if LOGGING and not NO_SUMMARY then update_test_line("RUNNING") end

		local func, err = loadfile(test_item.path)

		if not func then
			error("failed to load " .. test_item.name .. ":\n" .. err, 2)
		end

		local ok, err = run_func(func)

		if not ok then error("failed to run " .. test_item.name .. ":\n" .. err, 2) end

		test_file_count = test_file_count + 1
	end

	function test.EndTests(no_summary)
		local luajit_startup_time = _G.EARLY_STARTUP_TIME or 0
		local actual_total = os.clock() - luajit_startup_time

		if PROFILING then profiler.Stop() end

		if test_file_count > 0 then
			-- Display results for each test file that has completed, in order
			if LOGGING then
				-- Add newline after progress dots if needed
				if IS_TERMINAL and completed_test_count > 0 then io_write("\n") end

				local total_failed = 0
				local total_pending = 0
				local total_unavailable = 0

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

							local status = colors.green("✓")

							if test.unavailable_reason then
								status = colors.dim("-")
								total_unavailable = total_unavailable + 1
							elseif test.success == false then
								status = colors.red("✗")
								total_failed = total_failed + 1
							elseif test.pending then
								status = colors.yellow("?")
								total_pending = total_pending + 1
							end

							io_write(string.format("  %s %s%s%s\n", status, test.name, time_str, gc_str))

							if test.unavailable_reason then
								io_write(colors.dim("    " .. test.unavailable_reason) .. "\n")
							end
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

				if no_summary then
					io_write(string.format("\n#tests=%d\n", total_test_count))
					return
				end

				if total_failed > 0 then
					io_write(
						"\n" .. colors.red(string.format("FAILED: %d tests failed", total_failed)) .. "\n"
					)
				elseif total_pending > 0 then
					io_write(
						"\n" .. colors.yellow(string.format("PENDING: %d tests pending", total_pending)) .. "\n"
					)
				elseif total_unavailable > 0 then
					io_write(
						"\n" .. colors.dim(string.format("PASSED: all tests passed (%d unavailable)", total_unavailable)) .. "\n"
					)
				else
					io_write("\n" .. colors.green("PASSED: all tests passed") .. "\n")
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

function test.Screenshot(name)
	local render = require("render.render")
	render.target:GetTexture():SaveAs(name)
end

function test.ScreenshotAlbedo(name)
	local render3d = require("render3d.render3d")
	render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(1):SaveAs(name)
end

function test.AssertScreenPixel(tbl)
	local render = require("render.render")
	return test.TexturePixel(
		render.target:GetTexture(),
		tbl.pos[1],
		tbl.pos[2],
		tbl.color[1],
		tbl.color[2],
		tbl.color[3],
		tbl.color[4],
		tbl.tolerance
	)
end

function test.ScreenAlbedoPixel(x, y, r, g, b, a, tolerance)
	local render3d = require("render3d.render3d")
	return test.TexturePixel(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(1), x, y, r, g, b, a, tolerance)
end

function test.TexturePixel(tex, x, y, r, g, b, a, tolerance)
	tolerance = tolerance or 0.01

	if type(r) == "function" then
		local r_, g_, b_, a_ = tex:GetPixel(x, y)
		local r_norm, g_norm, b_norm, a_norm = r_ / 255, g_ / 255, b_ / 255, a_ / 255

		if not r(r_norm, g_norm, b_norm, a_norm) then
			error(
				string.format(
					"Pixel (%d,%d) mismatch - Got: (%.3f,%.3f,%.3f,%.3f)",
					x,
					y,
					r_norm,
					g_norm,
					b_norm,
					a_norm
				)
			)
		end

		return
	end

	local r_, g_, b_, a_ = tex:GetPixel(x, y)
	local r_norm, g_norm, b_norm, a_norm = r_ / 255, g_ / 255, b_ / 255, a_ / 255

	if
		math.abs(r_norm - r) > tolerance or
		math.abs(g_norm - g) > tolerance or
		math.abs(b_norm - b) > tolerance or
		math.abs(a_norm - a) > tolerance
	then
		error(
			string.format(
				"Pixel (%d,%d) mismatch - Expected: (%.3f,%.3f,%.3f,%.3f), Got: (%.3f,%.3f,%.3f,%.3f) (±%.3f)",
				x,
				y,
				r,
				g,
				b,
				a,
				r_norm,
				g_norm,
				b_norm,
				a_norm,
				tolerance
			),
			2
		)
	end
end

local attest = require("helpers.attest")
setmetatable(test, {
	__call = function(_, val)
		return attest.AssertHelper(val)
	end,
})
local event = require("event")
local threads = require("bindings.threads")
local system = require("system")
local colors = require("helpers.colors")
local commands = require("commands")

commands.Add({
	aliases = "test2",
	argtypes = "string|nil",
	flags = {
		filter = {
			type = "string",
			description = "Only run tests whose path contains this filter",
		},
		verbose = {
			type = "boolean",
			description = "Print each completed test name",
		},
		["no-separate"] = {
			type = "boolean",
			description = "Run in-process instead of spawning one process per file",
		},
		["no-parallel"] = {
			type = "boolean",
			description = "Disable parallel file execution when running separate processes",
		},
		["no-summary"] = {
			type = "boolean",
			description = "Suppress the final summary and only print the test count marker",
		},
	},
}, function(filter, flags)
	local logging = true
	local verbose = flags.verbose == true
	local profiling = false
	local profiling_mode = nil
	local separate = flags["no-separate"] ~= true
	local parallel = flags["no-parallel"] ~= true
	local summary = flags["no-summary"] ~= true
	filter = flags.filter or filter

	if separate then
		local tests = test.FindTests(filter)

		if not tests[1] then
			error("no tests found" .. (filter and (" with filter '" .. filter .. "'") or ""), 0)
		end

		-- Thread worker passed as source string to avoid upvalue-serialization bugs.
		-- If a function were used, any modules required in the outer scope
		-- (e.g. `local io = require("io")`) would be nil in the new Lua state
		-- because string.dump does not preserve upvalue values.
		local thread_worker = [[
			local input = ...
			local io = require("io")
			local output_parts = {}
			local function capture(...)
				for i = 1, select("#", ...) do
					table.insert(output_parts, tostring(select(i, ...)))
				end
			end
			-- Override io.write before requiring helpers.test so that the module's
			-- `local io_write = io.write` alias picks up our capture function.
			io.write = capture
			io.flush = function() end

			-- Intercept ShutDown: the test framework calls system.ShutDown() when all
			-- tests complete. In a thread's Lua state this would kill the whole process.
			-- Capture the exit code instead and use it to break the event loop.
			local shutdown_code = nil
			local system = require("system")
			system.ShutDown = function(code) shutdown_code = code or 0 os.exitcode = code end

			local ok, run_err = pcall(function()
				local t = require("helpers.test")
				t.BeginTests(true, false, nil, input.verbose, true)
				t.SetTestPaths({{name = input.name, path = input.path}})
				t.RunSingleTestSet({name = input.name, path = input.path})

			local event = require("event")
			local task = require("tasks")

			-- IsBusy normally counts ALL tasks, including raw tasks created inside tests.
			-- Those raw tasks may outlive the test tasks, preventing shutdown_code from
			-- ever being set. Patch IsBusy to only count test tasks so the shutdown
			-- signal fires as soon as all T.Test() wrappers have finished.
			task.IsBusy = function(exclude)
				for task in pairs(task.created) do
					if task ~= exclude and task.is_test_task then return true end
				end
				return false
			end

			local start_t = system.GetTime()
			local deadline = start_t + 60
			local next_warn = start_t + 10
			local stderr = io.stderr

			while (shutdown_code == nil) and system.GetTime() < deadline do
				local now = system.GetTime()

				if now >= next_warn then
					local elapsed = math.floor(now - start_t)
					stderr:write(string.format("[warning] test '%s' still running after %ds\n", input.name, elapsed))
					stderr:flush()
					next_warn = now + 10
				end

				local dt = 0.016
				system.SetElapsedTime(system.GetElapsedTime() + dt)
				event.Call("Update", dt)
				system.Sleep(0.001)
			end
			
			t.EndTests(true)
			end)

			if not ok then
				return {output = tostring(run_err), exit_code = 1, test_count = 0}
			end

			local output = table.concat(output_parts)
			local test_count = tonumber(output:match("#tests=(%d+)") or "0")
			local exit_code = shutdown_code or (output:find("\xe2\x9c\x97") ~= nil and 1 or 0)
			os.exitcode = exit_code
			return {output = output, exit_code = exit_code, test_count = test_count}
		]]
		local start_time = system.GetTime()
		local total_exit_code = 0
		local total_test_count = 0
		local failed_files = 0
		local failed_file_names = {}
		local running = {}
		local next_test_idx = 1
		local max_running = parallel and 8 or 1
		print(
			max_running == 1 and
				"Running tests in threads..." or
				"Running " .. max_running .. " tests in parallel threads..."
		)

		while next_test_idx <= #tests or #running > 0 do
			while #running < max_running and next_test_idx <= #tests do
				local test_item = tests[next_test_idx]
				next_test_idx = next_test_idx + 1
				local ok, thread_or_err = pcall(function()
					local t = threads.new(thread_worker)
					t:run({path = test_item.path, name = test_item.name, verbose = verbose})
					return t
				end)

				if ok then
					thread_or_err.test_name = test_item.name
					thread_or_err.start_time = system.GetTime()
					thread_or_err.next_warn_time = system.GetTime() + 5
					table.insert(running, thread_or_err)
				else
					io.write(
						"failed to start thread for " .. test_item.name .. ": " .. tostring(thread_or_err) .. "\n"
					)
					total_exit_code = 1
					failed_files = failed_files + 1
					table.insert(failed_file_names, test_item.name)
				end
			end

			for i = #running, 1, -1 do
				local t = running[i]

				-- Warn if this thread has been running too long
				if t.next_warn_time and system.GetTime() >= t.next_warn_time then
					local elapsed = math.floor(system.GetTime() - t.start_time)
					io.write(
						colors.yellow(string.format("[warning] %s has been running for %ds\n", t.test_name, elapsed))
					)
					io.flush()
					t.next_warn_time = system.GetTime() + 5
				end

				-- Check for both completed and error status (status ~= STATUS_UNDEFINED)
				local status = t.input_data and t.input_data.status

				if status and status ~= 0 then
					local result, join_err = t:join()

					if join_err then
						io.write("thread error for " .. t.test_name .. ": " .. tostring(join_err) .. "\n")
						total_exit_code = 1
						failed_files = failed_files + 1
						table.insert(failed_file_names, t.test_name)
					else
						if result.exit_code ~= 0 then
							total_exit_code = 1
							failed_files = failed_files + 1
							table.insert(failed_file_names, t.test_name)
						end

						total_test_count = total_test_count + (result.test_count or 0)
						local final_output = result.output:gsub("\n#tests=%d+\n", "\n")

						if result.exit_code ~= 0 and #final_output == 0 then
							io.write(colors.red("test file failed: " .. t.test_name) .. "\n")
						end

						if #final_output > 0 then io.write(final_output) end

						io.flush()
					end

					table.remove(running, i)
				end
			end

			system.Sleep(0.01)
		end

		local end_time = system.GetTime()

		if total_exit_code == 0 then
			io.write("\n" .. colors.green("ALL TESTS PASSED") .. "\n")
		else
			io.write("\n" .. colors.red("FAILED: " .. failed_files .. " test files failed") .. "\n")

			for _, name in ipairs(failed_file_names) do
				io.write(colors.red("  - " .. name) .. "\n")
			end
		end

		io.write("ran " .. total_test_count .. " tests in " .. #tests .. " files\n")
		io.write("total time: " .. string.format("%.2f", end_time - start_time) .. "s\n")
		io.flush()
		system.ShutDown(total_exit_code)
		return
	end

	test.RunTestsWithFilter(
		filter,
		{
			logging = logging,
			verbose = verbose,
			profiling = profiling,
			profiling_mode = profiling_mode,
			no_summary = not summary,
		}
	)

	event.AddListener("ShutDown", "tests", function()
		test.EndTests(not summary)
	end)
end)

return test