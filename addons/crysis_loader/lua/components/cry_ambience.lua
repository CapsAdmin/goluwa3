local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local audio = AUDIO and import("goluwa/audio.lua")
local weather = RENDER_3D and import("goluwa/render3d/weather.lua")
local fmod_events = import("lua/crysis_loader/fmod_events.lua")
local META = objects.CreateTemplate("cry_ambience")
META:StartStorable()
META:GetSet("Sound", "", {callback = "Reset"})
META:IsSet("Random", false)
META:GetSet("OuterRadius", 10)
META:GetSet("DiscRadius", 10)
META:GetSet("MinWait", 2)
META:GetSet("MaxWait", 5)
META:IsSet("RandomPosition", true)
META:GetSet("Areas", {})
META:EndStorable()
META.LoopLevel = 80
META.OneShotLevel = 95
local EVALUATE_INTERVAL = 1
local ONE_SHOT_VOICES = 2
local parameters = {battle = 0, daylight = 1}
local best_priority = {}
local one_shot_voices = {}

function META:Initialize()
	self.distances = {}
	self.loops = {}
	self.next_evaluate = 0
end

function META:Reset()
	self:StopLoops()
	self.event = nil
	self.loops = {}
end

function META:OnRemove()
	self:StopLoops()
end

function META:GetEvent()
	if self.event == nil then self.event = fmod_events.Get(self.Sound) or false end

	return self.event or nil
end

function META:StopLoops()
	for _, loop in pairs(self.loops or {}) do
		if loop.playing then
			loop.sound:Stop()
			loop.playing = false
		end
	end
end

do
	local function distance_to_segment(px, pz, ax, az, bx, bz)
		local dx, dz = bx - ax, bz - az
		local t = math.clamp(((px - ax) * dx + (pz - az) * dz) / math.max(dx * dx + dz * dz, 0.000001), 0, 1)
		local ex, ez = px - ax - dx * t, pz - az - dz * t
		return math.sqrt(ex * ex + ez * ez)
	end

	function META.GetAreaDistance(area, x, y, z)
		if area.kind == "sphere" then
			local c = area.center
			local dx, dy, dz = x - c[1], y - c[2], z - c[3]
			return math.max(math.sqrt(dx * dx + dy * dy + dz * dz) - area.radius, 0)
		end

		if area.kind == "box" then
			local o = area.origin
			local dx, dy, dz = x - o[1], y - o[2], z - o[3]
			local sum = 0

			for i = 1, 3 do
				local e = area.edges[i]
				local length2 = math.max(e[1] * e[1] + e[2] * e[2] + e[3] * e[3], 0.000001)
				local t = (dx * e[1] + dy * e[2] + dz * e[3]) / length2
				local outside = t < 0 and -t or t > 1 and t - 1 or 0
				sum = sum + outside * outside * length2
			end

			return math.sqrt(sum)
		end

		local points = area.points
		local count = #points
		local inside = false
		local horizontal = math.huge
		local j = count

		for i = 1, count do
			local a, b = points[i], points[j]

			if (a[2] > z) ~= (b[2] > z) and x < (b[1] - a[1]) * (z - a[2]) / (b[2] - a[2]) + a[1] then
				inside = not inside
			end

			horizontal = math.min(horizontal, distance_to_segment(x, z, a[1], a[2], b[1], b[2]))
			j = i
		end

		if inside then horizontal = 0 end

		local vertical = y < area.bottom and
			area.bottom - y or
			area.top and
			y > area.top and
			y - area.top or
			0
		return math.sqrt(horizontal * horizontal + vertical * vertical)
	end
end

