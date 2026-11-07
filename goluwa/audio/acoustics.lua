local Vec3 = import("goluwa/structs/vec3.lua")
local spatial = import("goluwa/audio/spatial.lua")
local dsp = import("goluwa/audio/dsp.lua")
local ground = import("goluwa/audio/ground.lua")
local acoustics = {}
acoustics.OPEN_DISTANCE = 400
acoustics.TRACE_DISTANCE = 1000
acoustics.LISTENER_CLEARANCE = 0.25
acoustics.SOURCE_CLEARANCE = 0.3
acoustics.SURFACE_OFFSET = 0.01
acoustics.scattering_scale = 1
acoustics.MIN_SOURCE_DISTANCE = 1
acoustics.MAX_TAIL_DELAY_PATHS = 2
acoustics.FRESNEL_CLEARANCE = 0.6
acoustics.RHO_C = 413
acoustics.RHO_C2 = 141600
acoustics.MAX_INCIDENCE = math.rad(78)
acoustics.FIELD_SAMPLES = 6
acoustics.MAX_LEAVES = 8
acoustics.LEAF_STEP = 0.001
acoustics.BAND_EDGES = {{50, 500}, {500, 4000}, {4000, 16000}}
acoustics.MIN_SCATTER_PROBABILITY = 0.05
acoustics.GATHER_WALL_BOUNCES = 2
acoustics.WALL_SEARCH = 3
acoustics.WIND_SHELTER = 20
acoustics.RAY_FLOATS = 12
acoustics.SAMPLE_FLOATS = 14
acoustics.AMBIENCE_CELLS = 4
acoustics.OPENING_CELLS = 8
acoustics.MAX_OPENINGS = 8
acoustics.CLUSTER_DISTANCE = 3
acoustics.CLUSTER_FREE_PATH = 0.25
-- ISO 9613-2 limit for one edge: turbulence and scattering fill the deep shadow
acoustics.DIFFRACTION_CAP_DB = 20
acoustics.DETOUR_MIN_RADIUS = 0.05
acoustics.DETOUR_MAX_RADIUS = 0.5
acoustics.DETOUR_MIN_REACH = 16
acoustics.DETOUR_NONE = 1000
acoustics.DETOUR_MEMORY = 0.7
acoustics.DETOUR_FOLLOW = 0.3
acoustics.DETOUR_SAMPLES = 6
acoustics.SNOW_MIN_SLOPE = math.cos(math.rad(50))
acoustics.MAX_REFLECTORS = 10
acoustics.MIN_REFLECTOR_AREA = 0.5
acoustics.MIN_REFLECTOR_HITS = 3
acoustics.REFLECTOR_MEMORY = 1.5
acoustics.REFLECTOR_RECENT = 0.5
acoustics.FOOTPRINT_SIGMA = 2
acoustics.FOOTPRINT_MARGIN = 0.5
acoustics.TAP_MEMORY = 1.0
acoustics.STATS_MEMORY = 0.5
acoustics.STATS_DISTANCE = 0.5
acoustics.OCCLUSION_MEMORY_SAMPLES = 12
acoustics.TRUSTED_RAYS = 256
acoustics.MIN_T60 = 0.05
acoustics.MAX_T60 = 12
acoustics.MIN_PREDELAY = 0.002
acoustics.REMOTE_T60_RATIO = 1.6
acoustics.ECHO_SPREAD_MIN = 0.3
acoustics.ECHO_SPREAD_MAX = 0.7
acoustics.QUERY_FLOATS = 12
acoustics.QUERY_INPUT_FLOATS = 12
acoustics.DIFFUSE_ESCAPING = 0.1
acoustics.SPARSE_ESCAPING = 0.35
acoustics.MIN_DIFFUSION = 0.8
acoustics.EMITTER_DISTANCE = 40
acoustics.EMITTER_MAX_DISTANCE = 100
acoustics.EMITTER_FREE_PATH = 2
acoustics.EMITTER_PERIOD = 3
acoustics.GROUND_MIN_SLOPE = 0.75
acoustics.GROUND_FILTER_DISTANCE = 40
acoustics.GROUND_SCATTER_FREQUENCIES = {250, 1500, 8000}
acoustics.GROUND_VOICES = 4
acoustics.GROUND_AHEAD_MARGIN = 128
local LN10_OVER_10 = math.log(10) / 10
local MAX_TAPS = 8

function acoustics.AirEnergyPerMeter(band)
	return spatial.AIR_ABSORPTION_DB[band] * LN10_OVER_10
end

function acoustics.NewMaterial(absorption, scattering, density, surface_mass, rain, wind)
	return {
		absorption = {absorption[1], absorption[2], absorption[3]},
		scattering = {scattering[1], scattering[2], scattering[3]},
		density = density,
		surface_mass = surface_mass,
		rain = {rain[1], rain[2], rain[3]},
		wind = {wind[1], wind[2], wind[3]},
	}
end

acoustics.DEFAULT_MATERIAL = acoustics.NewMaterial({0.06, 0.10, 0.16}, {0.1, 0.2, 0.3}, 1500, 20, {0.6, 0.8, 0.9}, {0, 0, 0})
acoustics.SNOW = acoustics.NewMaterial({0.45, 0.85, 0.90}, {0.1, 0.3, 0.6}, 300, 30, {0.05, 0.05, 0.05}, {0, 0, 0})

-- a porous layer absorbs a band once it is about a quarter wavelength deep
function acoustics.SnowCover(depth, speed, out)
	for b = 1, 3 do
		out[b] = math.min(depth / (speed / (4 * dsp.BAND_CENTERS[b])), 1)
	end

	return out
end

function acoustics.ReadMaterial(material, out)
	local a = material:GetAcousticAbsorption()
	local s = material:GetAcousticScattering()
	local r = material:GetAcousticRainEmission()
	local w = material:GetAcousticWindEmission()
	out.absorption[1], out.absorption[2], out.absorption[3] = a.x, a.y, a.z
	out.scattering[1], out.scattering[2], out.scattering[3] = s.x, s.y, s.z
	out.rain[1], out.rain[2], out.rain[3] = r.x, r.y, r.z
	out.wind[1], out.wind[2], out.wind[3] = w.x, w.y, w.z
	out.density = material:GetAcousticDensity()
	out.surface_mass = material:GetAcousticSurfaceMass()
	return out
end

do
	local frequencies = {}

	for b = 1, 3 do
		local low, high = acoustics.BAND_EDGES[b][1], acoustics.BAND_EDGES[b][2]

		for k = 1, 3 do
			frequencies[(b - 1) * 3 + k] = low * (high / low) ^ ((k - 0.5) / 3)
		end
	end

	acoustics.BAND_FREQUENCIES = frequencies

	function acoustics.LimpTransmission(frequency, mass, cos_theta)
		local x = math.pi * frequency * mass * cos_theta / acoustics.RHO_C
		return 1 / (1 + x * x)
	end

	local limp = acoustics.LimpTransmission

	local function chain(frequency, count, mass, cosines, gaps, cos_override, speed)
		local min_cos = math.cos(acoustics.MAX_INCIDENCE)
		local c = math.max(cos_override or cosines[1], min_cos)
		local total = mass[1]
		local tau = limp(frequency, total, c)

		for i = 2, count do
			c = math.max(cos_override or cosines[i], min_cos)
			local m = mass[i]
			local combined = tau * limp(frequency, total + m, c) / limp(frequency, total, c)
			local gap = gaps[i]

			if gap > 0 and total > 0 and m > 0 then
				local resonance = math.sqrt(acoustics.RHO_C2 * (total + m) / (gap * total * m)) / (2 * math.pi)

				if frequency > resonance then
					local coupling = math.min(4 * math.pi * frequency * gap / speed, 2)
					tau = math.min(tau * limp(frequency, m, c) / (coupling * coupling), combined)
				else
					tau = combined
				end
			else
				tau = combined
			end

			total = total + m
		end

		return tau
	end

	function acoustics.ChainTransmission(count, mass, cosines, gaps, speed, out, field)
		local u_max = 1 - math.cos(acoustics.MAX_INCIDENCE) ^ 2
		local samples = acoustics.FIELD_SAMPLES

		for b = 1, 3 do
			local sum = 0

			for k = 1, 3 do
				local frequency = frequencies[(b - 1) * 3 + k]

				if field then
					for i = 1, samples do
						sum = sum + chain(
								frequency,
								count,
								mass,
								cosines,
								gaps,
								math.sqrt(1 - u_max * (i - 0.5) / samples),
								speed
							) / samples
					end
				else
					sum = sum + chain(frequency, count, mass, cosines, gaps, nil, speed)
				end
			end

			out[b] = sum / 3
		end

		return out
	end
end

function acoustics.DiffractionGain(detour, speed, out)
	local frequencies = acoustics.BAND_FREQUENCIES
	local cap = acoustics.DIFFRACTION_CAP_DB

	if detour >= acoustics.DETOUR_NONE then
		out[1], out[2], out[3] = 0, 0, 0
		return out
	end

	for b = 1, 3 do
		local sum = 0

		for k = 1, 3 do
			local x = math.sqrt(2 * math.pi * 2 * math.max(detour, 0) * frequencies[(b - 1) * 3 + k] / speed)
			local loss = x < 1e-4 and 5 or 5 + 20 * math.log10(x / math.tanh(x))
			sum = sum + 10 ^ (-math.min(loss, cap) / 10)
		end

		out[b] = sum / 3
	end

	return out
end

function acoustics.NewTransmission()
	return {1, 1, 1, solid = 0, leaves = 0, rain = {0, 0, 0}, wind = {0, 0, 0}}
end

do
	local mass, cosines, gaps = {}, {}, {}

	function acoustics.Transmit(tracer, ox, oy, oz, dx, dy, dz, tmin, tmax, speed, out)
		local step = acoustics.LEAF_STEP
		local count, t, last_end, solid = 0, tmin, tmin, 0
		out.exit = nil

		while count < acoustics.MAX_LEAVES and t < tmax do
			local d, nx, ny, nz, material, front, exit = tracer:Trace(ox, oy, oz, dx, dy, dz, t, tmax)

			if not d then break end

			local density, surface_mass = material.density, material.surface_mass
			local r1, r2, r3 = material.rain[1], material.rain[2], material.rain[3]
			local w1, w2, w3 = material.wind[1], material.wind[2], material.wind[3]
			local m, e = surface_mass, d
			local ex, ey, ez = -nx, -ny, -nz

			if exit then
				e = math.min(exit, tmax)
				m = density * (e - d)
				solid = solid + e - d
			elseif front then
				local back, bx, by, bz, back_material, back_front = tracer:Trace(ox, oy, oz, dx, dy, dz, d + step, tmax)

				if back and back_front == false then
					e = back
					m = density * (back - d)
					solid = solid + back - d
					ex, ey, ez = -bx, -by, -bz
					r1, r2, r3 = back_material.rain[1], back_material.rain[2], back_material.rain[3]
					w1, w2, w3 = back_material.wind[1], back_material.wind[2], back_material.wind[3]
				end
			end

			count = count + 1
			mass[count] = m
			cosines[count] = math.abs(nx * dx + ny * dy + nz * dz)
			gaps[count] = d - last_end
			last_end = e
			t = e + step
			out.exit, out.nx, out.ny, out.nz = e, ex, ey, ez
			out.rain[1], out.rain[2], out.rain[3] = r1, r2, r3
			out.wind[1], out.wind[2], out.wind[3] = w1, w2, w3
		end

		out.solid = solid
		out.leaves = count

		if count == 0 then
			out[1], out[2], out[3] = 1, 1, 1
			return out
		end

		acoustics.ChainTransmission(count, mass, cosines, gaps, speed, out)
		return out
	end
end

function acoustics.NewStats()
	return {
		rays = 0,
		hits = 0,
		escapes = 0,
		segment = 0,
		volume = 0,
		log_reflect = {0, 0, 0},
		last_throughput = {0, 0, 0},
		last_throughput_length = {0, 0, 0},
		settled_throughput = {0, 0, 0},
		settled_first = {0, 0, 0},
		settled_final = {0, 0, 0},
		settled_length = {0, 0, 0},
		settled_path = {0, 0, 0},
		settled_escape = {0, 0, 0},
		settled_rain = {0, 0, 0},
		settled_wind = {0, 0, 0},
	}
