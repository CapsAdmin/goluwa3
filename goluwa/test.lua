local io = require("io")
local io_write = io.write
local io_stderr = io.stderr
local fs = import("goluwa/filesystem/fs.lua")
local debug = require("debug")
local pcall = _G.pcall
local type = _G.type
local ipairs = _G.ipairs
local xpcall = _G.xpcall
local assert = _G.assert
local loadfile = _G.loadfile
local profiler = import("goluwa/profiler.lua")
local jit = _G.jit
local table = _G.table
local process = import("goluwa/bindings/process.lua")
local colors = import("goluwa/cli/colors.lua")
local callstack = import("goluwa/debug/callstack.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local tasks = import("goluwa/tasks.lua")
local test = {}
local total_test_count = 0
local coroutine = _G.coroutine
local TEST_TIMEOUT = 20
local current_test_name = ""
local current_running_test_name = ""
local current_wait = nil
local current_file_timeout_deadline = nil
local tests_by_file = {}
local current_test_start_time = nil
local on_test_file_complete = nil
local LOGGING = false
local VERBOSE = false
local NESTING = false
local IS_TERMINAL = true
local NO_SUMMARY = false
local NAME_PATTERN = nil
local FAILURES_ONLY = false
local completed_test_count = 0
local has_failed_tests = false
local collecting_test_definitions = nil
local skipped_files = {}

local function flush_output_stream(handle)
	if handle and handle.flush then pcall(handle.flush, handle) end

	io.flush()
end

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

		if not line:find(".lua", 1, true) then table.remove(lines, i) end
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

function test.RunTestsWithPathPattern(path_pattern, config)
	test.BeginTests(
		config.logging,
		config.profiling,
		config.profiling_mode,
		config.verbose,
		config.no_summary,
		config.name_pattern,
		config.failures_only
	)
	local tests = test.FindTests(path_pattern)
	test.SetTestPaths(tests)

	for _, test_item in ipairs(tests) do
		test.RunSingleTestSet(test_item)
	end

	if config.logging and not config.no_summary then
		local pattern_parts = {}

		if path_pattern then
			table.insert(pattern_parts, "path pattern '" .. path_pattern .. "'")
		end

		if config.name_pattern then
			table.insert(pattern_parts, "name pattern '" .. config.name_pattern .. "'")
		end

		local pattern_str = #pattern_parts > 0 and
			(
				" with " .. table.concat(pattern_parts, " and ")
			)
			or
			""

		if #tests == 0 then
			logn("no tests found with pattern " .. path_pattern)
		else
			logn("running ", #tests, #tests == 1 and " test" or " tests", pattern_str)
		end
	end
end

function test.GetCurrentTestFileName()
	return current_test_name
end

function test.GetCurrentRunningTestName()
	return current_running_test_name
end

function test.GetCurrentFileTimeoutDeadline()
	return current_file_timeout_deadline
end

function test.SkipFile(reason)
	skipped_files[current_test_name] = reason or "skipped"
end

function test.GetSkippedFileReason()
	return skipped_files[current_test_name]
end

function test.ResetCurrentFileTimeout()
	current_file_timeout_deadline = system.GetTime() + TEST_TIMEOUT
	return current_file_timeout_deadline
end

local tasks = import("goluwa/tasks.lua")

function test.ExtendTimeout(seconds)
	local deadline = system.GetTime() + seconds
	current_file_timeout_deadline = math.max(current_file_timeout_deadline or 0, deadline)
	local task = tasks.GetActiveTask()

	if task and task.test_timeout_time then
		task.test_timeout_time = math.max(task.test_timeout_time, deadline)
	end
end

local active_test_tasks = {}
local unavailable_marker = {}

local function matches_name_pattern(name)
	return not NAME_PATTERN or
		NAME_PATTERN == "" or
		NAME_PATTERN == "all" or
		name:find(NAME_PATTERN, nil, true)
end

function test.Skip(name, reason)
	return test.Test(name, function()
		return test.Unavailable(reason or "skipped")
	end)
end

local function enqueue_test_definition(kind, name, cb, start, stop)
	local definition = {
		kind = kind,
		name = name,
		cb = cb,
		start = start,
		stop = stop,
	}
	table.insert(collecting_test_definitions, definition)
	return definition
end

function test.Test(name, cb, start, stop)
	if not matches_name_pattern(name) then return nil end

	local current_task = tasks.GetActiveTask()

	if current_task and active_test_tasks[current_task] then
		local inner_task = test._CreateTestTask(name, cb, start, stop)
		local ok, err = tasks.WaitForNestedTask(inner_task)

		if not ok then
			error("nested test failed: " .. name .. ": " .. tostring(err), 0)
		end

		return inner_task
	end

	if collecting_test_definitions then
		return enqueue_test_definition("test", name, cb, start, stop)
	end

	return test._CreateTestTask(name, cb, start, stop)
end

function test._CreateTestTask(name, cb, start, stop, options)
	options = options or {}
	local unref = system.KeepAlive("test: " .. name)
	local test_file_name = current_test_name
	local test_file_start_time = current_test_start_time or system.GetTime()
	total_test_count = total_test_count + 1
	tests_by_file[current_test_name] = (tests_by_file[current_test_name] or 0) + 1
	local test_start_time = system.GetTime()
	local test_start_gc = collectgarbage("count")
	local task = tasks.CreateTask(
		function(task_self)
			task_self.is_test_task = true
			current_running_test_name = name
			test_start_time = system.GetTime()
			test_start_gc = collectgarbage("count")
			task_self.test_timeout_time = test.ResetCurrentFileTimeout()

			if task_self.test_timeout_time and system.GetTime() > task_self.test_timeout_time then
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
			local test_time = system.GetTime() - test_start_time
			local test_gc = collectgarbage("count") - test_start_gc
			local file = test_file_name

			if file and tests_by_file[file] then
				tests_by_file[file] = tests_by_file[file] - 1

				if on_test_file_complete then
					on_test_file_complete(
						file,
						name,
						test_time,
						test_gc,
						tests_by_file[file] == 0,
						test_file_start_time,
						not self.failed and not self.unavailable,
						self.error,
						false,
						self.unavailable and self.unavailable_reason or nil
					)
				end
			end

			completed_test_count = completed_test_count + 1

			if LOGGING and IS_TERMINAL and not NO_SUMMARY and not FAILURES_ONLY then
				if VERBOSE then
					io_write(string.format("[%d/%d] %s\n", completed_test_count, total_test_count, name))
					io.flush()
				else
					if self.unavailable then
						io_write(colors.dim("-"))
					else
						io_write(".")
					end

					io.flush()

					if completed_test_count % 50 == 0 then
						io_write(string.format(" %d/%d\n", completed_test_count, total_test_count))
						io.flush()
					end
				end
			end

			active_test_tasks[self] = nil

			if self.next_test_task then self.next_test_task:ReleaseStart() end

			if not tasks.IsBusy() then
				system.ShutDown(has_failed_tests and 1 or 0)
			end
		end,
		true,
		function(self, err, co)
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

			local test_time = system.GetTime() - test_start_time
			local test_gc = collectgarbage("count") - test_start_gc
			local file = test_file_name

			if file and tests_by_file[file] then
				tests_by_file[file] = tests_by_file[file] - 1

				if on_test_file_complete then
					on_test_file_complete(
						file,
						name,
						test_time,
						test_gc,
						tests_by_file[file] == 0,
						test_file_start_time,
						false,
						self.error,
						false,
						nil
					)
				end
			end

			completed_test_count = completed_test_count + 1

			if LOGGING and IS_TERMINAL and not NO_SUMMARY and not FAILURES_ONLY then
				if not NESTING then
					io_write(colors.red("✗"))

					if completed_test_count % 50 == 0 then
						io_write(string.format(" %d/%d\n", completed_test_count, total_test_count))
						io.flush()
					end
				end
			end

			active_test_tasks[self] = nil

			if self.next_test_task then self.next_test_task:ReleaseStart() end

			if not tasks.IsBusy() then
				system.ShutDown(has_failed_tests and 1 or 0)
			end
		end,
		{defer_start = options.defer_start}
	)
	task:SetName(name)
	task:SetIterationsPerTick(10)
	task.is_test_task = true
	task.test_timeout_duration = TEST_TIMEOUT
	active_test_tasks[task] = true

	if not event.IsListenerActive("Update", "test_runner") then
		event.AddListener("Update", "test_runner", test.UpdateTestCoroutines)
	end

	return task
end

function test._CreatePendingTask(name, options)
	options = options or {}
	local test_file_name = current_test_name
	local test_file_start_time = current_test_start_time or system.GetTime()
	total_test_count = total_test_count + 1
	tests_by_file[current_test_name] = (tests_by_file[current_test_name] or 0) + 1
	local task = tasks.CreateTask(
		function(task_self)
			current_running_test_name = name
			task_self.test_timeout_time = test.ResetCurrentFileTimeout()
		end,
		function(self)
			local file = test_file_name

			if file and tests_by_file[file] then
				tests_by_file[file] = tests_by_file[file] - 1

				if on_test_file_complete then
					on_test_file_complete(
						file,
						name,
						0,
						0,
						tests_by_file[file] == 0,
						test_file_start_time,
						true,
						nil,
						true,
						nil
					)
				end
			end

			completed_test_count = completed_test_count + 1

			if LOGGING and IS_TERMINAL and not NO_SUMMARY and not FAILURES_ONLY then
				io_write(colors.yellow("?"))
				io.flush()

				if completed_test_count % 50 == 0 then
					io_write(string.format(" %d/%d\n", completed_test_count, total_test_count))
					io.flush()
				end
			end

			if self.next_test_task then self.next_test_task:ReleaseStart() end

			if not tasks.IsBusy() then
				system.ShutDown(has_failed_tests and 1 or 0)
			end
		end,
		true,
		nil,
		{defer_start = options.defer_start}
	)
	task:SetName(name)

	if not event.IsListenerActive("Update", "test_runner") then
		event.AddListener("Update", "test_runner", test.UpdateTestCoroutines)
	end

	return task
end

function test.Pending(name)
	if not matches_name_pattern(name) then return nil end

	if collecting_test_definitions then
		return enqueue_test_definition("pending", name)
	end

	return test._CreatePendingTask(name)
end

function test.Unavailable(reason)
	return setmetatable({reason = reason}, {__index = unavailable_marker})
end

do
	function test.Yield()
		tasks.Wait(0.001)
	end

	function test.Sleep(duration)
		local start_time = system.GetElapsedTime()
		local end_time = start_time + duration
		local active_task = tasks.GetActiveTask()

		if active_task then
			while system.GetElapsedTime() < end_time do
				tasks.Wait(math.min(0.016, end_time - system.GetElapsedTime()))
			end

			return
		end

		while system.GetElapsedTime() < end_time do
			local dt = 0.016
			system.SetElapsedTime(system.GetElapsedTime() + dt)
			event.CallUpdate(dt)
			system.Sleep(0.001)
		end
	end

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

	function test.GetCurrentWaitDescription()
		if not current_wait then return nil end

		return string.format(
			"%s (gives up in %ds)",
			current_wait.description,
			math.max(0, math.ceil(current_wait.end_time - system.GetTime()))
		)
	end

	function test.WaitUntilReal(condition, timeout, description)
		timeout = timeout or 10
		local end_time = system.GetTime() + timeout
		test.ExtendTimeout(timeout + TEST_TIMEOUT)
		local previous_wait = current_wait
		current_wait = description and {description = description, end_time = end_time} or nil

		while system.GetTime() < end_time do
			local value = condition()

			if value then
				current_wait = previous_wait
				return value
			end

			test.Yield()
		end

		current_wait = previous_wait
		error(
			"WaitUntilReal: " .. (
					description or
					"condition"
				) .. " not met within timeout of " .. timeout .. " seconds",
			2
		)
	end

	function test.UpdateTestCoroutines()
		if tasks and tasks.IsEnabled() then tasks.Update() end
	end
end

function test.FindTests(path_pattern)
	local current_directory = fs.get_current_directory()
	local roots = {
		{
			full = current_directory .. "/test/tests/",
			keep_relative_name = false,
		},
	}
	local addons_directory = current_directory .. "/addons/"

	if fs.is_directory(addons_directory) then
		for _, addon_name in ipairs(fs.get_files(addons_directory) or {}) do
			local tests_directory = addons_directory .. addon_name .. "/tests/"

			if
				not addon_name:starts_with("__") and
				not addon_name:starts_with(".") and
				fs.is_directory(tests_directory)
			then
				table.insert(roots, {full = tests_directory, keep_relative_name = true})
			end
		end
	end

	local expanded = {}

	for _, root in ipairs(roots) do
		for _, path in ipairs(fs.get_files_recursive(root.full) or {}) do
			if fs.is_file(path) then
				local relative_path = path:replace(current_directory .. "/", "")
				local name = root.keep_relative_name and relative_path or path:replace(root.full, "")

				if
					not path_pattern or
					path_pattern == "all" or
					relative_path:find(path_pattern, nil, true) or
					name:find(path_pattern, nil, true)
				then
					table.insert(expanded, {
						path = relative_path,
						name = name,
					})
				end
			end
		end
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
		if not LOGGING or NO_SUMMARY or FAILURES_ONLY then return end

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

	function test.LoadingIndicator()
		if not LOGGING or NO_SUMMARY or FAILURES_ONLY then return end

		if not IS_TERMINAL then return end

		spinner_index = (spinner_index % #spinner_chars) + 1
		update_test_line("RUNNING")
	end

	function test.SetTestPaths(tests)
		max_path_width = 0

		for _, test_item in ipairs(tests) do
			max_path_width = math.max(max_path_width, #test_item.name)
		end

		max_path_width = max_path_width + 2
	end

	local total_gc = 0
	local test_file_count = 0
	local test_results = {}
	local test_order = {}

	function test.BeginTests(
		logging,
		profiling,
		profiling_mode,
		verbose,
		no_summary,
		name_pattern,
		failures_only
	)
		LOGGING = logging or false
		VERBOSE = verbose or false
		PROFILING = profiling or false
		NO_SUMMARY = no_summary or false
		NAME_PATTERN = name_pattern
		FAILURES_ONLY = failures_only or false
		total_test_count = 0
		tests_by_file = {}
		current_test_name = ""
		current_test_start_time = nil
		current_running_test_name = ""
		current_file_timeout_deadline = nil
		total_gc = 0
		test_file_count = 0
		test_results = {}
		test_order = {}
		skipped_files = {}
		completed_test_count = 0
		has_failed_tests = false

		if PROFILING then profiler.Start(profiling_mode) end

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
			if not test_results[test_file_name] then
				test_results[test_file_name] = {
					tests = {},
					total_time = 0,
					total_gc = 0,
					file_start_time = file_start_time,
				}
			end

			local file_result = test_results[test_file_name]
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
			file_result.total_gc = file_result.total_gc + gc
			total_gc = total_gc + gc

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
		current_running_test_name = ""
		current_test_start_time = system.GetTime()
		test.ResetCurrentFileTimeout()
		local file_test_count_before = tests_by_file[current_test_name] or 0

		if LOGGING and not NO_SUMMARY and not FAILURES_ONLY then
			update_test_line("RUNNING")
		end

		local func, err = loadfile(test_item.path)

		if not func then
			error("failed to load " .. test_item.name .. ":\n" .. err, 2)
		end

		local current_test_definitions = {}
		collecting_test_definitions = current_test_definitions
		local ok, err = run_func(func)
		collecting_test_definitions = nil

		if ok then
			local created_tasks = {}

			for _, definition in ipairs(current_test_definitions) do
				if definition.kind == "pending" then
					created_tasks[#created_tasks + 1] = test._CreatePendingTask(definition.name, {defer_start = true})
				else
					created_tasks[#created_tasks + 1] = test._CreateTestTask(
						definition.name,
						definition.cb,
						definition.start,
						definition.stop,
						{defer_start = true}
					)
				end
			end

			for i = 1, #created_tasks - 1 do
				created_tasks[i].next_test_task = created_tasks[i + 1]
			end

			if created_tasks[1] then created_tasks[1]:ReleaseStart() end
		end

		if not ok then error("failed to run " .. test_item.name .. ":\n" .. err, 2) end

		local registered_test_count = (tests_by_file[current_test_name] or 0) - file_test_count_before

		if registered_test_count <= 0 then return false end

		table.insert(test_order, test_item.name)
		test_file_count = test_file_count + 1
		return true
	end

	function test.GetFileResults(name)
		return test_results[name]
	end

	function test.EndTests(no_summary)
		local luajit_startup_time = _G.EARLY_STARTUP_TIME or 0
		local actual_total = os.clock() - luajit_startup_time

		if PROFILING then profiler.Stop() end

		if LOGGING and not no_summary then
			for name, reason in pairs(skipped_files) do
				io_write(colors.dim(string.format("%s skipped: %s\n", name, reason)))
				io.flush()
			end
		end

		if test_file_count > 0 then
			if LOGGING then
				if IS_TERMINAL and completed_test_count > 0 and not FAILURES_ONLY then
					io_write("\n")
				end

				local total_failed = 0
				local total_pending = 0
				local total_unavailable = 0

				for _, file_name in ipairs(test_order) do
					local result = test_results[file_name]

					if result then
						local printed_file_header = false

						for _, test in ipairs(result.tests) do
							local time_str = ""
							local gc_str = ""

							if test.time >= 0.1 then
								time_str = " " .. format_time(test.time)
							end

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

							if not FAILURES_ONLY or test.success == false then
								if not printed_file_header then
									io_write(colors.bold(file_name) .. "\n")
									printed_file_header = true
								end

								io_write(string.format("  %s %s%s%s\n", status, test.name, time_str, gc_str))
							end

							if test.unavailable_reason and not FAILURES_ONLY then
								io_write(colors.dim("    " .. test.unavailable_reason) .. "\n")
							end
						end

						if printed_file_header then
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

				if no_summary then
					io_write(string.format("#tests=%d\n", total_test_count))
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

function test.RunFor(duration)
	local start_time = system.GetElapsedTime()
	local end_time = start_time + duration
	local active_task = tasks.GetActiveTask()

	if active_task then
		while system.GetElapsedTime() < end_time do
			tasks.Wait(math.min(0.016, end_time - system.GetElapsedTime()))
		end

		return
	end

	while system.GetElapsedTime() < end_time do
		local current_time = system.GetTime()
		local dt = 0.016
		system.SetElapsedTime(system.GetElapsedTime() + dt)
		event.CallUpdate(dt)
	end
end

function test.RunUntil(condition, timeout)
	timeout = timeout or 5.0
	local start_time = system.GetElapsedTime()
	local end_time = start_time + timeout
	local active_task = tasks.GetActiveTask()

	if active_task then
		while system.GetElapsedTime() < end_time do
			if condition() then return true end

			tasks.Wait(0.016)
		end

		return false
	end

	while system.GetElapsedTime() < end_time do
		if condition() then return true end

		local dt = 0.016
		system.SetElapsedTime(system.GetElapsedTime() + dt)
		event.CallUpdate(dt)
		system.Sleep(0.001)
	end

	return false
end

function test.RunUntil2(condition, timeout)
	timeout = timeout or 5.0
	local start_time = system.GetTime()
	local end_time = start_time + timeout

	while system.GetTime() < end_time do
		if condition() then return true end

		system.Sleep(0.001)
	end

	return false
end

function test.Screenshot(path)
	local render = import("goluwa/render/render.lua")
	render.target:GetTexture():Save(path)
end

function test.ScreenshotAlbedo(path)
	import("goluwa/render3d/gbuffer_layout.lua").GetTexture("albedo"):Save(path)
end

local function get_screen_texture()
	local render = import("goluwa/render/render.lua")
	return render.target:GetTexture()
end

local function get_albedo_texture()
	return import("goluwa/render3d/gbuffer_layout.lua").GetTexture("albedo")
end

function test.GetScreenPixel(x, y)
	local r, g, b, a = get_screen_texture():GetPixel(x, y)
	return r / 255, g / 255, b / 255, a / 255
end

function test.GetAlbedoPixel(x, y)
	local r, g, b, a = get_albedo_texture():GetPixel(x, y)
	return r / 255, g / 255, b / 255, a / 255
end

local function check_pixel(color, x, y, r, g, b, a, tolerance, msg)
	tolerance = tolerance or 0.01
	local got = string.format("(%.3f,%.3f,%.3f,%.3f)", r, g, b, a)
	local label = msg and (" (" .. msg .. ")") or ""

	if type(color) == "function" then
		if not color(r, g, b, a) then
			error(string.format("pixel (%d,%d)%s failed, got %s", x, y, label, got), 3)
		end

		return
	end

	if
		math.abs(r - color[1]) > tolerance or
		math.abs(g - color[2]) > tolerance or
		math.abs(b - color[3]) > tolerance or
		math.abs(a - color[4]) > tolerance
	then
		error(
			string.format(
				"pixel (%d,%d)%s mismatch, expected (%.3f,%.3f,%.3f,%.3f) (±%.3f), got %s",
				x,
				y,
				label,
				color[1],
				color[2],
				color[3],
				color[4],
				tolerance,
				got
			),
			3
		)
	end
end

function test.TexturePixel(tex, x, y, r, g, b, a, tolerance, msg)
	if type(r) == "number" then r = {r, g, b, a} end

	local r_, g_, b_, a_ = tex:GetPixel(x, y)
	check_pixel(r, x, y, r_ / 255, g_ / 255, b_ / 255, a_ / 255, tolerance, msg)
end

local function normalize_color(color)
	if type(color) == "table" and type(color[1]) == "function" then
		return color[1]
	end

	return color
end

function test.AssertScreenPixel(tbl)
	test.TexturePixel(
		get_screen_texture(),
		tbl.pos[1],
		tbl.pos[2],
		normalize_color(tbl.color),
		nil,
		nil,
		nil,
		tbl.tolerance,
		tbl.msg
	)
end

function test.AssertAlbedoPixel(tbl)
	test.TexturePixel(
		get_albedo_texture(),
		tbl.pos[1],
		tbl.pos[2],
		normalize_color(tbl.color),
		nil,
		nil,
		nil,
		tbl.tolerance,
		tbl.msg
	)
end

function test.AssertTexturePixel(tbl)
	test.TexturePixel(
		tbl.tex,
		tbl.pos[1],
		tbl.pos[2],
		normalize_color(tbl.color),
		nil,
		nil,
		nil,
		tbl.tolerance,
		tbl.msg
	)
end

function test.ScreenAlbedoPixel(x, y, r, g, b, a, tolerance, msg)
	test.TexturePixel(get_albedo_texture(), x, y, r, g, b, a, tolerance, msg)
end

function test.AssertTextureRegion(tbl)
	local image = tbl.tex:Download()
	local mode = tbl.mode or "any"
	local rect = tbl.rect
	local hit
	local failure

	for y = rect[2], rect[4] do
		for x = rect[1], rect[3] do
			local r, g, b, a = image:GetPixel(x, y)
			local ok = tbl.color(r / 255, g / 255, b / 255, a / 255)

			if ok then
				hit = true
			elseif mode == "all" and not failure then
				failure = {x, y, r / 255, g / 255, b / 255, a / 255}
			end
		end

		if (mode ~= "all" and hit) or (mode == "all" and failure) then break end
	end

	local label = tbl.msg and (" (" .. tbl.msg .. ")") or ""

	if mode == "all" then
		if not failure then return end

		error(
			string.format(
				"region (%d,%d)-(%d,%d)%s not fully satisfied, failing pixel (%d,%d)=(%.3f,%.3f,%.3f,%.3f)",
				rect[1],
				rect[2],
				rect[3],
				rect[4],
				label,
				failure[1],
				failure[2],
				failure[3],
				failure[4],
				failure[5],
				failure[6]
			),
			2
		)
	end

	if hit then return end

	error(
		string.format(
			"region (%d,%d)-(%d,%d)%s has no pixel satisfying the check",
			rect[1],
			rect[2],
			rect[3],
			rect[4],
			label
		),
		2
	)
end

local attest = import("goluwa/attest.lua")
setmetatable(test, {
	__call = function(_, val)
		return attest.AssertHelper(val)
	end,
})
local event = import("goluwa/event.lua")
local threads = import("goluwa/bindings/threads.lua")
local system = import("goluwa/system.lua")
local colors = import("goluwa/cli/colors.lua")
local commands = import("goluwa/cli/commands.lua")
local json = import("goluwa/codecs/json.lua")
local vfs = import("goluwa/vfs.lua")
-- eight render test processes at once trip the metal command queue timeout on apple integrated gpus
local MAX_PARALLEL_FILES = jit.os == "OSX" and 4 or math.max(1, math.floor(threads.get_thread_count() / 2))
local MIN_MEMORY_HEADROOM = 4 * 1024 ^ 3
local UNKNOWN_FILE_DURATION = 5
local KILL_FILE_SECONDS = 120
local RESULT_MARKER = "@@goluwa test result@@"

function test.FormatTimingReport(file_reports, info)
	local tests = {}
	local summed = 0

	for _, file in ipairs(file_reports) do
		file.test_time = 0

		for _, timing in ipairs(file.timings) do
			file.test_time = file.test_time + timing.time
			table.insert(tests, {file = file.name, name = timing.name, time = timing.time})
		end

		summed = summed + file.wall
	end

	table.sort(file_reports, function(a, b)
		return a.wall > b.wall
	end)

	table.sort(tests, function(a, b)
		return a.time > b.time
	end)

	local function format_files(limit)
		local lines = {
			string.format("%8s %8s %8s %8s %6s  %s", "wall", "load", "tests", "rest", "count", "file"),
		}

		for i = 1, math.min(limit, #file_reports) do
			local file = file_reports[i]
			table.insert(
				lines,
				string.format(
					"%7.2fs %7.2fs %7.2fs %7.2fs %6d  %s%s",
					file.wall,
					file.load_time,
					file.test_time,
					math.max(0, file.wall - file.load_time - file.test_time),
					#file.timings,
					file.name,
					file.failed and " (failed)" or ""
				)
			)
		end

		return table.concat(lines, "\n") .. "\n"
	end

	local lines = {
		string.format(
			"%s: %d tests in %d files, %d jobs, %.2fs wall, %.2fs summed over files (%.1f files running on average)",
			os.date("%Y-%m-%d %H:%M:%S"),
			info.test_count,
			info.file_count,
			info.jobs,
			info.wall,
			summed,
			summed / math.max(info.wall, 0.001)
		),
		"",
		"files by wall time of their process: load is starting the process and running the file body, tests is the sum of its tests, rest is waiting between ticks and shutdown",
		format_files(math.huge),
		"slowest tests",
	}

	for i = 1, math.min(100, #tests) do
		table.insert(lines, string.format("%7.2fs  %s  %s", tests[i].time, tests[i].file, tests[i].name))
	end

	return table.concat(lines, "\n") .. "\n", "slowest test files:\n" .. format_files(10)
end

commands.Add({
	aliases = "test",
	argtypes = "string|nil",
	flags = {
		["path-pattern"] = {
			type = "string",
			description = "Only run tests whose path name contains this pattern",
		},
		["name-pattern"] = {
			type = "string",
			description = "Only run tests whose test name contains this pattern",
		},
		verbose = {
			type = "boolean",
			description = "Print each completed test name",
		},
		["no-separate"] = {
			type = "boolean",
			description = "Run in-process instead of spawning one process per file",
		},
		jobs = {
			type = "number",
			description = "Maximum number of test files running at once (default half the cores, 4 on macOS)",
		},
		["no-parallel"] = {
			type = "boolean",
			description = "Run one test file at a time",
		},
		["no-summary"] = {
			type = "boolean",
			description = "Suppress the final summary and only print the test count marker",
		},
		["failures-only"] = {
			type = "boolean",
			description = "Only print failed tests and the final summary",
		},
		worker = {
			type = "string",
			description = "Run only this test file in this process and print its result, used by the runner for each file",
		},
	},
}, function(path_pattern, flags)
	local logging = true
	local verbose = flags.verbose == true
	local profiling = false
	local profiling_mode = nil
	local separate = flags["no-separate"] ~= true
	local parallel = flags["no-parallel"] ~= true
	local summary = flags["no-summary"] ~= true
	local failures_only = flags["failures-only"] == true
	local name_pattern = flags["name-pattern"]
	if os.getenv("GOLUWA_VALIDATE") ~= "0" then process.setenv("GOLUWA_VALIDATE", "1") end

	if name_pattern == "" or name_pattern == "all" then name_pattern = nil end

	path_pattern = flags["path-pattern"] or path_pattern

	if flags.worker then
		local item

		for _, test_item in ipairs(test.FindTests(flags.worker)) do
			if test_item.path == flags.worker then item = test_item end
		end

		assert(item, "no test file " .. flags.worker)
		local shutdown_code = nil
		system.ShutDown = function(code)
			shutdown_code = code or 0
		end
		test.BeginTests(true, false, nil, verbose, true, name_pattern, failures_only)
		test.SetTestPaths({item})
		local ok, has_tests = pcall(test.RunSingleTestSet, item)

		if not ok then
			io.write(colors.red(tostring(has_tests)), "\n")
			io.flush()
			os.realexit(1)
		end

		local run_start = system.GetTime()

		if has_tests then
			-- raw tasks created inside tests can outlive the test tasks and keep the file running, only count test tasks
			tasks.IsBusy = function(exclude)
				for task in pairs(tasks.created) do
					if task ~= exclude and task.is_test_task then return true end
				end

				return false
			end
			local next_warn = run_start + 10

			while shutdown_code == nil do
				local now = system.GetTime()

				if now >= test.GetCurrentFileTimeoutDeadline() then
					io.stderr:write(
						string.format(
							"[timeout] file '%s' stalled while running '%s'\n",
							item.name,
							test.GetCurrentRunningTestName()
						)
					)
					shutdown_code = 1

					break
				end

				if now >= next_warn then
					local waiting_for = test.GetCurrentWaitDescription()
					io.stderr:write(
						string.format(
							"[warning] %s: '%s' has been running for %ds%s\n",
							item.name,
							test.GetCurrentRunningTestName(),
							math.floor(now - run_start),
							waiting_for and (", waiting for " .. waiting_for) or ""
						)
					)
					next_warn = now + 10
				end

				system.SetElapsedTime(system.GetElapsedTime() + 0.016)
				event.CallUpdate(0.016)
				system.Sleep(0.001)
			end

			event.Call("ShutDown")
		elseif test.GetSkippedFileReason() then
			io.write(string.format("%s skipped: %s\n", item.name, test.GetSkippedFileReason()))
		end

		test.EndTests(true)
		local timings = {}
		local exit_code = shutdown_code or 0

		for i, res in ipairs(test.GetFileResults(item.name) and test.GetFileResults(item.name).tests or {}) do
			timings[i] = {name = res.name, time = res.time}

			if res.success == false and not res.unavailable_reason then exit_code = 1 end
		end

		io.write(
			RESULT_MARKER,
			json.encode{
				test_count = #timings,
				test_file_count = has_tests and 1 or 0,
				timings = timings,
				run_time = system.GetTime() - run_start,
			},
			"\n"
		)
		io.flush()
		os.realexit(exit_code)
		return
	end

	if separate then
		local tests = test.FindTests(path_pattern)

		if not tests[1] then
			error(
				"no tests found" .. (
						path_pattern and
						(
							" with path-pattern '" .. path_pattern .. "'"
						)
						or
						""
					),
				0
			)
		end

		local start_time = system.GetTime()
		local total_exit_code = 0
		local total_test_count = 0
		local total_test_file_count = 0
		local failed_files = 0
		local failed_file_names = {}
		local file_reports = {}
		local running = {}
		local pending = {}
		local max_running = parallel and
			math.min(flags.jobs or MAX_PARALLEL_FILES, threads.get_thread_count()) or
			1
		local durations_path = vfs.GetStorageDirectory("storage") .. "logs/test_durations.json"
		local durations = {}
		local durations_content = fs.read_file(durations_path)

		if durations_content and durations_content ~= "" then
			durations = json.decode(durations_content)
		end

		for i, test_item in ipairs(tests) do
			pending[i] = test_item
		end

		table.sort(pending, function(a, b)
			local da = durations[a.name] or UNKNOWN_FILE_DURATION
			local db = durations[b.name] or UNKNOWN_FILE_DURATION

			if da ~= db then return da > db end

			return a.name < b.name
		end)

		print("Running " .. max_running .. " test files at once, one process each...")
		local executable = process.get_executable_path()
		local script = vfs.GetStorageDirectory("root") .. "glw"

		while #pending > 0 or #running > 0 do
			while #running < max_running and #pending > 0 do
				if #running > 0 then
					local memory = system.GetMemoryInfo()

					if memory and memory.limit - memory.used < MIN_MEMORY_HEADROOM then break end
				end

				local test_item = table.remove(pending, 1)
				local args = {script, "test", "--worker=" .. test_item.path}

				if name_pattern then args[#args + 1] = "--name-pattern=" .. name_pattern end

				if verbose then args[#args + 1] = "--verbose" end

				if failures_only then args[#args + 1] = "--failures-only" end

				table.insert(
					running,
					{
						proc = assert(process.spawn{command = executable, args = args, stdout = "pipe", stderr = "pipe"}),
						test_name = test_item.name,
						start_time = system.GetTime(),
						next_warn_time = system.GetTime() + 30,
						stdout = {},
						stderr = {},
						stderr_line = "",
					}
				)
			end

			for i = #running, 1, -1 do
				local job = running[i]
				local done, exit_code = job.proc:try_wait()

				repeat
					local chunk = job.proc:read(65536)
					job.stdout[#job.stdout + 1] = chunk
				until chunk == ""

				repeat
					local chunk = job.proc:read_err(65536)
					job.stderr_line = job.stderr_line .. chunk

					for line in job.stderr_line:gmatch("([^\n]*\n)") do
						if line:starts_with("[warning]") or line:starts_with("[timeout]") then
							io.write(colors.yellow(line))
							io.flush()
							job.next_warn_time = system.GetTime() + 15
						else
							job.stderr[#job.stderr + 1] = line
						end
					end

					job.stderr_line = job.stderr_line:match("([^\n]*)$")
				until chunk == ""

				if not done and system.GetTime() >= job.next_warn_time then
					io.write(
						colors.yellow(
							string.format(
								"[warning] %s has been running for %ds\n",
								job.test_name,
								math.floor(system.GetTime() - job.start_time)
							)
						)
					)
					io.flush()
					job.next_warn_time = system.GetTime() + 10
				end

				if
					not done and
					not job.killed and
					system.GetTime() - job.start_time > KILL_FILE_SECONDS
				then
					job.proc:kill(process.SIGKILL)
					job.killed = true
				end

				if done then
					job.stderr[#job.stderr + 1] = job.stderr_line
					job.proc:close()
					table.remove(running, i)
					durations[job.test_name] = system.GetTime() - job.start_time
					local output = table.concat(job.stdout)
					local result_json = output:match(RESULT_MARKER .. "([^\n]*)\n")
					local result = result_json and json.decode(result_json)
					output = output:gsub(RESULT_MARKER .. "[^\n]*\n", ""):gsub("#tests=%d+\n", "") .. table.concat(job.stderr)

					if exit_code ~= 0 then
						total_exit_code = 1
						failed_files = failed_files + 1
						local reason = job.killed and
							string.format(" (killed after %ds)", KILL_FILE_SECONDS) or
							exit_code > 128 and
							string.format(" (crashed, signal %d)", exit_code - 128) or
							""
						table.insert(failed_file_names, job.test_name .. reason)

						if reason ~= "" or not result then
							output = output .. colors.red("test file failed: " .. job.test_name .. reason) .. "\n"
						end
					end

					io.write(output)
					io.flush()

					if result then
						total_test_count = total_test_count + result.test_count
						total_test_file_count = total_test_file_count + result.test_file_count
						table.insert(
							file_reports,
							{
								name = job.test_name,
								wall = durations[job.test_name],
								load_time = durations[job.test_name] - result.run_time,
								timings = result.timings,
								failed = exit_code ~= 0,
							}
						)
					end
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

		fs.create_directory_recursive(vfs.GetStorageDirectory("storage") .. "logs/")
		local existing_names = {}

		for _, test_item in ipairs(test.FindTests()) do
			existing_names[test_item.name] = true
		end

		for name in pairs(durations) do
			if not existing_names[name] then durations[name] = nil end
		end

		fs.write_file(durations_path, json.encode(durations))
		local report_path = vfs.GetStorageDirectory("storage") .. "logs/test_report.txt"
		local report, slowest_files = test.FormatTimingReport(
			file_reports,
			{
				wall = end_time - start_time,
				jobs = max_running,
				test_count = total_test_count,
				file_count = total_test_file_count,
			}
		)
		fs.write_file(report_path, report)
		io.write("\n", slowest_files, "full timing report: ", report_path, "\n\n")
		io.write("ran " .. total_test_count .. " tests in " .. total_test_file_count .. " files\n")
		io.write("total time: " .. string.format("%.2f", end_time - start_time) .. "s\n")
		io.flush()
		system.ShutDown(total_exit_code)
		return
	end

	test.RunTestsWithPathPattern(
		path_pattern,
		{
			logging = logging,
			verbose = verbose,
			profiling = profiling,
			profiling_mode = profiling_mode,
			name_pattern = name_pattern,
			failures_only = failures_only,
			no_summary = not summary,
		}
	)

	if total_test_count == 0 then
		test.EndTests(not summary)
		system.ShutDown(0)
		return
	end

	event.AddListener("ShutDown", "tests", function()
		test.EndTests(not summary)
	end)
end)

return test
