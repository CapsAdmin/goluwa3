local ffi = require("ffi")
local buffer = require("string.buffer")
local setmetatable = import("goluwa/helpers/setmetatable_gc.lua")
local LuaState = import("goluwa/bindings/luajit.lua")
local threads = {}
local live_threads = {}
local pool_signal_fields

ffi.cdef[[
	void *malloc(size_t size);
	void free(void *ptr);
]]

local function retain_thread(thread)
	live_threads[thread] = true
	return thread
end

local function release_thread(thread)
	live_threads[thread] = nil
	return thread
end

local function is_thread_dead(thread)
	if not thread or thread.id == nil then return false end
	if not thread.input_data then return false end
	return threads.get_status(thread) ~= threads.STATUS_UNDEFINED
end

local function release_dead_threads()
	for thread in pairs(live_threads) do
		if is_thread_dead(thread) then
			release_thread(thread)
		end
	end
end

local init_thread_signal
local signal_thread_done
local is_thread_signal_done
local close_thread_signal
local init_pool_signals
local signal_pool_work
local wait_pool_work
local reset_pool_done
local signal_pool_done
local wait_pool_done
local close_pool_signals

if ffi.os == "Windows" then
	ffi.cdef[[
		typedef uint32_t (__stdcall *thread_callback)(void*);
		uintptr_t _beginthreadex(
			void* security,
			uint32_t stack_size,
			thread_callback start_address,
			void* arglist,
			uint32_t initflag,
			uint32_t* thrdaddr
		);

        uint32_t WaitForSingleObject(void* hHandle, uint32_t dwMilliseconds);
        int CloseHandle(void* hObject);
        uint32_t GetLastError(void);
        int32_t GetExitCodeThread(void* hThread, uint32_t* lpExitCode);
		void* CreateEventA(void* lpEventAttributes, int bManualReset, int bInitialState, const char* lpName);
		int SetEvent(void* hEvent);
		int ResetEvent(void* hEvent);

		typedef struct _SYSTEM_INFO {
            union {
                uint32_t dwOemId;
                struct {
                    uint16_t wProcessorArchitecture;
                    uint16_t wReserved;
                };
            };
            uint32_t dwPageSize;
            void* lpMinimumApplicationAddress;
            void* lpMaximumApplicationAddress;
            size_t dwActiveProcessorMask;
            uint32_t dwNumberOfProcessors;
            uint32_t dwProcessorType;
            uint32_t dwAllocationGranularity;
            uint16_t wProcessorLevel;
            uint16_t wProcessorRevision;
        } SYSTEM_INFO;

        void GetSystemInfo(SYSTEM_INFO* lpSystemInfo);

		void Sleep(uint32_t dwMilliseconds);
    ]]
	local kernel32 = ffi.load("kernel32")
	local crt = ffi.load("ucrtbase")
	local WAIT_OBJECT_0 = 0
	local WAIT_TIMEOUT = 0x102

	local function check_win_error(success)
		if success ~= 0 then return end

		local error_code = kernel32.GetLastError()
		local error_messages = {
			[5] = "Access denied",
			[6] = "Invalid handle",
			[8] = "Not enough memory",
			[87] = "Invalid parameter",
			[1455] = "Page file quota exceeded",
		}
		local err_msg = error_messages[error_code] or "unknown error"
		error(string.format("Thread operation failed: %s (Error code: %d)", err_msg, error_code), 2)
	end

	-- Constants
	local INFINITE = 0xFFFFFFFF
	local WAIT_FAILED = 0xFFFFFFFF
	local THREAD_ALL_ACCESS = 0x1F03FF
	pool_signal_fields = [[
			void *work_ready_event;
			void *work_done_event;
	]]

	function init_thread_signal(data)
		data.completed_event = kernel32.CreateEventA(nil, 1, 0, nil)
		if data.completed_event == nil then check_win_error(0) end
	end

	function signal_thread_done(data)
		if kernel32.SetEvent(data.completed_event) == 0 then check_win_error(0) end
	end

	function is_thread_signal_done(data)
		if data == nil or data.completed_event == nil then return false end
		local result = kernel32.WaitForSingleObject(data.completed_event, 0)
		if result == WAIT_OBJECT_0 then return true end
		if result == WAIT_TIMEOUT then return false end
		check_win_error(0)
		return false
	end

	function close_thread_signal(data)
		if data == nil or data.completed_event == nil then return end
		if kernel32.CloseHandle(data.completed_event) == 0 then check_win_error(0) end
		data.completed_event = nil
	end

	function init_pool_signals(control)
		control.work_ready_event = kernel32.CreateEventA(nil, 0, 0, nil)
		if control.work_ready_event == nil then check_win_error(0) end
		control.work_done_event = kernel32.CreateEventA(nil, 1, 1, nil)
		if control.work_done_event == nil then
			kernel32.CloseHandle(control.work_ready_event)
			control.work_ready_event = nil
			check_win_error(0)
		end
	end

	function signal_pool_work(control)
		if kernel32.SetEvent(control.work_ready_event) == 0 then check_win_error(0) end
	end

	function wait_pool_work(control)
		local result = kernel32.WaitForSingleObject(control.work_ready_event, INFINITE)
		if result ~= WAIT_OBJECT_0 then check_win_error(0) end
	end

	function reset_pool_done(control)
		if kernel32.ResetEvent(control.work_done_event) == 0 then check_win_error(0) end
	end

	function signal_pool_done(control)
		if kernel32.SetEvent(control.work_done_event) == 0 then check_win_error(0) end
	end

	function wait_pool_done(control)
		local result = kernel32.WaitForSingleObject(control.work_done_event, INFINITE)
		if result ~= WAIT_OBJECT_0 then check_win_error(0) end
	end

	function close_pool_signals(control)
		if control.work_ready_event ~= nil then
			if kernel32.CloseHandle(control.work_ready_event) == 0 then check_win_error(0) end
			control.work_ready_event = nil
		end

		if control.work_done_event ~= nil then
			if kernel32.CloseHandle(control.work_done_event) == 0 then check_win_error(0) end
			control.work_done_event = nil
		end
	end

	function threads.run_thread(func_ptr, udata)
		local thread_id = ffi.new("uint32_t[1]")
		local thread_handle = crt._beginthreadex(nil, 0, ffi.cast("thread_callback", func_ptr), udata, 0, thread_id)

		if thread_handle == 0 then error("failed to start CRT thread", 2) end

		-- Return both handle and ID for Windows
		return {handle = ffi.new("void *[1]", ffi.cast("void *", tonumber(thread_handle)))[0], id = thread_id[0]}
	end

	function threads.join_thread(thread_data)
		local wait_result = tonumber(kernel32.WaitForSingleObject(thread_data.handle, INFINITE))

		if wait_result == WAIT_FAILED then check_win_error(0) end

		local exit_code = ffi.new("uint32_t[1]")

		if kernel32.GetExitCodeThread(thread_data.handle, exit_code) == 0 then
			check_win_error(0)
		end

		if kernel32.CloseHandle(thread_data.handle) == 0 then check_win_error(0) end

		return exit_code[0]
	end

	function threads.get_thread_count()
		local sysinfo = ffi.new("SYSTEM_INFO")
		kernel32.GetSystemInfo(sysinfo)
		return tonumber(sysinfo.dwNumberOfProcessors)
	end

	function threads.sleep(ms)
		ffi.C.Sleep(ms)
	end
