local weather = import("goluwa/render3d/weather.lua")
import("goluwa/render3d/climate.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local date = import("goluwa/date.lua")
weather.Initialize()
weather.SetWind(Vec3(1, 0, 0.35):GetNormalized() * 0.5)

local function parse_time(str, utc_offset)
	local y, m, d, h, min = str:match("(%d+)-(%d+)-(%d+) (%d+):(%d+)")
	local days = os.time{year = y, month = m, day = d, hour = 12} / 86400 -- the date as a day count, the noon keeps it on the right day in any zone
	return days * 86400 + (h - utc_offset) * 3600 + min * 60
end

weather.SetLocation(21.1777703, 106.070245)
weather.SetTime(date.diff(date(os.date("!%Y-%m-%d") .. " 10:00 +07:00"), date.epoch()):spanseconds())
