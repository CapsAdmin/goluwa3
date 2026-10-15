local system = import("goluwa/system.lua")
local Shot = import("goluwa/render3d/shot.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local water = import("goluwa/render3d/water.lua")
local pvars = import("goluwa/cli/pvars.lua")
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(0)
local wind = tonumber(os.getenv("WIND") or 12)
water.SetOcean{WindSpeed = wind, Development = 1, WindDirection = tonumber(os.getenv("WIND_DIR") or 30)}
for pair in (os.getenv("OCEAN") or ""):gmatch("[^;]+") do
	local key, value = pair:match("([^=]+)=(.*)")
	water.SetOcean{[key] = tonumber(value)}
end

if os.getenv("PRESET") then
	local preset = water.presets[os.getenv("PRESET")]
	water.SetOcean{Absorption = preset.Absorption:Copy(), ParticleScattering = preset.ParticleScattering:Copy()}
end

local elev = math.rad(tonumber(os.getenv("SUN_ELEV") or 35))
local az = math.rad(tonumber(os.getenv("SUN_AZ") or 200))
weather.SetSunDirection(Vec3(-math.sin(az) * math.cos(elev), math.sin(elev), -math.cos(az) * math.cos(elev)))

for pair in (os.getenv("PVARS") or ""):gmatch("[^;]+") do
	local key, value = pair:match("([^=]+)=(.*)")
	if value == "true" then value = true elseif value == "false" then value = false else value = tonumber(value) or value end
	pvars.SetSession(key, value)
end

local function nums(name, default)
	local out = {}

	for n in (os.getenv(name) or default):gmatch("[^,]+") do
		out[#out + 1] = tonumber(n)
	end

	return out
end

if os.getenv("AT_SURFACE") then
	-- the waves frozen, the camera at the surface (plus the offset) of a point near the origin
	water.GetWaveTime = function()
		return 100
	end
	local sample = {}
	local best
	for x = -40, 40, 2 do
		water.SampleOcean(x, 0, 100, 0, sample)
		if not best or math.abs(sample.height) < math.abs(best.height) then best = {x = x, height = sample.height} end
	end
	os.setenv = nil
	_G.AT_SURFACE_POS = string.format("%f,%f,0", best.x, best.height + tonumber(os.getenv("AT_SURFACE")))
end

local pos, ang = nums("POS", _G.AT_SURFACE_POS or "0,6,0"), nums("ANG", "0.25,0,0")
Shot.Capture(
	{
		Position = Vec3(pos[1], pos[2], pos[3]),
		Rotation = Quat():SetAngles(Ang3(ang[1], ang[2], ang[3])),
		FOV = tonumber(os.getenv("FOV") or 1.1),
		ExposureLock = tonumber(os.getenv("EV") or ""),
	},
	function(texture)
		print(texture:SaveWithoutAlpha(os.getenv("OUT") or "test/harnesses/ocean/cmp/shot.png"))
		system.ShutDown(0)
	end,
	{settle = tonumber(os.getenv("SETTLE") or 8)}
)
