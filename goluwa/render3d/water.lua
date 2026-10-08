local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local water = library()
water.GRAVITY = 9.81
water.MAX_OCEAN_WAVES = 48
water.DETAIL_OCTAVES = 4
water.MAX_VOLUMES = 64
water.WAVE_TEXELS_PER_WAVELENGTH = 3
water.NEAR_TEXEL_SIZE = 64 * 2 / 512
-- every wave frequency is a multiple of 2pi / WAVE_PERIOD, so the waves repeat exactly after
-- WAVE_PERIOD seconds and the time the shaders see can be wrapped without losing float precision
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
	Caustics = 1,
	Seed = 1,
}
water.volumes = {}
-- a tiling normal map (xy in the red and green) whose layers replace the ripples, as in
-- Crysis. slope_variance is the variance of its decoded red and green over the texture
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

do
	local function next_random(state)
		state[1] = (state[1] * 1103515245 + 12345) % 2147483648
		return state[1] / 2147483648
	end

	local function gaussian(state)
		local u = math.max(next_random(state), 1e-6)
		return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * next_random(state))
	end

	local function pierson_moskowitz(omega, peak_omega)
		return 0.0081 * water.GRAVITY ^ 2 * omega ^ -5 * math.exp(-1.25 * (peak_omega / omega) ^ 4)
	end

	local base_omega = 2 * math.pi / water.WAVE_PERIOD

	local function add_wave(out, state, lambda, amplitude, angle)
		local omega = math.max(math.round(math.sqrt(water.GRAVITY * 2 * math.pi / lambda) / base_omega), 1) * base_omega
		local k = omega * omega / water.GRAVITY
		list.insert(
			out,
			{
				kx = math.cos(angle) * k,
				kz = math.sin(angle) * k,
				dir_x = math.cos(angle),
				dir_z = math.sin(angle),
				k = k,
				omega = omega,
				wavelength = 2 * math.pi / k,
				amplitude = amplitude,
				phase = next_random(state) * 2 * math.pi,
			}
		)
	end

	local function spectrum_band(out, state, count, omega_from, omega_to, peak_omega, wind_angle, energy_scale)
		local log_from = math.log(omega_from)
		local log_step = (math.log(omega_to) - log_from) / count

		for i = 0, count - 1 do
			local omega_low = math.exp(log_from + log_step * i)
			local omega_high = math.exp(log_from + log_step * (i + 1))
			local omega = math.exp(log_from + log_step * (i + 0.25 + next_random(state) * 0.5))
			local amplitude = math.sqrt(
				2 * pierson_moskowitz(omega, peak_omega) * energy_scale * (
						omega_high - omega_low
					)
			)
			local spread = math.rad(math.clamp(20 + 45 * math.log(omega / peak_omega) / math.log(4), 20, 75))
			add_wave(
				out,
				state,
				2 * math.pi * water.GRAVITY / (omega * omega),
				amplitude,
				wind_angle + math.clamp(gaussian(state), -2, 2) * spread * 0.5
			)
		end
	end

	local function by_wavelength(a, b)
		return a.wavelength > b.wavelength
	end

	water.WIND_SEA_ONSET = 1
	water.WIND_SEA_GROWN = 3

	function water.BuildOceanWaves(near_texel_size)
		local params = water.ocean
		local state = {params.Seed * 7919 + 17}
		local wind_sea = math.smoothstep(water.WIND_SEA_ONSET, water.WIND_SEA_GROWN, params.WindSpeed)
		local wind = math.max(params.WindSpeed, water.WIND_SEA_GROWN)
		local wind_angle = math.rad(params.WindDirection)
		local development = math.clamp(params.Development, 0.05, 1)
		local peak_omega = 0.855 * water.GRAVITY / wind / math.sqrt(development)
		local split_wavelength = near_texel_size * water.WAVE_TEXELS_PER_WAVELENGTH
		local omega_from = peak_omega * 0.6
		local omega_split = math.sqrt(2 * math.pi * water.GRAVITY / split_wavelength)
		local omega_to = math.sqrt(2 * math.pi * water.GRAVITY / 0.06)
		local swell_count = params.SwellHeight > 0 and 3 or 0
		local main = {}

		if wind_sea > 0 and omega_from < omega_split then
			spectrum_band(
				main,
				state,
				water.MAX_OCEAN_WAVES - swell_count,
				omega_from,
				omega_split,
				peak_omega,
				wind_angle,
				development * wind_sea
			)
		end

		if swell_count > 0 then
			local amplitude = params.SwellHeight / 4 * math.sqrt(2) / math.sqrt(swell_count)
			local swell_angle = math.rad(params.SwellDirection)

			for i = 1, swell_count do
				add_wave(
					main,
					state,
					params.SwellWavelength * (0.8 + 0.2 * i),
					amplitude,
					swell_angle + math.rad((i - 2) * 8)
				)
			end
		end

		table.sort(main, by_wavelength)
		local detail = {}

		if wind_sea > 0 then
			spectrum_band(
				detail,
				state,
				16,
				math.max(omega_split, omega_from),
				omega_to,
				peak_omega,
				wind_angle,
				development * wind_sea
			)
		end

		local height_variance = 0
		local steepness = 0
		local max_height = 0

		for _, wave in ipairs(main) do
			height_variance = height_variance + wave.amplitude ^ 2 / 2
			steepness = steepness + wave.k * wave.amplitude
			max_height = max_height + wave.amplitude
		end

		local total_slope_variance = 0.003 + 0.00512 * params.WindSpeed * development
		local main_slope_variance = 0
		local detail_slope_variance = 0

		for _, wave in ipairs(main) do
			main_slope_variance = main_slope_variance + (wave.k * wave.amplitude) ^ 2 / 2
		end

		for _, wave in ipairs(detail) do
			detail_slope_variance = detail_slope_variance + (wave.k * wave.amplitude) ^ 2 / 2
		end

		water.ocean_waves = {
			main = main,
			wind_angle = wind_angle,
			detail_wavelength = split_wavelength,
			height_std = math.sqrt(height_variance),
			max_height = max_height,
			choppiness = params.Choppiness * math.min(1, 1.6 / math.max(steepness, 1e-4)),
			total_slope_variance = total_slope_variance,
			main_slope_variance = main_slope_variance,
			detail_slope_variance = detail_slope_variance,
			near_texel_size = near_texel_size,
		}
		return water.ocean_waves
	end