end

function acoustics.NewSourceSums()
	return {
		rays = 0,
		settled = {0, 0, 0},
		late = {0, 0, 0},
		moment = {0, 0, 0},
		moment2 = {0, 0, 0},
		direction = {0, 0, 0},
	}
end

function acoustics.CopySourceSums(from)
	local sums = acoustics.NewSourceSums()
	acoustics.AddSourceSums(sums, from, from.rays)
	return sums
end

function acoustics.DecayStats(stats, factor)
	stats.rays = stats.rays * factor
	stats.hits = stats.hits * factor
	stats.escapes = stats.escapes * factor
	stats.segment = stats.segment * factor
	stats.volume = stats.volume * factor

	for b = 1, 3 do
		stats.log_reflect[b] = stats.log_reflect[b] * factor
		stats.last_throughput[b] = stats.last_throughput[b] * factor
		stats.last_throughput_length[b] = stats.last_throughput_length[b] * factor
		stats.settled_throughput[b] = stats.settled_throughput[b] * factor
		stats.settled_first[b] = stats.settled_first[b] * factor
		stats.settled_final[b] = stats.settled_final[b] * factor
		stats.settled_length[b] = stats.settled_length[b] * factor
		stats.settled_path[b] = stats.settled_path[b] * factor
		stats.settled_escape[b] = stats.settled_escape[b] * factor
		stats.settled_rain[b] = stats.settled_rain[b] * factor
		stats.settled_wind[b] = stats.settled_wind[b] * factor
	end
end

function acoustics.AddStats(into, from)
	into.rays = into.rays + from.rays
	into.hits = into.hits + from.hits
	into.escapes = into.escapes + from.escapes
	into.segment = into.segment + from.segment
	into.volume = into.volume + from.volume

	for b = 1, 3 do
		into.log_reflect[b] = into.log_reflect[b] + from.log_reflect[b]
		into.last_throughput[b] = into.last_throughput[b] + from.last_throughput[b]
		into.last_throughput_length[b] = into.last_throughput_length[b] + from.last_throughput_length[b]
		into.settled_throughput[b] = into.settled_throughput[b] + from.settled_throughput[b]
		into.settled_first[b] = into.settled_first[b] + from.settled_first[b]
		into.settled_final[b] = into.settled_final[b] + from.settled_final[b]
		into.settled_length[b] = into.settled_length[b] + from.settled_length[b]
		into.settled_path[b] = into.settled_path[b] + from.settled_path[b]
		into.settled_escape[b] = into.settled_escape[b] + from.settled_escape[b]
		into.settled_rain[b] = into.settled_rain[b] + from.settled_rain[b]
		into.settled_wind[b] = into.settled_wind[b] + from.settled_wind[b]
	end
end

function acoustics.ScaleSourceSums(sums, factor)
	for b = 1, 3 do
		sums.late[b] = sums.late[b] * factor
		sums.moment[b] = sums.moment[b] * factor
		sums.moment2[b] = sums.moment2[b] * factor
		sums.settled[b] = sums.settled[b] * factor
		sums.direction[b] = sums.direction[b] * factor
	end
end

function acoustics.DecaySourceSums(sums, factor)
	sums.rays = sums.rays * factor

	for b = 1, 3 do
		sums.late[b] = sums.late[b] * factor
		sums.moment[b] = sums.moment[b] * factor
		sums.moment2[b] = sums.moment2[b] * factor
		sums.settled[b] = sums.settled[b] * factor
		sums.direction[b] = sums.direction[b] * factor
	end
end

function acoustics.AddSourceSums(into, from, rays)
	into.rays = into.rays + rays

	for b = 1, 3 do
		into.late[b] = into.late[b] + from.late[b]
		into.moment[b] = into.moment[b] + from.moment[b]
		into.moment2[b] = into.moment2[b] + from.moment2[b]
		into.settled[b] = into.settled[b] + from.settled[b]
		into.direction[b] = into.direction[b] + from.direction[b]
	end
end

function acoustics.ComputeProfile(stats, speed)
	local profile = {t60 = {}, survival = {}, tail_survival = {}, tail_path = {}}
	local segments = stats.hits + stats.escapes

	if stats.hits < 0.5 or segments <= 0 then
		profile.mean_free_path = acoustics.OPEN_DISTANCE
		profile.volume = 4 / 3 * math.pi * acoustics.OPEN_DISTANCE ^ 3
		profile.predelay = 0.08
		profile.openness = 1

		for b = 1, 3 do
			profile.t60[b] = acoustics.MIN_T60
			profile.survival[b] = 0
			profile.tail_survival[b] = 0
			profile.tail_path[b] = acoustics.OPEN_DISTANCE
		end

		return profile
	end

	local mean_free_path = stats.segment / stats.hits
	local hit_probability = stats.hits / segments

	for b = 1, 3 do
		local reflect = math.exp(stats.log_reflect[b] / stats.hits)
		local survival = math.min(
			hit_probability * reflect * math.exp(-acoustics.AirEnergyPerMeter(b) * mean_free_path),
			0.9995
		)
		profile.survival[b] = survival
		local kappa = -math.log(math.max(survival, 1e-9)) / mean_free_path
		profile.t60[b] = math.clamp(13.82 / (speed * kappa), acoustics.MIN_T60, acoustics.MAX_T60)
		local settled = stats.settled_throughput[b]
		local before_final = settled - stats.settled_final[b]

		if before_final > 0 then
			local tail_path = stats.settled_length[b] / settled
			profile.tail_path[b] = tail_path
			profile.tail_survival[b] = math.min(
				(
						settled - stats.settled_first[b]
					) / before_final * math.exp(-acoustics.AirEnergyPerMeter(b) * tail_path),
				0.9995
			)
		else
			profile.tail_path[b] = mean_free_path
			profile.tail_survival[b] = survival
		end
	end

	profile.mean_free_path = mean_free_path
	profile.volume = stats.rays > 0 and stats.volume / stats.rays or 0
	profile.predelay = math.clamp(1.5 * mean_free_path / speed, 0.005, 0.08)
	profile.openness = 1 - hit_probability
	return profile
end

-- the per bounce yield is measured at the settled bounces, the completion starts at the last one: air takes the path in between
function acoustics.TailAirLoss(stats, band)
	local settled, last = stats.settled_throughput[band], stats.last_throughput[band]

	if settled <= 0 or last <= 0 then return 1 end

	local extra = stats.last_throughput_length[band] / last - stats.settled_path[band] / settled
	return math.exp(-acoustics.AirEnergyPerMeter(band) * math.max(extra, 0))
end

function acoustics.ComputeSourceReverb(sums, stats, profile, direct_time, speed)
	local result = {energy = {}, t60 = {}, delay = 0}

	if sums.rays <= 0 or stats.rays <= 0 then return nil end

	for b = 1, 3 do
		local throughput = stats.settled_throughput[b] / stats.rays
		local per_bounce = throughput > 0 and
			(
				sums.settled[b] / sums.rays
			) / throughput * acoustics.TailAirLoss(stats, b)
			or
			0
		local survival = math.min(profile.tail_survival[b], 0.995)
		local geometric = survival / (1 - survival)
		local last = stats.last_throughput[b] / stats.rays
		local last_length = stats.last_throughput_length[b] / stats.rays
		local energy = sums.late[b] / sums.rays + last * per_bounce * geometric
		local first_time = last_length / speed - direct_time * last
		local step = profile.tail_path[b] / speed
		local one = survival / (1 - survival) ^ 2
		local two = survival * (1 + survival) / (1 - survival) ^ 3
		local moment = sums.moment[b] / sums.rays + per_bounce * (
				first_time * geometric + last * step * one
			)
		local moment2 = sums.moment2[b] / sums.rays + per_bounce * (
				(
					last > 0 and
					first_time * first_time / last or
					0
				) * geometric + 2 * step * first_time * one + step * step * last * two
			)
		result.energy[b] = energy

		if energy > 0 then
			local mean = moment / energy
			local spread = math.sqrt(math.max(moment2 / energy - mean * mean, 0))
			local excess = math.max(mean - profile.predelay, 0)
			local decay = math.lerp(
				math.clamp(
					(
							spread / math.max(excess, 1e-6) - acoustics.ECHO_SPREAD_MIN
						) / (
							acoustics.ECHO_SPREAD_MAX - acoustics.ECHO_SPREAD_MIN
						),
					0,
					1
				),
				spread,
				excess
			)

			if b == 2 then
				result.delay = math.min(
					math.max(excess - decay, 0),
					acoustics.MAX_TAIL_DELAY_PATHS * profile.mean_free_path / speed
				)
			end

			decay = math.min(decay, step / -math.log(survival))
			result.t60[b] = math.clamp(13.82 * decay, acoustics.MIN_T60, acoustics.MAX_T60)
		else
			result.t60[b] = profile.t60[b]
		end
	end

	return result
end

function acoustics.DiffuseEnergy(profile, distance, speed)
	local t60 = profile.t60[2]
	local volume = math.max(profile.volume, 1)
	return 16 * math.pi * t60 / (
			0.161 * volume
		) * math.exp(-13.82 * distance / (speed * t60))
end

function acoustics.FibonacciDirection(i, count, rotation)
	local z = 1 - 2 * (i + 0.5) / count
	local r = math.sqrt(math.max(0, 1 - z * z))
	local phi = i * 2.399963229728653
	local x, y = math.cos(phi) * r, math.sin(phi) * r
	local m = rotation
	return m[1] * x + m[2] * y + m[3] * z,
	m[4] * x + m[5] * y + m[6] * z,
	m[7] * x + m[8] * y + m[9] * z
end

function acoustics.RandomRotation(random)
	local u1, u2, u3 = random(), random(), random()
	local a = math.sqrt(1 - u1)
	local b = math.sqrt(u1)
	local qx = a * math.sin(2 * math.pi * u2)
	local qy = a * math.cos(2 * math.pi * u2)
	local qz = b * math.sin(2 * math.pi * u3)
	local qw = b * math.cos(2 * math.pi * u3)
	return {
		1 - 2 * (
			qy * qy + qz * qz
		),
		2 * (
			qx * qy - qz * qw
		),
		2 * (
			qx * qz + qy * qw
		),
		2 * (
			qx * qy + qz * qw
		),
		1 - 2 * (
			qx * qx + qz * qz
		),
		2 * (
			qy * qz - qx * qw
		),
		2 * (
			qx * qz - qy * qw
		),
		2 * (
			qy * qz + qx * qw
		),
		1 - 2 * (
			qx * qx + qy * qy
		),
	}
end

function acoustics.CosineDirection(nx, ny, nz, u1, u2)
	local r = math.sqrt(u1)
	local phi = 2 * math.pi * u2
	local x, y = r * math.cos(phi), r * math.sin(phi)
	local z = math.sqrt(math.max(0, 1 - u1))
	local tx, ty, tz

	if math.abs(nx) > 0.5 then
		tx, ty, tz = -ny, nx, 0
	else
		tx, ty, tz = 0, -nz, ny
	end

	local tl = math.sqrt(tx * tx + ty * ty + tz * tz)
	tx, ty, tz = tx / tl, ty / tl, tz / tl
	local bx, by, bz = ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
	return tx * x + bx * y + nx * z,
	ty * x + by * y + ny * z,
	tz * x + bz * y + nz * z
end

