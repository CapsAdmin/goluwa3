local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local water = import("goluwa/render3d/water.lua")
local water_field = import("goluwa/render3d/water_field.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local event = import("goluwa/event.lua")
local surf = {}
local SIZE = 512
local SWEEP_ROUNDS = 2
local UNREACHED = 1e9
local NEVER_BROKEN = 1e4
local BREAKING_RATIO = 0.78
local MIN_DEPTH = 0.02
local SWASH_ELEVATION = 3
local LAND_SPEED = 3
local BORE_CYCLES = 1.5
local SWASH_CYCLES = 0.85
local SWASH_PEAK = 0.35
local RUNUP = 1.25
local WAVE_DEPTH_RATIO = 0.8
local SHELTER_STEPS = 24
local EVENT_RADIUS = 220
local EVENT_CLUSTER = 12
surf.TAKEOVER = 0.6
local float_array = ffi.typeof("float[?]")
local textures = {}
local path_textures = {}
local active_set = 1
local active = {origin_x = 0, origin_z = 0, half = 0, frequency = 0, valid = false}
local solving
local solved_key = {}
local ROWS_PER_STEP = 32

local function wavenumber(omega, depth)
	local deep = omega * omega / water.GRAVITY
	local x = (deep * depth) ^ 0.75
	return deep * (1 / math.tanh(x)) ^ (2 / 3)
end

local function get_train()
	local waves = water.GetOceanWaves()
	local period = math.sqrt(2 * math.pi * waves.dominant_wavelength / water.GRAVITY)
	local cycles = math.max(math.floor(water.WAVE_PERIOD / period + 0.5), 1)
	return waves, cycles / water.WAVE_PERIOD
end

local function start_solve(
	heights,
	field_size,
	origin_x,
	origin_z,
	half,
	field_origin_x,
	field_origin_z,
	field_half
)
	local waves, frequency = get_train()
	local omega = 2 * math.pi * frequency
	local level = render3d.GetOceanLevel()
	local texel = half * 2 / SIZE
	local deep_depth = waves.dominant_wavelength * 0.5
	local deep_speed = water.GRAVITY / omega
	local dir_x, dir_z = math.cos(waves.dominant_angle), math.sin(waves.dominant_angle)
	local step = field_size / SIZE
	local arrival = float_array(SIZE * SIZE)
	local cost = float_array(SIZE * SIZE)
	local fixed = ffi.new("uint8_t[?]", SIZE * SIZE)
	local depths = float_array(SIZE * SIZE)
	local shallowest = float_array(SIZE * SIZE)
	local broken_at = float_array(SIZE * SIZE)
	local breaks = ffi.new("uint8_t[?]", SIZE * SIZE)
	local land = ffi.new("uint8_t[?]", SIZE * SIZE)
	local height = surf.GetHeight()

	for row = 0, SIZE - 1 do
		if row % ROWS_PER_STEP == ROWS_PER_STEP - 1 then coroutine.yield() end

		for column = 0, SIZE - 1 do
			local sum = 0

			for dy = 0, step - 1 do
				for dx = 0, step - 1 do
					sum = sum + heights[(row * step + dy) * field_size + column * step + dx]
				end
			end

			local depth = level - sum / (step * step)
			local i = row * SIZE + column
			depths[i] = depth
			shallowest[i] = depth
			broken_at[i] = UNREACHED
			breaks[i] = depth > MIN_DEPTH and
				height * math.min(deep_depth / depth, 40) ^ 0.25 > BREAKING_RATIO * depth and
				1 or
				0
			local x = ((column + 0.5) / SIZE * 2 - 1) * half
			local z = ((row + 0.5) / SIZE * 2 - 1) * half

			if depth <= -SWASH_ELEVATION then
				arrival[i] = UNREACHED
				fixed[i] = 1
			elseif depth <= MIN_DEPTH then
				arrival[i] = UNREACHED
				land[i] = 1
				cost[i] = texel / LAND_SPEED
			elseif
				depth >= deep_depth or
				row == 0 or
				column == 0 or
				row == SIZE - 1 or
				column == SIZE - 1
			then
				arrival[i] = (x * dir_x + z * dir_z) / deep_speed
				fixed[i] = 1
			else
				arrival[i] = UNREACHED
				cost[i] = texel * wavenumber(omega, depth) / omega
			end
		end
	end

	return {
		arrival = arrival,
		cost = cost,
		fixed = fixed,
		depths = depths,
		shallowest = shallowest,
		broken_at = broken_at,
		breaks = breaks,
		land = land,
		sweep = 0,
		origin_x = origin_x,
		origin_z = origin_z,
		half = half,
		texel = texel,
		frequency = frequency,
		deep_depth = deep_depth,
		heights = heights,
		field_size = field_size,
		field_origin_x = field_origin_x,
		field_origin_z = field_origin_z,
		field_half = field_half,
		level = level,
		wave_dir_x = dir_x,
		wave_dir_z = dir_z,
		wavelength = waves.dominant_wavelength,
	}
end

local function sweep(state, direction)
	local arrival, cost, fixed = state.arrival, state.cost, state.fixed
	local depths, shallowest, broken_at, breaks = state.depths, state.shallowest, state.broken_at, state.breaks
	local land = state.land
	local row_from, row_to, row_step = 0, SIZE - 1, 1
	local column_from, column_to, column_step = 0, SIZE - 1, 1

	if direction % 2 == 1 then row_from, row_to, row_step = SIZE - 1, 0, -1 end

	if direction >= 2 then
		column_from, column_to, column_step = SIZE - 1, 0, -1
	end

	for row = row_from, row_to, row_step do
		for column = column_from, column_to, column_step do
			local i = row * SIZE + column

			if fixed[i] == 0 then
				local on_land = land[i] == 1
				local left = column > 0 and (on_land or land[i - 1] == 0) and arrival[i - 1] or UNREACHED
				local right = column < SIZE - 1 and
					(
						on_land or
						land[i + 1] == 0
					)
					and
					arrival[i + 1] or
					UNREACHED
				local up = row > 0 and (on_land or land[i - SIZE] == 0) and arrival[i - SIZE] or UNREACHED
				local down = row < SIZE - 1 and
					(
						on_land or
						land[i + SIZE] == 0
					)
					and
					arrival[i + SIZE] or
					UNREACHED
				local a, a_index = left, i - 1

				if right < left then a, a_index = right, i + 1 end

				local b, b_index = up, i - SIZE

				if down < up then b, b_index = down, i + SIZE end

				local f = cost[i]
				local candidate

				if math.abs(a - b) >= f then
					candidate = math.min(a, b) + f
				else
					candidate = (a + b + math.sqrt(2 * f * f - (a - b) * (a - b))) * 0.5
				end

				if candidate < arrival[i] then
					local upwind = a < b and a_index or b_index
					arrival[i] = candidate
					shallowest[i] = on_land and shallowest[upwind] or math.min(shallowest[upwind], depths[i])
					broken_at[i] = broken_at[upwind] < UNREACHED and
						broken_at[upwind] or
						breaks[i] == 1 and
						candidate or
						UNREACHED
				end
			end
		end
	end
end

local function finish_solve(state)
	local arrival = state.arrival
	local packed = float_array(SIZE * SIZE * 4)
	local path = float_array(SIZE * SIZE * 2)

	for row = 0, SIZE - 1 do
		if row % ROWS_PER_STEP == ROWS_PER_STEP - 1 then coroutine.yield() end

		for column = 0, SIZE - 1 do
			local i = row * SIZE + column
			local t = arrival[i]
			local out = i * 4

			if t >= UNREACHED then
				packed[out] = 0
				packed[out + 3] = 0
			else
				local left = column > 0 and arrival[i - 1] or UNREACHED
				local right = column < SIZE - 1 and arrival[i + 1] or UNREACHED
				local up = row > 0 and arrival[i - SIZE] or UNREACHED
				local down = row < SIZE - 1 and arrival[i + SIZE] or UNREACHED
				local gx = left < UNREACHED and
					right < UNREACHED and
					(
						right - left
					) * 0.5 or
					left < UNREACHED and
					t - left or
					right < UNREACHED and
					right - t or
					0
				local gz = up < UNREACHED and
					down < UNREACHED and
					(
						down - up
					) * 0.5 or
					up < UNREACHED and
					t - up or
					down < UNREACHED and
					down - t or
					0
				packed[out] = t
				packed[out + 1] = gx / state.texel
				packed[out + 2] = gz / state.texel
				packed[out + 3] = 1
			end

			path[i * 2] = state.shallowest[i]
			path[i * 2 + 1] = t < UNREACHED and
				state.broken_at[i] < UNREACHED and
				t - state.broken_at[i] or
				NEVER_BROKEN
		end
	end

	local set = active_set

	if not textures[1] then
		for i = 1, 2 do
			local sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			}
			textures[i] = Texture.New{width = SIZE, height = SIZE, format = "r32g32b32a32_sfloat", buffer = packed, sampler = sampler}
			path_textures[i] = Texture.New{width = SIZE, height = SIZE, format = "r32g32_sfloat", buffer = path, sampler = sampler}
		end
	else
		set = 3 - active_set
		textures[set]:UploadAsync(packed)
		path_textures[set]:UploadAsync(path)
	end

	local event_cells = {}

	for row = 1, SIZE - 2 do
		if row % ROWS_PER_STEP == ROWS_PER_STEP - 1 then coroutine.yield() end

		for column = 1, SIZE - 2 do
			local i = row * SIZE + column
			local t = arrival[i]

			if t < UNREACHED then
				local kind

				if state.land[i] == 0 and state.breaks[i] == 1 and state.broken_at[i] == t then
					kind = "break"
				elseif
					state.land[i] == 1 and
					(
						state.land[i - 1] == 0 and
						state.fixed[i - 1] == 0 or
						state.land[i + 1] == 0 and
						state.fixed[i + 1] == 0 or
						state.land[i - SIZE] == 0 and
						state.fixed[i - SIZE] == 0 or
						state.land[i + SIZE] == 0 and
						state.fixed[i + SIZE] == 0
					)
				then
					kind = "swash"
				end

				if kind then
					event_cells[#event_cells + 1] = {
						kind = kind,
						x = state.origin_x + ((column + 0.5) / SIZE * 2 - 1) * state.half,
						z = state.origin_z + ((row + 0.5) / SIZE * 2 - 1) * state.half,
						arrival = t,
						depth = state.depths[i],
						travel_x = packed[i * 4 + 1],
						travel_z = packed[i * 4 + 2],
					}
				end
			end
		end
	end

	while not (textures[set]:IsUploadDone() and path_textures[set]:IsUploadDone()) do
		coroutine.yield()
	end

	active_set = set
	active = {
		origin_x = state.origin_x,
		origin_z = state.origin_z,
		half = state.half,
		frequency = state.frequency,
		deep_depth = state.deep_depth,
		packed = packed,
		path = path,
		heights = state.heights,
		field_size = state.field_size,
		field_origin_x = state.field_origin_x,
		field_origin_z = state.field_origin_z,
		field_half = state.field_half,
		level = state.level,
		wave_dir_x = state.wave_dir_x,
		wave_dir_z = state.wave_dir_z,
		wavelength = state.wavelength,
		event_cells = event_cells,
		valid = true,
	}
