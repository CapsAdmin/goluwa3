local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local screen_shake = {}
local shakes = {}
local offset = Vec3()

function screen_shake.Add(amplitude, frequency, length)
	shakes[#shakes + 1] = {
		amplitude = amplitude,
		frequency = frequency,
		length = length,
		ends = system.GetElapsedTime() + length,
		seed = math.random() * 100,
	}
end

function screen_shake.Get()
	if not shakes[1] then return end

	local now = system.GetElapsedTime()
	local x, y, roll = 0, 0, 0

	for i = #shakes, 1, -1 do
		local shake = shakes[i]
		local left = shake.ends - now

		if left <= 0 then
			table.remove(shakes, i)
		else
			local f = left / shake.length
			f = f * f * (3 - 2 * f)
			local t = now * shake.frequency * 30 + shake.seed
			local amplitude = shake.amplitude * f
			x = x + (math.sin(t * 1.7) + math.sin(t * 3.1) * 0.5) * amplitude
			y = y + (math.cos(t * 2.3) + math.sin(t * 4.3) * 0.5) * amplitude
			roll = roll + math.sin(t * 1.3) * amplitude * 0.15
		end
	end

	return offset:Set(x, y, 0), roll
end

return screen_shake
