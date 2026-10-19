-- how often the wind is set and how often it differs from the one before
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local calls, changed = 0, 0
local last
local old = atmosphere.SetWind
atmosphere.SetWind = function(v)
	calls = calls + 1
	if not last or last.x ~= v.x or last.y ~= v.y or last.z ~= v.z then changed = changed + 1 end
	last = v:Copy()
	return old(v)
end
function _G.MP_RESET() calls, changed = 0, 0 end
function _G.MP_REPORT(frames)
	local w = atmosphere.GetWind()
	print(string.format("MP   SetWind calls %d changed %d over %d frames, wind now %.3f %.3f %.3f", calls, changed, frames, w.x, w.y, w.z))
end