end

local value_noise2 = glsl_common.ValueNoise2

local function smoothstep(edge0, edge1, x)
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function bilinear(data, stride, channel, size, u, v)
	local x = u * size - 0.5
	local y = v * size - 0.5
	local x0 = math.floor(x)
	local y0 = math.floor(y)
	local fx = x - x0
	local fy = y - y0
	local x1 = math.min(x0 + 1, size - 1)
	local y1 = math.min(y0 + 1, size - 1)
	x0 = math.max(x0, 0)
	y0 = math.max(y0, 0)
	x1 = math.max(x1, 0)
	y1 = math.max(y1, 0)
	local a = data[(y0 * size + x0) * stride + channel]
	local b = data[(y0 * size + x1) * stride + channel]
	local c = data[(y1 * size + x0) * stride + channel]
	local d = data[(y1 * size + x1) * stride + channel]
	local top = a + (b - a) * fx
	return top + (c + (d - c) * fx - top) * fy
end

local function field_height(x, z)
	local u = (x - active.field_origin_x) / (2 * active.field_half) + 0.5
	local v = (z - active.field_origin_z) / (2 * active.field_half) + 0.5

	if u < 0 or v < 0 or u > 1 or v > 1 then return nil end

	return bilinear(active.heights, 1, 0, active.field_size, u, v)
