local ffi = require("ffi")
local process = {}

-- Platform-specific error handling
local function lasterror(num)
	if ffi.os == "Windows" then
		ffi.cdef[[
			uint32_t GetLastError();
			uint32_t FormatMessageA(
				uint32_t dwFlags,
				const void* lpSource,
				uint32_t dwMessageId,
				uint32_t dwLanguageId,
				char* lpBuffer,
				uint32_t nSize,
				va_list *Arguments
			);
		]]
		local error_str = ffi.new("uint8_t[?]", 1024)
		local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000
		local FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200
		local error_flags = bit.bor(FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS)
		local code = num or ffi.C.GetLastError()
		local numout = ffi.C.FormatMessageA(error_flags, nil, code, 0, error_str, 1023, nil)
		local err = numout ~= 0 and ffi.string(error_str, numout)
		if err and err:sub(-2) == "\r\n" then
			return err:sub(0, -3), code
		end
		return err or tostring(code), code
	else
		ffi.cdef("const char *strerror(int);")
		num = num or ffi.errno()
		local err = ffi.string(ffi.C.strerror(num))
		return err == "" and tostring(num) or err, num
	end
end

-- Process metatable
local meta = {}
meta.__index = meta

if ffi.os == "Windows" then
	-- Windows implementation
	ffi.cdef[[
		typedef void* HANDLE;
		typedef uint32_t DWORD;
		typedef int BOOL;
		typedef struct {
			DWORD nLength;
			void* lpSecurityDescriptor;
			BOOL bInheritHandle;
		} SECURITY_ATTRIBUTES;
		
		typedef struct {
			HANDLE hProcess;
			HANDLE hThread;
			DWORD dwProcessId;
			DWORD dwThreadId;
		} PROCESS_INFORMATION;
		
		typedef struct {
			DWORD cb;
			char* lpReserved;
			char* lpDesktop;
			char* lpTitle;
			DWORD dwX;
			DWORD dwY;
			DWORD dwXSize;
			DWORD dwYSize;
			DWORD dwXCountChars;
			DWORD dwYCountChars;
			DWORD dwFillAttribute;
			DWORD dwFlags;
			uint16_t wShowWindow;
			uint16_t cbReserved2;
			uint8_t* lpReserved2;
			HANDLE hStdInput;
			HANDLE hStdOutput;
			HANDLE hStdError;
		} STARTUPINFOA;
		
		BOOL CreateProcessA(
			const char* lpApplicationName,
			char* lpCommandLine,
			SECURITY_ATTRIBUTES* lpProcessAttributes,
			SECURITY_ATTRIBUTES* lpThreadAttributes,
			BOOL bInheritHandles,
			DWORD dwCreationFlags,
			void* lpEnvironment,
			const char* lpCurrentDirectory,
			STARTUPINFOA* lpStartupInfo,
			PROCESS_INFORMATION* lpProcessInformation
		);
		
		BOOL CreatePipe(
			HANDLE* hReadPipe,
			HANDLE* hWritePipe,
			SECURITY_ATTRIBUTES* lpPipeAttributes,
			DWORD nSize
		);
		
		BOOL ReadFile(
			HANDLE hFile,
			void* lpBuffer,
			DWORD nNumberOfBytesToRead,
			DWORD* lpNumberOfBytesRead,
			void* lpOverlapped
		);
		
		BOOL WriteFile(
			HANDLE hFile,
			const void* lpBuffer,
			DWORD nNumberOfBytesToWrite,
			DWORD* lpNumberOfBytesWritten,
			void* lpOverlapped
		);
		
		BOOL CloseHandle(HANDLE hObject);
		BOOL TerminateProcess(HANDLE hProcess, uint32_t uExitCode);
		DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
		BOOL GetExitCodeProcess(HANDLE hProcess, DWORD* lpExitCode);
		BOOL SetHandleInformation(HANDLE hObject, DWORD dwMask, DWORD dwFlags);
		DWORD GetCurrentDirectoryA(DWORD nBufferLength, char* lpBuffer);
	]]
	
	local INFINITE = 0xFFFFFFFF
	local WAIT_OBJECT_0 = 0
	local WAIT_TIMEOUT = 0x00000102
	local STILL_ACTIVE = 259
	local STARTF_USESTDHANDLES = 0x00000100
	local HANDLE_FLAG_INHERIT = 0x00000001
	
	function process.spawn(opts)
		opts = opts or {}
		local command = opts.command or opts[1]
		if not command then
			return nil, "command is required"
		end
		
		-- Build command line
		local cmdline = command
		if opts.args then
			for _, arg in ipairs(opts.args) do
				-- Simple quoting - in production you'd want proper Windows quoting
				if arg:match("%s") then
					cmdline = cmdline .. ' "' .. arg .. '"'
				else
					cmdline = cmdline .. " " .. arg
				end
			end
		end
		
		-- Create pipes if needed
		local stdin_read, stdin_write
		local stdout_read, stdout_write
		local stderr_read, stderr_write
		
		local sa = ffi.new("SECURITY_ATTRIBUTES")
		sa.nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
		sa.bInheritHandle = 1
		sa.lpSecurityDescriptor = nil
		
		if opts.stdin == "pipe" then
			local hr = ffi.new("HANDLE[1]")
			local hw = ffi.new("HANDLE[1]")
			if ffi.C.CreatePipe(hr, hw, sa, 0) == 0 then
				return nil, lasterror()
			end
			stdin_read = hr[0]
			stdin_write = hw[0]
			-- Make write handle non-inheritable
			ffi.C.SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0)
		end
		
		if opts.stdout == "pipe" then
			local hr = ffi.new("HANDLE[1]")
			local hw = ffi.new("HANDLE[1]")
			if ffi.C.CreatePipe(hr, hw, sa, 0) == 0 then
				return nil, lasterror()
			end
			stdout_read = hr[0]
			stdout_write = hw[0]
			-- Make read handle non-inheritable
			ffi.C.SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0)
		end
		
		if opts.stderr == "pipe" then
			local hr = ffi.new("HANDLE[1]")
			local hw = ffi.new("HANDLE[1]")
			if ffi.C.CreatePipe(hr, hw, sa, 0) == 0 then
				return nil, lasterror()
			end
			stderr_read = hr[0]
			stderr_write = hw[0]
			-- Make read handle non-inheritable
			ffi.C.SetHandleInformation(stderr_read, HANDLE_FLAG_INHERIT, 0)
		end
		
		-- Setup startup info
		local si = ffi.new("STARTUPINFOA")
		si.cb = ffi.sizeof("STARTUPINFOA")
		si.dwFlags = STARTF_USESTDHANDLES
		si.hStdInput = stdin_read
		si.hStdOutput = stdout_write
		si.hStdError = stderr_write
		
		-- Process information
		local pi = ffi.new("PROCESS_INFORMATION")
		
		-- Get current directory if specified
		local cwd = opts.cwd
		if cwd then
			cwd = ffi.cast("const char*", cwd)
		end
		
		-- Create process
		local cmdline_buf = ffi.new("char[?]", #cmdline + 1)
		ffi.copy(cmdline_buf, cmdline)
		
		local ret = ffi.C.CreateProcessA(
			nil,
			cmdline_buf,
			nil,
			nil,
			1, -- inherit handles
			0, -- creation flags
			nil, -- environment
			cwd,
			si,
			pi
		)
		
		-- Close child process's pipe ends
		if stdin_read then ffi.C.CloseHandle(stdin_read) end
		if stdout_write then ffi.C.CloseHandle(stdout_write) end
		if stderr_write then ffi.C.CloseHandle(stderr_write) end
		
		if ret == 0 then
			return nil, lasterror()
		end
		
		-- Close thread handle, we don't need it
		ffi.C.CloseHandle(pi.hThread)

		local self = setmetatable({
			handle = pi.hProcess,
			pid = tonumber(pi.dwProcessId),
			stdin = stdin_write,
			stdout = stdout_read,
			stderr = stderr_read,
			exit_code = nil,  -- Cached exit code after wait
		}, meta)

		return self
	end

	function meta:wait()
		-- Return cached exit code if already waited
		if self.exit_code then
			return self.exit_code
		end

		local result = ffi.C.WaitForSingleObject(self.handle, INFINITE)
		if result ~= WAIT_OBJECT_0 then
			return nil, lasterror()
		end

		local exit_code = ffi.new("DWORD[1]")
		if ffi.C.GetExitCodeProcess(self.handle, exit_code) == 0 then
			return nil, lasterror()
		end

		self.exit_code = tonumber(exit_code[0])
		return self.exit_code
	end

	function meta:try_wait()
		-- Return cached exit code if already waited
		if self.exit_code then
			return true, self.exit_code
		end

		local result = ffi.C.WaitForSingleObject(self.handle, 0)
		if result == WAIT_TIMEOUT then
			return false
		elseif result == WAIT_OBJECT_0 then
			local exit_code = ffi.new("DWORD[1]")
			if ffi.C.GetExitCodeProcess(self.handle, exit_code) == 0 then
				return nil, lasterror()
			end
			self.exit_code = tonumber(exit_code[0])
			return true, self.exit_code
		else
			return nil, lasterror()
		end
	end
	
	function meta:kill()
		if ffi.C.TerminateProcess(self.handle, 1) == 0 then
			return nil, lasterror()
		end
		return true
	end
	
	function meta:write(data)
		if not self.stdin then
			return nil, "stdin is not piped"
		end
		
		local written = ffi.new("DWORD[1]")
		if ffi.C.WriteFile(self.stdin, data, #data, written, nil) == 0 then
			return nil, lasterror()
		end
		
		return tonumber(written[0])
	end
	
	function meta:read(size)
		if not self.stdout then
			return nil, "stdout is not piped"
		end
		
		size = size or 4096
		local buffer = ffi.new("char[?]", size)
		local read = ffi.new("DWORD[1]")
		
		if ffi.C.ReadFile(self.stdout, buffer, size, read, nil) == 0 then
			local err, code = lasterror()
			-- ERROR_BROKEN_PIPE means the process closed the pipe
			if code == 109 then
				return ""
			end
			return nil, err
		end
		
		return ffi.string(buffer, tonumber(read[0]))
	end
	
	function meta:read_err(size)
		if not self.stderr then
			return nil, "stderr is not piped"
		end
		
		size = size or 4096
		local buffer = ffi.new("char[?]", size)
		local read = ffi.new("DWORD[1]")
		
		if ffi.C.ReadFile(self.stderr, buffer, size, read, nil) == 0 then
			local err, code = lasterror()
			if code == 109 then
				return ""
			end
			return nil, err
		end
		
		return ffi.string(buffer, tonumber(read[0]))
	end
	
	function meta:close()
		if self.stdin then
			ffi.C.CloseHandle(self.stdin)
			self.stdin = nil
		end
		if self.stdout then
			ffi.C.CloseHandle(self.stdout)
			self.stdout = nil
		end
		if self.stderr then
			ffi.C.CloseHandle(self.stderr)
			self.stderr = nil
		end
		return true
	end
	
	function meta:__gc()
		self:close()
		if self.handle then
			ffi.C.CloseHandle(self.handle)
			self.handle = nil
		end
	end

else
	-- Unix implementation (macOS, Linux, BSD)
	ffi.cdef[[
		typedef int pid_t;
		typedef long ssize_t;
		typedef unsigned int mode_t;
		
		pid_t fork(void);
		int execve(const char *pathname, char *const argv[], char *const envp[]);
		int pipe(int pipefd[2]);
		int close(int fd);
		ssize_t read(int fd, void *buf, size_t count);
		ssize_t write(int fd, const void *buf, size_t count);
		pid_t waitpid(pid_t pid, int *status, int options);
		int kill(pid_t pid, int sig);
		int chdir(const char *path);
		int dup2(int oldfd, int newfd);
		int fcntl(int fd, int cmd, ...);
		void _exit(int status);
		
		char **environ;
	]]
	
	local WNOHANG = 1
	local O_NONBLOCK = 0x0004 -- macOS
	local F_GETFL = 3
	local F_SETFL = 4
	
	if ffi.os ~= "OSX" then
		O_NONBLOCK = 0x0800 -- Linux
	end
	
	local SIGTERM = 15
	local SIGKILL = 9
	
	-- Helper to make fd non-blocking
	local function set_nonblocking(fd)
		local flags = ffi.C.fcntl(fd, F_GETFL, 0)
		if flags < 0 then
			return nil, lasterror()
		end
		if ffi.C.fcntl(fd, F_SETFL, ffi.new("int", bit.bor(flags, O_NONBLOCK))) < 0 then
			return nil, lasterror()
		end
		return true
	end
	
	-- Helper to build argv array
	local function build_argv(command, args)
		local count = 1 + (args and #args or 0)
		local argv = ffi.new("char*[?]", count + 1)
		
		argv[0] = ffi.cast("char*", command)
		if args then
			for i, arg in ipairs(args) do
				argv[i] = ffi.cast("char*", arg)
			end
		end
		argv[count] = nil
		
		return argv
	end
	
	-- Helper to build envp array
	local function build_envp(env)
		if not env then
			return ffi.C.environ
		end
		
		local count = 0
		for _ in pairs(env) do
			count = count + 1
		end
		
		local envp = ffi.new("char*[?]", count + 1)
		local i = 0
		for k, v in pairs(env) do
			local entry = k .. "=" .. v
			envp[i] = ffi.cast("char*", entry)
			i = i + 1
		end
		envp[count] = nil
		
		return envp
	end
	
	function process.spawn(opts)
		opts = opts or {}
		local command = opts.command or opts[1]
		if not command then
			return nil, "command is required"
		end
		
		-- Create pipes if needed
		local stdin_pipe = opts.stdin == "pipe" and ffi.new("int[2]") or nil
		local stdout_pipe = opts.stdout == "pipe" and ffi.new("int[2]") or nil
		local stderr_pipe = opts.stderr == "pipe" and ffi.new("int[2]") or nil
		
		if stdin_pipe and ffi.C.pipe(stdin_pipe) < 0 then
			return nil, lasterror()
		end
		if stdout_pipe and ffi.C.pipe(stdout_pipe) < 0 then
			return nil, lasterror()
		end
		if stderr_pipe and ffi.C.pipe(stderr_pipe) < 0 then
			return nil, lasterror()
		end
		
		-- Make parent-side fds non-blocking
		if stdin_pipe then
			local ok, err = set_nonblocking(stdin_pipe[1])
			if not ok then return nil, err end
		end
		if stdout_pipe then
			local ok, err = set_nonblocking(stdout_pipe[0])
			if not ok then return nil, err end
		end
		if stderr_pipe then
			local ok, err = set_nonblocking(stderr_pipe[0])
			if not ok then return nil, err end
		end
		
		local pid = ffi.C.fork()
		
		if pid < 0 then
			return nil, lasterror()
		elseif pid == 0 then
			-- Child process
			
			-- Setup stdin
			if stdin_pipe then
				ffi.C.dup2(stdin_pipe[0], 0)
				ffi.C.close(stdin_pipe[0])
				ffi.C.close(stdin_pipe[1])
			end
			
			-- Setup stdout
			if stdout_pipe then
				ffi.C.dup2(stdout_pipe[1], 1)
				ffi.C.close(stdout_pipe[0])
				ffi.C.close(stdout_pipe[1])
			end
			
			-- Setup stderr
			if stderr_pipe then
				ffi.C.dup2(stderr_pipe[1], 2)
				ffi.C.close(stderr_pipe[0])
				ffi.C.close(stderr_pipe[1])
			end
			
			-- Change directory if specified
			if opts.cwd then
				ffi.C.chdir(opts.cwd)
			end
			
			-- Build argv and envp
			local argv = build_argv(command, opts.args)
			local envp = build_envp(opts.env)
			
			-- Execute
			ffi.C.execve(command, argv, envp)
			
			-- If we get here, exec failed
			ffi.C._exit(127)
		else
			-- Parent process

			-- Close child ends of pipes
			if stdin_pipe then ffi.C.close(stdin_pipe[0]) end
			if stdout_pipe then ffi.C.close(stdout_pipe[1]) end
			if stderr_pipe then ffi.C.close(stderr_pipe[1]) end

			local self = setmetatable({
				pid = tonumber(pid),
				stdin = stdin_pipe and stdin_pipe[1] or nil,
				stdout = stdout_pipe and stdout_pipe[0] or nil,
				stderr = stderr_pipe and stderr_pipe[0] or nil,
				exit_code = nil,  -- Cached exit code after wait
			}, meta)

			return self
		end
	end

	function meta:wait()
		-- Return cached exit code if already waited
		if self.exit_code then
			return self.exit_code
		end

		local status = ffi.new("int[1]")
		local ret = ffi.C.waitpid(self.pid, status, 0)

		if ret < 0 then
			return nil, lasterror()
		end

		-- Extract exit code from status
		-- WIFEXITED(status) and WEXITSTATUS(status)
		local exit_code = bit.rshift(bit.band(status[0], 0xFF00), 8)
		self.exit_code = exit_code
		return exit_code
	end

	function meta:try_wait()
		-- Return cached exit code if already waited
		if self.exit_code then
			return true, self.exit_code
		end

		local status = ffi.new("int[1]")
		local ret = ffi.C.waitpid(self.pid, status, WNOHANG)

		if ret < 0 then
			return nil, lasterror()
		elseif ret == 0 then
			return false
		else
			local exit_code = bit.rshift(bit.band(status[0], 0xFF00), 8)
			self.exit_code = exit_code
			return true, exit_code
		end
	end
	
	function meta:kill(signal)
		signal = signal or SIGTERM
		if ffi.C.kill(self.pid, signal) < 0 then
			return nil, lasterror()
		end
		return true
	end
	
	function meta:write(data)
		if not self.stdin then
			return nil, "stdin is not piped"
		end
		
		local ret = ffi.C.write(self.stdin, data, #data)
		if ret < 0 then
			local err, code = lasterror()
			-- EAGAIN/EWOULDBLOCK means non-blocking write would block
			if code == 11 or code == 35 then
				return 0
			end
			return nil, err
		end
		
		return tonumber(ret)
	end
	
	function meta:read(size)
		if not self.stdout then
			return nil, "stdout is not piped"
		end
		
		size = size or 4096
		local buffer = ffi.new("char[?]", size)
		local ret = ffi.C.read(self.stdout, buffer, size)
		
		if ret < 0 then
			local err, code = lasterror()
			-- EAGAIN/EWOULDBLOCK means no data available
			if code == 11 or code == 35 then
				return ""
			end
			return nil, err
		elseif ret == 0 then
			return ""
		end
		
		return ffi.string(buffer, tonumber(ret))
	end
	
	function meta:read_err(size)
		if not self.stderr then
			return nil, "stderr is not piped"
		end
		
		size = size or 4096
		local buffer = ffi.new("char[?]", size)
		local ret = ffi.C.read(self.stderr, buffer, size)
		
		if ret < 0 then
			local err, code = lasterror()
			if code == 11 or code == 35 then
				return ""
			end
			return nil, err
		elseif ret == 0 then
			return ""
		end
		
		return ffi.string(buffer, tonumber(ret))
	end
	
	function meta:close()
		if self.stdin then
			ffi.C.close(self.stdin)
			self.stdin = nil
		end
		if self.stdout then
			ffi.C.close(self.stdout)
			self.stdout = nil
		end
		if self.stderr then
			ffi.C.close(self.stderr)
			self.stderr = nil
		end
		return true
	end
	
	function meta:__gc()
		self:close()
	end
	
	-- Export signal constants for Unix
	process.SIGTERM = SIGTERM
	process.SIGKILL = SIGKILL
	process.SIGINT = 2
	process.SIGQUIT = 3
end

return process