else
	ffi.cdef[[
		typedef uint64_t pthread_t;

		typedef struct {
			uint32_t flags;
			void * stack_base;
			size_t stack_size;
			size_t guard_size;
			int32_t sched_policy;
			int32_t sched_priority;
		} pthread_attr_t;

		int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start_routine)(void *), void *arg);
		int pthread_join(pthread_t thread, void **value_ptr);

		long sysconf(int name);

		int usleep(unsigned int usecs);
	]]
	local pt = ffi.load("pthread")

	-- Enhanced pthread error checking
	local function check_pthread(int)
		if int == 0 then return end

		local error_messages = {
			[11] = "System lacks resources or reached thread limit",
			[22] = "Invalid thread attributes specified",
			[1] = "Insufficient permissions to set scheduling parameters",
			[3] = "Thread not found",
			[35] = "Deadlock condition detected",
			[12] = "Insufficient memory to create thread",
		}
		local err_msg = error_messages[int] or "unknown error"

		if err_msg then
			error(string.format("Thread operation failed: %s (Error code: %d)", err_msg, int), 2)
		end
	end

	function threads.run_thread(func_ptr, udata)
		local thread_id = ffi.new("pthread_t[1]", 1)
		check_pthread(pt.pthread_create(thread_id, nil, func_ptr, udata))
		return thread_id[0]
	end

	function threads.join_thread(id)
		local out = ffi.new("void*[1]")
		check_pthread(pt.pthread_join(id, out))
		return out[0]
	end

	local FLAG_SC_NPROCESSORS_ONLN = 83

	if ffi.os == "OSX" then FLAG_SC_NPROCESSORS_ONLN = 58 end

	function threads.get_thread_count()
		return tonumber(ffi.C.sysconf(FLAG_SC_NPROCESSORS_ONLN))
	end

	function threads.sleep(ms)
		ffi.C.usleep(ms * 1000)
	end

	ffi.cdef[[
		struct pollfd {
			int fd;
			short events;
			short revents;
		};
		int poll(struct pollfd *fds, unsigned long nfds, int timeout);
		int pipe(int pipefd[2]);
		long read(int fd, void *buf, size_t count);
		long write(int fd, const void *buf, size_t count);
		int close(int fd);
	]]
	local POLLIN = 0x0001
	local signal_byte = ffi.new("uint8_t[1]", 1)
	local drain_byte = ffi.new("uint8_t[1]")
	pool_signal_fields = [[
			int work_read_fd;
			int work_write_fd;
			int done_read_fd;
			int done_write_fd;
	]]

	local function poll_fd(fd, timeout)
		local pfd = ffi.new("struct pollfd[1]")
		pfd[0].fd = fd
		pfd[0].events = POLLIN
		local ret = ffi.C.poll(pfd, 1, timeout)
		if ret < 0 then error("poll failed while synchronizing thread state", 2) end
		return ret > 0 and bit.band(pfd[0].revents, POLLIN) ~= 0
	end

	local function write_signal(fd)
		if ffi.C.write(fd, signal_byte, 1) ~= 1 then
			error("failed to signal thread state", 2)
		end
	end

	local function read_signal(fd)
		if ffi.C.read(fd, drain_byte, 1) ~= 1 then
			error("failed to receive thread state signal", 2)
		end
	end

	function init_thread_signal(data)
		local pipefd = ffi.new("int[2]")
		if ffi.C.pipe(pipefd) ~= 0 then error("failed to create completion pipe", 2) end
		data.completed_read_fd = pipefd[0]
		data.completed_write_fd = pipefd[1]
	end

	function signal_thread_done(data)
		write_signal(data.completed_write_fd)
	end

	function is_thread_signal_done(data)
		if data == nil or data.completed_read_fd < 0 then return false end
		return poll_fd(data.completed_read_fd, 0)
	end

	function close_thread_signal(data)
		if data == nil then return end
		if data.completed_read_fd >= 0 then
			ffi.C.close(data.completed_read_fd)
			data.completed_read_fd = -1
		end
		if data.completed_write_fd >= 0 then
			ffi.C.close(data.completed_write_fd)
			data.completed_write_fd = -1
		end
	end

	function init_pool_signals(control)
		local work_pipe = ffi.new("int[2]")
		if ffi.C.pipe(work_pipe) ~= 0 then error("failed to create pool work pipe", 2) end
		local done_pipe = ffi.new("int[2]")
		if ffi.C.pipe(done_pipe) ~= 0 then
			ffi.C.close(work_pipe[0])
			ffi.C.close(work_pipe[1])
			error("failed to create pool completion pipe", 2)
		end
		control.work_read_fd = work_pipe[0]
		control.work_write_fd = work_pipe[1]
		control.done_read_fd = done_pipe[0]
		control.done_write_fd = done_pipe[1]
	end

	function signal_pool_work(control)
		write_signal(control.work_write_fd)
	end

	function wait_pool_work(control)
		read_signal(control.work_read_fd)
	end

	function reset_pool_done(control)
		if poll_fd(control.done_read_fd, 0) then
			read_signal(control.done_read_fd)
		end
	end

	function signal_pool_done(control)
		write_signal(control.done_write_fd)
	end

	function wait_pool_done(control)
		read_signal(control.done_read_fd)
	end

	function close_pool_signals(control)
		if control.work_read_fd >= 0 then ffi.C.close(control.work_read_fd) control.work_read_fd = -1 end
		if control.work_write_fd >= 0 then ffi.C.close(control.work_write_fd) control.work_write_fd = -1 end
		if control.done_read_fd >= 0 then ffi.C.close(control.done_read_fd) control.done_read_fd = -1 end
		if control.done_write_fd >= 0 then ffi.C.close(control.done_write_fd) control.done_write_fd = -1 end
	end