end

local function field_depth(x, z)
	local height = field_height(x, z)
	return height and active.level - height or 1e4
end

local function shelter_at(x, z)
	local reach = math.clamp(active.wavelength * 6, 60, 240)
	local step = reach / SHELTER_STEPS
	local shelter = 0

	for i = 1, SHELTER_STEPS do
		local along = i * step
		local height = field_height(x - active.wave_dir_x * along, z - active.wave_dir_z * along)

		if not height then break end

		shelter = math.max(shelter, smoothstep(-2, 0.5, height - active.level) * (1 - along / reach))
	end

	return shelter
end

local function crest_height(x, z, crest, shelter)
	local along = value_noise2(x * 0.012 + crest * 3.7, z * 0.012 + crest * 1.3) * 0.7 + value_noise2(x * 0.05 + crest * 1.9, z * 0.05) * 0.3
	local sets = 0.8 + 0.3 * math.sin(crest * 0.8975979 + value_noise2(x * 0.002, z * 0.002) * 6)
	return surf.GetHeight() * math.lerp(0.45, 1.3, along) * sets * (1 - 0.85 * shelter)
end

local function swash_curve(tau)
	if tau < SWASH_PEAK then return math.sin(math.pi / 2 * tau / SWASH_PEAK) end

	if tau < 1 then
		return math.cos(math.pi / 2 * (tau - SWASH_PEAK) / (1 - SWASH_PEAK))
	end

	return 0
