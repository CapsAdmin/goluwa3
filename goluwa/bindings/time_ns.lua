local ffi = require("ffi")

if ffi.os == "Windows" then
	ffi.cdef([[
		int QueryPerformanceFrequency(uint64_t *lpFrequency);
		int QueryPerformanceCounter(uint64_t *lpPerformanceCount);
	]])
	local q = ffi.new("uint64_t[1]")
	ffi.C.QueryPerformanceFrequency(q)
	local freq = tonumber(q[0])
	local start_time = ffi.new("uint64_t[1]")
	ffi.C.QueryPerformanceCounter(start_time)
	return function()
		local time = ffi.new("uint64_t[1]")
		ffi.C.QueryPerformanceCounter(time)
		local elapsed = time[0] - start_time[0]
		return ffi.cast("uint64_t", elapsed * 1000000000ULL / freq)
	end
elseif ffi.os == "OSX" then
	pcall(ffi.cdef, [[
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
		return ffi.cast("uint64_t", tonumber(diff) * timebase)
	end
else
	local timespec_t = ffi.typeof([[struct {
        long int tv_sec;
        long tv_nsec;
    }]])
	ffi.cdef([[
		int clock_gettime(int clock_id, $ *tp);
	]], timespec_t)
	local ts = ffi.new("struct timespec")
	local CLOCK_MONOTONIC_RAW = 4
	local CLOCK_MONOTONIC = 1
	local clock_id = CLOCK_MONOTONIC_RAW
	local func = ffi.C.clock_gettime

	if func(clock_id, ts) ~= 0 then clock_id = CLOCK_MONOTONIC end

	return function()
		func(clock_id, ts)
		return ts.tv_sec * 1000000000ULL + ts.tv_nsec
	end
end
