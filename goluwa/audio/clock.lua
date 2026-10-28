local ffi = require("ffi")

if ffi.os == "Windows" then
	pcall(
		ffi.cdef,
		[[
		int QueryPerformanceFrequency(uint64_t *lpFrequency);
		int QueryPerformanceCounter(uint64_t *lpPerformanceCount);
	]]
	)
	local counter = ffi.new("uint64_t[1]")
	ffi.C.QueryPerformanceFrequency(counter)
	local frequency = tonumber(counter[0])
	return function()
		ffi.C.QueryPerformanceCounter(counter)
		return tonumber(counter[0]) / frequency
	end
elseif jit.os == "OSX" then
	pcall(
		ffi.cdef,
		[[
		struct mach_timebase_info {
			uint32_t	numer;
			uint32_t	denom;
		};
		int mach_timebase_info(struct mach_timebase_info *info);
		uint64_t mach_absolute_time(void);
	]]
	)
	local info = ffi.new("struct mach_timebase_info")
	ffi.C.mach_timebase_info(info)
	local scale = tonumber(info.numer) / tonumber(info.denom) / 1e9
	return function()
		return tonumber(ffi.C.mach_absolute_time()) * scale
	end
end

local get_time_ns = import("goluwa/bindings/time_ns.lua")
return function()
	return tonumber(get_time_ns()) * 1e-9
end
