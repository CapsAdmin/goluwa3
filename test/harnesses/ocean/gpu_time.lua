-- GPU time of the ocean passes. VARIANTS="pvar=val,pvar=val;pvar=val" runs each after a baseline in one
-- process (the gpu clock wanders between runs), POS ANG WIND OCEAN FOV as in shot.lua
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local water = import("goluwa/render3d/water.lua")
local pvars = import("goluwa/cli/pvars.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
render3d.SetOceanEnabled(true)
render3d.SetOceanLevel(0)
water.SetOcean{WindSpeed = tonumber(os.getenv("WIND") or 12), WindDirection = 30}

for pair in (os.getenv("OCEAN") or ""):gmatch("[^;]+") do
	local key, value = pair:match("([^=]+)=(.*)")
	water.SetOcean{[key] = tonumber(value)}
end

weather.SetTimeScale(0)
local elev, az = math.rad(35), math.rad(200)
weather.SetSunDirection(Vec3(-math.sin(az) * math.cos(elev), math.sin(elev), -math.cos(az) * math.cos(elev)))

local function nums(name, default)
	local out = {}

	for n in (os.getenv(name) or default):gmatch("[^,]+") do
		out[#out + 1] = tonumber(n)
	end

	return out
end

local pos, ang = nums("POS", "0,6,0"), nums("ANG", "-0.12,0,0")
View.New{Position = Vec3(pos[1], pos[2], pos[3]), Rotation = QuatDeg3(math.deg(ang[1]), math.deg(ang[2]), 0), FOV = tonumber(os.getenv("FOV") or 1.1), Priority = 100}:Activate()
local variants = {""}

for variant in (os.getenv("VARIANTS") or ""):gmatch("[^;]+") do
	variants[#variants + 1] = variant
	variants[#variants + 1] = ""
end

local frames, warm = tonumber(os.getenv("FRAMES") or "150"), 40
local per = frames + warm
local frame, current = 0, 0
local sum, last, n = {}, {}, 0
local results = {}

local function apply(variant)
	for pair in variant:gmatch("[^,]+") do
		local key, value = pair:match("([^=]+)=(.*)")
		if value == "true" then value = true elseif value == "false" then value = false else value = tonumber(value) or value end
		pvars.SetSession(key, value)
	end
end

event.AddListener("Update", "ocean_gpu_time", function()
	local vi = math.floor(frame / per) + 1

	if vi > #variants then
		for i = 1, #variants do
			print(string.format("%-60s %s", variants[i] == "" and "baseline" or variants[i], results[i]))
		end

		system.ShutDown(0)
		return
	end

	if vi ~= current then
		current = vi
		-- every variant starts from the defaults
		for _, previous in ipairs(variants) do
			for pair in previous:gmatch("[^,]+") do
				local key = pair:match("([^=]+)=")
				local object = pvars.GetObject(key)
				local default = object and object:GetDefault()
				if default ~= nil then pvars.SetSession(key, default) end
			end
		end

		apply(variants[vi])
		sum, last, n = {}, {}, 0
	end

	local k = frame % per
	frame = frame + 1

	if k < warm then return end

	local names = gpu_timing.GetScopeNames()

	for i = 1, #names do
		local ms = gpu_timing.GetRawMilliseconds(names[i])

		if last[names[i]] ~= ms then
			last[names[i]] = ms
			sum[names[i]] = (sum[names[i]] or 0) + ms
		end
	end

	n = n + 1

	if k == per - 1 then
		local total, fft, waves, foam = 0, 0, 0, 0

		for name, v in pairs(sum) do
			v = v / n

			if name == "ocean" then total = v
			elseif name:find("ocean_fft") then fft = fft + v
			elseif name:find("_foam") then foam = foam + v
			elseif name:find("ocean_waves") then waves = waves + v end
		end

		results[vi] = string.format("ocean %.3f  fft %.3f  waves %.3f  foam %.3f  sum %.3f", total, fft, waves, foam, total + fft + waves + foam)
	end
end)
