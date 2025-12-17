local T = require("test.environment")
local process = require("bindings.process")

-- Helper to read all output with retries
local function read_all_stdout(proc)
	local result = ""

	T.RunUntil2(function()
		local chunk = proc:read(4096)

		if chunk then result = result .. chunk end

		return result ~= ""
	end)

	return result
end

T.Test("echo command with piped output", function()
	local proc = assert(process.spawn({command = "echo", args = {"hello", "world"}, stdout = "pipe"}))
	T(proc.pid)["~="](nil)
	T(read_all_stdout(proc))["contains"]("hello world")
	T(assert(proc:wait()))["=="](0)
end)

T.Test("cat with stdin/stdout pipe", function()
	local proc = assert(process.spawn({command = "cat", stdin = "pipe", stdout = "pipe"}))
	local test_msg = "Hello from stdin!"
	local written = proc:write(test_msg .. "\n")
	T(written)[">"](0)
	local output = ""
	local success = T.RunUntil2(function()
		local chunk = proc:read(4096)

		if chunk and chunk ~= "" then output = output .. chunk end

		return output:find("Hello from stdin", nil, true) ~= nil
	end)
	T(success)["=="](true)
	T(output)["contains"]("Hello from stdin")
	proc:close()
	T(assert(proc:wait()))["=="](0)
end)

T.Test("try_wait non-blocking check", function()
	local proc = assert(process.spawn({command = "sh", args = {"-c", "exit 0"}}))
	local success = T.RunUntil2(function()
		done, code = proc:try_wait()
		return done == true
	end)
	T(success)["=="](true)
	T(done)["=="](true)
	T(code)["=="](0)
end)

T.Test("directory listing with ls", function()
	local proc = assert(
		process.spawn(
			{
				command = "ls",
				args = {"-1"}, -- one file per line
				stdout = "pipe",
			}
		)
	)
	local ls_output = read_all_stdout(proc)
	local lines = {}

	for line in ls_output:gmatch("[^\n]+") do
		table.insert(lines, line)
	end

	T(#lines)[">"](0)
	T(assert(proc:wait()))["=="](0)
end)

T.Test("stderr capture with invalid path", function()
	local proc = assert(
		process.spawn(
			{
				command = "ls",
				args = {"/this/path/does/not/exist"},
				stdout = "pipe",
				stderr = "pipe",
			}
		)
	)
	local stderr = ""
	local success = T.RunUntil2(function()
		local chunk = proc:read_err(4096)

		if chunk and chunk ~= "" then stderr = stderr .. chunk end

		local done = proc:try_wait()

		if done then
			-- One more read to catch remaining data
			local final = proc:read_err(4096)

			if final and final ~= "" then stderr = stderr .. final end

			return true
		end

		return false
	end)
	T(success)["=="](true)
	local stdout = proc:read(4096) or ""
	T(#stderr)[">"](0)
	-- ls returns non-zero exit code for errors
	local exit_code = assert(proc:wait())
	T(exit_code)["~="](0)
end)