end

function threads.pointer_encode(obj)
	local buf = buffer.new()
	buf:encode(obj)
	local ptr, len = buf:ref()
	return buf, ptr, len
end

function threads.pointer_encode_owned(obj)
	local buf, ptr, len = threads.pointer_encode(obj)
	local alloc_len = tonumber(len)

	if alloc_len == 0 then return nil, 0 end

	local mem = ffi.C.malloc(alloc_len)

	if mem == nil then error("failed to allocate thread buffer", 2) end

	ffi.copy(mem, ptr, alloc_len)
	return ffi.cast("char *", mem), alloc_len
end

function threads.pointer_decode(ptr, len)
	local buf = buffer.new()
	buf:set(ptr, len)
	return buf:decode()
end

function threads.pointer_free(ptr)
	if ptr == nil then return end
	ffi.C.free(ptr)
end

threads.STATUS_UNDEFINED = 0
threads.STATUS_COMPLETED = 1
threads.STATUS_ERROR = 2
local thread_data_t = ffi.typeof([[
	struct {
		char *input_buffer;
		uint32_t input_buffer_len;
		char *output_buffer;
		uint32_t output_buffer_len;
		void *shared_pointer;
		uint8_t status;
		void *completed_event;
		int completed_read_fd;
		int completed_write_fd;
	}
]])
threads.thread_data_ptr_t = ffi.typeof("$*", thread_data_t)
threads.signal_thread_done = signal_thread_done
threads.wait_pool_work = wait_pool_work
threads.signal_pool_done = signal_pool_done
local worker_bootstrap = [=[
    local run = assert(load(...))
	local ffi = require("ffi")
	local callback_result = ffi.os == "Windows" and 0 or nil

	if ffi.os == "Windows" then
		ffi.cdef[[typedef uint32_t (__stdcall *thread_callback)(void*);]]
	end

	local function get_threads()
		if rawget(_G, "import") == nil or rawget(_G, "require") == nil then
			require("goluwa.global_environment")
		end

		return import("goluwa/bindings/threads.lua")
	end

	local function main(udata)
		local threads = get_threads()
        local data = ffi.cast(threads.thread_data_ptr_t, udata)

        if data.shared_pointer ~= nil then
			run(data.shared_pointer)

            data.status = threads.STATUS_COMPLETED
			threads.signal_thread_done(data)

			return callback_result
		end

		local input = threads.pointer_decode(data.input_buffer, tonumber(data.input_buffer_len))
		local ptr, len = threads.pointer_encode_owned(run(input))

		data.output_buffer = ptr
		data.output_buffer_len = len

		data.status = threads.STATUS_COMPLETED
		threads.signal_thread_done(data)

		return callback_result
    end

	local function main_protected(udata)
		local ok, err_or_ptr = pcall(main, udata)

		if not ok then
			local threads = get_threads()
			local data = ffi.cast(threads.thread_data_ptr_t, udata)

			data.status = threads.STATUS_ERROR

			local ptr, len = threads.pointer_encode_owned({ok, err_or_ptr})
			data.output_buffer = ptr
			data.output_buffer_len = len
			threads.signal_thread_done(data)

			return callback_result
		end

		return callback_result
	end

	_G.main_ref = main_protected
	_G.main_ref_ptr = ffi.cast(ffi.os == "Windows" and "thread_callback" or "void *(*)(void *)", main_protected)

    return tostring(ffi.new("uintptr_t", ffi.cast("uintptr_t", _G.main_ref_ptr)))
]=]

