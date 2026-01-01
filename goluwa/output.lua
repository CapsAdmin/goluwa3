local function library()
	local output = {}
	return output
end

local output = library()
local event = require("event")
local fs = require("fs")
local log_file
local log_fd -- Raw fd for crash-safe writes
local suppress_print = false
local READ_BUF_SIZE = 4096
-- State for pipe redirection mode
local original_stdout_fd
local original_stdout_file
local read_fd, write_fd
local process_pipe

function output.CanWrite(str)
	if suppress_print then return false end

	suppress_print = true
	local result = event.Call("StdOutWrite", str)
	suppress_print = false
	return result ~= false
end

function output.Initialize()
	if output.initialized then return end
	output.initialized = true
	output.normal_stdout = _G.NORMAL_STDOUT
	fs.create_directory("logs/")
	log_file = assert(fs.file_open("logs/log.txt", "w"))
	output.file = log_file

	if not output.normal_stdout then
		local ffi = require("ffi")
		-- Make stdout unbuffered so writes go directly to kernel
		if jit.os == "Windows" then
			io.stdout:setvbuf("no")
		else
			ffi.C.setvbuf(ffi.C.stdout, nil, 2, 0) -- 2 = _IONBF (no buffering)
		end
		-- Also make the log file unbuffered for crash safety
		pcall(ffi.C.setvbuf, log_file.file, nil, 2, 0)

		-- On Windows, save the original console handles before redirecting
		-- This allows terminal.lua to still use console-specific functions
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
			output.original_console_in = console_in_ptr[0]
			output.original_console_out = console_out_ptr[0]
		end

		original_stdout_fd = assert(fs.fd.stdout:dup())
		-- Save the FILE* BEFORE redirecting
		original_stdout_file = assert(fs.file_open(original_stdout_fd.fd, "w"))
		-- Get log file's raw fd for crash-safe writes
		local log_fd_num = log_file:get_fileno()
		local log_fd_wrapper = setmetatable({fd = log_fd_num}, getmetatable(fs.fd.stdout))
		-- Create pipe for intercepting stdout
		read_fd, write_fd = assert(fs.get_read_write_fd_pipes())
		-- Redirect stdout to the write end of the pipe
		assert(write_fd:dup(fs.fd.stdout))
		assert(read_fd:set_nonblocking(true))
		output.original_stdout_fd = original_stdout_fd
		output.original_stdout_file = original_stdout_file
		output.log_fd = log_fd_wrapper
		process_pipe = function()
			while true do
				local data, n = read_fd:read(READ_BUF_SIZE - 1)

				if not data or n <= 0 then break end

				-- Write to log file using raw fd (bypasses libc buffering)
				log_fd_wrapper:write(data)

				-- Styled terminal output via StdOutWrite event
				if output.CanWrite(data) then assert(original_stdout_fd:write(data)) end
			end
		end
	end
end

function output.Write(str)
	if not output.CanWrite(str) then return end

	if output.normal_stdout then
		assert(log_file:write(str, 1, #str))
		assert(log_file:flush())
		io.write(str)
		io.flush()
	else
		io.write(str)
		io.flush()
		process_pipe()
	end
end

function output.WriteDirect(str)
	if output.normal_stdout then
		io.write(str)
		io.flush()
	else
		assert(original_stdout_fd:write(str))
	end
end

function output.Flush()
	if output.normal_stdout then
		io.flush()
	else
		io.stdout:flush()
		process_pipe()
	end
end

function output.Shutdown()
	if not output.normal_stdout then
		-- Flush any remaining data
		io.stdout:flush()
		process_pipe()
		-- Restore original stdout
		assert(original_stdout_fd:dup(fs.fd.stdout))
		assert(original_stdout_fd:close())
		assert(read_fd:close())
		assert(write_fd:close())
	end

	if log_file then assert(log_file:close()) end
end

return output
