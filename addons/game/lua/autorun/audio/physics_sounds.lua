local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local sounds = import("lua/sounds.lua")
local sound_profiles = import("lua/sound_profiles.lua")
local MIN_SPEED = 1
local SOFT_SPEED = 3
local MAX_SKIP = 0.5
local SOFT_SKIP = 0.5
local FADE_SPEED = 4
local MAX_FADE = 0.012
local LOUD_SPEED = 7
local INTERVAL = 0.05
local REFERENCE_MASS = 20
local MASS_DB = 6
local DAMP_DB = 18
local MIN_MASS_DB = -18
local MAX_MASS_DB = 4
local SCRAPE_MIN = 0.3
local SCRAPE_ROUGH = 2.5
local LOUD_SLIP = 4
local SCRAPE_GAIN = 10 ^ (-8 / 20)
local ROLL_MIN = 0.3
local LOUD_ROLL = 5
local ROLL_GAIN = 10 ^ (-8 / 20)
local GROUND_GAIN = 10 ^ (-12 / 20)
local GRAIN_GAIN = 10 ^ (-6 / 20)
local GRAIN_SPACING = 0.3
local MAX_LOOPS = 8
local REFERENCE_SIZE = 0.625
local MIN_PITCH = 0.25
local MAX_PITCH = 2
local ATTACK = 0.08
local RELEASE = 0.15
local STALE = 0.1
-- every new one-shot is probed for occlusion on Play, and a burst of hundreds of impacts in one frame would not be heard apart anyway
local MAX_IMPACTS_PER_FRAME = 6
local MAX_LOOP_STARTS_PER_FRAME = 2
local physics_sounds = {}

function physics_sounds.GetSurfaces()
	return sound_profiles.Get().GetSurfaces()
end

local function get_pitch(size)
	if not size then return 1 end

	return math.clamp(REFERENCE_SIZE / size, MIN_PITCH, MAX_PITCH)
end

local function get_mass_gain(mass)
	return 10 ^ (
			math.clamp(MASS_DB * math.log10(mass / REFERENCE_MASS), MIN_MASS_DB, MAX_MASS_DB) / 20
		)
end

local function get_damping_gain(found, other)
	return 10 ^ (-DAMP_DB * math.max(found.hardness - other.hardness, 0) / 20)
end

local last_played = table.weak("k")
local pending = {}
local pending_count = 0
local loop_starts = 0

local function queue_impact(path, position, volume, pitch, skip)
	local level = sounds.GetLevel(position, volume)

	if not sounds.IsAudible(position, volume) then return end

	local impact

	if pending_count < MAX_IMPACTS_PER_FRAME then
		pending_count = pending_count + 1
		impact = pending[pending_count]

		if not impact then
			impact = {position = Vec3()}
			pending[pending_count] = impact
		end
	else
		for i = 1, pending_count do
			if pending[i].level < level and (not impact or pending[i].level < impact.level) then
				impact = pending[i]
			end
		end

		if not impact then return end
	end

	impact.path = path
	impact.position:Set(position.x, position.y, position.z)
	impact.volume = volume
	impact.pitch = pitch
	impact.skip = skip
	impact.level = level
end

