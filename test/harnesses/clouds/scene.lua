local Vec3 = import("goluwa/structs/vec3.lua")
local weather = import("goluwa/render3d/weather.lua")
import("test/harnesses/haze/scene.lua")
weather.SetClouds(os.getenv("CLOUDS") or "cumulus")
local elev = math.rad(tonumber(os.getenv("SUN_ELEV") or 35))
local az = math.rad(tonumber(os.getenv("SUN_AZ") or 40))
weather.SetSunDirection(
	Vec3(-math.sin(az) * math.cos(elev), math.sin(elev), -math.cos(az) * math.cos(elev))
)
