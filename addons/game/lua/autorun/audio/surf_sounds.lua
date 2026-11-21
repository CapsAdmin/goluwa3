if not CLIENT or not AUDIO then return end

local ffi = require("ffi")
local event = import("goluwa/event.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local system = import("goluwa/system.lua")
local sounds = import("lua/sounds.lua")
local SAMPLE_RATE = 32000
local MAX_PER_SECOND = 4
local QUIETEST = 10 ^ (-30 / 20)
local KINDS = {
	crash = {
		variants = 12,
		seconds = 2.8,
		thump = 0.9,
		roar_attack = 0.015,
		roar_decay = 0.7,
		hiss = 0.1,
		bubbles = 420,
		bubble_decay = 0.8,
	},
	spill = {
		variants = 12,
		seconds = 3.2,
		thump = 0.15,
		roar_attack = 0.25,
		roar_decay = 1.4,
		hiss = 0.16,
		bubbles = 260,
		bubble_decay = 1.4,
	},
	swash = {
		variants = 12,
		seconds = 2.6,
		thump = 0,
		roar_attack = 0,
		roar_decay = 0,
		hiss = 0.6,
		bubbles = 900,
		bubble_decay = 0,
	},
}
local float_array = ffi.typeof("float[?]")

local function one_pole(cutoff)
	return 1 - math.exp(-2 * math.pi * cutoff / SAMPLE_RATE)
end

local function synthesize(kind, seed)
	math.randomseed(seed)
	local frames = math.floor(kind.seconds * SAMPLE_RATE)
	local data = float_array(frames)
	local roar_low, roar_smooth, roar_high, hiss_low, hiss_high, hiss_smooth = 0, 0, 0, 0, 0, 0
	local roar_low_a, roar_high_a, hiss_low_a, hiss_high_a = one_pole(1600), one_pole(110), one_pole(1800), one_pole(4500)
	local swash = kind.roar_decay == 0
	local thump_frequency = 55 + math.random() * 30
	local wobble = 0

	for i = 0, frames - 1 do
		local t = i / SAMPLE_RATE
		local noise = math.random() * 2 - 1
		roar_low = roar_low + roar_low_a * (noise - roar_low)
		roar_smooth = roar_smooth + roar_low_a * (roar_low - roar_smooth)
		roar_high = roar_high + roar_high_a * (roar_smooth - roar_high)
		hiss_low = hiss_low + hiss_low_a * (noise - hiss_low)
		hiss_high = hiss_high + hiss_high_a * (noise - hiss_high)
		hiss_smooth = hiss_smooth + hiss_high_a * (hiss_high - hiss_smooth)
		wobble = wobble + one_pole(3) * ((math.random() * 2 - 1) - wobble)
		local roar = (roar_smooth - roar_high) * 6
		local hiss = (hiss_smooth - hiss_low) * 2
		local value

		if swash then
			local shape = math.sin(math.pi * math.min(t / kind.seconds, 1)) ^ 1.5
			value = hiss * kind.hiss * shape * (0.7 + 0.6 * wobble)
		else
			local roar_envelope = (1 - math.exp(-t / kind.roar_attack)) * math.exp(-t / kind.roar_decay)
			local thump = math.sin(2 * math.pi * thump_frequency * t * (1 - 0.25 * t)) * math.exp(-t / 0.12) * kind.thump
			value = thump + roar * roar_envelope * (
					0.8 + 0.4 * wobble
				) + hiss * kind.hiss * math.exp(-t / (kind.roar_decay * 1.6)) * (
					1 - math.exp(-t / 0.05)
				)
		end

		data[i] = value
	end

	local bubble_time = 0

	while true do
		local density = swash and
			kind.bubbles * math.sin(math.pi * math.min(bubble_time / kind.seconds, 1)) ^ 2 or
			kind.bubbles * math.exp(-bubble_time / kind.bubble_decay)
		bubble_time = bubble_time - math.log(1 - math.random()) / math.max(density, 1)

		if bubble_time >= kind.seconds then break end

		local frequency = 500 + math.random() ^ 2 * 2600
		local amplitude = (0.05 + math.random() * 0.15) * (swash and 0.5 or 1)
		local start = math.floor(bubble_time * SAMPLE_RATE)
		local length = math.floor(0.012 * SAMPLE_RATE)
		local chirp = 1 + math.random() * 0.4

		for j = 0, math.min(length, frames - 1 - start) do
			local t = j / SAMPLE_RATE
			data[start + j] = data[start + j] + amplitude * math.sin(2 * math.pi * frequency * t * (1 + chirp * t * 20)) * math.exp(-t / 0.003)
		end
	end

	local peak = 0

	for i = 0, frames - 1 do
		peak = math.max(peak, math.abs(data[i]))
	end

	local fade = math.floor(0.2 * SAMPLE_RATE)

	for i = 0, frames - 1 do
		local tail = math.min((frames - 1 - i) / fade, 1)
		data[i] = data[i] / peak * 0.9 * tail
	end

	return data, frames
end

local ready = {}
local last_played = {}
local pending = {}

for name, kind in pairs(KINDS) do
	ready[name] = {}

	for variant = 1, kind.variants do
		pending[#pending + 1] = {name = name, variant = variant, kind = kind}
	end
end

event.AddListener("Update", "surf_sounds_synthesize", function()
	local job = list.remove(pending)

	if not job then return event.destroy_tag end

	local key = "surf_" .. job.name .. "_" .. job.variant
	local data, frames = synthesize(job.kind, #job.name * 1000 + job.variant)
	sounds.Register(key, data, frames, SAMPLE_RATE)
	list.insert(ready[job.name], key)
	last_played[key] = -math.huge
end)

local function least_recent(name)
	local best

	for _, key in ipairs(ready[name]) do
		if not best or last_played[key] < last_played[best] then best = key end
	end

	return best
end

local position = Vec3()
local budget = MAX_PER_SECOND
local budget_time = 0

event.AddListener("SurfBreak", "surf_sounds", function(info)
	local now = system.GetElapsedTime()
	budget = math.min(budget + (now - budget_time) * MAX_PER_SECOND, MAX_PER_SECOND)
	budget_time = now

	if budget < 1 or info.Height < 0.05 then return end

	local name, spl

	if info.Kind == "swash" then
		name = "swash"
		spl = 72 + 20 * math.log10(info.Height / 0.3)
	elseif info.Plunge > 0.3 then
		name = "crash"
		spl = 92 + 20 * math.log10(info.Height) + 6 * info.Plunge
	else
		name = "spill"
		spl = 86 + 20 * math.log10(info.Height)
	end

	position:Set(info.X, info.Y + info.Height * 0.5, info.Z)
	local volume = sounds.SPLToVolume(spl)

	if sounds.GetLevel(position, volume) < QUIETEST then return end

	local key = least_recent(name)

	if not key then return end

	budget = budget - 1
	last_played[key] = now
	sounds.Play(key, position, volume, math.clamp(1.15 - info.Height * 0.15, 0.8, 1.15))
end)
