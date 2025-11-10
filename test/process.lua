local test = require("test.gambarina")
local process = require("process")

-- Helper to read all output with retries
local function read_all_stdout(proc, timeout)
	timeout = timeout or 1
	local result = ""
	local start = os.time()
	local iterations = 0
	
	while os.time() - start < timeout and iterations < 100 do
		iterations = iterations + 1
		local chunk = proc:read(4096)
		if chunk and chunk ~= "" then
			result = result .. chunk
		end
		
		-- Check if process exited
		local done = proc:try_wait()
		if done then
			-- One more read to catch any remaining data
			local final = proc:read(4096)
			if final and final ~= "" then
				result = result .. final
			end
			break
		end
		
		-- Small delay
		os.execute("sleep 0.05")
	end
	
	return result
end

test("echo command with piped output", function()
	local proc = assert(process.spawn({
		command = "/bin/echo",
		args = {"hello", "world"},
		stdout = "pipe"
	}))

	ok(proc.pid ~= nil, "process should have a PID")

	-- Give it a moment to execute
	os.execute("sleep 0.1")

	-- Read output
	local output = read_all_stdout(proc, 1)
	ok(output:match("hello world") ~= nil, "output should contain 'hello world'")

	-- Wait for completion
	local exit_code = assert(proc:wait())
	ok(exit_code == 0, "process should exit with code 0")
end)

test("cat with stdin/stdout pipe", function()
	local proc = assert(process.spawn({
		command = "/bin/cat",
		stdin = "pipe",
		stdout = "pipe"
	}))

	-- Write to stdin
	local test_msg = "Hello from stdin!"
	local written = proc:write(test_msg .. "\n")
	ok(written > 0, "should write bytes to stdin")

	-- Give cat time to echo
	os.execute("sleep 0.1")

	-- Read output (should echo what we wrote)
	local output = proc:read(4096) or ""
	ok(output:match("Hello from stdin") ~= nil, "output should echo input")

	-- Close to signal EOF
	proc:close()

	local exit_code = proc:wait()
	ok(exit_code == 0, "process should exit with code 0")
end)

test("try_wait non-blocking check", function()
	local proc = assert(process.spawn({
		command = "/bin/sleep",
		args = {"1"}
	}))

	-- Check immediately (should still be running)
	local done, code = proc:try_wait()
	ok(done == false or done == nil, "process should still be running immediately after spawn")

	-- Wait for process to finish
	os.execute("sleep 1.5")
	done, code = proc:try_wait()
	ok(done == true, "process should be done after sleep")
	ok(code == 0, "exit code should be 0")
end)

test("directory listing with ls", function()
	local proc = assert(process.spawn({
		command = "/bin/ls",
		args = {"-1"}, -- one file per line
		stdout = "pipe"
	}))

	local ls_output = read_all_stdout(proc, 2)
	local lines = {}
	for line in ls_output:gmatch("[^\n]+") do
		table.insert(lines, line)
	end
	
	ok(#lines > 0, "should list at least one item")
	proc:wait()
end)

test("stderr capture with invalid path", function()
	local proc = assert(process.spawn({
		command = "/bin/ls",
		args = {"/this/path/does/not/exist"},
		stdout = "pipe",
		stderr = "pipe"
	}))

	-- Give it time to fail
	os.execute("sleep 0.1")

	local stdout = proc:read(4096) or ""
	local stderr = proc:read_err(4096) or ""
	
	ok(#stderr > 0, "stderr should contain error message")
	proc:wait()
end)
