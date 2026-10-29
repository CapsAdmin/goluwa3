local Vec3 = import("goluwa/structs/vec3.lua")
local spatial = import("goluwa/audio/spatial.lua")
local dsp = import("goluwa/audio/dsp.lua")
local acoustics = {}
acoustics.OPEN_DISTANCE = 400
acoustics.TRACE_DISTANCE = 1000
acoustics.LISTENER_CLEARANCE = 0.25
acoustics.SOURCE_CLEARANCE = 0.3
acoustics.SURFACE_OFFSET = 0.01
acoustics.SCATTERING = 0.2
acoustics.FRESNEL_CLEARANCE = 0.6
acoustics.TRANSMISSION = {0.05, 0.02, 0.008}
acoustics.DEFAULT_ABSORPTION = {0.06, 0.10, 0.16}
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
acoustics.REMOTE_T60_RATIO = 1.6
acoustics.DIFFUSE_ESCAPING = 0.1
acoustics.SPARSE_ESCAPING = 0.35
local LN10_OVER_10 = math.log(10) / 10
local MAX_TAPS = 8

function acoustics.AirEnergyPerMeter(band)
	return spatial.AIR_ABSORPTION_DB[band] * LN10_OVER_10
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
	}
end

function acoustics.NewSourceSums()
	return {rays = 0, settled = {0, 0, 0}, late = {0, 0, 0}, moment = {0, 0, 0}}
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
	end
end

function acoustics.DecaySourceSums(sums, factor)
	sums.rays = sums.rays * factor

	for b = 1, 3 do
		sums.late[b] = sums.late[b] * factor
		sums.moment[b] = sums.moment[b] * factor
		sums.settled[b] = sums.settled[b] * factor
	end
end

function acoustics.AddSourceSums(into, from, rays)
	into.rays = into.rays + rays

	for b = 1, 3 do
		into.late[b] = into.late[b] + from.late[b]
		into.moment[b] = into.moment[b] + from.moment[b]
		into.settled[b] = into.settled[b] + from.settled[b]
	end
end

function acoustics.ComputeProfile(stats, speed)
	local profile = {t60 = {}, survival = {}}
	local segments = stats.hits + stats.escapes

	if stats.hits < 0.5 or segments <= 0 then
		profile.mean_free_path = acoustics.OPEN_DISTANCE
		profile.volume = 4 / 3 * math.pi * acoustics.OPEN_DISTANCE ^ 3
		profile.predelay = 0.08
		profile.openness = 1

		for b = 1, 3 do
			profile.t60[b] = acoustics.MIN_T60
			profile.survival[b] = 0
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
	end

	profile.mean_free_path = mean_free_path
	profile.volume = stats.rays > 0 and stats.volume / stats.rays or 0
	profile.predelay = math.clamp(1.5 * mean_free_path / speed, 0.005, 0.08)
	profile.openness = 1 - hit_probability
	return profile
end