end

local function shape(u, steepness, broken, plunge)
	local front = u < 0.5 and 0.5 * (2 * u) ^ (1 + 2 * steepness + 4 * plunge) or u
	local peaked = (0.5 + 0.5 * math.cos(2 * math.pi * (front - 0.5))) ^ (1 + 3 * steepness)
	local bore = u < 0.5 and smoothstep(0.5 - 0.08, 0.5, u) or (1 - (u - 0.5) * 2) ^ 1.5
	return peaked + (bore - peaked) * broken - 0.3
end

local function breaker_plunge(x, z, wave_height)
	local slope_x = ((field_height(x + 2, z) or 0) - (field_height(x - 2, z) or 0)) / 4
	local slope_z = ((field_height(x, z + 2) or 0) - (field_height(x, z - 2) or 0)) / 4
	local beach_slope = math.sqrt(slope_x * slope_x + slope_z * slope_z)
	local deep_wavelength = water.GRAVITY / (2 * math.pi * active.frequency * active.frequency)
	local iribarren = math.max(beach_slope, 0.01) / math.sqrt(math.max(wave_height / deep_wavelength, 1e-4))
	return beach_slope, deep_wavelength, iribarren
end

function surf.IsActive()
	return active.valid
end

function surf.ApplyToSample(x, z, time, out)
	if not active.valid then return end

	local depth = field_depth(x, z)

	if depth >= 1e3 then return end

	time = time % water.WAVE_PERIOD
	local u = (x - active.origin_x) / (2 * active.half) + 0.5
	local v = (z - active.origin_z) / (2 * active.half) + 0.5
	local packed = active.packed
	local reached = smoothstep(0.6, 1, bilinear(packed, 4, 3, SIZE, u, v))
	local height, slope_x, slope_z, velocity_x, velocity_y, velocity_z, presence = 0, 0, 0, 0, 0, 0, 0

	if reached > 0 then
		local weight = math.max(bilinear(packed, 4, 3, SIZE, u, v), 1e-3)
		local arrival = bilinear(packed, 4, 0, SIZE, u, v) / weight
		local travel_x = bilinear(packed, 4, 1, SIZE, u, v) / weight
		local travel_z = bilinear(packed, 4, 2, SIZE, u, v) / weight
		local shallowest = bilinear(active.path, 2, 0, SIZE, u, v)
		local since_break_seconds = bilinear(active.path, 2, 1, SIZE, u, v)
		local frequency = active.frequency
		local shelter = shelter_at(x, z)
		local cycles = (time - arrival) * frequency + 0.5
		local since_break = since_break_seconds * frequency
		local swash_phase = cycles - 0.5
		local swash_crest = math.floor(swash_phase)
		local spent = since_break_seconds >= NEVER_BROKEN * 0.5 and
			1 or
			math.exp(-math.max(since_break, 0) / (BORE_CYCLES * 4))
		local shore_height = crest_height(x, z, swash_crest, shelter) * spent
		local _, _, shore_iribarren = breaker_plunge(x, z, shore_height)
		local runup = shore_height * math.clamp(shore_iribarren, 0.3, 1.5) * RUNUP
		local swash = runup * swash_curve((swash_phase - swash_crest) / SWASH_CYCLES) * reached

		if depth <= 0 then
			presence = reached
			height = swash
		else
			presence = reached * (1 - smoothstep(0.35, 1, depth / active.deep_depth))

			if presence > 0 then
				local crest = math.floor(cycles)
				local phase = cycles - crest
				local shoaling = math.clamp(active.deep_depth / math.max(depth, 0.05), 1, 40) ^ 0.25
				local wave_height = crest_height(x, z, crest, shelter) * shoaling
				local ratio = wave_height / (BREAKING_RATIO * depth)
				local broken = math.max(smoothstep(0.85, 1.1, ratio), math.exp(-math.max(since_break, 0) / BORE_CYCLES))
				wave_height = math.min(
					wave_height,
					BREAKING_RATIO * math.min(depth, math.max(shallowest, 0) + 0.25 * math.max(depth - shallowest, 0))
				)
				local travel = math.sqrt(travel_x * travel_x + travel_z * travel_z)
				local wavelength = 1 / math.max(travel * frequency, 1e-3)
				local steepness = math.clamp(wave_height / wavelength / 0.14, 0, 1)
				local _, _, iribarren = breaker_plunge(x, z, wave_height)
				local plunge = smoothstep(0.35, 0.9, iribarren) * smoothstep(0.7, 0.95, ratio) * (
						1 - smoothstep(1.05, 1.3, ratio)
					)
				local du = 0.004
				local value = shape(phase, steepness, broken, plunge)
				local derivative = (
						shape(math.min(phase + du, 1), steepness, broken, plunge) - shape(math.max(phase - du, 0), steepness, broken, plunge)
					) / (
						math.min(phase + du, 1) - math.max(phase - du, 0)
					)
				height = wave_height * value * presence
				slope_x = -derivative * wave_height * frequency * travel_x * presence
				slope_z = -derivative * wave_height * frequency * travel_z * presence
				local slope_length = math.sqrt(slope_x * slope_x + slope_z * slope_z)

				if slope_length > 2.5 then
					slope_x = slope_x * 2.5 / slope_length
					slope_z = slope_z * 2.5 / slope_length
				end

				local speed = 1 / math.max(travel, 1e-4)
				local carried = speed * math.max(height, 0) / math.max(depth, 0.1)
				velocity_x = travel_x / math.max(travel, 1e-4) * carried
				velocity_z = travel_z / math.max(travel, 1e-4) * carried
				velocity_y = derivative * wave_height * frequency * presence
				local sheet = swash * (1 - smoothstep(0, 0.3 + runup, depth))

				if sheet > height then height = sheet end
			end
		end
	end

	local cap = math.max(WAVE_DEPTH_RATIO * depth, 1e-3)
	local ratio = out.height / cap
	local scale = math.abs(ratio) < 1e-3 and 1 or math.tanh(ratio) / ratio
	local damping = smoothstep(0, water.GetOcean().ShoalDepth, depth) * scale * (
			1 - surf.TAKEOVER * presence
		)
	out.height = out.height * damping + height
	out.slope_x = out.slope_x * damping + slope_x
	out.slope_z = out.slope_z * damping + slope_z
	out.velocity_x = out.velocity_x * damping + velocity_x
	out.velocity_y = out.velocity_y * damping + velocity_y
	out.velocity_z = out.velocity_z * damping + velocity_z
