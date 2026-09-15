local callstack = import("goluwa/debug/callstack.lua")
local protected_call = library()

function protected_call.call(cb, a_, b_, c_, d_, e_, f_)
	assert(f_ == nil)

	if protected_call.strict then return true, cb(a_, b_, c_, d_, e_) end

	return xpcall(cb, callstack.traceback, a_, b_, c_, d_, e_)
end

function protected_call.call_error_callback(cb, on_error, a_, b_, c_, d_, e_, f_)
	assert(f_ == nil)

	if protected_call.strict then return true, cb(a_, b_, c_, d_, e_) end

	return xpcall(cb, on_error, a_, b_, c_, d_, e_)
end

return protected_call
