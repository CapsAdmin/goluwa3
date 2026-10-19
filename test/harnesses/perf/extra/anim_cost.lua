-- counts and times the wind animation record writes of the gbuffer and shadow batch tables
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local system = import("goluwa/system.lua")
local stats = {}
local function wrap(tbl, name, label)
	local f = tbl[name]
	tbl[name] = function(...)
		local t = system.GetTime()
		local a, b = f(...)
		local s = stats[label] or {0, 0}
		stats[label] = s
		s[1] = s[1] + 1
		s[2] = s[2] + system.GetTime() - t
		return a, b
	end
end
wrap(model_pipeline, "WritePBRBatchAnimationRecord", "gbuffer anim record")
wrap(model_pipeline, "FillVertexAnimationData", "FillVertexAnimationData")
function _G.MP_RESET() stats = {} end
function _G.MP_REPORT(frames)
	for k, s in pairs(stats) do
		print(string.format("MP   %-28s %7.1f calls/frame  %6.2f us/call  %6.3f ms/frame", k, s[1] / frames, s[2] / s[1] * 1e6, s[2] / frames * 1000))
	end
end
