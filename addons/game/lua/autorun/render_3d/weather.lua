local weather = import("goluwa/render3d/weather.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
weather.Initialize()
weather.SetTime(os.time() + (60 * 60 * 6))
weather.SetLocation(21.1777703, 106.070245)
weather.SetWind(Vec3(1, 0, 0.35):GetNormalized() * 14)
weather.SetMoonScale(4) -- rain
--weather.SetRain(0)
--weather.SetCloudCover(0)