end

water.SetShallowSampler(surf.ApplyToSample)

do
	local previous_time
	local clusters = {}
	local found = {}

	local function detect_events(time)
		if not previous_time or time < previous_time or time - previous_time > 1 then
			previous_time = time
			return
		end

		local camera = render3d.GetCamera():GetPosition()
		local frequency = active.frequency
		local radius2 = EVENT_RADIUS * EVENT_RADIUS
		local count = 0

		for i = 1, #active.event_cells do
			local cell = active.event_cells[i]
			local dx, dy, dz = cell.x - camera.x, active.level - camera.y, cell.z - camera.z

			if dx * dx + dy * dy + dz * dz < radius2 then
				local before = math.floor((previous_time - cell.arrival) * frequency)
				local now = math.floor((time - cell.arrival) * frequency)

				if now > before then
					local shelter = shelter_at(cell.x, cell.z)
					local wave_height = crest_height(cell.x, cell.z, now, shelter)
					local height, plunge

					if cell.kind == "break" then
						wave_height = math.min(
							wave_height * math.clamp(active.deep_depth / math.max(cell.depth, 0.05), 1, 40) ^ 0.25,
							BREAKING_RATIO * math.max(cell.depth, 0.05)
						)
						local _, _, iribarren = breaker_plunge(cell.x, cell.z, wave_height)
						height = wave_height
						plunge = smoothstep(0.35, 0.9, iribarren)
					else
						local _, _, iribarren = breaker_plunge(cell.x, cell.z, wave_height)
						height = wave_height * math.clamp(iribarren, 0.3, 1.5) * RUNUP
						plunge = 0
					end

					local key = cell.kind .. math.floor(cell.x / EVENT_CLUSTER) .. ":" .. math.floor(cell.z / EVENT_CLUSTER)
					local existing = clusters[key]

					if not existing then
						count = count + 1
						existing = found[count] or {}
						found[count] = existing
						clusters[key] = existing
						existing.Kind = cell.kind
						existing.Height = 0
					end

					if height > existing.Height then
						local travel = math.max(math.sqrt(cell.travel_x * cell.travel_x + cell.travel_z * cell.travel_z), 1e-4)
						existing.Height = height
						existing.Plunge = plunge
						existing.X = cell.x
						existing.Y = active.level + (cell.kind == "swash" and -cell.depth or 0)
						existing.Z = cell.z
						existing.DirectionX = cell.travel_x / travel
						existing.DirectionZ = cell.travel_z / travel
						existing.Speed = 1 / travel
					end
				end
			end
		end

		for i = 1, count do
			event.Call("SurfBreak", found[i])
		end

		for key in pairs(clusters) do
			clusters[key] = nil
		end

		previous_time = time
	end

	surf.DetectEvents = detect_events