do
	local w = {1, 1, 1}
	local a, sc = {0, 0, 0}, {0, 0, 0}
	local rain, wind = {0, 0, 0}, {0, 0, 0}
	local air = {0, 0, 0}
	local wall = acoustics.NewTransmission()
	local surface = acoustics.NewMaterial({0, 0, 0}, {0, 0, 0}, 0, 0, {0, 0, 0}, {0, 0, 0})

	local function exposed(tracer, px, py, pz, ux, uy, uz, distance)
		return not tracer:Trace(px, py, pz, ux, uy, uz, 0, distance)
	end

	-- radiance per band of a surface hit seen from the ray, rain and wind added into rain/wind scaled by scale
	local function gather_surface(tracer, job, material, hx, hy, hz, nx, ny, nz, scale_1, scale_2, scale_3)
		local offset = acoustics.SURFACE_OFFSET
		local px, py, pz = hx + nx * offset, hy + ny * offset, hz + nz * offset
		local up = job.rain_up
		local flux = nx * up.x + ny * up.y + nz * up.z
		local r1, r2, r3 = material.rain[1], material.rain[2], material.rain[3]
		local e1, e2, e3 = material.wind[1], material.wind[2], material.wind[3]

		if flux > 0 and r1 + r2 + r3 > 0 then
			if exposed(tracer, px, py, pz, up.x, up.y, up.z, acoustics.OPEN_DISTANCE) then
				rain[1] = rain[1] + scale_1 * r1 * flux
				rain[2] = rain[2] + scale_2 * r2 * flux
				rain[3] = rain[3] + scale_3 * r3 * flux
			end
		end

		local upwind = job.upwind

		if upwind and e1 + e2 + e3 > 0 then
			if exposed(tracer, px, py, pz, upwind.x, upwind.y, upwind.z, acoustics.WIND_SHELTER) then
				wind[1] = wind[1] + scale_1 * e1
				wind[2] = wind[2] + scale_2 * e2
				wind[3] = wind[3] + scale_3 * e3
			end
		end
	end

	local function gather_escape(job, dx, dy, dz, scale_1, scale_2, scale_3)
		local up = job.rain_up

		if dx * up.x + dy * up.y + dz * up.z < 0 then
			local r = acoustics.DEFAULT_MATERIAL.rain
			rain[1] = rain[1] + scale_1 * r[1]
			rain[2] = rain[2] + scale_2 * r[2]
			rain[3] = rain[3] + scale_3 * r[3]
		end
	end

	local function gather_through_wall(tracer, job, px, py, pz, dx, dy, dz)
		acoustics.Transmit(tracer, px, py, pz, dx, dy, dz, 0, acoustics.WALL_SEARCH, job.speed, wall)

		if not wall.exit then return end

		local t1, t2, t3 = w[1] * wall[1], w[2] * wall[2], w[3] * wall[3]
		local offset = acoustics.SURFACE_OFFSET
		local ex, ey, ez = px + dx * wall.exit, py + dy * wall.exit, pz + dz * wall.exit
		local up = job.rain_up
		local flux = wall.nx * up.x + wall.ny * up.y + wall.nz * up.z
		local r = wall.rain

		if
			flux > 0 and
			exposed(
				tracer,
				ex + wall.nx * offset,
				ey + wall.ny * offset,
				ez + wall.nz * offset,
				up.x,
				up.y,
				up.z,
				acoustics.OPEN_DISTANCE
			)
		then
			rain[1] = rain[1] + t1 * r[1] * flux
			rain[2] = rain[2] + t2 * r[2] * flux
			rain[3] = rain[3] + t3 * r[3] * flux
		end

		local start = wall.exit + acoustics.LEAF_STEP
		local distance, nx, ny, nz, material = tracer:Trace(px, py, pz, dx, dy, dz, start, acoustics.TRACE_DISTANCE)

		if not distance or distance > acoustics.OPEN_DISTANCE then
			gather_escape(job, dx, dy, dz, t1, t2, t3)
		else
			gather_surface(
				tracer,
				job,
				material,
				px + dx * distance,
				py + dy * distance,
				pz + dz * distance,
				nx,
				ny,
				nz,
				t1,
				t2,
				t3
			)
		end
	end

	function acoustics.PathTrace(tracer, job, result)
		local lx, ly, lz = job.listener.x, job.listener.y, job.listener.z
		local speed = job.speed
		local stats = result.stats
		local random = job.random
		local sources = job.sources
		local source_count = #sources
		local open = acoustics.OPEN_DISTANCE
		local offset = acoustics.SURFACE_OFFSET
		local clearance = acoustics.SOURCE_CLEARANCE
		local min_p = acoustics.MIN_SCATTER_PROBABILITY
		local rays_out = result.rays
		local ray_floats = acoustics.RAY_FLOATS
		local settled_bounce = math.floor(job.bounces / 2)

		for b = 1, 3 do
			air[b] = acoustics.AirEnergyPerMeter(b)
		end

		for ray = 0, job.rays - 1 do
			local dx, dy, dz = acoustics.FibonacciDirection(ray, job.rays, job.rotation)
			local fx, fy, fz = dx, dy, dz
			local ox, oy, oz = lx, ly, lz
			local tmin = acoustics.LISTENER_CLEARANCE
			local length = 0
			w[1], w[2], w[3] = 1, 1, 1
			rain[1], rain[2], rain[3] = 0, 0, 0
			wind[1], wind[2], wind[3] = 0, 0, 0
			stats.rays = stats.rays + 1
			local escaped = false
			local at = ray * ray_floats

			for i = 1, ray_floats do
				rays_out[at + i] = 0
			end

			for bounce = 0, job.bounces - 1 do
				local distance, nx, ny, nz, material = tracer:Trace(ox, oy, oz, dx, dy, dz, tmin, acoustics.TRACE_DISTANCE)

				if bounce == 0 then
					local d = math.min(distance or open, open)
					stats.volume = stats.volume + 4 / 3 * math.pi * d * d * d
				end

				if not distance or distance > open then
					stats.escapes = stats.escapes + 1
					escaped = true

					if job.gather then
						local before_1, before_2, before_3 = rain[1], rain[2], rain[3]
						gather_escape(job, dx, dy, dz, w[1], w[2], w[3])

						if bounce >= settled_bounce then
							stats.settled_rain[1] = stats.settled_rain[1] + rain[1] - before_1
							stats.settled_rain[2] = stats.settled_rain[2] + rain[2] - before_2
							stats.settled_rain[3] = stats.settled_rain[3] + rain[3] - before_3
						end
					end

					if bounce >= settled_bounce then
						for b = 1, 3 do
							stats.settled_escape[b] = stats.settled_escape[b] + w[b]
						end
					end

					rays_out[at + 7], rays_out[at + 8], rays_out[at + 9] = ox, oy, oz
					rays_out[at + 10], rays_out[at + 11], rays_out[at + 12] = w[1], w[2], w[3]

					break
				end

				local hx, hy, hz = ox + dx * distance, oy + dy * distance, oz + dz * distance

				for b = 1, 3 do
					surface.absorption[b] = material.absorption[b]
					surface.scattering[b] = math.min(material.scattering[b] * acoustics.scattering_scale, 1)
					surface.rain[b] = material.rain[b]
					surface.wind[b] = material.wind[b]
				end

				local cover = job.snow_cover

				if
					cover[3] > 0 and
					ny > acoustics.SNOW_MIN_SLOPE and
					exposed(tracer, hx + nx * offset, hy + ny * offset, hz + nz * offset, 0, 1, 0, open)
				then
					local snow = acoustics.SNOW

					for b = 1, 3 do
						surface.absorption[b] = math.lerp(cover[b], surface.absorption[b], snow.absorption[b])
						surface.scattering[b] = math.lerp(cover[b], surface.scattering[b], snow.scattering[b])
						surface.rain[b] = math.lerp(cover[b], surface.rain[b], snow.rain[b])
					end
				end

				material = surface
				a[1], a[2], a[3] = material.absorption[1], material.absorption[2], material.absorption[3]
				sc[1], sc[2], sc[3] = material.scattering[1], material.scattering[2], material.scattering[3]

				if bounce == 0 and ray < job.sample_count then
					local s = result.samples
					local n = #s
					s[n + 1] = hx
					s[n + 2] = hy
					s[n + 3] = hz
					s[n + 4] = nx
					s[n + 5] = ny
					s[n + 6] = nz
					s[n + 7] = distance
					s[n + 8] = math.abs(nx * dx + ny * dy + nz * dz)
					s[n + 9] = a[1]
					s[n + 10] = a[2]
					s[n + 11] = a[3]
					s[n + 12] = sc[1]
					s[n + 13] = sc[2]
					s[n + 14] = sc[3]
				end

				local rain_before_1, rain_before_2, rain_before_3 = rain[1], rain[2], rain[3]
				local wind_before_1, wind_before_2, wind_before_3 = wind[1], wind[2], wind[3]

				if job.gather then
					gather_surface(tracer, job, material, hx, hy, hz, nx, ny, nz, w[1], w[2], w[3])

					if bounce < acoustics.GATHER_WALL_BOUNCES and rain[2] == rain_before_2 then
						gather_through_wall(
							tracer,
							job,
							hx + nx * offset,
							hy + ny * offset,
							hz + nz * offset,
							dx,
							dy,
							dz
						)
					end
				end

				stats.hits = stats.hits + 1
				stats.segment = stats.segment + distance
				length = length + distance
				local settled = bounce >= settled_bounce

				if settled then
					for b = 1, 3 do
						stats.settled_throughput[b] = stats.settled_throughput[b] + w[b]
						stats.settled_length[b] = stats.settled_length[b] + w[b] * distance
						stats.settled_path[b] = stats.settled_path[b] + w[b] * length
					end

					stats.settled_rain[1] = stats.settled_rain[1] + rain[1] - rain_before_1
					stats.settled_rain[2] = stats.settled_rain[2] + rain[2] - rain_before_2
					stats.settled_rain[3] = stats.settled_rain[3] + rain[3] - rain_before_3
					stats.settled_wind[1] = stats.settled_wind[1] + wind[1] - wind_before_1
					stats.settled_wind[2] = stats.settled_wind[2] + wind[2] - wind_before_2
					stats.settled_wind[3] = stats.settled_wind[3] + wind[3] - wind_before_3

					if bounce == settled_bounce then
						for b = 1, 3 do
							stats.settled_first[b] = stats.settled_first[b] + w[b]
						end
					end

					if bounce == job.bounces - 1 then
						for b = 1, 3 do
							stats.settled_final[b] = stats.settled_final[b] + w[b]
						end
					end
				end

				for b = 1, 3 do
					stats.log_reflect[b] = stats.log_reflect[b] + math.log(math.max(1 - a[b], 1e-6))
				end

				local px, py, pz = hx + nx * offset, hy + ny * offset, hz + nz * offset

				for s = 1, source_count do
					local source = sources[s]
					local sx, sy, sz = source.x - px, source.y - py, source.z - pz
					local d2 = sx * sx + sy * sy + sz * sz
					local d = math.sqrt(d2)
					local cos_s = (sx * nx + sy * ny + sz * nz) / math.max(d, 1e-6)

					if cos_s > 0 and d > clearance then
						local inv = 1 / d

						if not tracer:Trace(px, py, pz, sx * inv, sy * inv, sz * inv, 0, d - clearance) then
							local sums = result.sources[s]
							local total = length + d
							local t = total / speed - job.direct_time[s]
							local base = 4 * cos_s / math.max(d2, acoustics.MIN_SOURCE_DISTANCE ^ 2)
							local late = (bounce > 0 or job.emitter) and t > job.split_time

							for b = 1, 3 do
								local e = base * w[b] * (1 - a[b]) * math.exp(-air[b] * total)

								if late then
									sums.late[b] = sums.late[b] + e
									sums.moment[b] = sums.moment[b] + e * t
									sums.moment2[b] = sums.moment2[b] + e * t * t
								end

								if settled then sums.settled[b] = sums.settled[b] + e end
							end

							if late then
								local e = base * w[2] * (1 - a[2]) * math.exp(-air[2] * total)

								if job.emitter then
									sums.direction[1] = sums.direction[1] - e * sx * inv
									sums.direction[2] = sums.direction[2] - e * sy * inv
									sums.direction[3] = sums.direction[3] - e * sz * inv
								else
									sums.direction[1] = sums.direction[1] + e * fx
									sums.direction[2] = sums.direction[2] + e * fy
									sums.direction[3] = sums.direction[3] + e * fz
								end
							end
						end
					end
				end

				for b = 1, 3 do
					w[b] = w[b] * (1 - a[b])
				end

				ox, oy, oz = px, py, pz
				tmin = 0
				local p = math.clamp(sc[2], min_p, 1 - min_p)

				if random() < p then
					dx, dy, dz = acoustics.CosineDirection(nx, ny, nz, random(), random())

					for b = 1, 3 do
						w[b] = w[b] * sc[b] / p
					end
				else
					local k = 2 * (dx * nx + dy * ny + dz * nz)
					dx, dy, dz = dx - k * nx, dy - k * ny, dz - k * nz

					for b = 1, 3 do
						w[b] = w[b] * (1 - sc[b]) / (1 - p)
					end
				end
			end

			if not escaped then
				for b = 1, 3 do
					stats.last_throughput[b] = stats.last_throughput[b] + w[b]
					stats.last_throughput_length[b] = stats.last_throughput_length[b] + w[b] * length
				end
			end

			rays_out[at + 1], rays_out[at + 2], rays_out[at + 3] = rain[1], rain[2], rain[3]
			rays_out[at + 4], rays_out[at + 5], rays_out[at + 6] = wind[1], wind[2], wind[3]
		end
	end