event.AddListener("Impact", "physics_impacts", function(info)
	if info.Kind ~= "physics" or info.Speed < MIN_SPEED then return end

	local now = system.GetElapsedTime()
	local row = last_played[info.Entity]

	if not row then
		row = table.weak("k")
		last_played[info.Entity] = row
	end

	if now - (row[info.Other] or -math.huge) < INTERVAL then return end

	row[info.Other] = now
	local found = sound_profiles.Get().GetImpact(info.Surface)
	local gain = found.gain * get_damping_gain(found, sound_profiles.Get().GetImpact(info.OtherSurface))
	local soft = info.Speed < SOFT_SPEED
	local paths = soft and found.soft or found.hard
	local index = math.random(#paths)

	if index == paths.last then index = index % #paths + 1 end

	paths.last = index
	queue_impact(
		paths[index],
		info.Position,
		gain * get_mass_gain(info.Mass) * math.min(info.Speed / LOUD_SPEED, 1),
		get_pitch(info.Size),
		MAX_SKIP * (
				1 - math.clamp((info.Speed - MIN_SPEED) / (LOUD_SPEED - MIN_SPEED), 0, 1)
			)
	)
end)

event.AddListener("LateUpdate", "physics_impacts", function()
	for i = 1, pending_count do
		local impact = pending[i]
		sounds.Play(impact.path, impact.position, impact.volume, impact.pitch, impact.skip)
		impact.path = nil
	end

	pending_count = 0
	loop_starts = 0
end)

local voices = table.weak("k")
local active = {}
local idle = {}

local function stop_voice(voice)
	voice.source:Stop()
	voice.owner[voice.path] = nil
	local pool = idle[voice.path]

	if not pool then
		pool = {}
		idle[voice.path] = pool
	end

	pool[#pool + 1] = voice.source

	for i = 1, #active do
		if active[i] == voice then
			table.remove(active, i)

			break
		end
	end
end

local function get_source(path)
	local pool = idle[path]

	if pool and pool[1] then return table.remove(pool) end

	local source = sounds.CreateSource(path)

	if source then source:SetLooping(true) end

	return source
end

local function get_priority(voice)
	return sounds.GetLevel(voice.position, voice.target)
end

local function drive(owner, path, volume, pitch, low, mid, high, position, now)
	local voice = owner[path]

	if not voice then
		if loop_starts >= MAX_LOOP_STARTS_PER_FRAME then return end

		local quietest

		if #active >= MAX_LOOPS then
			for _, other in ipairs(active) do
				if not quietest or get_priority(other) < get_priority(quietest) then
					quietest = other
				end
			end

			if sounds.GetLevel(position, volume) <= get_priority(quietest) then
				return
			end

			stop_voice(quietest)
		end

		local source = get_source(path)

		if not source then return end

		loop_starts = loop_starts + 1
		voice = {source = source, owner = owner, path = path, volume = 0, tone = Vec3(1, 1, 1)}
		owner[path] = voice
		active[#active + 1] = voice
		source:SetVolume(0)
		source:SetBandGains(voice.tone)
		source:SetPosition(position)
		source:Play()
	end

	voice.target = volume
	voice.pitch = pitch
	voice.tone:Set(low, mid, high)
	voice.position = position
	voice.updated = now
end

local function get_layers(entity, other)
	local row = voices[entity]

	if not row then
		row = table.weak("k")
		voices[entity] = row
	end

	local layers = row[other]

	if not layers then
		layers = {scrape = {}, ground = {}, object = {}, grain_distance = 0, grain_time = 0}
		row[other] = layers
	end

	return layers
end

event.AddListener("Contact", "physics_sounds", function(info)
	local found = sound_profiles.Get().GetImpact(info.Surface)
	local gain = found.gain * get_mass_gain(info.Mass)

	if not sounds.IsAudible(info.Position, gain) then return end

	local now = system.GetElapsedTime()
	local layers = get_layers(info.Entity, info.Other)
	local slip, roll = info.Slip, info.Roll
	local pitch = get_pitch(info.Size)

	if slip >= SCRAPE_MIN then
		local path = slip >= SCRAPE_ROUGH and found.rough or found.smooth
		local speed = math.min(slip / LOUD_SLIP, 1)

		if path then
			drive(
				layers.scrape,
				path,
				gain * SCRAPE_GAIN * speed * get_damping_gain(found, sound_profiles.Get().GetImpact(info.OtherSurface)),
				pitch * (0.9 + 0.2 * speed),
				1,
				1,
				1,
				info.Position,
				now
			)
		end
	end

	if roll < ROLL_MIN then return end

	local speed = math.min(roll / LOUD_ROLL, 1)

	if info.Rolling then
		if found.smooth then
			drive(
				layers.ground,
				found.smooth,
				gain * GROUND_GAIN * speed,
				pitch * (0.6 + 0.6 * speed),
				1,
				0.4 + 0.6 * speed,
				0.1 + 0.9 * speed,
				info.Position,
				now
			)
		end
	elseif found.roll then
		drive(
			layers.object,
			found.roll,
			gain * ROLL_GAIN * speed,
			pitch * (0.7 + 0.5 * speed),
			1,
			1,
			1,
			info.Position,
			now
		)
	else
		local dt = now - layers.grain_time
		layers.grain_time = now
		layers.grain_distance = layers.grain_distance + roll * (dt < STALE and dt or 0)

		if layers.grain_distance >= GRAIN_SPACING then
			layers.grain_distance = 0
			local paths = found.soft
			local index = math.random(#paths)

			if index == paths.last then index = index % #paths + 1 end

			paths.last = index
			sounds.Play(
				paths[index],
				info.Position,
				gain * GRAIN_GAIN * speed,
				get_pitch(info.Size),
				0,
				0,
				1
			)
		end
	end
end)

event.AddListener("Update", "physics_sounds", function(dt)
	local now = system.GetElapsedTime()

	for i = #active, 1, -1 do
		local voice = active[i]
		local target = now - voice.updated > STALE and 0 or voice.target
		voice.volume = voice.volume + (
				target - voice.volume
			) * math.min(dt / (target > voice.volume and ATTACK or RELEASE), 1)

		if target == 0 and voice.volume < 0.002 then
			stop_voice(voice)
		else
			voice.source:SetVolume(voice.volume)
			voice.source:SetPitch(voice.pitch)
			voice.source:SetPosition(voice.position)
		end
	end
end)

return physics_sounds
