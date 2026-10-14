-- renders one fixed, frozen cloud view at an exact frame count and prints the average GPU time of the cloud passes
-- OUT=path.png, CLOUDS=preset, POS=x,y,z, PITCH, YAW, FOV (degrees), EV, WARM (frames before the capture), FRAMES (frames timed)
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local weather = import("goluwa/render3d/weather.lua")
local clouds = import("goluwa/render3d/clouds.lua")
import("test/harnesses/clouds/scene.lua")
local pvars = import("goluwa/cli/pvars.lua")
pvars.SetSession("r_dither", false)
if os.getenv("AA") then pvars.SetSession("r_aa", os.getenv("AA")) end

for pair in (os.getenv("PVARS") or ""):gmatch("[^;]+") do
	local key, value = pair:match("([^=]+)=(.*)")
	pvars.SetSession(key, tonumber(value) or value)
end
pvars.SetSession("r_local_exposure_shadows", 0)
pvars.SetSession("r_local_exposure_highlights", 0)
weather.SetWind(Vec3(0, 0, 0))

for _, layer in ipairs(clouds.layers) do
	layer.evolution = 0
end

local pos = {}

for n in (os.getenv("POS") or "0,600,0"):gmatch("[^,]+") do
	pos[#pos + 1] = tonumber(n)
end

View.New{
	Priority = 100,
	Position = Vec3(pos[1], pos[2], pos[3]),
	Rotation = QuatDeg3(tonumber(os.getenv("PITCH") or 8), tonumber(os.getenv("YAW") or 200), 0),
	FOV = math.rad(tonumber(os.getenv("FOV") or 80)),
	ExposureLock = tonumber(os.getenv("EV") or 14),
}:Activate()

local warm = tonumber(os.getenv("WARM") or "120")
local frames = tonumber(os.getenv("FRAMES") or "200")
local out = os.getenv("OUT") or "test/harnesses/clouds/cmp/bench.png"
local frame = 0
local sum, last, n = {}, {}, 0
local saved = false
local asked = false
event.AddListener("Update", "clouds_bench", function()
	frame = frame + 1

	if not asked and frame >= warm and system.GetFrameNumber() % 64 == 0 then
		asked = true
		print("CAPTURE at render frame " .. system.GetFrameNumber() .. ", cloud frame " .. tostring(clouds.frame))
		Screenshot(function(texture)
			print("SAVED " .. texture:SaveWithoutAlpha(out))
			saved = true
		end)
	end

	if frame <= warm + 10 or not saved then return end

	local names = gpu_timing.GetScopeNames()

	for i = 1, #names do
		local ms = gpu_timing.GetRawMilliseconds(names[i])

		if last[names[i]] ~= ms then
			last[names[i]] = ms
			sum[names[i]] = (sum[names[i]] or 0) + ms
		end
	end

	n = n + 1

	if n >= frames then
		local parts = {}

		for name, v in pairs(sum) do
			if name:find("cloud") or name == "gpu_frame" then
				parts[#parts + 1] = string.format("%s=%.3f", name, v / n)
			end
		end

		table.sort(parts)
		print("GPU " .. table.concat(parts, "  "))
		system.ShutDown(0)
	end
end)