end

function water.GetOceanWaves(near_texel_size)
	local waves = water.ocean_waves

	if not waves or waves.near_texel_size ~= near_texel_size then
		waves = water.BuildOceanWaves(near_texel_size)
	end

	return waves
end

function water.GetWaveTime()
	return system.GetGameTime() % water.WAVE_PERIOD
end

do
	local UNDISPLACE_ITERATIONS = 4

	-- the large waves at x, z at the given game time, following gerstner_displacement and
	-- gerstner_surface in the cascade shader but skipping every wave shorter than min_wavelength,
	-- which a body that size does not follow. the slope is taken at the undisplaced point and
	-- ignores the stretching of the horizontal displacement, so it is an approximation
	-- out receives height (above the mean), slope_x, slope_z and the water velocity
	function water.SampleOcean(x, z, time, min_wavelength, out)
		local waves = water.GetOceanWaves(water.NEAR_TEXEL_SIZE)
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

function water.GetResolvedWaveCount(waves, texel_size)
	local min_wavelength = texel_size * water.WAVE_TEXELS_PER_WAVELENGTH

	for i, wave in ipairs(waves.main) do
		if wave.wavelength < min_wavelength then return i - 1 end
	end

	return #waves.main
end

function water.GetResolvedSlopeVariance(waves, texel_size)
	local variance = 0

	for i = 1, water.GetResolvedWaveCount(waves, texel_size) do
		local wave = waves.main[i]
		variance = variance + (wave.k * wave.amplitude) ^ 2 / 2
	end

	return variance
end

water.wave_block = {
	{"waves", "vec4", water.MAX_OCEAN_WAVES},
	{"wave_count", "int"},
	{"wave_choppiness", "float"},
}

function water.WriteWaveBlock(block, waves, count)
	for i = 0, water.MAX_OCEAN_WAVES - 1 do
		local wave = waves.main[i + 1]
		local out = block.waves[i]

		if wave and i < count then
			out[0] = wave.kx
			out[1] = wave.kz
			out[2] = wave.amplitude
			out[3] = wave.phase
		else
			out[0] = 0
			out[1] = 0
			out[2] = 0
			out[3] = 0
		end
	end

	block.wave_count = count
	block.wave_choppiness = waves.choppiness
end

water.GERSTNER_GLSL = [[
	const float WATER_GRAVITY = ]] .. water.GRAVITY .. [[;

	// horizontal displacement of the undisplaced point p
	vec2 gerstner_displacement(vec2 p, float time, float choppiness) {
		vec2 d = vec2(0.0);

		for (int i = 0; i < wave_block.wave_count; i++) {
			vec4 w = wave_block.waves[i];
			float k = length(w.xy);
			float theta = dot(w.xy, p) - sqrt(WATER_GRAVITY * k) * time + w.w;
			d -= (w.xy / k) * (w.z * choppiness * sin(theta));
		}

		return d;
	}

	// the undisplaced point that the waves carry to world_xz
	vec2 gerstner_undisplace(vec2 world_xz, float time, float choppiness) {
		vec2 p = world_xz;

		for (int i = 0; i < 4; i++) {
			p = world_xz - gerstner_displacement(p, time, choppiness);
		}

		return p;
	}

	// height, surface normal and the jacobian of the horizontal displacement,
	// which drops towards 0 and below where a crest folds over and breaks
	void gerstner_surface(vec2 p, float time, float choppiness, out float height, out vec3 normal, out float jacobian) {
		height = 0.0;
		float dx_dx = 0.0;
		float dz_dz = 0.0;
		float dx_dz = 0.0;
		float dh_dx = 0.0;
		float dh_dz = 0.0;

		for (int i = 0; i < wave_block.wave_count; i++) {
			vec4 w = wave_block.waves[i];
			float k = length(w.xy);
			vec2 dir = w.xy / k;
			float theta = dot(w.xy, p) - sqrt(WATER_GRAVITY * k) * time + w.w;
			float s = sin(theta);
			float c = cos(theta);
			float ak = w.z * k;
			height += w.z * c;
			dh_dx -= ak * dir.x * s;
			dh_dz -= ak * dir.y * s;
			float chop = ak * choppiness * c;
			dx_dx -= dir.x * dir.x * chop;
			dz_dz -= dir.y * dir.y * chop;
			dx_dz -= dir.x * dir.y * chop;
		}

		vec3 tangent_x = vec3(1.0 + dx_dx, dh_dx, dx_dz);
		vec3 tangent_z = vec3(dx_dz, dh_dz, 1.0 + dz_dz);
		normal = normalize(cross(tangent_z, tangent_x));
		jacobian = (1.0 + dx_dx) * (1.0 + dz_dz) - dx_dz * dx_dz;
	}
]]
return water
