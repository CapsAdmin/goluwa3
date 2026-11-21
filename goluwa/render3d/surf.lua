local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local system = import("goluwa/system.lua")
local water = import("goluwa/render3d/water.lua")
local water_field = import("goluwa/render3d/water_field.lua")
local surf = {}
local SIZE = 512
local SWEEP_ROUNDS = 2
local UNREACHED = 1e9
local NEVER_BROKEN = 1e4
local BREAKING_RATIO = 0.78
local MIN_DEPTH = 0.02
local float_array = ffi.typeof("float[?]")
local texture
local path_texture
local active = {origin_x = 0, origin_z = 0, half = 0, frequency = 0, valid = false}
local solve
local solved_key

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

local function start_solve(heights, field_size, origin_x, origin_z, half)
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
	local height = surf.GetHeight()

	for row = 0, SIZE - 1 do
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

			if depth <= MIN_DEPTH then
				arrival[i] = UNREACHED
				fixed[i] = 1
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

	solve = {
		arrival = arrival,
		cost = cost,
		fixed = fixed,
		depths = depths,
		shallowest = shallowest,
		broken_at = broken_at,
		breaks = breaks,
		sweep = 0,
		origin_x = origin_x,
		origin_z = origin_z,
		half = half,
		texel = texel,
		frequency = frequency,
		deep_depth = deep_depth,
	}
end

