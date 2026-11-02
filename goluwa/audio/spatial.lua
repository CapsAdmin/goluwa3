local Vec3 = import("goluwa/structs/vec3.lua")
local ffi = require("ffi")
local dsp = import("goluwa/audio/dsp.lua")
local ground = import("goluwa/audio/ground.lua")
local audio_state = import("goluwa/audio/state.lua")
local CUE_GROUPS = audio_state.CUE_GROUPS
local spatial = {}
spatial.MIN_RATE = -3
-- a supersonic source has two arrivals at once (or none) and a boom between them; one delay line follows it only below the speed of sound
spatial.MAX_SOURCE_MACH = 0.95
spatial.MAX_RATE = 0.75
spatial.PINNA_NOTCH = {frequency = 7500, octaves = 0.65, depth = 18, q = 2.5, rear = 0.6, far = 0.2}
spatial.PINNA_OVERHEAD = {frequency = 8000, gain = 10, q = 1.2}
spatial.PINNA_FRONT = {frequency = 4000, gain = 5, q = 0.8}
-- positions arrive in physics steps and frame jitter; the ear hears every step of the delay as pitch, so paths follow a tracked path instead
spatial.MOTION_TIME = 0.15
local RATE_STEP = 0.01
local TRACK_SIZE = 1024
local TRACK_STEP = 1 / 30
local VELOCITY_STEP = 0.05
spatial.TRAJECTORY_MIN_DELAY = 0.5
spatial.TRAJECTORY_BLEND = 0.5
local TELEPORT_SPEED = 1000

function spatial.ComputeDistanceAttenuation(model, distance, reference_distance, max_distance, rolloff, ids)
	reference_distance = math.max(reference_distance, 0.0001)
	max_distance = math.max(max_distance, reference_distance)
	rolloff = math.max(rolloff, 0)

	if model == ids.none then return 1 end

	local d = math.max(distance, reference_distance)

	if
		model == ids.inverse_clamped or
		model == ids.linear_clamped or
		model == ids.exponent_clamped
	then
		d = math.clamp(d, reference_distance, max_distance)
	end

	if model == ids.inverse or model == ids.inverse_clamped then
		return reference_distance / (reference_distance + rolloff * (d - reference_distance))
	end

	if model == ids.linear or model == ids.linear_clamped then
		if max_distance <= reference_distance then return 1 end

		return math.clamp(
			1 - rolloff * (d - reference_distance) / (max_distance - reference_distance),
			0,
			1
		)
	end

	return (d / reference_distance) ^ -rolloff
end

function spatial.ComputeConeGain(direction, to_listener, inner_angle, outer_angle, outer_gain)
	if inner_angle >= 360 and outer_angle >= 360 then return 1 end

	if direction:IsZero() or to_listener:IsZero() then return 1 end

	local angle = math.deg(
		math.acos(math.clamp(direction:GetNormalized():GetDot(to_listener:GetNormalized()), -1, 1))
	)
	local inner_half = inner_angle * 0.5
	local outer_half = math.max(outer_angle, inner_angle) * 0.5

	if angle <= inner_half then return 1 end

	if angle >= outer_half or outer_half <= inner_half then return outer_gain end

	return 1 + (outer_gain - 1) * (angle - inner_half) / (outer_half - inner_half)
end

do
	local T0 = 293.15
	local T01 = 273.16
	local REFERENCE_PRESSURE = 101325
	-- band coefficients are fitted at this distance: the energy average over a band does not fall exponentially
	local FIT_DISTANCE = 30
	local SUBBANDS = 6
	local EDGES = {{50, 500}, {500, 4000}, {4000, 16000}}

	function spatial.AirAbsorptionAt(frequency, celsius, relative_humidity, pressure)
		local t = celsius + 273.15
		local pa = pressure / REFERENCE_PRESSURE
		local saturation = 10 ^ (-6.8346 * (T01 / t) ^ 1.261 + 4.6151)
		local h = relative_humidity * 100 * saturation / pa
		local fr_o = pa * (24 + 4.04e4 * h * (0.02 + h) / (0.391 + h))
		local fr_n = pa * (
				t / T0
			) ^ -0.5 * (
				9 + 280 * h * math.exp(-4.170 * ((t / T0) ^ (-1 / 3) - 1))
			)
		local f2 = frequency * frequency
		return 8.686 * f2 * (
				1.84e-11 / pa * (
					t / T0
				) ^ 0.5 + (
					t / T0
				) ^ -2.5 * (
					0.01275 * math.exp(-2239.1 / t) / (
						fr_o + f2 / fr_o
					) + 0.1068 * math.exp(-3352 / t) / (
						fr_n + f2 / fr_n
					)
				)
			)
	end

	-- per band the absorption of its sub frequencies, so a band's loss can be summed at any distance
	function spatial.ComputeAirSubbands(celsius, relative_humidity, pressure)
		local out = {}

		for band = 1, 3 do
			local low, high = EDGES[band][1], EDGES[band][2]
			out[band] = {}

			for k = 1, SUBBANDS do
				out[band][k] = spatial.AirAbsorptionAt(low * (high / low) ^ ((k - 0.5) / SUBBANDS), celsius, relative_humidity, pressure)
			end
		end

		return out
	end

	function spatial.ComputeAirAbsorption(celsius, relative_humidity, pressure)
		local out = {}

		for band = 1, 3 do
			local low, high = EDGES[band][1], EDGES[band][2]
			local energy = 0

			for k = 1, SUBBANDS do
				local frequency = low * (high / low) ^ ((k - 0.5) / SUBBANDS)
				energy = energy + 10 ^ (
						-spatial.AirAbsorptionAt(frequency, celsius, relative_humidity, pressure) * FIT_DISTANCE / 10
					) / SUBBANDS
			end

			out[band] = -10 * math.log10(energy) / FIT_DISTANCE
		end

		return out
	end
