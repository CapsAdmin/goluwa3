local test = require("helpers.test")
local attest = require("helpers.attest")
local event = require("event")
local process = require("bindings.process")
local system = require("system")
local colors = require("helpers.colors")
local filter = nil
local logging = true
local verbose = false
local profiling = false
local profiling_mode = nil
local separate = true
local parallel = true
local summary = true

if ... then
	local args = {...}

	for i, arg in ipairs(args) do
		if arg == "--filter" then
			filter = args[i + 1]
		elseif arg:starts_with("--filter=") then
			filter = arg:split("=")[2]
		elseif arg == "--verbose" then
			verbose = true
		elseif arg == "--no-separate" then
			separate = false
		elseif arg == "--no-parallel" then
			parallel = false
		elseif arg == "--no-summary" then
			summary = false
		elseif not arg:starts_with("-") then
			filter = arg
		end
	end
end

event.AddListener("Initialize", "tests", function()
	if separate then
		local tests = test.FindTests(filter)

		if #tests > 0 then
			local start_time = system.GetTime()
			local total_exit_code = 0
			local total_test_count = 0
			local failed_files = 0
			local running = {}
			local next_test_idx = 1
			local max_running = parallel and 8 or 1

			while next_test_idx <= #tests or #running > 0 do
				while #running < max_running and next_test_idx <= #tests do
					local test_item = tests[next_test_idx]
					next_test_idx = next_test_idx + 1
					local args = {"glw", "test", test_item.name, "--no-separate", "--no-summary"}

					if verbose then table.insert(args, "--verbose") end

					local proc, err = process.spawn(
						{
							command = "luajit",
							args = args,
							stdout = "pipe",
							stderr = "pipe",
						}
					)

					if proc then
						proc.test_name = test_item.name
						proc.out_buffer = ""
						proc.err_buffer = ""
						table.insert(running, proc)
					else
						io.write("failed to spawn process for " .. test_item.name .. ": " .. tostring(err) .. "\n")
						total_exit_code = 1
					end
				end

				for i = #running, 1, -1 do
					local proc = running[i]
					local out = proc:read()

					if out and #out > 0 then proc.out_buffer = proc.out_buffer .. out end

					local err = proc:read_err()

					if err and #err > 0 then proc.err_buffer = proc.err_buffer .. err end

					local finished, code = proc:try_wait()

					if finished then
						local out = proc:read()

						while out and #out > 0 do
							proc.out_buffer = proc.out_buffer .. out
							out = proc:read()
						end

						local err = proc:read_err()

						while err and #err > 0 do
							proc.err_buffer = proc.err_buffer .. err
							err = proc:read_err()
						end

						if code ~= 0 then
							total_exit_code = 1
							failed_files = failed_files + 1
						end

						local count = proc.out_buffer:match("#tests=(%d+)")

						if count then total_test_count = total_test_count + tonumber(count) end

						local final_output = proc.out_buffer:gsub("\n#tests=%d+\n", "\n")

						if #final_output > 0 then io.write(final_output) end

						if #proc.err_buffer > 0 then io.write(proc.err_buffer) end

						io.flush()
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
			end

			io.write("ran " .. total_test_count .. " tests in " .. #tests .. " files\n")
			io.write("total time: " .. string.format("%.2f", end_time - start_time) .. "s\n")
			io.flush()
			os.exit(total_exit_code)
		end
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
end)

event.AddListener("ShutDown", "tests", function()
	test.EndTests(not summary)
end)
