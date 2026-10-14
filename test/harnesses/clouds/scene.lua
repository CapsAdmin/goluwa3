local Vec3 = import("goluwa/structs/vec3.lua")
local weather = import("goluwa/render3d/weather.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Color = import("goluwa/structs/color.lua")
if not os.getenv("NOGROUND") then
	shapes.Box{
		Position = Vec3(0, -0.5, 0),
		Size = Vec3(16000, 1, 16000),
		Material = shapes.Material{Color = Color(0.25, 0.3, 0.2, 1), Roughness = 1},
		Collision = false,
		RigidBody = false,
	}
end
import("goluwa/render3d/climate.lua").SetPreset(os.getenv("CLOUDS") or "cumulus", 0)
local elev = math.rad(tonumber(os.getenv("SUN_ELEV") or 35))
local az = math.rad(tonumber(os.getenv("SUN_AZ") or 40))
weather.SetSunDirection(
	Vec3(-math.sin(az) * math.cos(elev), math.sin(elev), -math.cos(az) * math.cos(elev))
)