end

do
	local transmission = acoustics.NewTransmission()

	function acoustics.RunQueries(tracer, job, result)
		local q = job.queries
		local out = result.queries
		local stride = acoustics.QUERY_INPUT_FLOATS

		for i = 0, job.query_count - 1 do
			local at = i * stride
			local ox, oy, oz, tmin = q[at + 1], q[at + 2], q[at + 3], q[at + 4]
			local dx, dy, dz, tmax = q[at + 5], q[at + 6], q[at + 7], q[at + 8]
			local distance, nx, ny, nz, material = tracer:Trace(ox, oy, oz, dx, dy, dz, tmin, tmax)
			local o = i * acoustics.QUERY_FLOATS
			out[o + 1] = distance or -1
			out[o + 2] = nx or 0
			out[o + 3] = ny or 0
			out[o + 4] = nz or 0
			out[o + 5] = material and material.absorption[1] or 0
			out[o + 6] = material and material.absorption[2] or 0
			out[o + 7] = material and material.absorption[3] or 0
			out[o + 8] = material and
				math.min(material.scattering[2] * acoustics.scattering_scale, 1) or
				0
			out[o + 9], out[o + 10], out[o + 11], out[o + 12] = 1, 1, 1, 0

			if distance and q[at + 9] ~= 0 then
				acoustics.Transmit(tracer, ox, oy, oz, dx, dy, dz, tmin, tmax, job.speed, transmission)
				out[o + 9], out[o + 10], out[o + 11] = transmission[1], transmission[2], transmission[3]
				out[o + 12] = transmission.solid
			end
		end
	end
end

function acoustics.NewResult(job)
	local result = {
		stats = acoustics.NewStats(),
		sources = {},
		samples = {},
		queries = {},
		rays = {},
	}

	for i = 1, #job.sources do
		result.sources[i] = acoustics.NewSourceSums()
	end

	return result
end

local function octahedral_key(nx, ny, nz, cells)
	local l = math.abs(nx) + math.abs(ny) + math.abs(nz)
	local u, v = nx / l, ny / l

	if nz < 0 then
		u, v = (1 - math.abs(v)) * (u >= 0 and 1 or -1), (1 - math.abs(u)) * (v >= 0 and 1 or -1)
	end

	return math.floor((u * 0.5 + 0.5) * cells + 0.5),
	math.floor((v * 0.5 + 0.5) * cells + 0.5)
end

local function add_query(job, ox, oy, oz, dx, dy, dz, tmin, tmax, transmit)
	local q = job.queries
	local at = job.query_count * acoustics.QUERY_INPUT_FLOATS
	q[at + 1], q[at + 2], q[at + 3], q[at + 4] = ox, oy, oz, tmin
	q[at + 5], q[at + 6], q[at + 7], q[at + 8] = dx, dy, dz, tmax
	q[at + 9], q[at + 10], q[at + 11], q[at + 12] = transmit and 1 or 0, 0, 0, 0
	job.query_count = job.query_count + 1
	return job.query_count - 1
end

local function add_segment(job, a, b, tmin, trim, transmit)
	local d = b - a
	local length = d:GetLength()
	d = d / length
	return add_query(job, a.x, a.y, a.z, d.x, d.y, d.z, tmin, math.max(length - trim, tmin), transmit)
end

local function perpendicular(axis)
	local t = math.abs(axis.x) > 0.5 and Vec3(-axis.y, axis.x, 0) or Vec3(0, -axis.z, axis.y)
	t = t:GetNormalized()
	return t, axis:GetCross(t)
end

local function reflector_plane(reflector)
	local n = Vec3(reflector.normal[1], reflector.normal[2], reflector.normal[3]):GetNormalized()
	local p = Vec3(reflector.position[1], reflector.position[2], reflector.position[3]) / reflector.count
	return n, n:GetDot(p)
end

local function reflection_point(listener, source, n, offset)
	local ls = listener:GetDot(n) - offset
	local ss = source:GetDot(n) - offset

	if ls <= 0.05 or ss <= 0.05 then return end

	local image = source - n * (2 * ss)
	local to_image = image - listener
	local denom = n:GetDot(to_image)

	if math.abs(denom) < 1e-6 then return end

	local t = (offset - listener:GetDot(n)) / denom

	if t <= 0 or t >= 1 then return end

	return listener + to_image * t, image
end

local function by_importance(a, b)
	return a.importance > b.importance
end

local function by_count(a, b)
	return a.count > b.count
end

local function by_gain(a, b)
	return math.abs(a.gain) > math.abs(b.gain)
end

local function by_energy(a, b)
	return a.energy > b.energy
end

local META = {}
META.__index = META

function acoustics.New(audio, tracer)
	local self = setmetatable({}, META)
	self.audio = audio
	self.tracer = tracer
	self.stats = acoustics.NewStats()
	self.reflectors = {}
	self.reflector_scale = 1
	self.reflector_candidates = {}
	self.reflector_culled = 0
	self.openings = {}
	self.ambience = acoustics.NewAmbience()
	self.random = math.random
	self.frame = 0
	self.profile = acoustics.ComputeProfile(self.stats, audio.speed_of_sound)
	self.ambient = acoustics.NewSourceSums()
	self.remote = {t60 = {0.5, 0.5, 0.5}, predelay = 0.02}
	self.last_time = nil
	return self
end

function acoustics.NewAmbience()
	local ambience = {
		rays = 0,
		rain = {0, 0, 0},
		wind = {0, 0, 0},
		bins = {},
	}
	local cells = acoustics.AMBIENCE_CELLS + 1

	for i = 1, cells * cells do
		ambience.bins[i] = {rain = {0, 0, 0}, wind = {0, 0, 0}, x = 0, y = 0, z = 0}
	end

	return ambience
end

function META:GetEnvironment(sound)
	local env = sound.audio_environment

	if not env then
		env = {
			sums = acoustics.NewSourceSums(),
			visibility = {1, 1, 1},
			visibility_samples = {0, 0, 0},
			transmission = {1, 1, 1},
			transmission_samples = 0,
			direct = 1,
			detour = 0,
			diffraction = {1, 1, 1},
			solid = 0,
			occlusion = {1, 1, 1},
			reflections = {},
			tap_keys = {},
			taps = {},
			tap_band = {1, 1, 1},
			send = {0, 0},
		}
		sound.audio_environment = env
		sound.audio_occlusion = env.occlusion
	end

	return env
end