local function sweep(state, direction)
	local arrival, cost, fixed = state.arrival, state.cost, state.fixed
	local depths, shallowest, broken_at, breaks = state.depths, state.shallowest, state.broken_at, state.breaks
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
				local left = column > 0 and arrival[i - 1] or UNREACHED
				local right = column < SIZE - 1 and arrival[i + 1] or UNREACHED
				local up = row > 0 and arrival[i - SIZE] or UNREACHED
				local down = row < SIZE - 1 and arrival[i + SIZE] or UNREACHED
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
					shallowest[i] = math.min(shallowest[upwind], depths[i])
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

	if not texture then
		texture = Texture.New{
			width = SIZE,
			height = SIZE,
			format = "r32g32b32a32_sfloat",
			buffer = packed,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
		path_texture = Texture.New{
			width = SIZE,
			height = SIZE,
			format = "r32g32_sfloat",
			buffer = path,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	else
		texture:Upload(packed)
		path_texture:Upload(path)
	end

	active = {
		origin_x = state.origin_x,
		origin_z = state.origin_z,
		half = state.half,
		frequency = state.frequency,
		deep_depth = state.deep_depth,
		valid = true,
	}
end

local updated_frame = -1

function surf.Update()
	local frame = system.GetFrameNumber()

	if frame == updated_frame then return end

	updated_frame = frame
	local heights, version, field_size, origin_x, origin_z, half = water_field.GetHeights()

	if not heights then
		active.valid = false
		solve = nil
		return
	end

	local key = tostring(water.GetOceanWaves()) .. ":" .. version

	if not solve and solved_key ~= key then
		solved_key = key
		start_solve(heights, field_size, origin_x, origin_z, half)
		return
	end

	if not solve then return end

	if solve.sweep < SWEEP_ROUNDS * 4 then
		sweep(solve, solve.sweep % 4)
		solve.sweep = solve.sweep + 1
		return
	end

	finish_solve(solve)
	solve = nil
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
	block.surf_tex = active.valid and self:GetTextureIndex(texture) or -1
	block.surf_path_tex = active.valid and self:GetTextureIndex(path_texture) or -1
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

		float surf_shape(float u, float steepness, float broken) {
			float front = u < 0.5 ? 0.5 * pow(2.0 * u, 1.0 + 2.0 * steepness) : u;
			float peaked = pow(0.5 + 0.5 * cos(6.28318530718 * (front - 0.5)), 1.0 + 3.0 * steepness);
			float bore = u < 0.5 ? smoothstep(0.5 - SURF_BORE_FRONT, 0.5, u) : pow(1.0 - (u - 0.5) * 2.0, 1.5);
			return mix(peaked, bore, broken) - 0.3;
		}

		void surf_wave(vec2 world_xz, float depth, float time, float shelter, out float height, out vec2 slope, out float whitewater, out float presence) {
			height = 0.0;
			slope = vec2(0.0);
			whitewater = 0.0;
			presence = 0.0;

			if ($B.surf_tex < 0 || depth <= 0.0) return;

			vec2 uv = (world_xz - $B.surf_origin) / (2.0 * $B.surf_half) + 0.5;

			if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return;

			vec4 arrival = textureLod(TEXTURE($B.surf_tex), uv, 0.0);
			presence = smoothstep(0.6, 1.0, arrival.w) * (1.0 - smoothstep(0.35, 1.0, depth / $B.surf_deep_depth));

			if (presence <= 0.0) return;

			vec2 travel = arrival.yz / max(arrival.w, 1e-3);
			float cycles = (time - arrival.x / max(arrival.w, 1e-3)) * $B.surf_frequency + 0.5;
			float crest = floor(cycles);
			float u = cycles - crest;
			float along = value_noise2(world_xz * 0.012 + vec2(crest * 3.7, crest * 1.3)) * 0.7 + value_noise2(world_xz * 0.05 + vec2(crest * 1.9, 0.0)) * 0.3;
			float sets = 0.8 + 0.3 * sin(crest * 0.8975979 + value_noise2(world_xz * 0.002) * 6.0);
			vec2 path = textureLod(TEXTURE($B.surf_path_tex), uv, 0.0).rg;
			float shoaling = pow(clamp($B.surf_deep_depth / max(depth, 0.05), 1.0, 40.0), 0.25);
			float wave_height = $B.surf_height * shoaling * mix(0.45, 1.3, along) * sets * (1.0 - 0.85 * shelter);
			float ratio = wave_height / (SURF_BREAKING_RATIO * depth);
			float since_break = path.y * $B.surf_frequency;
			float broken = max(smoothstep(0.85, 1.1, ratio), exp(-max(since_break, 0.0) / SURF_BORE_CYCLES));
			wave_height = min(wave_height, SURF_BREAKING_RATIO * min(depth, max(path.x, 0.0) + 0.25 * max(depth - path.x, 0.0)));
			float wavelength = 1.0 / max(length(travel) * $B.surf_frequency, 1e-3);
			float steepness = clamp(wave_height / wavelength / 0.14, 0.0, 1.0);
			float shape = surf_shape(u, steepness, broken);
			float du = 0.004;
			float shape_slope = (surf_shape(min(u + du, 1.0), steepness, broken) - surf_shape(max(u - du, 0.0), steepness, broken)) / (min(u + du, 1.0) - max(u - du, 0.0));
			height = wave_height * shape * presence;
			slope = -shape_slope * wave_height * $B.surf_frequency * travel * presence;
			float slope_length = length(slope);
			if (slope_length > 2.5) slope *= 2.5 / slope_length;
			float face = u < 0.5 ? smoothstep(0.5 - SURF_BORE_FRONT * 1.5, 0.5, u) : exp(-(u - 0.5) * 12.0);
			float energy = exp(-max(since_break, 0.0) / (SURF_BORE_CYCLES * 2.0)) * smoothstep(0.03, 0.25, wave_height);
			float patches = smoothstep(0.25, 0.7, value_noise2(world_xz * 0.15 + vec2(crest * 5.3, 0.0)) * 0.6 + value_noise2(world_xz * 0.6 - vec2(0.0, crest * 2.1)) * 0.4 + energy * 0.4);
			whitewater = (broken * face * energy * patches + smoothstep(0.75, 1.0, ratio) * smoothstep(0.4, 0.5, u) * (1.0 - step(0.55, u))) * presence;
		}
	]]
	):gsub("%$B", block_name)
end

return surf