end

spatial.AIR_ABSORPTION_DB = spatial.ComputeAirAbsorption(20, 0.5, 101325)
spatial.AIR_SUBBANDS = spatial.ComputeAirSubbands(20, 0.5, 101325)
audio_state.default_air_flat_high = spatial.AIR_ABSORPTION_DB[3]
audio_state.state.air_flat_high = spatial.AIR_ABSORPTION_DB[3]
spatial.AIR_STAGES = 6
spatial.MAX_HISTORY_SECONDS = 20
spatial.HISTORY_MARGIN = 1.25
spatial.HISTORY_EXTRA = 0.5
spatial.AIR_FILTER_POINTS = 32
spatial.AIR_FILTER_MIN_DISTANCE = 2
spatial.AIR_FILTER_MAX_DISTANCE = 4000
spatial.AIR_FILTER_FIT_LIMIT = 80
spatial.AIR_FILTER_RELATIVE = 0.5
spatial.AIR_FILTER_MAX_CUTOFF = 40
spatial.AIR_REFERENCE = {20, 0.5, 101325}
spatial.AIR_REFERENCE_FREQUENCY = 5000
spatial.AIR_SCALE = 1

do
	local FREQUENCIES = {}

	for k = 0, 59 do
		FREQUENCIES[#FREQUENCIES + 1] = 200 * (20000 / 200) ^ (k / 59)
	end

	-- the reference loss is fitted once per sample rate as a cascade of one pole filters (bilinear, so the zero at nyquist is part of the shape); other air only scales the distance, since the shape of the loss over a path is the absorption per meter times its length. Absorption grows close to f^2 in dB, a cascade of equal poles falls off too slowly for it, so close by one or two poles carry the fit and the rest are bypassed
	function spatial.ComputeAirFilter(sample_rate)
		local reference = spatial.AIR_REFERENCE
		local warped, per_meter = {}, {}

		for i, f in ipairs(FREQUENCIES) do
			warped[i] = math.tan(math.pi * f / sample_rate)
			per_meter[i] = spatial.AirAbsorptionAt(f, reference[1], reference[2], reference[3])
		end

		local stages = spatial.AIR_STAGES
		local top = math.log(spatial.AIR_FILTER_MAX_CUTOFF)
		local targets = {}
		local log_cutoff = {}

		for k = 1, stages do
			log_cutoff[k] = top
		end

		local function fit_error()
			local sum = 0

			for i = 1, #FREQUENCIES do
				local target = targets[i]

				if target < spatial.AIR_FILTER_FIT_LIMIT then
					local model = 0

					for k = 1, stages do
						model = model + 10 * math.log10(1 + (warped[i] / math.exp(log_cutoff[k])) ^ 2)
					end

					sum = sum + (model - target) ^ 2 / (spatial.AIR_FILTER_RELATIVE + target) ^ 2
				end
			end

			return sum
		end

		local result = {}

		for point = 0, spatial.AIR_FILTER_POINTS - 1 do
			local distance = spatial.AIR_FILTER_MIN_DISTANCE * (
					spatial.AIR_FILTER_MAX_DISTANCE / spatial.AIR_FILTER_MIN_DISTANCE
				) ^ (
					point / (
						spatial.AIR_FILTER_POINTS - 1
					)
				)

			for i = 1, #FREQUENCIES do
				targets[i] = per_meter[i] * distance
			end

			local best = fit_error()
			local step = 0.6

			while step > 0.01 do
				local improved = false

				for k = 1, stages do
					for _, direction in ipairs{1, -1} do
						local old = log_cutoff[k]
						log_cutoff[k] = math.min(old + direction * step, top)
						local error_sum = fit_error()

						if error_sum < best then
							best, improved = error_sum, true
						else
							log_cutoff[k] = old
						end
					end
				end

				if not improved then step = step * 0.6 end
			end

			local row = {}

			for k = 1, stages do
				local cutoff = math.exp(log_cutoff[k])
				row[k] = cutoff >= spatial.AIR_FILTER_MAX_CUTOFF and 1 or cutoff / (1 + cutoff)
			end

			result[point + 1] = row
		end

		return result
	end
end

function spatial.SetAirConditions(celsius, relative_humidity, pressure)
	local reference = spatial.AIR_REFERENCE
	spatial.AIR_SCALE = spatial.AirAbsorptionAt(spatial.AIR_REFERENCE_FREQUENCY, celsius, relative_humidity, pressure) / spatial.AirAbsorptionAt(spatial.AIR_REFERENCE_FREQUENCY, reference[1], reference[2], reference[3])
end

local air_filters = {}
-- fills out[offset + 1 .. offset + AIR_STAGES] with the one pole coefficients of the air loss over a path (1 passes the signal)
spatial.TURBULENCE_LENGTH = 1.1
spatial.TURBULENCE_BASE = 1e-6
spatial.TURBULENCE_WIND = 0.12
spatial.SCINTILLATION_SATURATION = 0.3
spatial.SCINTILLATION_FREQUENCIES = {250, 1400, 6000}
spatial.WIND_GRADIENT = 0.026
spatial.TEMPERATURE_GRADIENT_SOUND = 0.6
spatial.SHADOW_EDGE_DB = 6
spatial.SHADOW_FLOOR_DB = 25
spatial.DUCT_MAX_DB = 6
spatial.MIN_REFRACTION = 0.00005

-- mean square refractive index fluctuation: thermal turbulence plus the wind's own
function spatial.GetTurbulence(audio)
	local wind = audio.medium_velocity:GetLength() * spatial.TURBULENCE_WIND / audio.speed_of_sound
	return audio.turbulence + wind * wind
end

-- Gaussian spectrum phase variance of a wave over a path (Ostashev)
function spatial.PhaseVariance(mu2, frequency, distance, speed)
	local k = 2 * math.pi * frequency / speed
	return math.sqrt(math.pi) * mu2 * k * k * distance * spatial.TURBULENCE_LENGTH
end

-- standard deviation of the log amplitude (nepers) from Rytov's weak scattering, saturating in strong scattering
function spatial.ScintillationDepth(mu2, frequency, distance, speed)
	local length = spatial.TURBULENCE_LENGTH
	local k = 2 * math.pi * frequency / speed
	local fresnel = 4 * distance / (k * length * length)
	local variance = 0.5 * spatial.PhaseVariance(mu2, frequency, distance, speed) * (
			1 - math.atan(fresnel) / fresnel
		)
	local saturation = spatial.SCINTILLATION_SATURATION
	return math.sqrt(saturation * variance / (saturation + variance))
end

-- how much of the mean of a reflected path survives against the direct one: the two rays through different turbulence drift apart in phase
function spatial.Coherence(mu2, frequency, path, separation, speed)
	local rho = math.exp(-(separation / spatial.TURBULENCE_LENGTH) ^ 2)
	return math.exp(-0.5 * spatial.PhaseVariance(mu2, frequency, path, speed) * (1 - rho))
end

-- sound speed gradient (1/s) along the way from the source to the listener: the temperature lapse plus the wind that blows along the path, the wind growing with height
function spatial.GetSoundGradient(audio, source, listener)
	local dx, dz = listener.x - source.x, listener.z - source.z
	local length = math.sqrt(dx * dx + dz * dz)
	local gradient = spatial.TEMPERATURE_GRADIENT_SOUND * audio.temperature_gradient

	if length > 0.001 then
		local wind = audio.medium_velocity
		gradient = gradient + spatial.WIND_GRADIENT * (wind.x * dx + wind.z * dz) / length
	end

	return gradient
end

-- band gains (low, mid, high) of the direct path from the bending of sound by the sound speed gradient. Upward bending leaves a shadow zone past the horizon of the rays, where the sound only creeps along (Airy modes, loss growing with the cube root of frequency) down to what turbulence scatters in; downward bending traps it near the ground and spreads it cylindrically
function spatial.GetRefraction(audio, gradient, distance, source_height, listener_height, out)
	local speed = audio.speed_of_sound
	local radius = speed / math.max(math.abs(gradient), 0.00001)
	local horizon = math.sqrt(2 * radius) * (math.sqrt(source_height) + math.sqrt(listener_height))
	local excess = distance - horizon

	if gradient < 0 then
		local width = math.max(horizon * 0.15, 5)
		local edge = spatial.SHADOW_EDGE_DB / (1 + math.exp(-excess / width))

		for band = 1, 3 do
			local k = 2 * math.pi * spatial.SCINTILLATION_FREQUENCIES[band] / speed
			local rate = 8.686 * 0.441 * (2 / radius) ^ (2 / 3) * k ^ (1 / 3)
			local db = math.min(edge + rate * math.max(excess, 0), spatial.SHADOW_FLOOR_DB)
			out[band] = 10 ^ (-db / 20)
		end
	else
		local db = excess > 0 and
			math.min(5 * math.log10(distance / horizon), spatial.DUCT_MAX_DB) or
			0

		for band = 1, 3 do
			out[band] = 10 ^ (db / 20)
		end
	end

	return out
end

function spatial.GetAirFilter(distance, sample_rate, out, offset)
	local filter = air_filters[sample_rate]

	if not filter then
		filter = spatial.ComputeAirFilter(sample_rate)
		air_filters[sample_rate] = filter
	end

	if distance <= spatial.AIR_FILTER_MIN_DISTANCE then
		for k = 1, spatial.AIR_STAGES do
			out[offset + k] = 1
		end

		return
	end

	local position = math.log(math.min(distance, spatial.AIR_FILTER_MAX_DISTANCE) / spatial.AIR_FILTER_MIN_DISTANCE) / math.log(spatial.AIR_FILTER_MAX_DISTANCE / spatial.AIR_FILTER_MIN_DISTANCE) * (
			spatial.AIR_FILTER_POINTS - 1
		)
	local index = math.min(math.floor(position), spatial.AIR_FILTER_POINTS - 2)
	local fraction = position - index
	local low, high = filter[index + 1], filter[index + 2]

	for k = 1, spatial.AIR_STAGES do
		out[offset + k] = low[k] + (high[k] - low[k]) * fraction
	end
end

-- the band's energy is the mean of its sub frequencies, each decaying on its own: far away only the low end of a band is left
function spatial.AirAbsorption(band, distance)
	local subbands = spatial.AIR_SUBBANDS[band]
	local energy = 0

	for k = 1, #subbands do
		energy = energy + 10 ^ (-subbands[k] * distance / 10)
	end

	return math.sqrt(energy / #subbands)
end

function spatial.HeadShadow(band, side, front)
	local shadow = math.max(0, -side)
	local back = math.max(0, -front)

	if band == 1 then return 1 - 0.15 * shadow end

	if band == 2 then return (1 - 0.45 * shadow) * (1 - 0.1 * back) end

	return (1 - 0.7 * shadow) * (1 - 0.3 * back)
end

function spatial.GetPinnaCues(height, front, toward, strength)
	local notch = spatial.PINNA_NOTCH
	return notch.frequency * 2 ^ (notch.octaves * height),
	-notch.depth * (
			1 - math.max(height, 0)
		) * (
			1 - (
				1 - notch.rear
			) * math.max(-front, 0)
		) * (
			notch.far + (
				1 - notch.far
			) * (
				0.5 + 0.5 * toward
			)
		) * strength,
	spatial.PINNA_OVERHEAD.gain * math.max(height, 0) * strength,
	spatial.PINNA_FRONT.gain * front * strength
end

function spatial.WriteCueGroups(state, strength)
	for group = 0, CUE_GROUPS - 1 do
		local height = (math.floor(group / 2) - 1) * audio_state.CUE_GROUP_HEIGHT
		local front = (group % 2 == 0 and 1 or -1) * math.sqrt(1 - height * height)
		local notch_frequency, notch_gain, overhead_gain, front_gain = spatial.GetPinnaCues(height, front, 0, strength)
		local at = group * 3
		state.cue_frequency[at], state.cue_gain[at] = notch_frequency, notch_gain
		state.cue_frequency[at + 1], state.cue_gain[at + 1] = spatial.PINNA_OVERHEAD.frequency, overhead_gain
		state.cue_frequency[at + 2], state.cue_gain[at + 2] = spatial.PINNA_FRONT.frequency, front_gain
	end

	state.cue_q[0] = spatial.PINNA_NOTCH.q
	state.cue_q[1] = spatial.PINNA_OVERHEAD.q
	state.cue_q[2] = spatial.PINNA_FRONT.q
end

-- solves |ear - source + v delay| = speed delay: the sound now arriving left where the source was a delay ago; v is the source velocity relative to the air
function spatial.RetardedDelay(ear, source, source_velocity, speed)
	local rx, ry, rz = ear.x - source.x, ear.y - source.y, ear.z - source.z
	local vx, vy, vz = source_velocity.x, source_velocity.y, source_velocity.z
	local v2 = vx * vx + vy * vy + vz * vz
	local max_speed = speed * spatial.MAX_SOURCE_MACH

	if v2 > max_speed * max_speed then
		local k = max_speed / math.sqrt(v2)
		vx, vy, vz, v2 = vx * k, vy * k, vz * k, max_speed * max_speed
	end

	local rv = rx * vx + ry * vy + rz * vz
	local r2 = rx * rx + ry * ry + rz * rz
	local a = speed * speed - v2
	return (rv + math.sqrt(rv * rv + a * r2)) / a
end

function spatial.DelayRate(from, to, from_velocity, to_velocity, speed)
	local direction = to - from

	if direction:IsZero() then return 0 end

	direction = direction:GetNormalized()
	local source_radial = direction:GetDot(from_velocity)
	local rate = (
			direction:GetDot(to_velocity) - source_radial
		) / math.max(speed - source_radial, 0.0001)
	return math.clamp(rate, spatial.MIN_RATE, spatial.MAX_RATE)
end

function spatial.RecordTrack(motion)
	local track = motion.track

	if not track then
		track = {count = 0, next = 0, t = {}, x = {}, y = {}, z = {}}
		motion.track = track
	end

	if
		track.count > 0 and
		motion.time - track.t[(
			track.next - 1
		) % TRACK_SIZE + 1] < TRACK_STEP
	then
		return
	end

	local at = track.next + 1
	track.t[at] = motion.time
	track.x[at], track.y[at], track.z[at] = motion.position.x, motion.position.y, motion.position.z
	track.next = (track.next + 1) % TRACK_SIZE
	track.count = math.min(track.count + 1, TRACK_SIZE)
end

local function track_time(track, i)
	return track.t[(track.next - track.count + i) % TRACK_SIZE + 1]
end

local function track_position(track, time)
	local count = track.count
	local first = (track.next - count) % TRACK_SIZE + 1
	local last = (track.next - 1) % TRACK_SIZE + 1

	if time <= track.t[first] then
		return track.x[first], track.y[first], track.z[first]
	end

	if time >= track.t[last] then
		return track.x[last], track.y[last], track.z[last]
	end

	local lo, hi = 0, count - 1

	while hi - lo > 1 do
		local mid = math.floor((lo + hi) / 2)

		if track_time(track, mid) <= time then lo = mid else hi = mid end
	end

	local a = (track.next - count + lo) % TRACK_SIZE + 1
	local b = (track.next - count + hi) % TRACK_SIZE + 1
	local k = (time - track.t[a]) / (track.t[b] - track.t[a])
	return track.x[a] + (track.x[b] - track.x[a]) * k,
	track.y[a] + (track.y[b] - track.y[a]) * k,
	track.z[a] + (track.z[b] - track.z[a]) * k
end

local function mirrored_position(track, time, nx, ny, nz, offset)
	local x, y, z = track_position(track, time)

	if not nx then return x, y, z end

	local d = 2 * (x * nx + y * ny + z * nz - offset)
	return x - d * nx, y - d * ny, z - d * nz
end

-- the wave front leaves the emission point and is carried by the medium: it reaches the ear after tau when speed * tau = |ear - (S(t - tau) + medium * tau)|
local function retarded_error(track, time, ex, ey, ez, wx, wy, wz, speed, nx, ny, nz, offset, tau)
	local x, y, z = mirrored_position(track, time - tau, nx, ny, nz, offset)
	local dx, dy, dz = ex - x - wx * tau, ey - y - wy * tau, ez - z - wz * tau
	return speed * tau - math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- delay, rate of the delay and the position the sound is heard from (where it was emitted, carried along by the medium) of a path from a moving source (or its mirror image in a plane) to an ear. Close paths use the tracked velocity, far ones the recorded trajectory, since over seconds the velocity does not stay what it is now
function spatial.PathTiming(
	motion,
	position,
	velocity,
	ear,
	ear_velocity,
	medium,
	speed,
	ahead,
	normal,
	offset
)
	local delay = spatial.RetardedDelay(ear, position, velocity, speed)
	local rate = spatial.DelayRate(position - velocity * delay, ear, velocity, ear_velocity, speed)
	local emitted = position - velocity * delay
	local track = motion and motion.track

	if not track or track.count < 2 or delay < spatial.TRAJECTORY_MIN_DELAY then
		return delay, rate, emitted.x, emitted.y, emitted.z
	end

	local time = motion.time + ahead
	local first = track.t[(track.next - track.count) % TRACK_SIZE + 1]
	local nx, ny, nz

	if normal then nx, ny, nz = normal.x, normal.y, normal.z end

	local wx, wy, wz = medium.x, medium.y, medium.z
	local ex, ey, ez = ear.x, ear.y, ear.z
	local hi = delay * 1.5 + 0.5

	while
		hi < time - first and
		retarded_error(track, time, ex, ey, ez, wx, wy, wz, speed, nx, ny, nz, offset, hi) < 0
	do
		hi = hi * 2
	end

	if hi >= time - first then
		return delay, rate, emitted.x, emitted.y, emitted.z
	end

	local lo = 0

	for _ = 1, 40 do
		local mid = (lo + hi) * 0.5

		if
			retarded_error(track, time, ex, ey, ez, wx, wy, wz, speed, nx, ny, nz, offset, mid) < 0
		then
			lo = mid
		else
			hi = mid
		end
	end

	local tau = (lo + hi) * 0.5
	local px, py, pz = mirrored_position(track, time - tau, nx, ny, nz, offset)
	local ax, ay, az = mirrored_position(track, time - tau + VELOCITY_STEP, nx, ny, nz, offset)
	local bx, by, bz = mirrored_position(track, time - tau - VELOCITY_STEP, nx, ny, nz, offset)
	local source_velocity = Vec3(ax - bx, ay - by, az - bz) / (2 * VELOCITY_STEP) - medium
	local carried = Vec3(px + wx * tau, py + wy * tau, pz + wz * tau)
	local traced_rate = spatial.DelayRate(carried, ear, source_velocity, ear_velocity, speed)
	local blend = math.clamp((delay - spatial.TRAJECTORY_MIN_DELAY) / spatial.TRAJECTORY_BLEND, 0, 1)
	return delay + (tau - delay) * blend,
	rate + (traced_rate - rate) * blend,
	emitted.x + (carried.x - emitted.x) * blend,
	emitted.y + (carried.y - emitted.y) * blend,
	emitted.z + (carried.z - emitted.z) * blend
end

function spatial.UpdateMotion(motion, position, time)
	if not motion.time then
		motion.time = time
		motion.position = position:Copy()
		motion.velocity = Vec3(0, 0, 0)
		spatial.RecordTrack(motion)
		return motion
	end

	local dt = time - motion.time

	if dt <= 0 then return motion end

	local predicted = motion.position + motion.velocity * dt
	local residual = position - predicted

	if residual:GetLength() / dt > TELEPORT_SPEED then
		motion.position = position:Copy()
		motion.velocity = Vec3(0, 0, 0)
		motion.seeded = false
		motion.track = nil
	elseif not motion.seeded then
		-- a sound that starts on a moving object already moves: the first step sets the velocity instead of a slow climb from rest
		motion.velocity = (position - motion.position) / dt
		motion.position = position:Copy()
		motion.seeded = true
	else
		-- critically damped position and velocity tracker (g-h filter): no lag at constant velocity, steps and jitter shorter than MOTION_TIME are smoothed out
		local theta = math.exp(-dt / spatial.MOTION_TIME)
		motion.position = predicted + residual * (1 - theta * theta)
		motion.velocity = motion.velocity + residual * ((1 - theta) * (1 - theta) / dt)
	end

	motion.time = time
	spatial.RecordTrack(motion)
	return motion
end

function spatial.ComputePaths(audio, sound, out)
	out = out or
		{
			ear_delay = {},
			ear_rate = {},
			ear_rate_change = {},
			ear_gain = {},
			ear_filter_frequency = {},
			ear_filter_gain = {},
			ear_air = {},
			send_air = {},
			scintillation_depth = {},
		}
	local listener = audio.listener_motion.position or audio.listener_position
	local forward = audio.listener_forward:GetNormalized()
	local right = forward:GetCross(audio.listener_up)

	if right:IsZero() then
		right = Vec3(1, 0, 0)
	else
		right = right:GetNormalized()
	end

	local motion = sound.audio_motion
	local source = motion and motion.position or sound:GetPosition()
	local medium = audio.medium_velocity
	local source_velocity = (motion and motion.velocity or Vec3(0, 0, 0)) - medium
	local listener_velocity = (audio.listener_motion.velocity or Vec3(0, 0, 0)) - medium
	local doppler = audio.doppler_factor
	local speed = audio.speed_of_sound / math.max(doppler, 0.000001)
	local heard = source

	if doppler > 0 then
		local _, _, hx, hy, hz = spatial.PathTiming(motion, source, source_velocity, listener, listener_velocity, medium, speed, 0)
		heard = Vec3(hx, hy, hz)
	end

	local to_source = heard - listener
	local distance = to_source:GetLength()
	local direction = distance > 0.0001 and to_source / distance or forward
	local side = direction:GetDot(right)
	local front = direction:GetDot(forward)
	local height = direction:GetDot(right:GetCross(forward))
	local pinna = audio.pinna_cues:Get()
	local attenuation = spatial.ComputeDistanceAttenuation(
		audio.DISTANCE_MODE_IDS[audio.distance_model],
		distance,
		sound:GetReferenceDistance(),
		sound:GetMaxDistance(),
		sound:GetRolloffFactor(),
		audio.DISTANCE_MODE_IDS
	)
	local cone = spatial.ComputeConeGain(
		sound:GetDirection(),
		-to_source,
		sound:GetInnerConeAngle(),
		sound:GetOuterConeAngle(),
		sound:GetOuterConeGain()
	)
	local occlusion = sound.audio_occlusion
	local refraction = sound.audio_refraction
	local tone = sound:GetBandGains()
	local mu2 = spatial.GetTurbulence(audio)
	out.scintillation_depth[1] = spatial.ScintillationDepth(mu2, spatial.SCINTILLATION_FREQUENCIES[2], distance, speed)
	out.scintillation_depth[2] = spatial.ScintillationDepth(mu2, spatial.SCINTILLATION_FREQUENCIES[3], distance, speed)
	out.scintillation_rate = (0.5 + audio.medium_velocity:GetLength()) / (2 * spatial.TURBULENCE_LENGTH)
	local half_ear = right * (audio.ear_distance * 0.5)

	for ear = 1, 2 do
		local sign = ear == 1 and -1 or 1
		local ear_position = listener + half_ear * sign

		if doppler <= 0 then
			out.ear_delay[ear] = 0
			out.ear_rate[ear] = 0
			out.ear_rate_change[ear] = 0
		else
			local delay, rate = spatial.PathTiming(
				motion,
				source,
				source_velocity,
				ear_position,
				listener_velocity,
				medium,
				speed,
				0
			)
			out.ear_delay[ear] = delay
			out.ear_rate[ear] = rate
			-- how the rate itself moves (a close pass sweeps it fast), from the same paths a moment later along the tracked velocities
			local later_ear = ear_position + (listener_velocity + medium) * RATE_STEP
			local later_source = source + (source_velocity + medium) * RATE_STEP
			local _, later_rate = spatial.PathTiming(
				motion,
				later_source,
				source_velocity,
				later_ear,
				listener_velocity,
				medium,
				speed,
				RATE_STEP
			)
			out.ear_rate_change[ear] = (later_rate - rate) / RATE_STEP
		end

		for band = 1, 3 do
			out.ear_gain[(ear - 1) * 3 + band] = attenuation * cone * spatial.HeadShadow(band, side * sign, front) * (
					occlusion and
					occlusion[band] or
					1
				) * (
					refraction and
					refraction[band] or
					1
				) * (
					band == 1 and
					tone.x or
					band == 2 and
					tone.y or
					tone.z
				)
		end

		spatial.GetAirFilter(
			distance * spatial.AIR_SCALE,
			audio.state.sample_rate,
			out.ear_air,
			(ear - 1) * spatial.AIR_STAGES
		)
		spatial.GetAirFilter(distance * spatial.AIR_SCALE, audio.state.sample_rate, out.send_air, 0)
		local f = (ear - 1) * 3
		local notch_frequency, notch_gain, overhead_gain, front_gain = spatial.GetPinnaCues(height, front, side * sign, pinna)
		out.ear_filter_frequency[f + 1] = notch_frequency
		out.ear_filter_gain[f + 1] = notch_gain
		out.ear_filter_frequency[f + 2] = spatial.PINNA_OVERHEAD.frequency
		out.ear_filter_gain[f + 2] = overhead_gain
		out.ear_filter_frequency[f + 3] = spatial.PINNA_FRONT.frequency
		out.ear_filter_gain[f + 3] = front_gain
	end

	out.distance = distance
	out.attenuation = attenuation
	out.cone_gain = cone
	out.direction = direction
	out.side = side
	out.front = front
	return out
end

function spatial.WriteSlot(slot, paths, sound, time)
	local longest = math.max(paths.ear_delay[1], paths.ear_delay[2])

	for ear = 0, 1 do
		slot.ear_delay[ear] = paths.ear_delay[ear + 1]
		slot.ear_rate[ear] = paths.ear_rate[ear + 1]
		slot.ear_rate_change[ear] = paths.ear_rate_change[ear + 1]

		for k = 0, spatial.AIR_STAGES - 1 do
			slot.ear_air[ear * spatial.AIR_STAGES + k] = paths.ear_air[ear * spatial.AIR_STAGES + k + 1]
		end
	end

	for ear = 0, 1 do
		local g = paths.ear_gain
		slot.ear_gain[ear * 3], slot.ear_gain[ear * 3 + 1], slot.ear_gain[ear * 3 + 2] = dsp.WarpBandGains(g[ear * 3 + 1], g[ear * 3 + 2], g[ear * 3 + 3])
	end

	for k = 0, spatial.AIR_STAGES - 1 do
		slot.send_air[k] = paths.send_air[k + 1]
	end

	for i = 0, 5 do
		slot.ear_filter_frequency[i] = paths.ear_filter_frequency[i + 1]
		slot.ear_filter_gain[i] = paths.ear_filter_gain[i + 1]
	end

	slot.ear_filter_q[0] = spatial.PINNA_NOTCH.q
	slot.ear_filter_q[1] = spatial.PINNA_OVERHEAD.q
	slot.ear_filter_q[2] = spatial.PINNA_FRONT.q
	local env = sound.audio_environment
	local ground_tap = 0

	for t = 0, 7 do
		local tap = env and env.taps[t + 1]

		if tap then
			if tap.ground then
				ground_tap = t + 1
				slot.ground_ahead = tap.ground_ahead

				if slot.ground_serial ~= tap.ground.serial then
					ffi.copy(slot.ground_ir, tap.ground.ir, ground.IR_SIZE * 4)
					slot.ground_serial = tap.ground.serial
				end
			end

			longest = math.max(longest, tap.delay_left, tap.delay_right)
			slot.tap_delay[t * 2] = tap.delay_left
			slot.tap_delay[t * 2 + 1] = tap.delay_right
			slot.tap_rate[t * 2] = tap.rate_left
			slot.tap_rate[t * 2 + 1] = tap.rate_right
			slot.tap_height[t] = tap.height
			slot.tap_front[t] = tap.front
			slot.tap_gain[t * 2] = tap.gain_left
			slot.tap_gain[t * 2 + 1] = tap.gain_right

			for k = 0, spatial.AIR_STAGES - 1 do
				slot.tap_air[t * spatial.AIR_STAGES + k] = tap.air[k + 1]
			end
		else
			slot.tap_gain[t * 2] = 0
			slot.tap_gain[t * 2 + 1] = 0
		end
	end

	slot.scintillation_depth[0] = paths.scintillation_depth[1]
	slot.scintillation_depth[1] = paths.scintillation_depth[2]
	slot.scintillation_rate = paths.scintillation_rate
	slot.history_seconds = math.min(
		longest * spatial.HISTORY_MARGIN + spatial.HISTORY_EXTRA,
		spatial.MAX_HISTORY_SECONDS
	)
	slot.ground_tap = ground_tap
	local tone = sound:GetBandGains()

	if env then
		slot.tap_band[0], slot.tap_band[1], slot.tap_band[2] = dsp.WarpBandGains(env.tap_band[1] * tone.x, env.tap_band[2] * tone.y, env.tap_band[3] * tone.z)
	else
		slot.tap_band[0], slot.tap_band[1], slot.tap_band[2] = dsp.WarpBandGains(tone.x, tone.y, tone.z)
	end

	for bus = 0, 1 do
		slot.send[bus] = env and env.send[bus + 1] or 0
	end

	slot.param_time = time
	slot.param_serial = slot.param_serial + 1
end

function spatial.Attach(audio)
	audio.listener_motion = {}
	local paths = {
		ear_delay = {},
		ear_rate = {},
		ear_rate_change = {},
		ear_gain = {},
		ear_filter_frequency = {},
		ear_filter_gain = {},
		ear_air = {},
		send_air = {},
		scintillation_depth = {},
	}

	function audio.UpdateSoundPaths(sound, time)
		local slot = audio.state.slots[sound.slot]

		if not slot.spatial then return end

		sound.audio_motion = spatial.UpdateMotion(sound.audio_motion or {}, sound:GetPosition(), time)
		spatial.WriteSlot(slot, spatial.ComputePaths(audio, sound, paths), sound, time)
	end

	function audio.ComputePaths(sound)
		return spatial.ComputePaths(audio, sound)
	end

	function audio.UpdateListenerMotion(time)
		spatial.UpdateMotion(audio.listener_motion, audio.listener_position, time)
	end

	function audio.UpdateCueGroups()
		spatial.WriteCueGroups(audio.state, audio.pinna_cues:Get())
	end

	return audio
end

return spatial
