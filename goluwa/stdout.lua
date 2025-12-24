local ffi = require("ffi")
local fs_util = require("fs")
local fs = require("goluwa.bindings.filesystem")
local event = require("event")
local base_log_dir = "logs/"
fs_util.create_directory(base_log_dir)
local suppress_print = false
-- Open log file
local log_file = assert(fs.file_open(base_log_dir .. "log.txt", "w"))
-- Save original stdout fd
local original_stdout_fd = assert(fs.fd.stdout:dup())
-- Create a FILE* for the original stdout for terminal operations
local original_stdout_file = assert(fs.file_open(original_stdout_fd.fd, "w"))
-- Create pipe
local read_fd, write_fd = assert(fs.get_read_write_fd_pipes())
-- Redirect stdout to write end of pipe
assert(write_fd:dup(fs.fd.stdout))
-- Set read end to non-blocking
assert(read_fd:set_nonblocking(true))
-- Buffer for reading from pipe
local READ_BUF_SIZE = 4096

-- Filter callback using event system
local function can_write(str)
	if suppress_print then return false end

	suppress_print = true
	local result = event.Call("StdOutWrite", str)
	suppress_print = false
	return result ~= false
end

-- Process any pending data in the pipe
local function process_pipe()
	while true do
		local data, n = read_fd:read(READ_BUF_SIZE - 1)

		if not data or n <= 0 then break end

		-- Apply filter callback
		if can_write(data) then
			-- Write to log file
			assert(log_file:write(data, 1, n))
			assert(log_file:flush())
			-- Mirror to original terminal
			assert(original_stdout_fd:write(data))
		else
			-- Write blocked message to terminal only (not to log)
			local msg = string.format("[FILTERED]\n")
			assert(original_stdout_fd:write(msg))
		end
	end
end

-- Cleanup function
local function cleanup()
	-- Flush any remaining data
	io.stdout:flush()
	process_pipe()
	-- Restore original stdout
	assert(original_stdout_fd:dup(fs.fd.stdout))
	assert(original_stdout_fd:close())
	assert(read_fd:close())
	assert(write_fd:close())
	assert(log_file:close())
end

local output = {}
output.file = log_file
output.original_stdout_fd = original_stdout_fd
output.original_stdout_file = original_stdout_file

function output.write(str)
	io.write(str)
	io.flush()
	process_pipe()
end

function output.write_direct(str)
	-- Write directly to terminal bypassing capture
	assert(original_stdout_fd:write(str))
end

function output.flush()
	io.stdout:flush()
	process_pipe()
end

function output.cleanup()
	cleanup()
end

return output
