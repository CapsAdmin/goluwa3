local ffi = require("ffi")
local bit = require("bit")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local water = {}
water.GRAVITY = 9.81
water.DETAIL_OCTAVES = 4
water.MAX_VOLUMES = 64
water.WAVE_TEXELS_PER_WAVELENGTH = 3
water.NEAR_TEXEL_SIZE = 64 * 2 / 512
water.WAVE_PERIOD = 1024
water.MOLECULAR_SCATTERING = Vec3(0.00114, 0.00191, 0.00454)
water.PARTICLE_PHASE_G = 0.92
water.ABBE_NUMBER = 55.8
water.presets = {
	ocean = {
		Absorption = Vec3(0.45, 0.065, 0.021),
		ParticleScattering = Vec3(0.030, 0.034, 0.042),
	},
	open_ocean = {
		Absorption = Vec3(0.46, 0.072, 0.051),
		ParticleScattering = Vec3(0.126, 0.142, 0.174),
	},
	temperate_sea = {
		Absorption = Vec3(0.47, 0.089, 0.137),
		ParticleScattering = Vec3(0.342, 0.386, 0.472),
	},
	tropical = {
		Absorption = Vec3(0.42, 0.058, 0.024),
		ParticleScattering = Vec3(0.064, 0.072, 0.088),
	},
	coastal = {
		Absorption = Vec3(0.5, 0.1, 0.13),
		ParticleScattering = Vec3(0.09, 0.13, 0.11),
	},
	lake = {
		Absorption = Vec3(0.5, 0.11, 0.19),
		ParticleScattering = Vec3(0.025, 0.035, 0.03),
	},
	pond = {
		Absorption = Vec3(0.95, 0.42, 0.85),
		ParticleScattering = Vec3(0.3, 0.42, 0.24),
	},
	swamp = {
		Absorption = Vec3(0.9, 1.4, 2.6),
		ParticleScattering = Vec3(0.32, 0.22, 0.08),
	},
	glacial = {
		Absorption = Vec3(0.48, 0.075, 0.07),
		ParticleScattering = Vec3(0.55, 0.7, 0.78),
	},
	pool = {
		Absorption = Vec3(0.34, 0.052, 0.016),
		ParticleScattering = Vec3(0.003, 0.003, 0.003),
	},
}

function water.MediumFromFog(color, extinction, albedo_scale)
	local brightest = math.max(color.x, color.y, color.z, 1e-4)
	local absorption = Vec3()
	local scattering = Vec3()

	for _, c in ipairs({"x", "y", "z"}) do
		local channel_extinction = extinction * math.lerp(color[c] / brightest, 1.8, 0.7)
		scattering[c] = channel_extinction * math.clamp(color[c] * albedo_scale, 0.005, 0.9)
		absorption[c] = channel_extinction - scattering[c]
	end

	return absorption, scattering
end

water.ocean = {
	WindSpeed = 7,
	WindDirection = 30,
	Choppiness = 1.1,
	RippleStrength = 0.5,
	RippleScale = 10,
	RippleLifetime = 5,
	Development = 1,
	SwellHeight = 0.35,
	SwellWavelength = 140,
	SwellDirection = 50,
	Absorption = water.presets.ocean.Absorption:Copy(),
	ParticleScattering = water.presets.ocean.ParticleScattering:Copy(),
	IOR = 1.333,
	AbbeNumber = water.ABBE_NUMBER,
	Foam = 1,
	GustAmount = 1,
	SlickAmount = 1,
	StreakAmount = 1,
	Caustics = 1,
	Seed = 1,
}
water.volumes = {}
water.wave_bump = nil

function water.SetWaveBump(texture, slope_variance)
	water.wave_bump = texture and {texture = texture, slope_variance = slope_variance} or nil
end

function water.SetOcean(params)
	for key, value in pairs(params) do
		if water.ocean[key] == nil then error("unknown ocean parameter " .. key, 2) end

		water.ocean[key] = value
	end

	water.ocean_waves = nil
	event.Call("OceanChanged")
end

function water.GetOcean()
	return water.ocean
end

