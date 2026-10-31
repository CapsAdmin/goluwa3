local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local screen_shake = {}
local shakes = {}
local offset = Vec3()

function screen_shake.Add(amplitude, frequency, length, axis_x, axis_y)
	shakes[#shakes + 1] = {
		amplitude = amplitude,
		frequency = frequency,
		length = length,
		axis_x = axis_x,
		axis_y = axis_y,
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
			local sway = (math.sin(t * 1.7) + math.sin(t * 3.1) * 0.5) * amplitude

			if shake.axis_x then
				x = x + shake.axis_x * sway
				y = y + shake.axis_y * sway
			else
				x = x + sway
				y = y + (math.cos(t * 2.3) + math.sin(t * 4.3) * 0.5) * amplitude
				roll = roll + math.sin(t * 1.3) * amplitude * 0.15
			end
		end
	end

	return offset:Set(x, y, 0), roll
end

return screen_shake
