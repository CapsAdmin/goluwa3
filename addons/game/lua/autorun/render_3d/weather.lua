local weather = import("goluwa/render3d/weather.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
weather.Initialize()
weather.SetWind(Vec3(1, 0, 0.35):GetNormalized() * 4)
