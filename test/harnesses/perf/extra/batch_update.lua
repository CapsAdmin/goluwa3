-- time and count of BatchTable:Update, and how many were full rewrites (batch_serial changed) or grew the table
local BatchTable = import("goluwa/render3d/batch_table.lua")
local system = import("goluwa/system.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local stats = {}
local f = BatchTable.Update
BatchTable.Update = function(self, pipeline, batches, batch_serial, submission, context)
	local full = ""
	if self.batch_serial ~= batch_serial then full = full .. " serial" end
	if self.address_release_serial ~= Buffer.address_release_serial then full = full .. " release" end
	if self.capacity < #batches then full = full .. " capacity" end
	local t = system.GetTime()
	local a = f(self, pipeline, batches, batch_serial, submission, context)
	local dt = system.GetTime() - t
	local key = (self.label or "?") .. full
	local s = stats[key] or {0, 0, 0, 0}
	stats[key] = s
	s[1] = s[1] + 1
	s[2] = s[2] + dt
	s[3] = math.max(s[3], dt)
	s[4] = math.max(s[4], #batches)
	return a
end
function _G.MP_RESET() stats = {} end
function _G.MP_REPORT(frames)
	for k, s in pairs(stats) do
		print(string.format("MP   %-40s %6d calls  %8.3f ms total/frame  max %7.2f ms  batches max %d", k, s[1], s[2] / frames * 1000, s[3] * 1000, s[4]))
	end
end
