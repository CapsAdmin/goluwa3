local easing = import("goluwa/math/easing.lua")
local track = {}
local META = {}
META.__index = META

local function hold()
	return 0
end

function track.New(spec)
	if type(spec) == "function" then
		return setmetatable({fn = spec, count = 0, cursor = 1}, META)
	end

	local self = setmetatable({times = {}, values = {}, eases = {}, count = #spec, cursor = 1}, META)

	for i, key in ipairs(spec) do
		local time, value, ease = key[1], key[2], key[3]

		if i > 1 and time <= self.times[i - 1] then
			error("track key times must increase, key " .. i .. " is at " .. time, 2)
		end

		if ease == "hold" then
			ease = hold
		elseif type(ease) == "string" then
			ease = easing[ease] or error("unknown easing " .. ease, 2)
		end

		self.times[i] = time
		self.values[i] = value
		self.eases[i] = ease or false
	end

	return self
end

function META:Get(t)
	if self.fn then return self.fn(t) end

	local times, values = self.times, self.values

	if t <= times[1] then return values[1] end

	local n = self.count

	if t >= times[n] then return values[n] end

	local i = self.cursor

	if t < times[i] then i = 1 end

	while times[i + 1] <= t do
		i = i + 1
	end

	self.cursor = i
	local f = (t - times[i]) / (times[i + 1] - times[i])
	local ease = self.eases[i]

	if ease then f = ease(f) end

	return values[i] + (values[i + 1] - values[i]) * f
end

return track
