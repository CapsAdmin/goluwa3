local event = require("event")
local fs = require("fs")
fs.create_directory("logs/")
local log_file = assert(fs.file_open("logs/log.txt", "w"))

if _G.NORMAL_STDOUT then
	local output = {}
	local suppress_print = false

	local function can_write(str)
		if suppress_print then return false end

		suppress_print = true
		local result = event.Call("StdOutWrite", str)
		suppress_print = false
		return result ~= false
	end

	function output.write(str)
		if can_write(str) then
			assert(log_file:write(str, 1, #str))
			assert(log_file:flush())
			io.write(str)
			io.flush()
		end
	end

	function output.write_direct(str)
		io.write(str)
		io.flush()
	end

	function output.flush()
		io.flush()
	end

	function output.cleanup() end

	return output
end

local ffi = require("ffi")

-- On Windows, save the original console handles before redirecting
-- This allows terminal.lua to still use console-specific functions
local original_console_in, original_console_out
if jit.os == "Windows" then
	ffi.cdef[[
		void* GetStdHandle(uint32_t nStdHandle);
		int DuplicateHandle(
			void* hSourceProcessHandle,
			void* hSourceHandle,
			void* hTargetProcessHandle,
			void** lpTargetHandle,
			uint32_t dwDesiredAccess,
			int bInheritHandle,
			uint32_t dwOptions
		);
		void* GetCurrentProcess(void);
	]]
	
	local STD_INPUT_HANDLE = ffi.cast("uint32_t", -10)
	local STD_OUTPUT_HANDLE = ffi.cast("uint32_t", -11)
	local DUPLICATE_SAME_ACCESS = 0x00000002
	
	local console_in_ptr = ffi.new("void*[1]")
	local console_out_ptr = ffi.new("void*[1]")
	local current_process = ffi.C.GetCurrentProcess()
	
	-- Duplicate the console handles so we keep them even after redirecting stdout
	ffi.C.DuplicateHandle(
		current_process,
		ffi.C.GetStdHandle(STD_INPUT_HANDLE),
		current_process,
		console_in_ptr,
		0,
		0,
		DUPLICATE_SAME_ACCESS
	)
	
	ffi.C.DuplicateHandle(
		current_process,
		ffi.C.GetStdHandle(STD_OUTPUT_HANDLE),
		current_process,
		console_out_ptr,
		0,
		0,
		DUPLICATE_SAME_ACCESS
	)
	
	original_console_in = console_in_ptr[0]
	original_console_out = console_out_ptr[0]
end

local original_stdout_fd = assert(fs.fd.stdout:dup())
-- Save the FILE* BEFORE redirecting
local original_stdout_file = assert(fs.file_open(original_stdout_fd.fd, "w"))
local read_fd, write_fd = assert(fs.get_read_write_fd_pipes())
-- Now redirect stdout to the write end of the pipe
assert(write_fd:dup(fs.fd.stdout))
assert(read_fd:set_nonblocking(true))
local READ_BUF_SIZE = 4096
local suppress_print = false

local function can_write(str)
	if suppress_print then return false end

	suppress_print = true
	local result = event.Call("StdOutWrite", str)
	suppress_print = false
	return result ~= false
end

local function process_pipe()
	while true do
		local data, n = read_fd:read(READ_BUF_SIZE - 1)

		if not data or n <= 0 then break end

		if can_write(data) then
			assert(log_file:write(data, 1, n))
			assert(log_file:flush())
			assert(original_stdout_fd:write(data))
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
output.original_console_in = original_console_in
output.original_console_out = original_console_out

function output.write(str)
	io.write(str)
	io.flush()
	process_pipe()
end

function output.write_direct(str)
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
