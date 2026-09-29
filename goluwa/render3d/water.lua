--[[
	Water: the ocean's sea state and the water volumes.

	The ocean is an infinite plane at render3d.GetOceanLevel(). Its waves are a
	sum of Gerstner waves drawn from the Pierson-Moskowitz spectrum of a fully
	developed sea for the wind speed, spread around the wind direction, plus a
	few long swell waves. Waves too short for the wave textures are noise
	ripples per pixel, and the slopes of the ones too short for either go
	into the surface roughness, so the total matches the Cox-Munk slope
	statistics of a real sea at that wind speed.

	Water volumes (the water_volume component) are boxes of still or rippled
	water whose top face is the surface: lakes, ponds, pools, rivers.

	Both are shaded as a participating medium with an absorption and a
	particle scattering coefficient per meter for red, green and blue, on top
	of pure water's own molecular scattering. See water.presets for
	measured-ish values.
]]
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local water = library()
water.GRAVITY = 9.81
water.MAX_OCEAN_WAVES = 48
-- octaves of noise ripples per pixel, shorter than the near wave texture resolves
water.DETAIL_OCTAVES = 4
-- the nearest this many to the camera are drawn
water.MAX_VOLUMES = 64
-- waves shorter than this many texels of a wave texture are left out of it
water.WAVE_TEXELS_PER_WAVELENGTH = 3
-- Pure seawater's molecular scattering per meter, red green blue: Morel
-- 1974's 0.00288 at 500 nm falling with wavelength^-4.32, taken at 620, 550
-- and 450 nm. It scatters about as much back as forward. Every water has it,
-- the presets' ParticleScattering is what's suspended in it.
water.MOLECULAR_SCATTERING = Vec3(0.00114, 0.00191, 0.00454)
-- Particles scatter mostly forward: a Henyey-Greenstein asymmetry of 0.92
-- sends 1.8% of it back, Petzold's measured ratio for ocean water.
water.PARTICLE_PHASE_G = 0.92
-- Absorption and ParticleScattering per meter, red green blue. Where it says
-- chlorophyll, the particles are 0.3 * chl^0.62 at 550 nm going with 1 /
-- wavelength (Gordon and Morel 1983), the absorption pure water plus
-- phytoplankton (Bricaud 1995) and dissolved organic matter.
water.presets = {
	-- the clearest open ocean, like the Sargasso Sea: 0.03 mg/m3 chlorophyll, violet blue
	ocean = {
		Absorption = Vec3(0.45, 0.065, 0.021),
		ParticleScattering = Vec3(0.030, 0.034, 0.042),
	},
	-- typical open ocean, 0.3 mg/m3 chlorophyll: blue with some green in it
	open_ocean = {
		Absorption = Vec3(0.46, 0.072, 0.051),
		ParticleScattering = Vec3(0.126, 0.142, 0.174),
	},
	-- a productive shelf sea like the North Sea, 1.5 mg/m3 chlorophyll and river
	-- runoff: green grey
	temperate_sea = {
		Absorption = Vec3(0.47, 0.089, 0.137),
		ParticleScattering = Vec3(0.342, 0.386, 0.472),
	},
	-- shallow tropical sea over sand, 0.1 mg/m3 chlorophyll, turquoise from the
	-- absorption and the sand
	tropical = {
		Absorption = Vec3(0.42, 0.058, 0.024),
		ParticleScattering = Vec3(0.064, 0.072, 0.088),
	},
	-- plankton and sediment: greener and more turbid
	coastal = {
		Absorption = Vec3(0.5, 0.1, 0.13),
		ParticleScattering = Vec3(0.09, 0.13, 0.11),
	},
	-- a clear mountain lake, slightly green from dissolved organic matter
	lake = {
		Absorption = Vec3(0.5, 0.11, 0.19),
		ParticleScattering = Vec3(0.025, 0.035, 0.03),
	},
	-- algae and silt, you can see a meter or two into it
	pond = {
		Absorption = Vec3(0.95, 0.42, 0.85),
		ParticleScattering = Vec3(0.3, 0.42, 0.24),
	},
	-- tannins make bog water tea coloured
	swamp = {
		Absorption = Vec3(0.9, 1.4, 2.6),
		ParticleScattering = Vec3(0.32, 0.22, 0.08),
	},
	-- rock flour from a glacier scatters and makes it milky turquoise
	glacial = {
		Absorption = Vec3(0.48, 0.075, 0.07),
		ParticleScattering = Vec3(0.55, 0.7, 0.78),
	},
	-- filtered and chlorinated, hardly any particles, the tiles do the rest
	pool = {
		Absorption = Vec3(0.34, 0.052, 0.016),
		ParticleScattering = Vec3(0.003, 0.003, 0.003),
	},
}

