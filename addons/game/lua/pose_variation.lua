local pose_variation = {}
pose_variation.Gravity = 9.81
pose_variation.LeanSideGain = 1
pose_variation.LeanForwardGain = 0.6
pose_variation.MaxLean = 0.2
pose_variation.MaxAcceleration = 60
pose_variation.AccelerationFollow = 8
pose_variation.LeanFollow = 10
pose_variation.SwayPitch = math.rad(1)
pose_variation.SwayYaw = math.rad(1.5)
pose_variation.SwaySpeed = 2
pose_variation.SwayWalkAmount = 0.3
pose_variation.RateSpread = 0.05
pose_variation.RateDrift = 0.02
pose_variation.BackRatio = 0.8
pose_variation.SideRatio = 0.7
local FREQUENCIES = {0.13, 0.31, 0.47}
local PHASE_STEP = 12.9898

function pose_variation.Noise(seed, channel, time)
	local sum = 0

	for i = 1, 3 do
		sum = sum + math.sin(
				(
						time * FREQUENCIES[i] * (
							1 + channel * 0.37
						) + seed * PHASE_STEP * i + channel * 1.7
					) * math.pi * 2
			)
	end

	return sum / 3
end

function pose_variation.HashSeed(key)
	if type(key) == "number" then
		local value = math.sin(key * 12.9898) * 43758.5453
		return value - math.floor(value)
	end

	local hash = 2166136261

	for i = 1, #key do
		hash = bit.bxor(hash, key:byte(i)) * 16777619 % 4294967296
	end

	return hash / 4294967296
end

function pose_variation.GetRateScale(seed)
	return 1 + (seed * 7.31 % 1 * 2 - 1) * pose_variation.RateSpread
end

function pose_variation.GetStrideScale(forward, right, crouching)
	local speed = math.sqrt(forward * forward + right * right)

	if crouching or speed < 1e-4 then return 1 end

	local along = forward / speed
	local across = right / speed
	local along_ratio = along >= 0 and 1 or pose_variation.BackRatio
	return math.sqrt((along / along_ratio) ^ 2 + (across / pose_variation.SideRatio) ^ 2)
end

function pose_variation.GetClockCycle(seed, rate_scale, time, duration)
	return (time * rate_scale / duration + seed) % 1
end

function pose_variation.GetStrideCycle(seed, rate_scale, distance, stride)
	return (distance * rate_scale / stride + seed) % 1
end

function pose_variation.GetLean(out, side, forward)
	out:Identity()
	out:RotateRoll(-side)
	out:RotatePitch(-forward)
	return out
end

return pose_variation