function acoustics.ComputeSourceReverb(sums, stats, profile, direct_time, speed)
	local result = {energy = {}, t60 = {}}

	if sums.rays <= 0 or stats.rays <= 0 then return nil end

	for b = 1, 3 do
		local throughput = stats.settled_throughput[b] / stats.rays
		local per_bounce = throughput > 0 and (sums.settled[b] / sums.rays) / throughput or 0
		local survival = math.min(profile.survival[b], 0.995)
		local geometric = survival / (1 - survival)
		local last = stats.last_throughput[b] / stats.rays
		local last_length = stats.last_throughput_length[b] / stats.rays
		local energy = sums.late[b] / sums.rays + last * per_bounce * geometric
		local moment = sums.moment[b] / sums.rays + per_bounce * (
				(
					last_length / speed - direct_time * last
				) * geometric + last * (
					profile.mean_free_path / speed
				) * survival / (
					(
						1 - survival
					) ^ 2
				)
			)
		result.energy[b] = energy
		result.t60[b] = energy > 0 and
			math.clamp(
				13.82 * math.max(moment / energy - profile.predelay, 0),
				acoustics.MIN_T60,
				acoustics.MAX_T60
			) or
			profile.t60[b]
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
	local air = {
		acoustics.AirEnergyPerMeter(1),
		acoustics.AirEnergyPerMeter(2),
		acoustics.AirEnergyPerMeter(3),
	}
	local w = {1, 1, 1}

	for ray = 0, job.rays - 1 do
		local dx, dy, dz = acoustics.FibonacciDirection(ray, job.rays, job.rotation)
		local ox, oy, oz = lx, ly, lz
		local tmin = acoustics.LISTENER_CLEARANCE
		local length = 0
		w[1], w[2], w[3] = 1, 1, 1
		stats.rays = stats.rays + 1
		local escaped = false

		for bounce = 0, job.bounces - 1 do
			local distance, nx, ny, nz, absorption = tracer:Trace(ox, oy, oz, dx, dy, dz, tmin, acoustics.TRACE_DISTANCE)

			if bounce == 0 then
				local d = math.min(distance or open, open)
				stats.volume = stats.volume + 4 / 3 * math.pi * d * d * d

				if distance and ray < job.sample_count then
					local s = result.samples
					local at = #s
					s[at + 1] = ox + dx * distance
					s[at + 2] = oy + dy * distance
					s[at + 3] = oz + dz * distance
					s[at + 4] = nx
					s[at + 5] = ny
					s[at + 6] = nz
					s[at + 7] = distance
					s[at + 8] = math.abs(nx * dx + ny * dy + nz * dz)
					s[at + 9] = absorption[1]
					s[at + 10] = absorption[2]
					s[at + 11] = absorption[3]
				end
			end

			if not distance or distance > open then
				stats.escapes = stats.escapes + 1
				escaped = true

				break
			end

			stats.hits = stats.hits + 1
			stats.segment = stats.segment + distance
			length = length + distance
			local hx, hy, hz = ox + dx * distance, oy + dy * distance, oz + dz * distance
			local settled = bounce >= math.floor(job.bounces / 2)

			if settled then
				for b = 1, 3 do
					stats.settled_throughput[b] = stats.settled_throughput[b] + w[b]
				end
			end

			for b = 1, 3 do
				stats.log_reflect[b] = stats.log_reflect[b] + math.log(math.max(1 - absorption[b], 1e-6))
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
						local base = 4 * cos_s / math.max(d2, 0.01)
						local late = bounce > 0 and t > job.split_time

						for b = 1, 3 do
							local e = base * w[b] * (1 - absorption[b]) * math.exp(-air[b] * total)

							if late then
								sums.late[b] = sums.late[b] + e
								sums.moment[b] = sums.moment[b] + e * t
							end

							if settled then sums.settled[b] = sums.settled[b] + e end
						end
					end
				end
			end

			for b = 1, 3 do
				w[b] = w[b] * (1 - absorption[b])
			end

			ox, oy, oz = px, py, pz
			tmin = 0
			dx, dy, dz = acoustics.CosineDirection(nx, ny, nz, random(), random())
		end

		if not escaped then
			for b = 1, 3 do
				stats.last_throughput[b] = stats.last_throughput[b] + w[b]
				stats.last_throughput_length[b] = stats.last_throughput_length[b] + w[b] * length
			end
		end
	end
end

function acoustics.RunQueries(tracer, job, result)
	local q = job.queries
	local out = result.queries

	for i = 0, job.query_count - 1 do
		local at = i * 8
		local distance, nx, ny, nz = tracer:Trace(
			q[at + 1],
			q[at + 2],
			q[at + 3],
			q[at + 5],
			q[at + 6],
			q[at + 7],
			q[at + 4],
			q[at + 8]
		)
		out[i * 4 + 1] = distance or -1
		out[i * 4 + 2] = nx or 0
		out[i * 4 + 3] = ny or 0
		out[i * 4 + 4] = nz or 0
	end
end

function acoustics.NewResult(job)
	local result = {stats = acoustics.NewStats(), sources = {}, samples = {}, queries = {}}

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

local function add_query(job, ox, oy, oz, dx, dy, dz, tmin, tmax)
	local q = job.queries
	local at = job.query_count * 8
	q[at + 1], q[at + 2], q[at + 3], q[at + 4] = ox, oy, oz, tmin
	q[at + 5], q[at + 6], q[at + 7], q[at + 8] = dx, dy, dz, tmax
	job.query_count = job.query_count + 1
	return job.query_count - 1
end

local function add_segment(job, a, b, tmin, trim)
	local d = b - a
	local length = d:GetLength()
	d = d / length
	return add_query(job, a.x, a.y, a.z, d.x, d.y, d.z, tmin, math.max(length - trim, tmin))
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
	return a.gain > b.gain
end

local META = {}
META.__index = META