-- The medium of a game's water fog. Games fog water towards a colour with a
-- density, which is roughly the extinction per meter. Channels that are dark in
-- the fog colour are absorbed faster, which tints what's seen through the water,
-- and the colour times albedo_scale is the particles' scattering albedo. color
-- is linear.
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
	-- m/s at 10 m above the sea, sets the wave heights and lengths
	WindSpeed = 7,
	-- degrees, the direction the wind blows towards, 0 is +x, 90 is +z
	WindDirection = 30,
	-- how far the Gerstner waves pull towards their crests, 0 gives sine waves
	Choppiness = 1.1,
	-- how much of the wind waves are grown yet, 1 is a fully developed sea
	Development = 1,
	SwellHeight = 0.35,
	SwellWavelength = 140,
	SwellDirection = 50,
	Absorption = water.presets.ocean.Absorption:Copy(),
	ParticleScattering = water.presets.ocean.ParticleScattering:Copy(),
	IOR = 1.333,
	Foam = 1,
	Caustics = 1,
	Seed = 1,
}
water.volumes = {}

function water.SetOcean(params)
	for key, value in pairs(params) do
		if water.ocean[key] == nil then error("unknown ocean parameter " .. key, 2) end

		water.ocean[key] = value
	end

	water.ocean_waves = nil
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

	-- Pierson-Moskowitz, the spectrum of a sea the wind has blown over long
	-- enough to be in equilibrium. peak_omega is where most energy is.
	local function pierson_moskowitz(omega, peak_omega)
		return 0.0081 * water.GRAVITY ^ 2 * omega ^ -5 * math.exp(-1.25 * (peak_omega / omega) ^ 4)
	end

	local function add_wave(out, state, lambda, amplitude, angle)
		local k = 2 * math.pi / lambda
		list.insert(
			out,
			{
				kx = math.cos(angle) * k,
				kz = math.sin(angle) * k,
				k = k,
				wavelength = lambda,
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
			-- the waves at the peak follow the wind, shorter ones spread wider
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

	-- longest first, so the far wave texture sums a prefix
	local function by_wavelength(a, b)
		return a.wavelength > b.wavelength
	end

	-- wave texture texel size in meters of the near wave texture; the main
	-- waves go down to where that stops resolving them and the per pixel
	-- ripples take over
	function water.BuildOceanWaves(near_texel_size)
		local params = water.ocean
		local state = {params.Seed * 7919 + 17}
		local wind = math.max(params.WindSpeed, 0.5)
		local wind_angle = math.rad(params.WindDirection)
		local development = math.clamp(params.Development, 0.05, 1)
		-- a younger sea peaks at shorter waves and holds less energy
		local peak_omega = 0.855 * water.GRAVITY / wind / math.sqrt(development)
		local split_wavelength = near_texel_size * water.WAVE_TEXELS_PER_WAVELENGTH
		local omega_from = peak_omega * 0.6
		local omega_split = math.sqrt(2 * math.pi * water.GRAVITY / split_wavelength)
		local omega_to = math.sqrt(2 * math.pi * water.GRAVITY / 0.06)
		local swell_count = params.SwellHeight > 0 and 3 or 0
		local main = {}
		spectrum_band(
			main,
			state,
			water.MAX_OCEAN_WAVES - swell_count,
			omega_from,
			math.max(omega_split, omega_from * 1.5),
			peak_omega,
			wind_angle,
			development
		)

		if swell_count > 0 then
			-- significant height is 4 standard deviations, a sine's is amplitude / sqrt(2)
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
		-- only the slopes of the waves shorter than that matter, the per
		-- pixel ripples are noise with the same slope variance
		local detail = {}
		spectrum_band(
			detail,
			state,
			16,
			math.max(omega_split, omega_from * 1.5),
			omega_to,
			peak_omega,
			wind_angle,
			development
		)
		local height_variance = 0
		local steepness = 0

		for _, wave in ipairs(main) do
			height_variance = height_variance + wave.amplitude ^ 2 / 2
			steepness = steepness + wave.k * wave.amplitude
		end

		-- Cox and Munk's slope variance of the sea surface for a wind speed
		local total_slope_variance = 0.003 + 0.00512 * wind * development
		local main_slope_variance = 0
		local detail_slope_variance = 0

		for _, wave in ipairs(main) do
			main_slope_variance = main_slope_variance + (wave.k * wave.amplitude) ^ 2 / 2
		end

		for _, wave in ipairs(detail) do
			detail_slope_variance = detail_slope_variance + (wave.k * wave.amplitude) ^ 2 / 2
		end

		-- the Gerstner displacement makes the choppiest steep waves fold over,
		-- keep the sum of steepnesses from folding everything
		water.ocean_waves = {
			main = main,
			wind_angle = wind_angle,
			detail_wavelength = split_wavelength,
			height_std = math.sqrt(height_variance),
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

-- how many of the longest waves a wave texture with this texel size holds
function water.GetResolvedWaveCount(waves, texel_size)
	local min_wavelength = texel_size * water.WAVE_TEXELS_PER_WAVELENGTH

	for i, wave in ipairs(waves.main) do
		if wave.wavelength < min_wavelength then return i - 1 end
	end

	return #waves.main
end

-- the slope variance of the waves a wave texture with this texel size holds
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

-- GLSL: one Gerstner wave sum at a displaced point. waves are vec4(kx, kz,
-- amplitude, phase), deep water dispersion gives each its speed.
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
