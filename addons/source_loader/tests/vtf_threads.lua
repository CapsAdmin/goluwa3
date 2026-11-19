local T = import("test/environment.lua")
local ffi = require("ffi")
local vtf = import("lua/codecs/vtf.lua")
local thread_pool = import("goluwa/thread_pool.lua")

T.Test("worker errors from malformed vtf data are reported", function()
	local job = thread_pool.Run(vtf.thread_job, string.rep("x", 200), 1e9)
	local ok, err = pcall(job.Await, job)
	T(ok)["=="](false)
	T(tostring(err):find("signature", 1, true) ~= nil)["=="](true)
end)

T.Test("vtf only asks for a worker when the image needs converting", function()
	local function build_vtf(format)
		local header = ffi.new("uint8_t[?]", 80 + 16)
		ffi.copy(header, "VTF\0", 4)
		ffi.cast("uint32_t *", header)[1] = 7
		ffi.cast("uint32_t *", header)[2] = 2
		ffi.cast("uint32_t *", header)[3] = 80
		ffi.cast("uint16_t *", header + 16)[0] = 4
		ffi.cast("uint16_t *", header + 16)[1] = 4
		ffi.cast("uint16_t *", header + 24)[0] = 1
		ffi.cast("uint32_t *", header + 52)[0] = format
		header[56] = 1
		ffi.cast("uint32_t *", header + 57)[0] = 0
		return ffi.string(header, 96)
	end

	local dxt1 = build_vtf(13)
	local bgr888 = build_vtf(3)
	T(vtf.ThreadCost(dxt1))["=="](0)
	T(vtf.ThreadCost(bgr888))[">"](0)
end)