function acoustics.New(audio, tracer)
	local self = setmetatable({}, META)
	self.audio = audio
	self.tracer = tracer
	self.stats = acoustics.NewStats()
	self.reflectors = {}
	self.random = math.random
	self.frame = 0
	self.profile = acoustics.ComputeProfile(self.stats, audio.speed_of_sound)
	self.ambient = acoustics.NewSourceSums()
	self.remote = {t60 = {0.5, 0.5, 0.5}, predelay = 0.02}
	self.last_time = nil
	return self
end

function META:GetEnvironment(sound)
	local env = sound.audio_environment

	if not env then
		env = {
			sums = acoustics.NewSourceSums(),
			visibility = {1, 1, 1},
			visibility_samples = {0, 0, 0},
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
		if sound:IsSpatial() and sound.slot and audio.state.slots[sound.slot].active then
			local distance = (sound:GetPosition() - audio.listener_position):GetLength()
			list[#list + 1] = {
				sound = sound,
				importance = sound:GetMixVolume() * sound:GetReferenceDistance() / math.max(distance, sound:GetReferenceDistance()),
			}
		end
	end

	table.sort(list, by_importance)
	local sounds = {}

	for i = 1, math.min(#list, budget) do
		sounds[i] = list[i].sound
	end

	return sounds
end

function META:BuildJob(time)
	local audio = self.audio
	local budget = self.tracer.budget
	local listener = audio.listener_position:Copy()
	local speed = audio.speed_of_sound
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
		sounds = self:SelectSources(budget.sources),
		direct_time = {},
		split_time = self.profile.predelay,
		queries = {},
		query_count = 0,
		fresnel = {},
		reflection_checks = {},
	}

	for i, sound in ipairs(job.sounds) do
		local position = sound:GetPosition():Copy()
		job.sources[i] = position
		job.direct_time[i] = (position - listener):GetLength() / speed
		self:AddFresnelQueries(job, sound, position, budget.fresnel)
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

function META:AddFresnelQueries(job, sound, source, samples)
	local listener = job.listener
	local axis = source - listener
	local distance = axis:GetLength()

	if distance < acoustics.SOURCE_CLEARANCE + acoustics.LISTENER_CLEARANCE + 0.1 then
		return
	end

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

	for _, reflector in pairs(self.reflectors) do
		if
			reflector.weight >= acoustics.MIN_REFLECTOR_AREA and
			reflector.count >= acoustics.MIN_REFLECTOR_HITS
		then
			list[#list + 1] = reflector
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

function META:AbsorbReflectors(job, result, decay)
	for key, reflector in pairs(self.reflectors) do
		reflector.weight = reflector.weight * decay
		reflector.count = reflector.count * decay

		for i = 1, 3 do
			reflector.position[i] = reflector.position[i] * decay
			reflector.normal[i] = reflector.normal[i] * decay
			reflector.absorption[i] = reflector.absorption[i] * decay
		end

		for i = 1, 6 do
			reflector.spread[i] = reflector.spread[i] * decay
		end

		if reflector.weight < 0.01 then self.reflectors[key] = nil end
	end

	local s = result.samples
	local solid_angle = 4 * math.pi / job.rays

	for at = 0, #s - 1, 11 do
		local px, py, pz = s[at + 1], s[at + 2], s[at + 3]
		local nx, ny, nz = s[at + 4], s[at + 5], s[at + 6]
		local distance = s[at + 7]
		local u, v = octahedral_key(nx, ny, nz, 24)
		local offset = nx * px + ny * py + nz * pz
		local cell = math.max(0.5, distance * 0.02)
		local bucket = math.floor(offset / cell + 0.5)
		local prefix = u .. "," .. v .. ","
		local key = prefix .. bucket
		local reflector = self.reflectors[key] or
			self.reflectors[prefix .. (
				bucket - 1
			)] or
			self.reflectors[prefix .. (
				bucket + 1
			)]

		if not reflector then
			reflector = {
				key = key,
				weight = 0,
				count = 0,
				position = {0, 0, 0},
				normal = {0, 0, 0},
				absorption = {0, 0, 0},
				spread = {0, 0, 0, 0, 0, 0},
			}
			self.reflectors[key] = reflector
		end

		reflector.weight = reflector.weight + solid_angle * distance * distance / math.max(s[at + 8], 0.2) * job.rays / job.sample_count
		reflector.count = reflector.count + 1
		reflector.seen = job.time
		local spread = reflector.spread
		spread[1], spread[2], spread[3] = spread[1] + px * px, spread[2] + py * py, spread[3] + pz * pz
		spread[4], spread[5], spread[6] = spread[4] + px * py, spread[5] + px * pz, spread[6] + py * pz
		reflector.position[1] = reflector.position[1] + px
		reflector.position[2] = reflector.position[2] + py
		reflector.position[3] = reflector.position[3] + pz
		reflector.normal[1] = reflector.normal[1] + nx
		reflector.normal[2] = reflector.normal[2] + ny
		reflector.normal[3] = reflector.normal[3] + nz
		reflector.absorption[1] = reflector.absorption[1] + s[at + 9]
		reflector.absorption[2] = reflector.absorption[2] + s[at + 10]
		reflector.absorption[3] = reflector.absorption[3] + s[at + 11]
	end
end

function META:Absorb(job, result)
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
		local env = self:GetEnvironment(sound)
		local source = job.sources[i]
		local source_moved = env.traced and (source - env.traced):GetLength() / reach or 0
		env.traced = source
		acoustics.DecaySourceSums(env.sums, decay * math.exp(-source_moved))
		acoustics.AddSourceSums(env.sums, result.sources[i], job.rays)
	end

	acoustics.DecaySourceSums(self.ambient, decay)
	acoustics.AddSourceSums(self.ambient, result.sources[#job.sounds + 1], job.rays)
	self.ambient_reverb = acoustics.ComputeSourceReverb(self.ambient, self.stats, self.profile, 0, job.speed)
	self:AbsorbReflectors(job, result, math.exp(-dt / acoustics.REFLECTOR_MEMORY - moved))
	self.samples = result.samples
	self.last_job = job
	local q = result.queries
	local frame_visible = {}

	for _, check in ipairs(job.fresnel) do
		local visible = q[check.query * 4 + 1] < 0 and q[check.query * 4 + 5] < 0
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

	for _, check in ipairs(job.reflection_checks) do
		local at = check.query * 4
		local distance = q[at + 1]
		local tolerance = math.max(0.3, check.expected * 0.03)
		local normal_dot = q[at + 2] * check.normal.x + q[at + 3] * check.normal.y + q[at + 4] * check.normal.z
		local valid = distance >= 0 and
			math.abs(distance - check.expected) <= tolerance and
			normal_dot > 0.8 and
			q[at + 5] < 0
		local env = self:GetEnvironment(check.sound)

		if valid then
			env.reflections[check.key] = job.time
		else
			env.reflections[check.key] = nil
		end
	end
end

function META:UpdateSoundEnvironment(sound, time)
	local audio = self.audio
	local env = self:GetEnvironment(sound)
	local speed = audio.speed_of_sound
	local listener = audio.listener_position
	local source = sound:GetPosition()
	local distance = (source - listener):GetLength()

	for band = 1, 3 do
		local transmission = acoustics.TRANSMISSION[band]
		env.occlusion[band] = transmission + (1 - transmission) * env.visibility[band]
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

function META:UpdateTaps(sound, env, time)
	local audio = self.audio
	local speed = audio.speed_of_sound / math.max(audio.doppler_factor, 0.000001)
	local listener = audio.listener_position
	local forward = audio.listener_forward:GetNormalized()
	local right = forward:GetCross(audio.listener_up):GetNormalized()
	local source = sound:GetPosition()
	local motion = sound.audio_motion
	local velocity = motion and motion.velocity or Vec3(0, 0, 0)
	local listener_velocity = audio.listener_motion.velocity or Vec3(0, 0, 0)
	local ids = audio.DISTANCE_MODE_IDS
	local candidates = {}
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

				for b = 1, 3 do
					absorption[b] = reflector.absorption[b] / reflector.count
				end

				local reflect_mid = close * math.sqrt((1 - absorption[2]) * (1 - acoustics.SCATTERING))
				local direction = (point - listener):GetNormalized()
				local gain = spatial.ComputeDistanceAttenuation(
						ids[audio.distance_model],
						path,
						sound:GetReferenceDistance(),
						sound:GetMaxDistance(),
						sound:GetRolloffFactor(),
						ids
					) * reflect_mid * spatial.ComputeConeGain(
						sound:GetDirection(),
						point - source,
						sound:GetInnerConeAngle(),
						sound:GetOuterConeAngle(),
						sound:GetOuterConeGain()
					) * spatial.AirAbsorption(2, path)
				local image_velocity = velocity - n * (2 * velocity:GetDot(n))
				local delay = 0
				local rate = 0

				if audio.doppler_factor > 0 then
					delay = spatial.RetardedDelay(listener, image, image_velocity, speed)
					rate = spatial.DelayRate(
						image - image_velocity * delay,
						listener,
						image_velocity,
						listener_velocity,
						speed
					)
				end

				local side = direction:GetDot(right)
				local front = direction:GetDot(forward)
				candidates[#candidates + 1] = {
					key = key,
					point = point,
					gain = gain,
					delay = delay,
					rate = rate,
					gain_left = gain * spatial.HeadShadow(2, -side, front),
					gain_right = gain * spatial.HeadShadow(2, side, front),
					band = {
						math.sqrt((1 - absorption[1]) / (1 - absorption[2])) * spatial.AirAbsorption(1, path) / spatial.AirAbsorption(2, path),
						1,
						math.sqrt((1 - absorption[3]) / (1 - absorption[2])) * spatial.AirAbsorption(3, path) / spatial.AirAbsorption(2, path),
					},
				}
			end
		end
	end

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

		if tap then
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

	for b = 1, 3 do
		listener_bus.t60[b - 1] = profile.t60[b]
	end

	listener_bus.predelay = profile.predelay
	listener_bus.scale = profile.mean_free_path / (self.audio.speed_of_sound * dsp.REVERB_MEAN_DELAY)
	listener_bus.diffusion = math.clamp(
		(
				acoustics.SPARSE_ESCAPING - profile.openness
			) / (
				acoustics.SPARSE_ESCAPING - acoustics.DIFFUSE_ESCAPING
			),
		0,
		1
	)
	local weight = 0
	local t60 = {0, 0, 0}

	for _, sound in pairs(self.audio.active_sounds) do
		local env = sound.audio_environment

		if env and env.remote_weight and env.remote_weight > 0 then
			weight = weight + env.remote_weight

			for b = 1, 3 do
				t60[b] = t60[b] + env.t60[b] * env.remote_weight
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
	end
end

function META:Update(time)
	self.frame = self.frame + 1

	for _, done in ipairs(self.tracer:Collect()) do
		self:Absorb(done.job, done.result)
	end

	if self.tracer:IsReady() then
		self.tracer:Submit(self:BuildJob(time))

		for _, done in ipairs(self.tracer:Collect()) do
			self:Absorb(done.job, done.result)
		end
	end

	for _, sound in pairs(self.audio.active_sounds) do
		if sound:IsSpatial() then self:UpdateSoundEnvironment(sound, time) end
	end

	self:UpdateBuses()
end

do
	local function contains(reflector, point, n)
		local count = reflector.count
		local cx, cy, cz = reflector.position[1] / count, reflector.position[2] / count, reflector.position[3] / count
		local dx, dy, dz = point.x - cx, point.y - cy, point.z - cz
		local along = dx * n.x + dy * n.y + dz * n.z
		dx, dy, dz = dx - n.x * along, dy - n.y * along, dz - n.z * along
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

		if distance <= acoustics.FOOTPRINT_MARGIN then return true end

		local ux, uy, uz = dx / distance, dy / distance, dz / distance
		local m = reflector.spread
		local xx, yy, zz = m[1] / count - cx * cx, m[2] / count - cy * cy, m[3] / count - cz * cz
		local xy, xz, yz = m[4] / count - cx * cy, m[5] / count - cx * cz, m[6] / count - cy * cz
		local variance = ux * ux * xx + uy * uy * yy + uz * uz * zz + 2 * (
				ux * uy * xy + ux * uz * xz + uy * uz * yz
			)
		return distance <= acoustics.FOOTPRINT_SIGMA * math.sqrt(math.max(variance, 0)) + acoustics.FOOTPRINT_MARGIN
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
		env.traced = source:Copy()
		table.clear(env.reflections)
	end

	self:AcceptReflections(env, source, time)

	if self.tracer.Probe then
		local visibility = self.tracer:Probe(self.audio.listener_position, source, self.audio.speed_of_sound)

		if visibility then
			for band = 1, 3 do
				env.visibility[band] = visibility[band]
				env.visibility_samples[band] = 1
				local transmission = acoustics.TRANSMISSION[band]
				env.occlusion[band] = transmission + (1 - transmission) * visibility[band]
			end
		end
	end

	self:UpdateSoundEnvironment(sound, time)
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