function water.AddVolume(volume)
	list.insert(water.volumes, volume)
end

function water.RemoveVolume(volume)
	for i, other in ipairs(water.volumes) do
		if other == volume then
			list.remove(water.volumes, i)

			break
		end
	end
end

function water.GetVolumes()
	return water.volumes
end

function water.HasVolumes()
	return water.volumes[1] ~= nil
end

water.FFT_SIZE = 256
water.FFT_CASCADES = {{size = 1000}, {size = 167}, {size = 37.3}}
water.FFT_BAND_WAVELENGTHS = {
	water.NEAR_TEXEL_SIZE * water.WAVE_TEXELS_PER_WAVELENGTH * 16,
	water.NEAR_TEXEL_SIZE * water.WAVE_TEXELS_PER_WAVELENGTH * 4,
	water.NEAR_TEXEL_SIZE * water.WAVE_TEXELS_PER_WAVELENGTH,
}
water.PHYSICS_WAVES = 128
water.RIPPLE_WAVELENGTH = 0.06
water.spectrum_version = 0

do
	local PI = math.pi
	local BASE_OMEGA = 2 * PI / water.WAVE_PERIOD
	local N = water.FFT_SIZE

	local function multiply(a, b)
		local ah, al = bit.rshift(a, 16), bit.band(a, 0xffff)
		local bh, bl = bit.rshift(b, 16), bit.band(b, 0xffff)
		return bit.tobit(al * bl + bit.lshift(bit.tobit(ah * bl + al * bh), 16))
	end

	local function hash(x)
		x = bit.bxor(x, bit.rshift(x, 16))
		x = multiply(x, 0x7feb352d)
		x = bit.bxor(x, bit.rshift(x, 15))
		x = multiply(x, 0x846ca68b)
		return bit.bxor(x, bit.rshift(x, 16))
	end

	local function to_unit(x)
		return ((x < 0 and x + 4294967296 or x) + 0.5) / 4294967296
	end

	local function pierson_moskowitz(omega, peak_omega)
		return 0.0081 * water.GRAVITY ^ 2 * omega ^ -5 * math.exp(-1.25 * (peak_omega / omega) ^ 4)
	end

	local function gaussians(seed, cascade, u, r)
		local key = hash(bit.bxor(hash(r * N + u), hash(seed * 131 + cascade * 17 + 5)))
		local u1 = to_unit(hash(key + 1))
		local u2 = to_unit(hash(key + 2))
		local radius = math.sqrt(-2 * math.log(u1))
		return radius * math.cos(2 * PI * u2), radius * math.sin(2 * PI * u2)
	end

	local function wrap_angle(angle)
		return math.atan2(math.sin(angle), math.cos(angle))
	end

	local function slope_variance_between(waves, k_from, k_to)
		if k_to <= k_from then return 0 end

		local steps = 400
		local ratio = (k_to / k_from) ^ (1 / steps)
		local variance = 0
		local k = k_from

		for _ = 1, steps do
			local k_next = k * ratio
			local mid = math.sqrt(k * k_next)
			variance = variance + waves.wind_spectrum(mid) * mid * mid * (k_next - k)
			k = k_next
		end

		return variance
	end

	function water.BuildOceanWaves()
		local params = water.ocean
		local g = water.GRAVITY
		local seed = params.Seed
		local wind_sea = math.smoothstep(1, 3, params.WindSpeed)
		local wind = math.max(params.WindSpeed, 3)
		local development = math.clamp(params.Development, 0.05, 1)
		local peak_omega = 0.855 * g / wind / math.sqrt(development)
		local omega_from = peak_omega * 0.6
		local energy = development * wind_sea
		local wind_angle = math.rad(params.WindDirection)
		local waves = {wind_angle = wind_angle, detail_wavelength = water.FFT_BAND_WAVELENGTHS[3]}

		function waves.wind_spectrum(k)
			local omega = math.sqrt(g * k)

			if energy <= 0 or omega < omega_from then return 0 end

			return pierson_moskowitz(omega, peak_omega) * energy * omega / (2 * k)
		end

		local swell_sigma = params.SwellHeight / 4
		local swell_k = 2 * PI / (params.SwellWavelength * 1.2)
		local swell_angle = math.rad(params.SwellDirection)
		local swell_spread = math.rad(8)
		local swell_width = swell_k * 0.25
		local band_edges = {}

		for i, wavelength in ipairs(water.FFT_BAND_WAVELENGTHS) do
			band_edges[i] = 2 * PI / wavelength
		end

		local first_dk = 2 * PI / water.FFT_CASCADES[1].size
		local swell_raw = 0

		if swell_sigma > 0 then
			for r = 0, N - 1 do
				local m = r < N / 2 and r or r - N

				for u = 0, N - 1 do
					local n = u < N / 2 and u or u - N
					local kx, kz = n * first_dk, m * first_dk
					local k = math.sqrt(kx * kx + kz * kz)

					if k > 0 and k <= band_edges[1] then
						local weight = math.exp(-0.5 * ((k - swell_k) / swell_width) ^ 2) * math.exp(-0.5 * (wrap_angle(math.atan2(kz, kx) - swell_angle) / swell_spread) ^ 2)
						swell_raw = swell_raw + weight
					end
				end
			end
		end

		local swell_scale = swell_raw > 0 and swell_sigma * swell_sigma / (swell_raw * 1) or 0
		local height_variance = 0
		local gradient_variance = 0
		local candidates = {}
		waves.cascades = {}

		for cascade_index, cascade in ipairs(water.FFT_CASCADES) do
			local dk = 2 * PI / cascade.size
			local k_low = cascade_index == 1 and 0 or band_edges[cascade_index - 1]
			local k_high = band_edges[cascade_index]
			local h0 = ffi.new("float[?]", N * N * 4)
			local omega_index = ffi.new("float[?]", N * N)

			local function mode(u, r)
				local n = u < N / 2 and u or u - N
				local m = r < N / 2 and r or r - N
				local kx, kz = n * dk, m * dk
				local k = math.sqrt(kx * kx + kz * kz)

				if k <= k_low or k > k_high then return 0, 0, kx, kz, k end

				local omega = math.sqrt(g * k)
				local angle = wrap_angle(math.atan2(kz, kx) - wind_angle)
				local sigma = math.rad(math.clamp(20 + 45 * math.log(omega / peak_omega) / math.log(4), 20, 75)) * 0.5
				local spectrum = waves.wind_spectrum(k) / k * math.exp(-0.5 * (angle / sigma) ^ 2) / (sigma * math.sqrt(2 * PI))

				if swell_scale > 0 then
					local weight = math.exp(-0.5 * ((k - swell_k) / swell_width) ^ 2) * math.exp(-0.5 * (wrap_angle(math.atan2(kz, kx) - swell_angle) / swell_spread) ^ 2)
					spectrum = spectrum + weight * swell_scale / (dk * dk)
				end

				local deviation = math.sqrt(spectrum * dk * dk / 2)
				local re, im = gaussians(seed, cascade_index, u, r)
				return re * deviation / math.sqrt(2), im * deviation / math.sqrt(2), kx, kz, k
			end

			for r = 0, N - 1 do
				for u = 0, N - 1 do
					local index = (r * N + u) * 4
					local re, im, kx, kz, k = mode(u, r)
					local partner_re, partner_im = mode((N - u) % N, (N - r) % N)
					h0[index] = re
					h0[index + 1] = im
					h0[index + 2] = partner_re
					h0[index + 3] = partner_im

					if k > k_low and k <= k_high then
						local j = math.max(math.round(math.sqrt(g * k) / BASE_OMEGA), 1)
						omega_index[r * N + u] = j
						local amplitude = 2 * math.sqrt(re * re + im * im)
						height_variance = height_variance + amplitude * amplitude / 2
						gradient_variance = gradient_variance + (k * amplitude) ^ 2 / 2

						if cascade_index <= 2 then
							candidates[#candidates + 1] = {
								kx = kx,
								kz = kz,
								amplitude = amplitude,
								phase = math.atan2(im, re),
								k = k,
								omega = j * BASE_OMEGA,
							}
						end
					end
				end
			end

			waves.cascades[cascade_index] = {h0 = h0, omega_index = omega_index}
		end

		table.sort(candidates, function(a, b)
			return a.amplitude > b.amplitude
		end)

		local main = {}

		for i = 1, math.min(water.PHYSICS_WAVES, #candidates) do
			local wave = candidates[i]
			wave.dir_x = wave.kx / wave.k
			wave.dir_z = wave.kz / wave.k
			wave.wavelength = 2 * PI / wave.k
			main[i] = wave
		end

		table.sort(main, function(a, b)
			return a.wavelength > b.wavelength
		end)

		waves.main = main
		waves.height_std = math.sqrt(height_variance)
		waves.max_height = waves.height_std * 3.5
		waves.choppiness = params.Choppiness * math.min(1, 0.3 / math.max(math.sqrt(gradient_variance), 1e-4))
		waves.total_slope_variance = 0.003 + 0.00512 * params.WindSpeed * development
		waves.swell_variance = swell_sigma * swell_sigma
		waves.swell_k = swell_k
		waves.detail_slope_variance = slope_variance_between(
			waves,
			band_edges[3],
			2 * PI / water.RIPPLE_WAVELENGTH
		)
		water.spectrum_version = water.spectrum_version + 1
		water.ocean_waves = waves
		return waves
	end

	function water.GetResolvedSlopeVariance(waves, texel_size)
		local k_max = 2 * PI / (texel_size * water.WAVE_TEXELS_PER_WAVELENGTH)
		local variance = slope_variance_between(waves, 2 * PI / water.FFT_CASCADES[1].size, k_max)

		if waves.swell_k <= k_max then
			variance = variance + waves.swell_variance * waves.swell_k ^ 2
		end

		return variance
	end
end

function water.GetOceanWaves()
	return water.ocean_waves or water.BuildOceanWaves()
end

function water.GetWhitecapFactor(wind_speed)
	return math.clamp((wind_speed - 3) / 11, 0, 1) ^ 1.5
end

function water.GetWaveTime()
	return system.GetGameTime() % water.WAVE_PERIOD
end

do
	local UNDISPLACE_ITERATIONS = 4

	function water.SampleOcean(x, z, time, min_wavelength, out)
		local waves = water.GetOceanWaves()
		local main = waves.main
		local count = #main
		local choppiness = waves.choppiness
		time = time % water.WAVE_PERIOD
		local px, pz = x, z

		for _ = 1, UNDISPLACE_ITERATIONS do
			local dx, dz = 0, 0

			for i = 1, count do
				local wave = main[i]

				if wave.wavelength < min_wavelength then break end

				local shift = wave.amplitude * choppiness * math.sin(wave.kx * px + wave.kz * pz - wave.omega * time + wave.phase)
				dx = dx + wave.dir_x * shift
				dz = dz + wave.dir_z * shift
			end

			px, pz = x + dx, z + dz
		end

		local height, slope_x, slope_z = 0, 0, 0
		local velocity_x, velocity_y, velocity_z = 0, 0, 0

		for i = 1, count do
			local wave = main[i]

			if wave.wavelength < min_wavelength then break end

			local theta = wave.kx * px + wave.kz * pz - wave.omega * time + wave.phase
			local sin, cos = math.sin(theta), math.cos(theta)
			local amplitude = wave.amplitude
			local steepness = amplitude * wave.k * sin
			local orbit = amplitude * choppiness * wave.omega * cos
			height = height + amplitude * cos
			slope_x = slope_x - steepness * wave.dir_x
			slope_z = slope_z - steepness * wave.dir_z
			velocity_x = velocity_x + wave.dir_x * orbit
			velocity_z = velocity_z + wave.dir_z * orbit
			velocity_y = velocity_y + amplitude * wave.omega * sin
		end

		out.height = height
		out.slope_x = slope_x
		out.slope_z = slope_z
		out.velocity_x = velocity_x
		out.velocity_y = velocity_y
		out.velocity_z = velocity_z
		return out
	end
end

return water
