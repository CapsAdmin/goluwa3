local ffi = require("ffi")
local buffer = require("string.buffer")
local threads = {}

if ffi.os == "Windows" then
	ffi.cdef[[
		typedef uint32_t (*thread_callback)(void*);

        void* CreateThread(
            void* lpThreadAttributes,
            size_t dwStackSize,
            thread_callback lpStartAddress,
            void* lpParameter,
            uint32_t dwCreationFlags,
            uint32_t* lpThreadId
        );
        uint32_t WaitForSingleObject(void* hHandle, uint32_t dwMilliseconds);
        int CloseHandle(void* hObject);
        uint32_t GetLastError(void);
        int32_t GetExitCodeThread(void* hThread, uint32_t* lpExitCode);

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
	local THREAD_ALL_ACCESS = 0x1F03FF

	function threads.run_thread(func_ptr, udata)
		local thread_id = ffi.new("uint32_t[1]")
		local thread_handle = kernel32.CreateThread(
			nil, -- Security attributes (default)
			0, -- Stack size (default)
			ffi.cast("thread_callback", func_ptr),
			udata, -- Thread parameter
			0, -- Creation flags (run immediately)
			thread_id -- Thread identifier
		)

		if thread_handle == nil then check_win_error(0) end

		-- Return both handle and ID for Windows
		return {handle = thread_handle, id = thread_id[0]}
	end

	function threads.join_thread(thread_data)
		local wait_result = kernel32.WaitForSingleObject(thread_data.handle, INFINITE)

		if wait_result == INFINITE then check_win_error(0) end

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
end

function threads.pointer_encode(obj)
	local buf = buffer.new()
	buf:encode(obj)
	local ptr, len = buf:ref()
	return buf, ptr, len
end

function threads.pointer_decode(ptr, len)
	local buf = buffer.new()
	buf:set(ptr, len)
	return buf:decode()
end

threads.STATUS_UNDEFINED = 0
threads.STATUS_COMPLETED = 1
threads.STATUS_ERROR = 2

local thread_func_signature = "void *(*)(void *)"
local thread_data_t = ffi.typeof([[
	struct {
		char *input_buffer;
		uint32_t input_buffer_len;
		char *output_buffer;
		uint32_t output_buffer_len;
		void *shared_pointer;
		uint8_t status;
	}
]])
threads.thread_data_ptr_t = ffi.typeof("$*", thread_data_t)

do
	local LUA_GLOBALSINDEX = -10002
	ffi.cdef[[
        typedef struct lua_State lua_State;
        lua_State *luaL_newstate(void);
        void luaL_openlibs(lua_State *L);
        void lua_close(lua_State *L);
        int luaL_loadstring(lua_State *L, const char *s);
        int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
        void lua_getfield(lua_State *L, int index, const char *k);
        void lua_settop(lua_State *L, int index);
        void lua_pop(lua_State *L, int n);
        const char *lua_tolstring(lua_State *L, int index, size_t *len);
        ptrdiff_t lua_tointeger(lua_State *L, int index);
        int lua_gettop(lua_State *L);
        void lua_pushstring(lua_State *L, const char *s);
        const void *lua_topointer(lua_State *L, int index);
        double lua_tonumber(lua_State *L, int index);
        void *lua_touserdata(lua_State *L, int idx);
        void lua_pushlstring(lua_State *L, const char *p, size_t len);
    ]]

	local function create_state()
		local L = ffi.C.luaL_newstate()

		if L == nil then error("Failed to create new Lua state: Out of memory", 2) end

		ffi.C.luaL_openlibs(L)
		return L
	end

	local function close_state(L)
		ffi.C.lua_close(L)
	end

	local function check_error(L, ret)
		if ret == 0 then return end

		local chr = ffi.C.lua_tolstring(L, -1, nil)
		local msg = ffi.string(chr)
		error(msg, 2)
	end

	local function get_function_pointer(L, code, func)
		check_error(L, ffi.C.luaL_loadstring(L, code))
		local str = string.dump(func)
		ffi.C.lua_pushlstring(L, str, #str)
		check_error(L, ffi.C.lua_pcall(L, 1, 1, 0))
		local ptr = ffi.C.lua_topointer(L, -1)
		ffi.C.lua_settop(L, -2)
		local box = ffi.cast("uintptr_t*", ptr)
		return box[0]
	end

	local meta = {}
	meta.__index = meta

	-- Automatic cleanup when thread object is garbage collected
	function meta:__gc()
		if self.lua_state then
			close_state(self.lua_state)
			self.lua_state = nil
		end
	end

	function threads.new(func)
		local self = setmetatable({}, meta)
		local L = create_state()
		local func_ptr = get_function_pointer(
			L,
			[[
            local run = assert(load(...))
            local ffi = require("ffi")
			local threads = require("threads")

            local function main(udata)
                local data = ffi.cast(threads.thread_data_ptr_t, udata)

                if data.shared_pointer ~= nil then
                    local result = run(data.shared_pointer)

                    data.status = threads.STATUS_COMPLETED

                    -- Return nothing (results written to shared memory)
                    return nil
				end

				local input = threads.pointer_decode(data.input_buffer, tonumber(data.input_buffer_len))
				local buf, ptr, len = threads.pointer_encode(run(input))

				data.output_buffer = ptr
				data.output_buffer_len = len

				data.status = threads.STATUS_COMPLETED

				return nil
            end

			local function main_protected(udata)
				local ok, err_or_ptr = pcall(main, udata)
				if not ok then
					local data = ffi.cast(threads.thread_data_ptr_t, udata)

					data.status = threads.STATUS_ERROR

					local data = ffi.cast(threads.thread_data_ptr_t, udata)
					local buf, ptr, len = threads.pointer_encode({ok, err_or_ptr})
					data.output_buffer = ptr
					data.output_buffer_len = len

					return nil
				end

				return err_or_ptr
			end

			_G.main_ref = main_protected

            return ffi.new("uintptr_t[1]", ffi.cast("uintptr_t", ffi.cast("void *(*)(void *)", main_protected)))
        ]],
			func
		)
		self.lua_state = L
		self.func_ptr = ffi.cast(thread_func_signature, func_ptr)
		return self
	end

	function meta:run(obj, shared_ptr)
		if shared_ptr then
			self.buffer = nil
			self.shared_ptr_ref = obj
			self.input_data = thread_data_t({shared_pointer = ffi.cast("void *", obj)})
			self.shared_mode = true
		else
			local buf, ptr, len = threads.pointer_encode(obj)
			self.buffer = buf
			self.input_data = thread_data_t({input_buffer = ptr, input_buffer_len = len})
			self.shared_mode = false
		end

		self.id = threads.run_thread(self.func_ptr, self.input_data)
	end

	function meta:is_done()
		return self.input_data and self.input_data.status == threads.STATUS_COMPLETED
	end

	function meta:join()
		threads.join_thread(self.id)

		if self.shared_mode then
			-- Shared memory mode: no result to deserialize
			self.buffer = nil
			self.input_data = nil
			self.shared_ptr_ref = nil
			return nil
		else
			local result = threads.pointer_decode(self.input_data.output_buffer, self.input_data.output_buffer_len)
			local status = self.input_data.status
			self.buffer = nil
			self.input_data = nil
			
			if status == threads.STATUS_ERROR then
				return result[1], result[2]
			end

			return result
		end
	end

	function meta:close()
		close_state(self.lua_state)
	end
end

-- Thread pool implementation using shared memory
do
	local pool_meta = {}
	pool_meta.__index = pool_meta
	-- Define shared memory structure for thread pool communication
	-- Each thread has: work_available, work_done, should_exit flags
	local thread_control_t = ffi.typeof[[
		struct {
			volatile int work_available;
			volatile int work_done;
			volatile int should_exit;
			const char* worker_func;  // Serialized worker function
			size_t worker_func_len;  // Length of serialized worker function
			const char* work_data;  // Serialized work data
			size_t work_data_len;  // Length of work data
			char* result_data;  // Serialized result data
			size_t result_data_len;  // Length of result data
			int thread_id;
			int padding;  // Alignment
		}
	]]
	threads.thread_control_t = thread_control_t
	threads.thread_control_ptr_t = ffi.typeof("$*", thread_control_t)
	local thread_control_array_t = ffi.typeof("$[?]", thread_control_t)

	-- Create a new thread pool
	function threads.new_pool(worker_func, num_threads)
		local self = setmetatable({}, pool_meta)
		self.num_threads = num_threads or 8
		self.worker_func = worker_func
		self.thread_objects = {}
		-- Allocate shared control structures (one per thread)
		self.control = thread_control_array_t(num_threads)
		local worker_func_str = string.dump(worker_func)

		-- Initialize control structures
		for i = 0, num_threads - 1 do
			local ctrl = self.control[i]
			ctrl.work_available = 0
			ctrl.work_done = 1
			ctrl.should_exit = 0
			ctrl.worker_func = worker_func_str
			ctrl.worker_func_len = #worker_func_str
			ctrl.work_data = nil
			ctrl.work_data_len = 0
			ctrl.result_data = nil
			ctrl.result_data_len = 0
			ctrl.thread_id = i + 1 -- 1-based for Lua
		end

		-- Keep buffers alive so pointers remain valid
		self.work_buffers = {}
		self.result_buffers = {}
		-- Create persistent worker that loops waiting for work
		local persistent_worker = function(shared_ptr)
			local ffi = require("ffi")
			local threads = require("threads")
			local buffer = require("string.buffer")
			local control = ffi.cast(threads.thread_control_ptr_t, shared_ptr)
			local thread_id = control.thread_id
			-- Get the actual worker function from the serialized input
			local worker_func = assert(load(ffi.string(control.worker_func, control.worker_func_len)))

			-- Thread loop: wait for work, process it, repeat
			while true do
				-- Check if we should exit
				if control.should_exit == 1 then break end

				-- Check if work is available
				if control.work_available == 1 then
					-- Deserialize work data
					local work = threads.pointer_decode(control.work_data, control.work_data_len)
					-- Process it with the worker function
					local result = worker_func(work)
					local buf, result_ptr, result_len = threads.pointer_encode(result)
					-- Store result pointer in control structure
					control.result_data = result_ptr
					control.result_data_len = result_len
					-- Mark as done
					control.work_available = 0
					control.work_done = 1
				end

				-- Small sleep to avoid busy-waiting
				threads.sleep(1)
			end

			return thread_id
		end

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
		assert(self.control[idx].work_done == 1, "Thread " .. thread_id .. " is still busy")
		local buf, work_ptr, work_len = threads.pointer_encode(work)
		self.work_buffers[thread_id] = buf -- Keep buffer alive
		-- Set work data in shared control structure
		self.control[idx].work_data = work_ptr
		self.control[idx].work_data_len = work_len
		self.control[idx].work_done = 0
		self.control[idx].work_available = 1
	end

	-- Wait for a specific thread to complete
	function pool_meta:wait(thread_id)
		local idx = thread_id - 1

		while self.control[idx].work_done == 0 do
			threads.sleep(1)
		end

		return threads.pointer_decode(self.control[idx].result_data, self.control[idx].result_data_len)
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
		end

		-- Wait for threads to exit and clean up
		for i = 1, self.num_threads do
			self.thread_objects[i]:join()
			self.thread_objects[i]:close()
		end

		self.thread_objects = {}
	end

	-- Cleanup on garbage collection
	function pool_meta:__gc()
		if self.thread_objects and #self.thread_objects > 0 then self:shutdown() end
	end
end

return threads