end

local updated_frame = -1

function surf.Update()
	local frame = system.GetFrameNumber()

	if frame == updated_frame then return end

	updated_frame = frame

	if active.valid then surf.DetectEvents(water.GetWaveTime()) end

	local heights, version, field_size, origin_x, origin_z, half = water_field.GetHeights()

	if not heights then
		active.valid = false
		solving = nil
		solved_key.version = nil
		return
	end

	local waves = water.GetOceanWaves()
	local angle_step = math.floor(math.deg(waves.dominant_angle) / 2 + 0.5)
	local wavelength_step = math.floor(math.log(waves.dominant_wavelength) / math.log(1.03) + 0.5)
	local height_step = math.floor(math.log(math.max(surf.GetHeight(), 1e-3)) / math.log(1.05) + 0.5)

	if
		solved_key.angle ~= angle_step or
		solved_key.wavelength ~= wavelength_step or
		solved_key.height ~= height_step or
		solved_key.version ~= version
	then
		solved_key.angle = angle_step
		solved_key.wavelength = wavelength_step
		solved_key.height = height_step
		solved_key.version = version
		solving = coroutine.create(function()
			local state = start_solve(heights, field_size, origin_x, origin_z, half, origin_x, origin_z, half)

			for step = 0, SWEEP_ROUNDS * 4 - 1 do
				coroutine.yield()
				sweep(state, step % 4)
			end

			coroutine.yield()
			finish_solve(state)
		end)
	end

	if not solving then return end

	local ok, err = coroutine.resume(solving)

	if not ok then
		solving = nil
		error(err, 0)
	end

	if coroutine.status(solving) == "dead" then solving = nil end
end

function surf.GetHeight()
	local waves = water.GetOceanWaves()
	return waves.height_std * 4 * 0.6 * water.GetOcean().Surf
end

function surf.GetHeightBound()
	return surf.GetHeight() * 2 * BREAKING_RATIO
end

function surf.GetFields()
	return {
		{"surf_tex", "int"},
		{"surf_path_tex", "int"},
		{"surf_origin", "vec2"},
		{"surf_half", "float"},
		{"surf_frequency", "float"},
		{"surf_height", "float"},
		{"surf_deep_depth", "float"},
	}