do
	local meta = {}
	meta.__index = meta

	function meta:__gc()
		if self.id ~= nil then
			if not is_thread_dead(self) then return end

			threads.join_thread(self.id)
			self.id = nil
		end

		release_thread(self)

		if self.input_data then
			if self.input_data.output_buffer ~= nil then
				threads.pointer_free(self.input_data.output_buffer)
				self.input_data.output_buffer = nil
				self.input_data.output_buffer_len = 0
			end
			close_thread_signal(self.input_data)
			self.input_data = nil
		end

		if self.thread_state then
			self.thread_state:Close()
			self.thread_state = nil
		end
	end

	function threads.new(func)
		release_dead_threads()
		assert(type(func) == "string" or type(func) == "function", "thread worker must be a source string or function")
		local self = setmetatable({}, meta)
		local worker_source = type(func) == "string" and func or string.dump(func)
		self.thread_state = LuaState.New()
		self.func_ptr = ffi.cast(ffi.os == "Windows" and "thread_callback" or "void *(*)(void *)", self.thread_state:Run(worker_bootstrap, worker_source))
	
		return self
	end

	function meta:run(obj, shared_ptr)
		if self.id ~= nil then error("thread is already running", 2) end

		if shared_ptr then
			self.buffer = nil
			self.shared_ptr_ref = obj
			self.input_data = thread_data_t{shared_pointer = ffi.cast("void *", obj), completed_read_fd = -1, completed_write_fd = -1}
			self.shared_mode = true
		else
			local buf, ptr, len = threads.pointer_encode(obj)
			self.buffer = buf
			self.input_data = thread_data_t{input_buffer = ptr, input_buffer_len = len, completed_read_fd = -1, completed_write_fd = -1}
			self.shared_mode = false
		end

		init_thread_signal(self.input_data)

		retain_thread(self)
		self.id = threads.run_thread(self.func_ptr, self.input_data)
	end

	function threads.get_status(thread)
		if not thread or not thread.input_data then return nil end
		if thread.id == nil then return tonumber(thread.input_data.status) end
		if not is_thread_signal_done(thread.input_data) then return threads.STATUS_UNDEFINED end
		return tonumber(thread.input_data.status)
	end

	function meta:is_done()
		if not self.input_data then return false end

		local done = threads.get_status(self) ~= threads.STATUS_UNDEFINED

		if done then
			release_thread(self)
		end

		return done
	end

	function meta:join()
		if not self.id then return nil end

		threads.join_thread(self.id)
		self.id = nil
		release_thread(self)

		if self.shared_mode then
			local result, err
			local status = self.input_data.status

			if status == threads.STATUS_ERROR then
				local res = threads.pointer_decode(self.input_data.output_buffer, self.input_data.output_buffer_len)
				threads.pointer_free(self.input_data.output_buffer)
				self.input_data.output_buffer = nil
				self.input_data.output_buffer_len = 0
				result, err = res[1], res[2]
			end

			-- Shared memory mode: no result to deserialize if successful
			self.buffer = nil
			close_thread_signal(self.input_data)
			self.input_data = nil
			self.shared_ptr_ref = nil

			if status == threads.STATUS_ERROR then return result, err end

			return nil
		else
			local result = threads.pointer_decode(self.input_data.output_buffer, self.input_data.output_buffer_len)
			threads.pointer_free(self.input_data.output_buffer)
			self.input_data.output_buffer = nil
			self.input_data.output_buffer_len = 0
			local status = self.input_data.status
			self.buffer = nil
			close_thread_signal(self.input_data)
			self.input_data = nil

			if status == threads.STATUS_ERROR then return result[1], result[2] end

			return result
		end
	end

	function meta:close()
		if self.id ~= nil then return nil, "cannot close running thread; join first" end

		release_thread(self)

		if self.thread_state then
			self.thread_state:Close()
			self.thread_state = nil
		end

		self.func_ptr = nil
		return true
	end