local function pick_entry(entries)
	local total = 0

	for _, entry in ipairs(entries) do
		total = total + entry.Gain
	end

	local pick = math.random() * total

	for _, entry in ipairs(entries) do
		pick = pick - entry.Gain

		if pick <= 0 then return entry end
	end

	return entries[#entries]
end

function META:UpdateLoops(fade)
	local event = self:GetEvent()

	if not event then return end

	if fade <= 0 then
		self:StopLoops()
		self.next_evaluate = 0
		return
	end

	local now = system.GetElapsedTime()

	if now >= self.next_evaluate then
		self.next_evaluate = now + EVALUATE_INTERVAL

		for _, loop in pairs(self.loops) do
			loop.gain = 0
		end

		for _, entry in ipairs(fmod_events.Evaluate(event, parameters)) do
			local loop = self.loops[entry.Key]

			if not loop then
				local sound = audio.CreateSource(entry.Paths[math.random(#entry.Paths)])
				sound:SetSpatial(false)
				sound:SetLooping(true)
				sound:SetNormalized(true)
				sound:SetPitch(2 ^ event.Pitch)
				loop = {sound = sound, playing = false}
				self.loops[entry.Key] = loop
			end

			loop.gain = entry.Gain
		end
	end

	local level = audio.SPLToVolume(META.LoopLevel) * event.Volume * fade

	for _, loop in pairs(self.loops) do
		if loop.gain > 0 then
			loop.sound:SetGain(level * loop.gain)

			if not loop.playing then
				loop.sound:Play()
				loop.playing = true
			end
		elseif loop.playing then
			loop.sound:Stop()
			loop.playing = false
		end
	end
end

function META:PlayOneShot(listener)
	local event = self:GetEvent()

	if not event then return end

	local entries = fmod_events.Evaluate(event, parameters)

	if not entries[1] then return end

	local entry = pick_entry(entries)
	local path = entry.Paths[math.random(#entry.Paths)]
	local pool = one_shot_voices[path]

	if not pool then
		pool = {next = 1}

		for i = 1, ONE_SHOT_VOICES do
			local sound = audio.CreateSource(path)
			sound:SetNormalized(true)
			sound:SetReferenceDistance(1)
			pool[i] = sound
		end

		one_shot_voices[path] = pool
	end

	local sound = pool[pool.next]
	pool.next = pool.next % ONE_SHOT_VOICES + 1
	local position

	if self.RandomPosition then
		local angle = math.randomf(0, math.pi * 2)
		position = Vec3(
			listener.x + math.cos(angle) * self.DiscRadius,
			listener.y,
			listener.z + math.sin(angle) * self.DiscRadius
		)
	else
		position = self.Owner.transform:GetPosition():Copy()
	end

	sound:SetPosition(position)
	sound:SetGain(audio.SPLToVolume(META.OneShotLevel) * event.Volume * entry.Gain)
	sound:SetPitch(fmod_events.GetPitch(event))
	sound:Play()
end

function META:UpdateRandom(inside, listener)
	if not inside then
		self.next_play = nil
		return
	end

	local now = system.GetElapsedTime()

	if not self.next_play then
		self.next_play = now + self.MinWait
	elseif now >= self.next_play then
		self.next_play = now + math.randomf(self.MinWait, math.max(self.MinWait, self.MaxWait))
		self:PlayOneShot(listener)
	end
end

local function update_all()
	local listener = audio.GetListenerPosition()
	local x, y, z = listener.x, listener.y, listener.z
	table.clear(best_priority)

	for _, self in ipairs(META.Instances) do
		for i, area in ipairs(self.Areas) do
			local distance = META.GetAreaDistance(area, x, y, z)
			self.distances[i] = distance

			if distance == 0 and area.group ~= 0 then
				best_priority[area.group] = math.max(best_priority[area.group] or -math.huge, area.priority)
			end
		end
	end

	if weather then
		parameters.daylight = math.clamp((weather.GetSunDirection().y + 0.05) / 0.15, 0, 1)
	end

	for _, self in ipairs(META.Instances) do
		local fade, inside = 0, false

		for i, area in ipairs(self.Areas) do
			local best = area.group ~= 0 and best_priority[area.group]

			if not best or area.priority >= best then
				local distance = self.distances[i]

				if distance == 0 then
					inside = true
					fade = 1
				elseif self.OuterRadius > 0 then
					fade = math.max(fade, 1 - distance / self.OuterRadius)
				end
			end
		end

		if self.Random then
			self:UpdateRandom(inside, listener)
		else
			self:UpdateLoops(fade)
		end
	end
end

if AUDIO then event.AddListener("Update", "cry_ambience", update_all) end

return META:Register()