function META:SelectSources(budget)
	local audio = self.audio
	local list = {}

	for _, sound in pairs(audio.active_sounds) do
		if
			sound:IsSpatial() and
			sound:IsTraced() and
			sound.slot and
			audio.state.slots[sound.slot].active
		then
			local distance = (sound:GetPosition() - audio.listener_position):GetLength()
			list[#list + 1] = {
				sound = sound,
				importance = sound:GetMixVolume() * sound:GetReferenceDistance() / math.max(distance, sound:GetReferenceDistance()),
			}
		end
	end

	table.sort(list, by_importance)
	local sounds = {}
	local members = {}
	local reach = math.min(acoustics.CLUSTER_DISTANCE, acoustics.CLUSTER_FREE_PATH * self.profile.mean_free_path)

	for _, entry in ipairs(list) do
		local position = entry.sound:GetPosition()
		local joined = false

		for i, sound in ipairs(sounds) do
			if (sound:GetPosition() - position):GetLength() <= reach then
				members[i][#members[i] + 1] = entry.sound
				joined = true

				break
			end
		end

		if not joined and #sounds < budget then
			sounds[#sounds + 1] = entry.sound
			members[#sounds] = {}
		end
	end

	return sounds, members
end

function META:GetEmitterReach()
	return math.min(
		math.max(acoustics.EMITTER_DISTANCE, acoustics.EMITTER_FREE_PATH * self.profile.mean_free_path),
		acoustics.EMITTER_MAX_DISTANCE
	)
end

function META:SelectEmitter()
	local audio = self.audio
	local reach = self:GetEmitterReach()
	local best, best_score

	for _, sound in pairs(audio.active_sounds) do
		if
			sound:IsSpatial() and
			sound:IsTraced() and
			sound.slot and
			audio.state.slots[sound.slot].active
		then
			local distance = (sound:GetPosition() - audio.listener_position):GetLength()

			if distance > reach then
				local env = self:GetEnvironment(sound)
				local score = sound:GetMixVolume() * sound:GetReferenceDistance() / distance + (
						env.emitter and
						0 or
						1e9
					) - (
						env.emitter and
						env.emitter.time or
						0
					) * 1e-3

				if not best_score or score > best_score then best, best_score = sound, score end
			end
		end
	end

	return best
end

function META:BuildEmitterJob(sound, time)
	local audio = self.audio
	local budget = self.tracer.budget
	local origin = sound:GetPosition():Copy()
	local target = audio.listener_position:Copy()
	local speed = audio.speed_of_sound
	local env = self:GetEnvironment(sound)
	local profile = env.emitter and env.emitter.profile or self.profile
	return {
		time = time,
		listener = origin,
		emitter = sound,
		speed = speed,
		rays = budget.rays,
		bounces = budget.bounces,
		sample_count = 0,
		rotation = acoustics.RandomRotation(self.random),
		random = self.random,
		seed = math.floor(self.random() * 2147483647),
		sources = {target},
		sounds = {},
		members = {},
		direct_time = {(target - origin):GetLength() / speed},
		split_time = profile.predelay,
		queries = {},
		query_count = 0,
		fresnel = {},
		detours = {},
		transmissions = {},
		reflection_checks = {},
		fresnel_samples = 0,
		gather = false,
		rain_up = audio.rain_up,
		upwind = audio.upwind,
		snow_cover = acoustics.SnowCover(audio.snow_depth, speed, {}),
	}
end

function META:AbsorbEmitter(job, result)
	local env = self:GetEnvironment(job.emitter)
	local emitter = env.emitter

	if not emitter then
		emitter = {
			stats = acoustics.NewStats(),
			sums = acoustics.NewSourceSums(),
			profile = self.profile,
		}
		env.emitter = emitter
	end

	local reach = acoustics.STATS_DISTANCE * emitter.profile.mean_free_path
	local dt = emitter.time and math.max(job.time - emitter.time, 0) or 0
	local moved = emitter.origin and (job.listener - emitter.origin):GetLength() / reach or 0
	local target_moved = emitter.target and (job.sources[1] - emitter.target):GetLength() / reach or 0
	local decay = math.exp(-dt / acoustics.STATS_MEMORY - moved - target_moved)
	acoustics.DecayStats(emitter.stats, decay)
	acoustics.AddStats(emitter.stats, result.stats)
	emitter.profile = acoustics.ComputeProfile(emitter.stats, job.speed)
	acoustics.DecaySourceSums(emitter.sums, decay)
	acoustics.AddSourceSums(emitter.sums, result.sources[1], job.rays)
	emitter.reverb = acoustics.ComputeSourceReverb(emitter.sums, emitter.stats, emitter.profile, job.direct_time[1], job.speed)
	emitter.time = job.time
	emitter.origin = job.listener:Copy()
	emitter.target = job.sources[1]:Copy()
end

function META:BuildJob(time)
	local audio = self.audio
	local budget = self.tracer.budget
	local listener = audio.listener_position:Copy()
	local speed = audio.speed_of_sound
	local sounds, members = self:SelectSources(budget.sources)
	local job = {
		time = time,
		listener = listener,
		speed = speed,
		rays = budget.rays,
		bounces = budget.bounces,
		sample_count = budget.samples,
		rotation = acoustics.RandomRotation(self.random),
		random = self.random,
		seed = math.floor(self.random() * 2147483647),
		sources = {},
		sounds = sounds,
		members = members,
		direct_time = {},
		split_time = self.profile.predelay,
		queries = {},
		query_count = 0,
		fresnel = {},
		detours = {},
		transmissions = {},
		reflection_checks = {},
		gather = audio.trace_ambience,
		rain_up = audio.rain_up,
		upwind = audio.upwind,
		snow_cover = acoustics.SnowCover(audio.snow_depth, speed, {}),
	}
	job.fresnel_samples = budget.fresnel

	for i, sound in ipairs(job.sounds) do
		local position = sound:GetPosition():Copy()
		job.sources[i] = position
		job.direct_time[i] = (position - listener):GetLength() / speed
		self:AddFresnelQueries(job, sound, position, budget.fresnel)
		self:AddDetourQueries(job, sound, position, budget.fresnel * acoustics.DETOUR_SAMPLES)

		for _, member in ipairs(members[i]) do
			local member_position = member:GetPosition():Copy()
			self:AddFresnelQueries(job, member, member_position, budget.fresnel)
			self:AddDetourQueries(job, member, member_position, budget.fresnel * acoustics.DETOUR_SAMPLES)
		end
	end

	job.sources[#job.sounds + 1] = listener
	job.direct_time[#job.sounds + 1] = 0
	local reflectors = self:GetTopReflectors()
	local count = #job.sounds

	if count > 0 then
		local first = budget.reflection_sources >= count and 1 or (self.frame % count) + 1

		for k = 0, math.min(budget.reflection_sources, count) - 1 do
			local i = (first - 1 + k) % count + 1
			self:AddReflectionQueries(job, job.sounds[i], job.sources[i], reflectors)
		end
	end

	return job
end

function META:AddDetourQueries(job, sound, source, samples)
	local listener = job.listener
	local axis = source - listener
	local distance = axis:GetLength()

	if distance < acoustics.SOURCE_CLEARANCE + acoustics.LISTENER_CLEARANCE + 0.1 then
		return
	end

	axis = axis / distance
	local t, b = perpendicular(axis)
	local min_radius = acoustics.DETOUR_MIN_RADIUS
	local max_radius = math.max(acoustics.DETOUR_MAX_RADIUS * distance, acoustics.DETOUR_MIN_REACH)
	local best = self:GetEnvironment(sound).detour_sample

	for i = 1, samples do
		local u, angle, radius
		-- half the samples straddle the shortest clear detour so far, so the estimate settles on the edge and keeps confirming it
		local refine = best and i % 2 == 0

		if refine then
			u = math.clamp(best.u + (self.random() - 0.5) * 0.1, 0.05, 0.95)
			angle = best.angle + (self.random() - 0.5) * 0.3
			radius = math.max(best.radius * (0.8 + 0.4 * self.random()), min_radius)
		else
			u = 0.15 + 0.7 * self.random()
			angle = self.random() * math.pi * 2
			radius = min_radius * (max_radius / min_radius) ^ self.random()
		end

		local point = listener + axis * (
				distance * u
			) + (
				t * math.cos(angle) + b * math.sin(angle)
			) * radius
		local first = add_segment(job, listener, point, acoustics.LISTENER_CLEARANCE, 0)
		add_segment(job, point, source, 0, acoustics.SOURCE_CLEARANCE)
		job.detours[#job.detours + 1] = {
			sound = sound,
			query = first,
			u = u,
			angle = angle,
			radius = radius,
			refine = refine,
			detour = (point - listener):GetLength() + (source - point):GetLength() - distance,
		}
	end
end

function META:AddFresnelQueries(job, sound, source, samples)
	local listener = job.listener
	local axis = source - listener
	local distance = axis:GetLength()

	if distance < acoustics.SOURCE_CLEARANCE + acoustics.LISTENER_CLEARANCE + 0.1 then
		return
	end

	job.transmissions[#job.transmissions + 1] = {
		sound = sound,
		query = add_segment(
			job,
			listener,
			source,
			acoustics.LISTENER_CLEARANCE,
			acoustics.SOURCE_CLEARANCE,
			true
		),
	}
	axis = axis / distance
	local t, b = perpendicular(axis)

	for band = 1, 3 do
		local wavelength = job.speed / dsp.BAND_CENTERS[band]

		for _ = 1, samples do
			local u = 0.15 + 0.7 * self.random()
			local radius = acoustics.FRESNEL_CLEARANCE * math.sqrt(wavelength * u * (1 - u) * distance) * math.sqrt(self.random())
			local angle = self.random() * math.pi * 2
			local point = listener + axis * (
					distance * u
				) + (
					t * math.cos(angle) + b * math.sin(angle)
				) * radius
			local first = add_segment(job, listener, point, acoustics.LISTENER_CLEARANCE, 0)
			add_segment(job, point, source, 0, acoustics.SOURCE_CLEARANCE)
			job.fresnel[#job.fresnel + 1] = {sound = sound, band = band, query = first}
		end
	end
end

function META:AddReflectionQueries(job, sound, source, reflectors)
	local listener = job.listener

	for _, reflector in ipairs(reflectors) do
		local n, offset = reflector_plane(reflector)
		local point = reflection_point(listener, source, n, offset)

		if point then
			local expected = (point - listener):GetLength()
			local first = add_segment(
				job,
				listener,
				point + (point - listener) / expected * 0.5,
				acoustics.LISTENER_CLEARANCE,
				0
			)
			add_segment(
				job,
				point + n * acoustics.SURFACE_OFFSET * 10,
				source,
				0,
				acoustics.SOURCE_CLEARANCE
			)
			job.reflection_checks[#job.reflection_checks + 1] = {
				sound = sound,
				key = reflector.key,
				query = first,
				expected = expected,
				normal = n,
			}
		end
	end
end

function META:GetTopReflectors()
	local list = {}
	local scale = self.reflector_scale
	local candidates = self.reflector_candidates

	for key, reflector in pairs(candidates) do
		if
			reflector.weight * scale >= acoustics.MIN_REFLECTOR_AREA and
			reflector.count * scale >= acoustics.MIN_REFLECTOR_HITS
		then
			list[#list + 1] = reflector
		else
			candidates[key] = nil
		end
	end

	table.sort(list, by_count)
	local listener = self.audio.listener_position
	local kept = {}

	for _, reflector in ipairs(list) do
		local n, offset = reflector_plane(reflector)
		local tolerance = 0.3 + 0.03 * math.abs(listener:GetDot(n) - offset)
		local duplicate = false

		for _, other in ipairs(kept) do
			if other.n:GetDot(n) > 0.97 and math.abs(other.offset - offset) < tolerance then
				duplicate = true

				break
			end
		end

		if not duplicate then
			kept[#kept + 1] = {n = n, offset = offset}
			list[#kept] = reflector

			if #kept == acoustics.MAX_REFLECTORS then break end
		end
	end

	for i = #kept + 1, #list do
		list[i] = nil
	end

	return list
end

function META:GetReflectorWeight(reflector)
	return reflector.weight * self.reflector_scale
end

function META:AbsorbReflectors(job, result, decay)
	local scale = self.reflector_scale * decay

	if scale < 1e-60 then
		for _, reflector in pairs(self.reflectors) do
			reflector.weight = reflector.weight * scale
			reflector.count = reflector.count * scale

			for i = 1, 3 do
				reflector.position[i] = reflector.position[i] * scale
				reflector.normal[i] = reflector.normal[i] * scale
				reflector.absorption[i] = reflector.absorption[i] * scale
				reflector.scattering[i] = reflector.scattering[i] * scale
			end

			for i = 1, 6 do
				reflector.spread[i] = reflector.spread[i] * scale
			end
		end

		scale = 1
	end

	self.reflector_scale = scale
	self.reflector_culled = self.reflector_culled + 1

	if self.reflector_culled >= 16 then
		self.reflector_culled = 0
		local floor = 0.01 / scale

		for key, reflector in pairs(self.reflectors) do
			if reflector.weight < floor then self.reflectors[key] = nil end
		end
	end

	local weight = 1 / scale
	local s = result.samples
	local solid_angle = 4 * math.pi / job.rays

	for at = 0, #s - 1, acoustics.SAMPLE_FLOATS do
		local px, py, pz = s[at + 1], s[at + 2], s[at + 3]
		local nx, ny, nz = s[at + 4], s[at + 5], s[at + 6]
		local distance = s[at + 7]
		local u, v = octahedral_key(nx, ny, nz, 24)
		local offset = nx * px + ny * py + nz * pz
		local cell = math.max(0.5, distance * 0.02)
		local key = (u * 25 + v) * 0x400000 + math.floor(offset / cell + 0.5) + 0x200000

		-- a degenerate triangle hit has a NaN normal, and a NaN key cannot index a table
		if key ~= key then goto continue end

		local reflector = self.reflectors[key] or self.reflectors[key - 1] or self.reflectors[key + 1]

		if not reflector then
			reflector = {
				key = key,
				weight = 0,
				count = 0,
				position = {0, 0, 0},
				normal = {0, 0, 0},
				absorption = {0, 0, 0},
				scattering = {0, 0, 0},
				spread = {0, 0, 0, 0, 0, 0},
			}
			self.reflectors[key] = reflector
		end

		reflector.weight = reflector.weight + weight * solid_angle * distance * distance / math.max(s[at + 8], 0.2) * job.rays / job.sample_count
		reflector.count = reflector.count + weight
		reflector.seen = job.time
		local spread = reflector.spread
		spread[1], spread[2], spread[3] = spread[1] + weight * px * px,
		spread[2] + weight * py * py,
		spread[3] + weight * pz * pz
		spread[4], spread[5], spread[6] = spread[4] + weight * px * py,
		spread[5] + weight * px * pz,
		spread[6] + weight * py * pz
		reflector.position[1] = reflector.position[1] + weight * px
		reflector.position[2] = reflector.position[2] + weight * py
		reflector.position[3] = reflector.position[3] + weight * pz
		reflector.normal[1] = reflector.normal[1] + weight * nx
		reflector.normal[2] = reflector.normal[2] + weight * ny
		reflector.normal[3] = reflector.normal[3] + weight * nz
		reflector.absorption[1] = reflector.absorption[1] + weight * s[at + 9]
		reflector.absorption[2] = reflector.absorption[2] + weight * s[at + 10]
		reflector.absorption[3] = reflector.absorption[3] + weight * s[at + 11]
		reflector.scattering[1] = reflector.scattering[1] + weight * s[at + 12]
		reflector.scattering[2] = reflector.scattering[2] + weight * s[at + 13]
		reflector.scattering[3] = reflector.scattering[3] + weight * s[at + 14]

		if
			reflector.weight * scale >= acoustics.MIN_REFLECTOR_AREA and
			reflector.count * scale >= acoustics.MIN_REFLECTOR_HITS
		then
			self.reflector_candidates[reflector.key] = reflector
		end

		::continue::
	end
end

function META:Absorb(job, result)
	if job.emitter then return self:AbsorbEmitter(job, result) end

	local dt = self.last_result_time and math.max(job.time - self.last_result_time, 0) or 0
	self.last_result_time = job.time
	local reach = acoustics.STATS_DISTANCE * self.profile.mean_free_path
	local moved = self.last_listener and
		(
			job.listener - self.last_listener
		):GetLength() / reach or
		0
	self.last_listener = job.listener
	local decay = math.exp(-dt / acoustics.STATS_MEMORY - moved)
	acoustics.DecayStats(self.stats, decay)
	acoustics.AddStats(self.stats, result.stats)
	self.profile = acoustics.ComputeProfile(self.stats, job.speed)

	for i, sound in ipairs(job.sounds) do
		local source = job.sources[i]

		for k = 0, #job.members[i] do
			local member = k == 0 and sound or job.members[i][k]
			local env = self:GetEnvironment(member)
			local position = k == 0 and source or member:GetPosition()
			local source_moved = env.traced and (position - env.traced):GetLength() / reach or 0
			env.traced = position:Copy()
			acoustics.DecaySourceSums(env.sums, decay * math.exp(-source_moved))
			acoustics.AddSourceSums(env.sums, result.sources[i], job.rays)
		end
	end

	self:AbsorbAmbience(job, result, decay)
	self:AbsorbOpenings(job, result, decay)
	acoustics.DecaySourceSums(self.ambient, decay)
	acoustics.AddSourceSums(self.ambient, result.sources[#job.sounds + 1], job.rays)
	self.ambient_reverb = acoustics.ComputeSourceReverb(self.ambient, self.stats, self.profile, 0, job.speed)
	self:AbsorbReflectors(job, result, math.exp(-dt / acoustics.REFLECTOR_MEMORY - moved))
	self.samples = result.samples
	self.last_job = job
	local q = result.queries
	local frame_visible = {}

	for _, check in ipairs(job.fresnel) do
		if check.query + 1 >= job.query_count then break end

		local at = check.query * acoustics.QUERY_FLOATS
		local visible = q[at + 1] < 0 and q[at + acoustics.QUERY_FLOATS + 1] < 0
		local counts = frame_visible[check.sound]

		if not counts then
			counts = {0, 0, 0, 0, 0, 0}
			frame_visible[check.sound] = counts
		end

		counts[check.band] = counts[check.band] + (visible and 1 or 0)
		counts[check.band + 3] = counts[check.band + 3] + 1
	end

	for sound, counts in pairs(frame_visible) do
		local env = self:GetEnvironment(sound)

		for band = 1, 3 do
			local n = counts[band + 3]

			if n > 0 then
				local k = 1 - math.exp(-n / acoustics.OCCLUSION_MEMORY_SAMPLES)

				if env.visibility_samples[band] == 0 then k = 1 end

				env.visibility[band] = env.visibility[band] + (counts[band] / n - env.visibility[band]) * k
				env.visibility_samples[band] = env.visibility_samples[band] + n
			end
		end
	end

	for _, check in ipairs(job.transmissions) do
		if check.query >= job.query_count then break end

		local at = check.query * acoustics.QUERY_FLOATS
		local env = self:GetEnvironment(check.sound)
		local k = env.transmission_samples == 0 and
			1 or
			1 - math.exp(-job.fresnel_samples / acoustics.OCCLUSION_MEMORY_SAMPLES)

		for band = 1, 3 do
			env.transmission[band] = env.transmission[band] + (q[at + 8 + band] - env.transmission[band]) * k
		end

		env.solid = env.solid + (q[at + 12] - env.solid) * k
		env.direct = env.direct + ((q[at + 1] < 0 and 1 or 0) - env.direct) * k
		env.transmission_samples = env.transmission_samples + 1
	end

	local frame_detour = {}
	local held_path = {}

	for _, check in ipairs(job.detours) do
		if check.query + 1 >= job.query_count then break end

		local at = check.query * acoustics.QUERY_FLOATS
		local best = frame_detour[check.sound]

		if not best then
			best = {detour = acoustics.DETOUR_NONE}
			frame_detour[check.sound] = best
		end

		if q[at + 1] < 0 and q[at + acoustics.QUERY_FLOATS + 1] < 0 then
			if check.refine then held_path[check.sound] = true end

			if check.detour < best.detour then frame_detour[check.sound] = check end
		end
	end

	for sound, best in pairs(frame_detour) do
		local env = self:GetEnvironment(sound)

		-- while samples around the held detour still get through it stands; once they are all blocked the path is gone and the shortest one found now takes over. A frame that finds nothing only lets it grow slowly: a missed sample is not a closed door
		if best.detour <= env.detour then
			env.detour = best.detour
			env.detour_sample = best.u and best
		elseif best.u and not held_path[sound] then
			env.detour = env.detour + (best.detour - env.detour) * acoustics.DETOUR_FOLLOW
			env.detour_sample = best
		else
			env.detour = math.min(
				math.max(env.detour, 0.001) * math.exp(dt / acoustics.DETOUR_MEMORY),
				acoustics.DETOUR_NONE
			)
		end
	end

	for _, check in ipairs(job.reflection_checks) do
		if check.query + 1 >= job.query_count then break end

		local at = check.query * acoustics.QUERY_FLOATS
		local distance = q[at + 1]
		local tolerance = math.max(0.3, check.expected * 0.03)
		local normal_dot = q[at + 2] * check.normal.x + q[at + 3] * check.normal.y + q[at + 4] * check.normal.z
		local valid = distance >= 0 and
			math.abs(distance - check.expected) <= tolerance and
			normal_dot > 0.8 and
			q[at + acoustics.QUERY_FLOATS + 1] < 0
		local env = self:GetEnvironment(check.sound)

		if valid then
			env.reflections[check.key] = job.time
		else
			env.reflections[check.key] = nil
		end
	end

	for i, sound in ipairs(job.sounds) do
		local reflections = self:GetEnvironment(sound).reflections

		for _, member in ipairs(job.members[i]) do
			local env = self:GetEnvironment(member)
			table.clear(env.reflections)

			for key, valid_time in pairs(reflections) do
				env.reflections[key] = valid_time
			end
		end
	end
end

function META:AbsorbAmbience(job, result, decay)
	local ambience = self.ambience
	local bins = ambience.bins
	ambience.rays = ambience.rays * decay

	for b = 1, 3 do
		ambience.rain[b] = ambience.rain[b] * decay
		ambience.wind[b] = ambience.wind[b] * decay
	end

	for _, bin in ipairs(bins) do
		for b = 1, 3 do
			bin.rain[b] = bin.rain[b] * decay
			bin.wind[b] = bin.wind[b] * decay
		end

		bin.x, bin.y, bin.z = bin.x * decay, bin.y * decay, bin.z * decay
	end

	if not job.gather then return end

	ambience.rays = ambience.rays + job.rays
	local r = result.rays
	local stride = acoustics.RAY_FLOATS
	local cells = acoustics.AMBIENCE_CELLS

	for ray = 0, job.rays - 1 do
		local at = ray * stride
		local energy = r[at + 2] + r[at + 5]

		if energy > 0 then
			local dx, dy, dz = acoustics.FibonacciDirection(ray, job.rays, job.rotation)
			local u, v = octahedral_key(dx, dy, dz, cells)
			local bin = bins[u * (cells + 1) + v + 1]

			for b = 1, 3 do
				bin.rain[b] = bin.rain[b] + r[at + b]
				bin.wind[b] = bin.wind[b] + r[at + 3 + b]
				ambience.rain[b] = ambience.rain[b] + r[at + b]
				ambience.wind[b] = ambience.wind[b] + r[at + 3 + b]
			end

			bin.x, bin.y, bin.z = bin.x + dx * energy, bin.y + dy * energy, bin.z + dz * energy
		end
	end
end

function META:GetAmbience()
	local ambience = self.ambience
	local stats = self.stats
	local profile = self.profile
	local out = {
		rain = {0, 0, 0},
		wind = {0, 0, 0},
		tail_rain = {0, 0, 0},
		tail_wind = {0, 0, 0},
		bins = {},
	}

	if ambience.rays <= 0 or stats.rays <= 0 then return out end

	for b = 1, 3 do
		local settled = stats.settled_throughput[b] + stats.settled_escape[b]
		local survival = math.min(profile.tail_survival[b], 0.995)
		local tail = stats.last_throughput[b] / stats.rays / (1 - survival)

		if settled > 0 then
			local air = acoustics.TailAirLoss(stats, b)
			out.tail_rain[b] = tail * air * stats.settled_rain[b] / settled
			out.tail_wind[b] = tail * air * stats.settled_wind[b] / settled
		end

		out.rain[b] = ambience.rain[b] / ambience.rays + out.tail_rain[b]
		out.wind[b] = ambience.wind[b] / ambience.rays + out.tail_wind[b]
	end

	for _, bin in ipairs(ambience.bins) do
		local energy = bin.rain[2] + bin.wind[2]

		if energy > 0 then
			local length = math.sqrt(bin.x * bin.x + bin.y * bin.y + bin.z * bin.z)
			out.bins[#out.bins + 1] = {
				rain = {
					bin.rain[1] / ambience.rays,
					bin.rain[2] / ambience.rays,
					bin.rain[3] / ambience.rays,
				},
				wind = {
					bin.wind[1] / ambience.rays,
					bin.wind[2] / ambience.rays,
					bin.wind[3] / ambience.rays,
				},
				direction = length > 0 and
					Vec3(bin.x / length, bin.y / length, bin.z / length) or
					Vec3(0, 1, 0),
				energy = energy / ambience.rays,
			}
		end
	end

	table.sort(out.bins, by_energy)
	return out
end

function META:AbsorbOpenings(job, result, decay)
	for key, opening in pairs(self.openings) do
		opening.weight = opening.weight * decay

		for b = 1, 3 do
			opening.position[b] = opening.position[b] * decay
			opening.energy[b] = opening.energy[b] * decay
		end

		if opening.weight < 0.01 then self.openings[key] = nil end
	end

	local r = result.rays
	local stride = acoustics.RAY_FLOATS
	local listener = job.listener
	local cells = acoustics.OPENING_CELLS
	self.opening_rays = (self.opening_rays or 0) * decay + job.rays

	for ray = 0, job.rays - 1 do
		local at = ray * stride
		local weight = r[at + 11]
		local px, py, pz = r[at + 7], r[at + 8], r[at + 9]
		local dx, dy, dz = px - listener.x, py - listener.y, pz - listener.z
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

		if weight > 0 and distance == distance and distance < math.huge then
			if distance < 0.01 then
				dx, dy, dz = acoustics.FibonacciDirection(ray, job.rays, job.rotation)
				distance = 0
			else
				dx, dy, dz = dx / distance, dy / distance, dz / distance
			end

			local u, v = octahedral_key(dx, dy, dz, cells)
			local key = (
					u * (
						cells + 1
					) + v
				) * 64 + math.floor(math.log(1 + distance) / math.log(2) + 0.5)
			local opening = self.openings[key]

			if not opening then
				opening = {key = key, weight = 0, position = {0, 0, 0}, energy = {0, 0, 0}}
				self.openings[key] = opening
			end

			opening.weight = opening.weight + weight
			opening.position[1] = opening.position[1] + px * weight
			opening.position[2] = opening.position[2] + py * weight
			opening.position[3] = opening.position[3] + pz * weight

			for b = 1, 3 do
				opening.energy[b] = opening.energy[b] + r[at + 9 + b]
			end
		end
	end
end

function META:GetOpenings()
	local list = {}
	local rays = math.max(self.opening_rays or 0, 1)

	for _, opening in pairs(self.openings) do
		list[#list + 1] = {
			position = Vec3(opening.position[1], opening.position[2], opening.position[3]) / opening.weight,
			energy = {opening.energy[1] / rays, opening.energy[2] / rays, opening.energy[3] / rays},
			count = opening.weight,
		}
	end

	table.sort(list, by_count)

	for i = #list, acoustics.MAX_OPENINGS + 1, -1 do
		list[i] = nil
	end

	return list
end

function META:UpdateSoundEnvironment(sound, time)
	local audio = self.audio
	local env = self:GetEnvironment(sound)
	local speed = audio.speed_of_sound
	local listener = audio.listener_position
	local source = sound:GetPosition()
	local distance = (source - listener):GetLength()
	acoustics.DiffractionGain(env.detour, audio.speed_of_sound, env.diffraction)
	local reach = math.max(acoustics.DETOUR_MAX_RADIUS * distance, acoustics.DETOUR_MIN_REACH)
	local longest = 2 * math.sqrt(0.25 * distance * distance + reach * reach) - distance
	-- a held detour past anything the samples can find means the path is gone; fade it out instead of dropping it, a missed sample is not a closed door
	local fade = math.clamp(2 - env.detour / longest, 0, 1)

	for band = 1, 3 do
		env.diffraction[band] = env.diffraction[band] * fade
	end

	for band = 1, 3 do
		local around = env.direct * env.visibility[band] + (
				1 - env.direct
			) * math.sqrt(env.diffraction[band])
		local visible = around * around
		env.occlusion[band] = math.sqrt(visible + (1 - visible) * env.transmission[band])
	end

	local profile = self.profile
	local reverb = acoustics.ComputeSourceReverb(env.sums, self.stats, profile, distance / speed, speed)
	local diffuse = acoustics.DiffuseEnergy(profile, distance, speed) * env.occlusion[2]
	local energy = diffuse
	local t60 = profile.t60[2]
	local trust = 0

	if reverb then
		trust = math.min(env.sums.rays / acoustics.TRUSTED_RAYS, 1)
		energy = math.lerp(trust, diffuse, reverb.energy[2])
		t60 = math.lerp(trust, t60, reverb.t60[2])
	end

	env.reverb_sums = env.sums
	local emitter = env.emitter

	if emitter and emitter.reverb and emitter.sums.rays >= acoustics.TRUSTED_RAYS then
		local reach = self:GetEmitterReach()
		local weight = math.clamp((distance - reach) / reach, 0, 1)

		if weight > 0 then
			energy = math.lerp(weight, energy, emitter.reverb.energy[2])
			t60 = math.lerp(weight, t60, emitter.reverb.t60[2])

			if weight >= 0.5 then
				reverb = emitter.reverb
				env.reverb_sums = emitter.sums
			end
		end
	end

	env.trust = trust
	env.energy = energy
	local amplitude = math.sqrt(math.max(energy, 0)) * math.min(distance, sound:GetReferenceDistance())
	local ratio = t60 / (self.ambient_reverb and self.ambient_reverb.t60[2] or profile.t60[2])
	local remote = math.clamp((ratio - 1) / (acoustics.REMOTE_T60_RATIO - 1), 0, 1)
	env.send[1] = amplitude * math.sqrt(1 - remote)
	env.send[2] = amplitude * math.sqrt(remote)
	env.remote_weight = energy * remote
	env.t60 = reverb and reverb.t60 or profile.t60
	self:UpdateTaps(sound, env, time)
end

function META:GetGroundFilter(candidate, sample_rate, ahead)
	local cache = self.ground_cache

	if not cache then
		cache = {count = 0, serial = 0}
		self.ground_cache = cache
	end

	local scatter = candidate.scatter
	local key = table.concat(
		{
			math.floor(math.log(candidate.sigma) * 8 + 0.5),
			math.floor(math.log(candidate.r2) * 30 + 0.5),
			math.floor(math.log(candidate.sin_psi) * 30 + 0.5),
			math.floor(scatter[1] * 10 + 0.5),
			math.floor(scatter[2] * 10 + 0.5),
			math.floor(scatter[3] * 10 + 0.5),
			sample_rate,
			ahead,
		},
		"|"
	)
	local entry = cache[key]

	if not entry then
		if cache.count >= 48 then
			table.clear(cache)
			cache.count = 0
			cache.serial = 0
		end

		cache.serial = cache.serial + 1
		cache.count = cache.count + 1
		entry = {ir = ground.CreateIR(), serial = cache.serial}
		ground.DesignFilter(
			entry.ir,
			candidate.sigma,
			candidate.r2,
			candidate.sin_psi,
			sample_rate,
			ahead,
			scatter[1],
			scatter[2],
			scatter[3]
		)
		cache[key] = entry
	end

	return entry
end

function META:UpdateTaps(sound, env, time)
	local audio = self.audio
	local speed = audio.speed_of_sound / math.max(audio.doppler_factor, 0.000001)
	local listener = audio.listener_motion.position or audio.listener_position
	local forward = audio.listener_forward:GetNormalized()
	local right = forward:GetCross(audio.listener_up):GetNormalized()
	local up = right:GetCross(forward)
	local half_ear = right * (audio.ear_distance * 0.5)
	local motion = sound.audio_motion
	local source = motion and motion.position or sound:GetPosition()
	local medium = audio.medium_velocity
	local velocity = (motion and motion.velocity or Vec3(0, 0, 0)) - medium
	local listener_velocity = (audio.listener_motion.velocity or Vec3(0, 0, 0)) - medium
	local ids = audio.DISTANCE_MODE_IDS
	local candidates = {}
	local mu2 = spatial.GetTurbulence(audio)
	local source_height, listener_height
	-- the direct path stops getting louder inside the reference distance, reflections are held back by the same amount so close sounds keep their physical balance
	local close = math.min((source - listener):GetLength() / sound:GetReferenceDistance(), 1)

	for key, valid_time in pairs(env.reflections) do
		local reflector = self.reflectors[key]

		if not reflector or time - valid_time > acoustics.TAP_MEMORY then
			env.reflections[key] = nil
		else
			local n, offset = reflector_plane(reflector)
			local point, image = reflection_point(listener, source, n, offset)

			if point then
				local path = (image - listener):GetLength()
				local absorption = {}
				local specular = {}

				for b = 1, 3 do
					absorption[b] = reflector.absorption[b] / reflector.count
					specular[b] = (1 - absorption[b]) * (1 - reflector.scattering[b] / reflector.count)
				end

				local sin_psi = (listener:GetDot(n) + source:GetDot(n) - 2 * offset) / path
				local ground_candidate

				if n.y >= acoustics.GROUND_MIN_SLOPE then
					if not source_height then
						source_height = math.max(source:GetDot(n) - offset, 0.01)
						listener_height = math.max(listener:GetDot(n) - offset, 0.01)
					end

					local sigma = ground.Resistivity(absorption[2])

					if sigma < ground.RIGID then
						local scatter = {}

						for b = 1, 3 do
							local coherence = spatial.Coherence(
								mu2,
								acoustics.GROUND_SCATTER_FREQUENCIES[b],
								path,
								0.5 * sin_psi * path,
								audio.speed_of_sound
							)
							scatter[b] = 1 - (1 - reflector.scattering[b] / reflector.count) * coherence * coherence
						end

						ground_candidate = {
							sigma = sigma,
							r2 = path,
							sin_psi = sin_psi,
							scatter = scatter,
						}
					end
				end

				local reflect_mid = ground_candidate and
					close * (
						ground.Coefficient(500, ground_candidate.sigma, path, sin_psi)
					) * math.sqrt(1 - ground_candidate.scatter[2])
					or
					close * math.sqrt(specular[2])
				local direction = (point - listener):GetNormalized()
				local attenuation = spatial.ComputeDistanceAttenuation(
						ids[audio.distance_model],
						path,
						sound:GetReferenceDistance(),
						sound:GetMaxDistance(),
						sound:GetRolloffFactor(),
						ids
					) * spatial.ComputeConeGain(
						sound:GetDirection(),
						point - source,
						sound:GetInnerConeAngle(),
						sound:GetOuterConeAngle(),
						sound:GetOuterConeGain()
					)
				local gain = attenuation * reflect_mid
				local image_velocity = velocity - n * (2 * velocity:GetDot(n))
				local delay_left, delay_right = 0, 0
				local rate_left, rate_right = 0, 0

				if audio.doppler_factor > 0 then
					local left_ear, right_ear = listener - half_ear, listener + half_ear
					delay_left, rate_left = spatial.PathTiming(
						motion,
						image,
						image_velocity,
						left_ear,
						listener_velocity,
						medium,
						speed,
						0,
						n,
						offset
					)
					delay_right, rate_right = spatial.PathTiming(
						motion,
						image,
						image_velocity,
						right_ear,
						listener_velocity,
						medium,
						speed,
						0,
						n,
						offset
					)
				end

				local side = direction:GetDot(right)
				local front = direction:GetDot(forward)
				local air = {}
				spatial.GetAirFilter(path * spatial.AIR_SCALE, audio.state.sample_rate, air, 0)
				local shadow_left, shadow_right = spatial.HeadShadow(2, -side, front), spatial.HeadShadow(2, side, front)
				candidates[#candidates + 1] = {
					key = key,
					point = point,
					attenuation = attenuation,
					shadow_left = shadow_left,
					shadow_right = shadow_right,
					ground_candidate = ground_candidate,
					gain = gain,
					delay = (delay_left + delay_right) * 0.5,
					delay_left = delay_left,
					delay_right = delay_right,
					rate_left = rate_left,
					rate_right = rate_right,
					height = direction:GetDot(up),
					front = front,
					gain_left = gain * shadow_left,
					gain_right = gain * shadow_right,
					band = ground_candidate and
						{1, 1, 1} or
						{math.sqrt(specular[1] / specular[2]), 1, math.sqrt(specular[3] / specular[2])},
					air = air,
				}
			end
		end
	end

	local refraction

	if source_height then
		refraction = spatial.GetRefraction(
			audio,
			spatial.GetSoundGradient(audio, source, listener),
			(source - listener):GetLength(),
			source_height,
			listener_height,
			sound.audio_refraction or {}
		)
	end

	sound.audio_refraction = refraction
	table.sort(candidates, by_gain)
	local kept = {}

	for _, tap in ipairs(candidates) do
		local duplicate = false

		for _, other in ipairs(kept) do
			if math.abs(other.delay - tap.delay) < 0.0003 then
				duplicate = true

				break
			end
		end

		if not duplicate and #kept < MAX_TAPS then kept[#kept + 1] = tap end
	end

	candidates = kept
	local chosen

	for _, tap in ipairs(candidates) do
		if
			tap.ground_candidate and
			tap.ground_candidate.r2 >= acoustics.GROUND_FILTER_DISTANCE
		then
			chosen = tap

			break
		end
	end

	if env.ground_user then
		if not chosen then env.ground_user = false end
	elseif chosen and self.ground_count < acoustics.GROUND_VOICES then
		env.ground_user = true
		self.ground_count = self.ground_count + 1
	end

	if env.ground_user and chosen then
		local sample_rate = audio.state.sample_rate
		local ahead = math.clamp(
			math.floor((chosen.delay * sample_rate - acoustics.GROUND_AHEAD_MARGIN) / 64) * 64,
			0,
			ground.READ_AHEAD
		)
		chosen.ground = self:GetGroundFilter(chosen.ground_candidate, sample_rate, ahead)
		chosen.ground_ahead = ahead
		chosen.gain = chosen.attenuation * close * refraction[2]
		chosen.gain_left = chosen.gain * chosen.shadow_left
		chosen.gain_right = chosen.gain * chosen.shadow_right
	end

	local by_key = {}

	for _, tap in ipairs(candidates) do
		by_key[tap.key] = tap
	end

	local keys = env.tap_keys

	for slot = 1, MAX_TAPS do
		if keys[slot] and not by_key[keys[slot]] then keys[slot] = nil end
	end

	for _, tap in ipairs(candidates) do
		local found = false

		for slot = 1, MAX_TAPS do
			if keys[slot] == tap.key then found = true end
		end

		if not found then
			for slot = 1, MAX_TAPS do
				if not keys[slot] and not env.taps[slot] then
					keys[slot] = tap.key

					break
				end
			end
		end
	end

	local weight = 0
	local band_low, band_high = 0, 0

	for slot = 1, MAX_TAPS do
		local tap = keys[slot] and by_key[keys[slot]]
		env.taps[slot] = tap

		if tap and not tap.ground then
			local e = tap.gain * tap.gain
			weight = weight + e
			band_low = band_low + tap.band[1] * e
			band_high = band_high + tap.band[3] * e
		end
	end

	env.tap_band[1] = weight > 0 and band_low / weight or 1
	env.tap_band[2] = 1
	env.tap_band[3] = weight > 0 and band_high / weight or 1
end

function META:UpdateBuses()
	local state = self.audio.state
	local profile = self.profile
	local listener_bus = state.buses[0]
	local ambient = self.ambient_reverb and self.ambient_reverb.t60 or profile.t60

	for b = 1, 3 do
		listener_bus.t60[b - 1] = ambient[b]
	end

	listener_bus.scale = profile.mean_free_path / (self.audio.speed_of_sound * dsp.REVERB_MEAN_DELAY)
	listener_bus.predelay = math.max(
			profile.predelay - math.max(dsp.REVERB_MIN_SCALE - listener_bus.scale, 0) * dsp.REVERB_MEAN_DELAY,
			acoustics.MIN_PREDELAY
		) + (
			self.ambient_reverb and
			self.ambient_reverb.delay or
			0
		)
	listener_bus.diffusion = math.clamp(
		(
				acoustics.SPARSE_ESCAPING - profile.openness
			) / (
				acoustics.SPARSE_ESCAPING - acoustics.DIFFUSE_ESCAPING
			),
		acoustics.MIN_DIFFUSION,
		1
	)
	local weight = 0
	local t60 = {0, 0, 0}
	local dx, dy, dz = 0, 0, 0

	for _, sound in pairs(self.audio.active_sounds) do
		local env = sound.audio_environment

		if env and env.remote_weight and env.remote_weight > 0 then
			weight = weight + env.remote_weight

			for b = 1, 3 do
				t60[b] = t60[b] + env.t60[b] * env.remote_weight
			end

			local sums = env.reverb_sums or env.sums
			local late = sums.late[2]

			if late > 0 then
				local k = env.remote_weight / late
				dx = dx + sums.direction[1] * k
				dy = dy + sums.direction[2] * k
				dz = dz + sums.direction[3] * k
			end
		end
	end

	if weight > 0 then
		local remote_bus = state.buses[1]

		for b = 1, 3 do
			remote_bus.t60[b - 1] = t60[b] / weight
		end

		remote_bus.predelay = math.clamp(remote_bus.t60[1] * 0.02, 0.01, 0.08)
		remote_bus.scale = 1
		remote_bus.diffusion = 1
		dx, dy, dz = dx / weight, dy / weight, dz / weight
		local concentration = math.min(math.sqrt(dx * dx + dy * dy + dz * dz), 1)
		remote_bus.concentration = concentration

		if concentration > 0 then
			local audio = self.audio
			local direction = Vec3(dx, dy, dz) / concentration
			local forward = audio.listener_forward:GetNormalized()
			local right = forward:GetCross(audio.listener_up):GetNormalized()
			local side = direction:GetDot(right)
			local front = direction:GetDot(forward)
			local left = spatial.HeadShadow(2, -side, front)
			local right_gain = spatial.HeadShadow(2, side, front)
			local norm = math.sqrt(2 / (left * left + right_gain * right_gain))
			local half = audio.ear_distance * 0.5 / audio.speed_of_sound
			remote_bus.ear_gain[0] = left * norm
			remote_bus.ear_gain[1] = right_gain * norm
			remote_bus.ear_delay[0] = half * (1 + side)
			remote_bus.ear_delay[1] = half * (1 - side)
			self.remote_direction = direction
		end
	end
end

function META:Update(time)
	self.frame = self.frame + 1

	for _, done in ipairs(self.tracer:Collect()) do
		self:Absorb(done.job, done.result)
	end

	if self.tracer:IsReady() then
		local emitter = self:SelectEmitter()

		if
			emitter and
			emitter.audio_environment.emitter and
			self.frame % acoustics.EMITTER_PERIOD ~= 0
		then
			emitter = nil
		end

		self.tracer:Submit(emitter and self:BuildEmitterJob(emitter, time) or self:BuildJob(time))

		for _, done in ipairs(self.tracer:Collect()) do
			self:Absorb(done.job, done.result)
		end
	end

	self.ground_count = 0

	for _, sound in pairs(self.audio.active_sounds) do
		local env = sound.audio_environment

		if env and env.ground_user then self.ground_count = self.ground_count + 1 end
	end

	for _, sound in pairs(self.audio.active_sounds) do
		if sound:IsSpatial() and sound:IsTraced() then
			self:UpdateSoundEnvironment(sound, time)
		end
	end

	self:UpdateBuses()
end

do
	-- branch-free so the comparison in contains() exits with two live values instead of every temporary
	local function footprint(reflector, point, n)
		local count = reflector.count
		local cx, cy, cz = reflector.position[1] / count, reflector.position[2] / count, reflector.position[3] / count
		local dx, dy, dz = point.x - cx, point.y - cy, point.z - cz
		local along = dx * n.x + dy * n.y + dz * n.z
		dx, dy, dz = dx - n.x * along, dy - n.y * along, dz - n.z * along
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		local safe = math.max(distance, 1e-9)
		local ux, uy, uz = dx / safe, dy / safe, dz / safe
		local m = reflector.spread
		local xx, yy, zz = m[1] / count - cx * cx, m[2] / count - cy * cy, m[3] / count - cz * cz
		local xy, xz, yz = m[4] / count - cx * cy, m[5] / count - cx * cz, m[6] / count - cy * cz
		local variance = ux * ux * xx + uy * uy * yy + uz * uz * zz + 2 * (
				ux * uy * xy + ux * uz * xz + uy * uz * yz
			)
		return distance,
		acoustics.FOOTPRINT_SIGMA * math.sqrt(math.max(variance, 0)) + acoustics.FOOTPRINT_MARGIN
	end

	local function contains(reflector, point, n)
		local distance, limit = footprint(reflector, point, n)
		return distance <= limit
	end

	function META:AcceptReflections(env, source, time)
		local listener = self.audio.listener_position

		for _, reflector in ipairs(self:GetTopReflectors()) do
			if reflector.seen and time - reflector.seen <= acoustics.REFLECTOR_RECENT then
				local n, offset = reflector_plane(reflector)
				local point = reflection_point(listener, source, n, offset)

				if point and contains(reflector, point, n) then
					env.reflections[reflector.key] = time
				end
			end
		end
	end
end

function META:Probe(sound)
	local env = self:GetEnvironment(sound)
	local source = sound:GetPosition()
	local time = self.audio.clock()

	if
		not env.traced or
		(
			source - env.traced
		):GetLength() > acoustics.STATS_DISTANCE * self.profile.mean_free_path
	then
		env.sums = acoustics.CopySourceSums(self.ambient)
		local t60 = self.ambient_reverb and self.ambient_reverb.t60[2] or self.profile.t60[2]
		acoustics.ScaleSourceSums(
			env.sums,
			math.exp(
				-13.82 * (
						source - self.audio.listener_position
					):GetLength() / (
						self.audio.speed_of_sound * t60
					)
			)
		)
		env.traced = source:Copy()
		table.clear(env.reflections)
	end

	self:AcceptReflections(env, source, time)
	local visibility, transmission, detour = self.tracer:Probe(self.audio.listener_position, source, self.audio.speed_of_sound)

	if visibility then
		for band = 1, 3 do
			env.visibility[band] = visibility[band]
			env.visibility_samples[band] = 1
			env.transmission[band] = transmission[band]
		end

		env.solid = transmission.solid
		env.direct = transmission.leaves == 0 and 1 or 0
		env.detour = detour
		env.transmission_samples = 1
	end

	self:UpdateSoundEnvironment(sound, time)
end

local function clear(tracer, listener, point, source)
	local d1 = point - listener
	local l1 = d1:GetLength()
	local d2 = source - point
	local l2 = d2:GetLength()
	return not tracer:Trace(
			listener.x,
			listener.y,
			listener.z,
			d1.x / l1,
			d1.y / l1,
			d1.z / l1,
			acoustics.LISTENER_CLEARANCE,
			l1
		) and
		not tracer:Trace(
			point.x,
			point.y,
			point.z,
			d2.x / l2,
			d2.y / l2,
			d2.z / l2,
			0,
			math.max(l2 - acoustics.SOURCE_CLEARANCE, 0)
		)
end

function acoustics.DetourProbe(tracer, listener, source, samples)
	local axis = source - listener
	local distance = axis:GetLength()

	if distance < acoustics.SOURCE_CLEARANCE + acoustics.LISTENER_CLEARANCE + 0.1 then
		return 0
	end

	axis = axis / distance
	local t, b = perpendicular(axis)
	local min_radius = acoustics.DETOUR_MIN_RADIUS
	local max_radius = math.max(acoustics.DETOUR_MAX_RADIUS * distance, acoustics.DETOUR_MIN_REACH)
	local best = acoustics.DETOUR_NONE
	local best_radius, best_angle

	for i = 1, samples do
		local radius = min_radius * (max_radius / min_radius) ^ ((i - 0.5) / samples)
		local angle = i * 2.399963229728653
		local point = listener + axis * (
				distance * 0.5
			) + (
				t * math.cos(angle) + b * math.sin(angle)
			) * radius
		local detour = (point - listener):GetLength() + (source - point):GetLength() - distance

		if detour < best and clear(tracer, listener, point, source) then
			best = detour
			best_radius, best_angle = radius, angle
		end
	end

	if best_radius then
		local inner, outer = 0, best_radius
		local direction = t * math.cos(best_angle) + b * math.sin(best_angle)

		for _ = 1, 6 do
			local radius = (inner + outer) * 0.5
			local point = listener + axis * (distance * 0.5) + direction * radius

			if clear(tracer, listener, point, source) then
				outer = radius
				best = math.min(best, (point - listener):GetLength() + (source - point):GetLength() - distance)
			else
				inner = radius
			end
		end
	end

	return best
end

function acoustics.ProbeTransmission(tracer, listener, source, speed)
	local axis = source - listener
	local distance = axis:GetLength()
	local out = acoustics.NewTransmission()

	if distance < acoustics.SOURCE_CLEARANCE + acoustics.LISTENER_CLEARANCE + 0.1 then
		return out
	end

	axis = axis / distance
	return acoustics.Transmit(
		tracer,
		listener.x,
		listener.y,
		listener.z,
		axis.x,
		axis.y,
		axis.z,
		acoustics.LISTENER_CLEARANCE,
		distance - acoustics.SOURCE_CLEARANCE,
		speed,
		out
	)
end

function acoustics.FresnelProbe(tracer, listener, source, speed, samples)
	local axis = source - listener
	local distance = axis:GetLength()
	local visibility = {1, 1, 1}

	if distance < acoustics.SOURCE_CLEARANCE + acoustics.LISTENER_CLEARANCE + 0.1 then
		return visibility
	end

	axis = axis / distance
	local t, b = perpendicular(axis)

	for band = 1, 3 do
		local wavelength = speed / dsp.BAND_CENTERS[band]
		local visible = 0

		for i = 1, samples do
			local u = 0.15 + 0.7 * (i - 0.5) / samples
			local radius = acoustics.FRESNEL_CLEARANCE * math.sqrt(wavelength * u * (1 - u) * distance) * math.sqrt((i - 0.5) / samples)
			local angle = i * 2.399963229728653
			local point = listener + axis * (
					distance * u
				) + (
					t * math.cos(angle) + b * math.sin(angle)
				) * radius
			local d1 = point - listener
			local l1 = d1:GetLength()
			local d2 = source - point
			local l2 = d2:GetLength()

			if
				not tracer:Trace(
					listener.x,
					listener.y,
					listener.z,
					d1.x / l1,
					d1.y / l1,
					d1.z / l1,
					acoustics.LISTENER_CLEARANCE,
					l1
				) and
				not tracer:Trace(
					point.x,
					point.y,
					point.z,
					d2.x / l2,
					d2.y / l2,
					d2.z / l2,
					0,
					math.max(l2 - acoustics.SOURCE_CLEARANCE, 0)
				)
			then
				visible = visible + 1
			end
		end

		visibility[band] = visible / samples
	end

	return visibility
end

return acoustics