end

-- Thread pool implementation using shared memory
do
	local pool_meta = {}
	pool_meta.__index = pool_meta
	-- Define shared memory structure for thread pool communication
	-- Each thread has: work_available, work_done, should_exit flags
	local thread_control_t = ffi.typeof(
		[[
		struct {
			volatile int should_exit;
			const char* worker_func;  // Serialized worker function
			size_t worker_func_len;  // Length of serialized worker function
			const char* work_data;  // Serialized work data
			size_t work_data_len;  // Length of work data
			char* result_data;  // Serialized result data
			size_t result_data_len;  // Length of result data
			int thread_id;
			int padding;  // Alignment
		]] .. pool_signal_fields .. [[
		}
	]]
	)
	threads.thread_control_t = thread_control_t
	threads.thread_control_ptr_t = ffi.typeof("$*", thread_control_t)
	local thread_control_array_t = ffi.typeof("$[?]", thread_control_t)

	-- Create a new thread pool
	function threads.new_pool(worker_func, num_threads)
		local self = setmetatable({}, pool_meta)
		self.num_threads = num_threads or 8
		self.worker_func = worker_func
		self.thread_objects = {}
		self.busy = {}
		-- Allocate shared control structures (one per thread)
		self.control = thread_control_array_t(num_threads)
		local worker_func_str = string.dump(worker_func)

		-- Initialize control structures
		for i = 0, num_threads - 1 do
			local ctrl = self.control[i]
			ctrl.should_exit = 0
			ctrl.worker_func = worker_func_str
			ctrl.worker_func_len = #worker_func_str
			ctrl.work_data = nil
			ctrl.work_data_len = 0
			ctrl.result_data = nil
			ctrl.result_data_len = 0
			ctrl.thread_id = i + 1 -- 1-based for Lua

			if ffi.os ~= "Windows" then
				ctrl.work_read_fd = -1
				ctrl.work_write_fd = -1
				ctrl.done_read_fd = -1
				ctrl.done_write_fd = -1
			end

			init_pool_signals(ctrl)
		end

		-- Keep buffers alive so pointers remain valid
		self.work_buffers = {}
		self.result_buffers = {}
		-- Create persistent worker that loops waiting for work
		local persistent_worker = [=[
			local shared_ptr = ...
			local ffi = require("ffi")
			local threads = import("goluwa/bindings/threads.lua")
			local control = ffi.cast(threads.thread_control_ptr_t, shared_ptr)
			local thread_id = control.thread_id
			local worker_func = assert(load(ffi.string(control.worker_func, control.worker_func_len)))

			while true do
				threads.wait_pool_work(control)

				if control.should_exit == 1 then break end

				local work = threads.pointer_decode(control.work_data, control.work_data_len)
				local result = worker_func(work)
				local result_ptr, result_len = threads.pointer_encode_owned(result)
				control.result_data = result_ptr
				control.result_data_len = result_len
				threads.signal_pool_done(control)
			end

			return thread_id
		]=]

		-- Create and start persistent threads
		for i = 1, num_threads do
			local thread = threads.new(persistent_worker)
			-- Pass the control structure pointer as shared memory
			-- and the worker function as serialized data
			local control_ptr = self.control + (i - 1)
			thread:run(control_ptr, true)
			self.thread_objects[i] = thread
		end

		return self
	end

	-- Submit work to a specific thread
	function pool_meta:submit(thread_id, work)
		local idx = thread_id - 1
		assert(not self.busy[thread_id], "Thread " .. thread_id .. " is still busy")

		if self.control[idx].result_data ~= nil then
			threads.pointer_free(self.control[idx].result_data)
			self.control[idx].result_data = nil
			self.control[idx].result_data_len = 0
		end

		local buf, work_ptr, work_len = threads.pointer_encode(work)
		self.work_buffers[thread_id] = buf -- Keep buffer alive
		-- Set work data in shared control structure
		self.control[idx].work_data = work_ptr
		self.control[idx].work_data_len = work_len
		self.busy[thread_id] = true
		reset_pool_done(self.control[idx])
		signal_pool_work(self.control[idx])
	end

	-- Wait for a specific thread to complete
	function pool_meta:wait(thread_id)
		local idx = thread_id - 1
		wait_pool_done(self.control[idx])
		self.busy[thread_id] = false

		local result = threads.pointer_decode(self.control[idx].result_data, self.control[idx].result_data_len)
		threads.pointer_free(self.control[idx].result_data)
		self.control[idx].result_data = nil
		self.control[idx].result_data_len = 0
		return result
	end

	-- Submit work to all threads
	function pool_meta:submit_all(work_items)
		assert(
			#work_items == self.num_threads,
			"Must provide work for all " .. self.num_threads .. " threads"
		)

		for i = 1, self.num_threads do
			self:submit(i, work_items[i])
		end
	end

	-- Wait for all threads to complete
	function pool_meta:wait_all()
		local results = {}

		for i = 1, self.num_threads do
			results[i] = self:wait(i)
		end

		return results
	end

	-- Shutdown the thread pool
	function pool_meta:shutdown()
		-- Signal all threads to exit
		for i = 0, self.num_threads - 1 do
			self.control[i].should_exit = 1
			signal_pool_work(self.control[i])
		end

		-- Wait for threads to exit and clean up
		for i = 1, self.num_threads do
			self.thread_objects[i]:join()
			self.thread_objects[i]:close()
		end

		for i = 0, self.num_threads - 1 do
			if self.control[i].result_data ~= nil then
				threads.pointer_free(self.control[i].result_data)
				self.control[i].result_data = nil
				self.control[i].result_data_len = 0
			end
			close_pool_signals(self.control[i])
		end

		self.thread_objects = {}
	end

	-- Cleanup on garbage collection
	function pool_meta:__gc()
		if self.thread_objects and #self.thread_objects > 0 then self:shutdown() end
	end
end

return threads
