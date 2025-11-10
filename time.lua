local ffi = require("ffi")

if ffi.os == "Windows" then
	ffi.cdef([[
		int QueryPerformanceFrequency(int64_t *lpFrequency);
		int QueryPerformanceCounter(int64_t *lpPerformanceCount);
	]])
	local q = ffi.new("int64_t[1]")
	ffi.C.QueryPerformanceFrequency(q)
	local freq = tonumber(q[0])
	local start_time = ffi.new("int64_t[1]")
	ffi.C.QueryPerformanceCounter(start_time)
	return function()
		local time = ffi.new("int64_t[1]")
		ffi.C.QueryPerformanceCounter(time)
		time[0] = time[0] - start_time[0]
		return tonumber(time[0]) / freq
	end
elseif ffi.os == "OSX" then
	ffi.cdef([[
		struct mach_timebase_info {
			uint32_t	numer;
			uint32_t	denom;
		};
		int mach_timebase_info(struct mach_timebase_info *info);
		uint64_t mach_absolute_time(void);
	]])
	local tb = ffi.new("struct mach_timebase_info")
	ffi.C.mach_timebase_info(tb)
	local timebase = tonumber(tb.numer) / tonumber(tb.denom)
	local orwl_timestart = ffi.C.mach_absolute_time()
	return function()
		local diff = ffi.C.mach_absolute_time() - orwl_timestart
		diff = tonumber(diff) * timebase / 1000000000
		return diff
	end
else
	ffi.cdef([[
		struct timespec {
			long int tv_sec;
			long tv_nsec;
		};
		int clock_gettime(int clock_id, struct timespec *tp);
	]])
	local ts = ffi.new("struct timespec")
	local enum = 1
	local func = ffi.C.clock_gettime
	return function()
		func(enum, ts)
		return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 0.000000001
	end
end
