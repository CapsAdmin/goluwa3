local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local pose_variation = import("lua/pose_variation.lua")

T.Test("pose noise is smooth, bounded and different for every seed and channel", function()
	local previous = pose_variation.Noise(0.3, 1, 0)

	for step = 1, 2000 do
		local value = pose_variation.Noise(0.3, 1, step * 0.01)
		T(math.abs(value))["<="](1)
		T(math.abs(value - previous))["<"](0.05)
		previous = value
	end

	T(pose_variation.Noise(0.3, 1, 5))["=="](pose_variation.Noise(0.3, 1, 5))
	T(pose_variation.Noise(0.3, 1, 5) ~= pose_variation.Noise(0.7, 1, 5))["=="](true)
	T(pose_variation.Noise(0.3, 1, 5) ~= pose_variation.Noise(0.3, 2, 5))["=="](true)
end)

T.Test("every seed gets an animation rate within the spread", function()
	local low, high = math.huge, -math.huge

	for i = 0, 100 do
		local rate = pose_variation.GetRateScale(i / 100)
		low = math.min(low, rate)
		high = math.max(high, rate)
	end

	T(low)[">="](1 - pose_variation.RateSpread - 1e-6)
	T(high)["<="](1 + pose_variation.RateSpread + 1e-6)
	T(high - low)[">"](pose_variation.RateSpread)
end)

T.Test("a positive lean tilts the up vector to the right and forward", function()
	local right = pose_variation.GetLean(Quat(), 0.2, 0):VecMul(Vec3(0, 1, 0))
	T(right.x)["~"](math.sin(0.2), 1e-5)
	local forward = pose_variation.GetLean(Quat(), 0, 0.2):VecMul(Vec3(0, 1, 0))
	T(forward.z)["~"](-math.sin(0.2), 1e-5)
end)

T.Test("a seed hashed from a network key is the same everywhere and different per key", function()
	T(pose_variation.HashSeed("76561198000000001"))["=="](pose_variation.HashSeed("76561198000000001"))
	T(pose_variation.HashSeed("76561198000000001") ~= pose_variation.HashSeed("76561198000000002"))["=="](true)
	T(pose_variation.HashSeed(12))["=="](pose_variation.HashSeed(12))
	T(pose_variation.HashSeed(12) ~= pose_variation.HashSeed(13))["=="](true)

	for _, key in ipairs{"a", "player", 1, 2, 3, 400} do
		local seed = pose_variation.HashSeed(key)
		T(seed >= 0 and seed < 1)["=="](true)
	end
end)

T.Test("the shared clock cycle is the same for every machine and wraps once per duration", function()
	local seed, scale = 0.37, 1.04
	T(pose_variation.GetClockCycle(seed, scale, 123.4, 2))["=="](pose_variation.GetClockCycle(seed, scale, 123.4, 2))
	local a = pose_variation.GetClockCycle(seed, scale, 10, 2)
	local b = pose_variation.GetClockCycle(seed, scale, 10 + 2 / scale, 2)
	T(math.abs(a - b) < 1e-9 or math.abs(math.abs(a - b) - 1) < 1e-9)["=="](true)

	for time = 0, 100, 0.37 do
		local cycle = pose_variation.GetClockCycle(seed, scale, time, 1.7)
		T(cycle >= 0 and cycle < 1)["=="](true)
	end

	T(
		pose_variation.GetClockCycle(0.1, scale, 5, 2) ~= pose_variation.GetClockCycle(0.6, scale, 5, 2)
	)["=="](true)
end)

T.Test("the stride cycle follows the distance walked and is the same for any speed history", function()
	local seed, scale, stride = 0.2, 1, 1.6
	local a = pose_variation.GetStrideCycle(seed, scale, 7, stride)
	local b = pose_variation.GetStrideCycle(seed, scale, 7 + stride, stride)
	T(math.abs(a - b) < 1e-9 or math.abs(math.abs(a - b) - 1) < 1e-9)["=="](true)
	local half = pose_variation.GetStrideCycle(seed, scale, 7 + stride / 2, stride)
	T(math.abs((half - a) % 1 - 0.5))["<"](1e-9)
	T(pose_variation.GetStrideCycle(seed, scale, 3.3, stride))["=="](pose_variation.GetStrideCycle(seed, scale, 3.3, stride))
end)

T.Test("moving sideways or backwards advances the stride odometer faster than moving forward", function()
	T(pose_variation.GetStrideScale(3, 0, false))["~"](1, 1e-9)
	T(pose_variation.GetStrideScale(-3, 0, false))["~"](1 / pose_variation.BackRatio, 1e-9)
	T(pose_variation.GetStrideScale(0, 3, false))["~"](1 / pose_variation.SideRatio, 1e-9)
	T(pose_variation.GetStrideScale(0, -3, false))["~"](1 / pose_variation.SideRatio, 1e-9)
	T(pose_variation.GetStrideScale(0, 0, false))["=="](1)
	T(pose_variation.GetStrideScale(0, 3, true))["=="](1)
	local diagonal = pose_variation.GetStrideScale(2, 2, false)
	T(diagonal > 1 and diagonal < 1 / pose_variation.SideRatio)["=="](true)
	T(pose_variation.GetStrideScale(1, 2, false))["=="](pose_variation.GetStrideScale(0.5, 1, false))
end)
