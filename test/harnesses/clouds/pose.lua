local system = import("goluwa/system.lua")
local Shot = import("goluwa/render3d/shot.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local weather = import("goluwa/render3d/weather.lua")
local pvars = import("goluwa/cli/pvars.lua")
import("test/harnesses/clouds/scene.lua")

if os.getenv("TONEMAP") then pvars.SetSession("r_tonemapper", os.getenv("TONEMAP")) end

for pair in (os.getenv("PVARS") or ""):gmatch("[^;]+") do
	local key, value = pair:match("([^=]+)=(.*)")
	pvars.SetSession(key, tonumber(value) or value)
end

local function nums(name)
	local out = {}

	for n in os.getenv(name):gmatch("[^,]+") do
		out[#out + 1] = tonumber(n)
	end

	return out
end

local pos, ang, sun = nums("POS"), nums("ANG"), nums("SUN")
weather.SetSunRotation(Quat(sun[1], sun[2], sun[3], sun[4]))
local out = os.getenv("OUT") or "test/harnesses/clouds/cmp/pose.png"
Shot.Capture(
	{
		Position = Vec3(pos[1], pos[2], pos[3]),
		Rotation = Quat():SetAngles(Ang3(ang[1], ang[2], ang[3])),
		FOV = tonumber(os.getenv("FOV")),
		ExposureLock = tonumber(os.getenv("EV") or ""),
	},
	function(texture)
		print(texture:SaveWithoutAlpha(out))
		system.ShutDown(0)
	end,
	{settle = 3}
)