end

function surf.WriteBlock(self, block)
	surf.Update()
	block.surf_tex = active.valid and self:GetTextureIndex(textures[active_set]) or -1
	block.surf_path_tex = active.valid and self:GetTextureIndex(path_textures[active_set]) or -1
	block.surf_origin[0] = active.origin_x
	block.surf_origin[1] = active.origin_z
	block.surf_half = active.half
	block.surf_frequency = active.frequency
	block.surf_height = surf.GetHeight()
	block.surf_deep_depth = active.deep_depth or 1
end

function surf.GetGLSL(block_name)
	return (
		[[
		const float SURF_BREAKING_RATIO = ]] .. BREAKING_RATIO .. [[;
		const float SURF_BORE_FRONT = 0.08;
		const float SURF_BORE_CYCLES = 1.5;

		float surf_shape(float u, float steepness, float broken, float plunge) {
			float front = u < 0.5 ? 0.5 * pow(2.0 * u, 1.0 + 2.0 * steepness + 4.0 * plunge) : u;
			float peaked = pow(0.5 + 0.5 * cos(6.28318530718 * (front - 0.5)), 1.0 + 3.0 * steepness);
			float bore = u < 0.5 ? smoothstep(0.5 - SURF_BORE_FRONT, 0.5, u) : pow(1.0 - (u - 0.5) * 2.0, 1.5);
			return mix(peaked, bore, broken) - 0.3;
		}

		const float SURF_SWASH_CYCLES = 0.85;
		const float SURF_SWASH_PEAK = 0.35;
		const float SURF_RUNUP = ]] .. RUNUP .. [[;
		const float SURF_NEVER_BROKEN = ]] .. NEVER_BROKEN * 0.5 .. [[;

		float surf_crest_height(vec2 world_xz, float crest, float shelter) {
			float along = value_noise2(world_xz * 0.012 + vec2(crest * 3.7, crest * 1.3)) * 0.7 + value_noise2(world_xz * 0.05 + vec2(crest * 1.9, 0.0)) * 0.3;
			float sets = 0.8 + 0.3 * sin(crest * 0.8975979 + value_noise2(world_xz * 0.002) * 6.0);
			return $B.surf_height * mix(0.45, 1.3, along) * sets * (1.0 - 0.85 * shelter);
		}

		float surf_swash_curve(float tau) {
			if (tau < SURF_SWASH_PEAK) return sin(1.5707963 * tau / SURF_SWASH_PEAK);
			if (tau < 1.0) return cos(1.5707963 * (tau - SURF_SWASH_PEAK) / (1.0 - SURF_SWASH_PEAK));
			return 0.0;
		}

		void surf_wave(vec2 world_xz, float depth, float time, float shelter, out float height, out vec2 slope, out float whitewater, out float presence, out float wet) {
			height = 0.0;
			slope = vec2(0.0);
			whitewater = 0.0;
			presence = 0.0;
			wet = 0.0;

			if ($B.surf_tex < 0) return;

			vec2 uv = (world_xz - $B.surf_origin) / (2.0 * $B.surf_half) + 0.5;

			if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return;

			vec4 arrival = textureLod(TEXTURE($B.surf_tex), uv, 0.0);
			float reached = smoothstep(0.6, 1.0, arrival.w);

			if (reached <= 0.0) return;

			vec2 path = textureLod(TEXTURE($B.surf_path_tex), uv, 0.0).rg;
			float cycles = (time - arrival.x / max(arrival.w, 1e-3)) * $B.surf_frequency + 0.5;
			float since_break = path.y * $B.surf_frequency;
			float swash_phase = cycles - 0.5;
			float swash_crest = floor(swash_phase);
			float spent = path.y >= SURF_NEVER_BROKEN ? 1.0 : exp(-max(since_break, 0.0) / (SURF_BORE_CYCLES * 4.0));
			float shore_height = surf_crest_height(world_xz, swash_crest, shelter) * spent;
			float beach_slope = length(vec2(
				water_field_height(world_xz + vec2(2.0, 0.0), 1.0) - water_field_height(world_xz - vec2(2.0, 0.0), 1.0),
				water_field_height(world_xz + vec2(0.0, 2.0), 1.0) - water_field_height(world_xz - vec2(0.0, 2.0), 1.0)
			)) / 4.0;
			float deep_wavelength = 9.81 / (6.28318530718 * $B.surf_frequency * $B.surf_frequency);
			float iribarren = max(beach_slope, 0.01) / sqrt(max(shore_height / deep_wavelength, 1e-4));
			float runup = shore_height * clamp(iribarren, 0.3, 1.5) * SURF_RUNUP;
			float tau = (swash_phase - swash_crest) / SURF_SWASH_CYCLES;
			float swash = runup * surf_swash_curve(tau) * reached;

			if (depth <= 0.0) {
				float film = swash + depth;
				presence = reached;
				wet = step(0.002, film);
				height = swash;
				float tip = smoothstep(0.0, 0.01, film) * (1.0 - smoothstep(0.01, 0.1, film));
				whitewater = (tau < SURF_SWASH_PEAK ? tip + 0.35 * wet : 0.0) * smoothstep(0.05, 0.3, shore_height);
				return;
			}

			presence = reached * (1.0 - smoothstep(0.35, 1.0, depth / $B.surf_deep_depth));

			if (presence <= 0.0) return;

			vec2 travel = arrival.yz / max(arrival.w, 1e-3);
			float crest = floor(cycles);
			float u = cycles - crest;
			float shoaling = pow(clamp($B.surf_deep_depth / max(depth, 0.05), 1.0, 40.0), 0.25);
			float wave_height = surf_crest_height(world_xz, crest, shelter) * shoaling;
			float ratio = wave_height / (SURF_BREAKING_RATIO * depth);
			float broken = max(smoothstep(0.85, 1.1, ratio), exp(-max(since_break, 0.0) / SURF_BORE_CYCLES));
			wave_height = min(wave_height, SURF_BREAKING_RATIO * min(depth, max(path.x, 0.0) + 0.25 * max(depth - path.x, 0.0)));
			float wavelength = 1.0 / max(length(travel) * $B.surf_frequency, 1e-3);
			float steepness = clamp(wave_height / wavelength / 0.14, 0.0, 1.0);
			float breaker_iribarren = max(beach_slope, 0.01) / sqrt(max(wave_height / deep_wavelength, 1e-4));
			float plunge = smoothstep(0.35, 0.9, breaker_iribarren) * smoothstep(0.7, 0.95, ratio) * (1.0 - smoothstep(1.05, 1.3, ratio));
			float shape = surf_shape(u, steepness, broken, plunge);
			float du = 0.004;
			float shape_slope = (surf_shape(min(u + du, 1.0), steepness, broken, plunge) - surf_shape(max(u - du, 0.0), steepness, broken, plunge)) / (min(u + du, 1.0) - max(u - du, 0.0));
			height = wave_height * shape * presence;
			slope = -shape_slope * wave_height * $B.surf_frequency * travel * presence;
			float slope_length = length(slope);
			if (slope_length > 2.5) slope *= 2.5 / slope_length;
			float sheet = swash * (1.0 - smoothstep(0.0, 0.3 + runup, depth));

			if (sheet > height) {
				slope *= 1.0 - smoothstep(height, height + 0.05, sheet);
				height = sheet;
			}

			float face = u < 0.5 ? smoothstep(0.5 - SURF_BORE_FRONT * 1.5, 0.5, u) : exp(-(u - 0.5) * 12.0);
			float energy = exp(-max(since_break, 0.0) / (SURF_BORE_CYCLES * 2.0)) * smoothstep(0.03, 0.25, wave_height);
			float patches = smoothstep(0.25, 0.7, value_noise2(world_xz * 0.15 + vec2(crest * 5.3, 0.0)) * 0.6 + value_noise2(world_xz * 0.6 - vec2(0.0, crest * 2.1)) * 0.4 + energy * 0.4);
			float lip = plunge * smoothstep(0.44, 0.49, u) * (1.0 - smoothstep(0.5, 0.53, u));
			whitewater = (broken * face * energy * patches + smoothstep(0.75, 1.0, ratio) * smoothstep(0.4, 0.5, u) * (1.0 - step(0.55, u)) + lip * 1.5) * presence;
		}
	]]
	):gsub("%$B", block_name)
end

return surf
