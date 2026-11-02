local event = import("goluwa/event.lua")
local audio = import("goluwa/audio.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local weather = import("goluwa/render3d/weather.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local sounds = import("lua/sounds.lua")
local ambience = {}
-- levels in dB against the reference loudness for a radiance of 1 over the whole sphere, calibrated once on open ground
ambience.RAIN_LEVEL = -12
ambience.RAIN_REFERENCE_RATE = 10
ambience.WIND_LEVEL = -20
ambience.WIND_REFERENCE_SPEED = 10
ambience.DRY_HUMIDITY = 0.6
ambience.RAIN_HUMIDITY = 0.9
ambience.PRESSURE = 101325
ambience.GLIDE = 0.3
ambience.SILENT = 10 ^ (-60 / 20)
ambience.KINDS = {
	rain = {path = "ambient/rain.wav", directional = 3, bed = 4},
	wind = {path = "ambient/nature/wind_leaves_mild_gust_1.wav", directional = 2, bed = 2},
}
ambience.voices = {}

local function stop_all()
	for _, list in pairs(ambience.voices) do
		for _, voice in ipairs(list) do
			if voice.sound:IsPlaying() then voice.sound:Stop() end

			voice.gain = 0
		end
	end
end

local function get_voices(kind)
	local list = ambience.voices[kind]

	if list then return list end

	local info = ambience.KINDS[kind]
	list = {}

	for i = 1, info.directional + info.bed do
		local sound = info.create and info.create() or sounds.CreateSource(info.path)

		if not sound then return end

		sound:SetLooping(true)
		sound:SetTraced(false)
		local angle = (i - info.directional - 1) / info.bed * math.pi * 2
		list[i] = {
			sound = sound,
			gain = 0,
			band = Vec3(1, 1, 1),
			direction = i <= info.directional and
				Vec3(0, 1, 0) or
				Vec3(math.cos(angle), 0, math.sin(angle)),
			bed = i > info.directional,
			start = (i - 1) / (info.directional + info.bed),
		}
	end

	ambience.voices[kind] = list
	return list
end

-- create() returns a fresh Sound per voice in place of the kind's file; nil goes back to the file
function ambience.SetSource(kind, create)
	for _, voice in ipairs(ambience.voices[kind] or {}) do
		voice.sound:Stop()
	end

	ambience.voices[kind] = nil
	ambience.KINDS[kind].create = create
end

local function play_voice(voice, energy, scale, direction, k)
	local mid = math.max(energy[2], 0)
	local target = math.sqrt(mid * scale)
	voice.gain = voice.gain + (target - voice.gain) * k

	if direction then
		voice.direction = (voice.direction + (direction - voice.direction) * k):GetNormalized()
	end

	local sound = voice.sound

	if voice.gain < ambience.SILENT then
		if sound:IsPlaying() then sound:Stop() end

		return
	end

	if mid > 0 then
		voice.band = Vec3(
			math.min(math.sqrt(energy[1] / mid), 4),
			1,
			math.min(math.sqrt(energy[3] / mid), 4)
		)
	end

	sound:SetGain(voice.gain)
	sound:SetBandGains(voice.band)
	sound:SetPosition(audio.GetListenerPosition() + voice.direction * sound:GetReferenceDistance())

	if not sound:IsPlaying() then sound:Play(voice.start, "fraction") end
end

local RANKING = {
	rain = function(a, b)
		return a.rain[2] > b.rain[2]
	end,
	wind = function(a, b)
		return a.wind[2] > b.wind[2]
	end,
}

local function update_kind(kind, field, scale, total, bins, k)
	local list = get_voices(kind)

	if not list then return end

	local info = ambience.KINDS[kind]
	local rest = {total[1], total[2], total[3]}
	local ranked = {}

	for _, bin in ipairs(bins) do
		if bin[field][2] > 0 then ranked[#ranked + 1] = bin end
	end

	table.sort(ranked, RANKING[field])

	for i = 1, info.directional do
		local bin = ranked[i]
		local energy = bin and bin[field] or {0, 0, 0}

		for b = 1, 3 do
			rest[b] = rest[b] - energy[b]
		end

		play_voice(list[i], energy, scale, bin and bin.direction, k)
	end

	for b = 1, 3 do
		rest[b] = math.max(rest[b], 0) / info.bed
	end

	for i = info.directional + 1, info.directional + info.bed do
		play_voice(list[i], rest, scale, nil, k)
	end
end

local open_ground = {rain = {}, wind = {0, 0, 0}, bins = {}}

for b = 1, 3 do
	open_ground.rain[b] = 0.5 * acoustics.DEFAULT_MATERIAL.rain[b]
end

event.AddListener("Update", "ambience", function()
	local rain = weather.GetRain()
	local wind = weather.GetWind()
	local wind_speed = wind:GetLength()
	local temperature = weather.GetTemperature()
	local humidity = (
			rain > 0 or
			weather.GetSnow() > 0
		)
		and
		ambience.RAIN_HUMIDITY or
		ambience.DRY_HUMIDITY
	audio.SetSnowDepth(weather.GetSnowDepth())
	audio.SetWind(wind:Copy())

	if temperature ~= ambience.temperature or humidity ~= ambience.humidity then
		ambience.temperature, ambience.humidity = temperature, humidity
		audio.SetAir(temperature, humidity, ambience.PRESSURE)
	end

	if rain <= 0 and wind_speed <= 0 then
		audio.StopAmbienceTracing()
		stop_all()
		return
	end

	audio.SetAmbienceTracing(surface_weather.precipitation_direction:Copy(), wind_speed > 0 and wind / -wind_speed or nil)
	local now = audio.clock()
	local dt = ambience.last_time and math.max(now - ambience.last_time, 0) or 0
	ambience.last_time = now
	local k = 1 - math.exp(-dt / ambience.GLIDE)
	local gathered = audio.acoustics and audio.acoustics:GetAmbience() or open_ground
	update_kind(
		"rain",
		"rain",
		10 ^ (ambience.RAIN_LEVEL / 10) * rain / ambience.RAIN_REFERENCE_RATE,
		gathered.rain,
		gathered.bins,
		k
	)
	update_kind(
		"wind",
		"wind",
		10 ^ (
				ambience.WIND_LEVEL / 10
			) * (
				wind_speed / ambience.WIND_REFERENCE_SPEED
			) ^ 6,
		gathered.wind,
		gathered.bins,
		k
	)
end)

return ambience
