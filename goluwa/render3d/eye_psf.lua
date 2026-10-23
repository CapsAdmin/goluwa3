local ffi = require("ffi")
local fft = import("goluwa/math/fft.lua")
local eye_glare = import("goluwa/render3d/eye_glare.lua")
local eye_psf = {}
eye_psf.GRID = 2048
eye_psf.SAMPLE_SPACING = 4e-6
eye_psf.PUPIL_DIAMETER = 4e-3
eye_psf.ANGLES = 1024
eye_psf.RADII = 160
eye_psf.MIN_DEGREES = 0.05
eye_psf.PREFILTER_DEGREES = 0.25
local SUB_SAMPLES = 4
local FIBRE_COUNT = 450
local FIBRE_MIN_WIDTH = 6e-6
local FIBRE_MAX_WIDTH = 50e-6
local LASH_WIDTH = 35e-6
local LASH_COUNT = 24
local SPECK_COUNT = 250

function eye_psf.GetMaxDegrees()
	return math.deg(eye_glare.REFERENCE_WAVELENGTH * 1e-9 / (2 * eye_psf.SAMPLE_SPACING))
end

local function make_random(seed)
	local state = seed
	return function()
		state = (state * 1664525 + 1013904223) % 4294967296
		return state / 4294967296
	end
end

local function build_aperture(re, grid, plain)
	local spacing = eye_psf.SAMPLE_SPACING
	local radius = eye_psf.PUPIL_DIAMETER / 2
	local half = grid / 2
	local transmission = ffi.new("float[?]", grid * grid)

	for iy = 0, grid - 1 do
		local y = (iy - half) * spacing

		for ix = 0, grid - 1 do
			local x = (ix - half) * spacing

			if x * x + y * y <= radius * radius then transmission[iy * grid + ix] = 1 end
		end
	end

	local function paint(x_min, x_max, y_min, y_max, inside, factor)
		for iy = math.max(math.floor(y_min / spacing + half), 0), math.min(math.ceil(y_max / spacing + half), grid - 1) do
			local y = (iy - half) * spacing

			for ix = math.max(math.floor(x_min / spacing + half), 0), math.min(math.ceil(x_max / spacing + half), grid - 1) do
				local x = (ix - half) * spacing

				if inside(x, y) then
					transmission[iy * grid + ix] = transmission[iy * grid + ix] * factor
				end
			end
		end
	end

	if not plain then
		local random = make_random(20240611)

		for _ = 1, FIBRE_COUNT do
			local angle = random() * 2 * math.pi
			local dx, dy = math.cos(angle), math.sin(angle)
			local start = radius * (0.05 + random() * 0.8)
			local length = radius * (0.1 + random() ^ 2 * 0.7)
			local width = FIBRE_MIN_WIDTH * (FIBRE_MAX_WIDTH / FIBRE_MIN_WIDTH) ^ random()
			local transmission = 0.2 + random() * 0.65
			local sx, sy = dx * start, dy * start
			local ex, ey = dx * (start + length), dy * (start + length)

			paint(
				math.min(sx, ex) - width,
				math.max(sx, ex) + width,
				math.min(sy, ey) - width,
				math.max(sy, ey) + width,
				function(x, y)
					local along = (x - sx) * dx + (y - sy) * dy
					return math.abs((x - sx) * dy - (y - sy) * dx) < width / 2 and
						along >= 0 and
						along <= length
				end,
				transmission
			)
		end

		for _ = 1, LASH_COUNT do
			local side = random() < 0.5 and -1 or 1
			local x0 = (random() * 2 - 1) * radius * 0.7
			local length = radius * (0.1 + random() * 0.25)
			local y_edge = side * radius

			paint(
				x0 - LASH_WIDTH,
				x0 + LASH_WIDTH,
				math.min(y_edge, y_edge - side * length) - spacing,
				math.max(y_edge, y_edge - side * length) + spacing,
				function(x, y)
					return math.abs(x - x0) < LASH_WIDTH / 2 and
						(
							y_edge - y
						) * side >= 0 and
						(
							y_edge - y
						) * side <= length
				end,
				0
			)
		end

		for _ = 1, SPECK_COUNT do
			local angle, distance = random() * 2 * math.pi, math.sqrt(random()) * radius
			local sx, sy = distance * math.cos(angle), distance * math.sin(angle)
			local speck_radius = (6 + random() * 14) * 1e-6

			paint(
				sx - speck_radius,
				sx + speck_radius,
				sy - speck_radius,
				sy + speck_radius,
				function(x, y)
					return (x - sx) ^ 2 + (y - sy) ^ 2 < speck_radius ^ 2
				end,
				0
			)
		end
	end

	for iy = 0, grid - 1 do
		for ix = 0, grid - 1 do
			re[iy * grid + ix] = transmission[iy * grid + ix] * ((ix + iy) % 2 == 0 and 1 or -1)
		end
	end
end

function eye_psf.BuildSpectrum(plain)
	local grid = eye_psf.GRID
	local re, im = ffi.new("double[?]", grid * grid), ffi.new("double[?]", grid * grid)
	build_aperture(re, grid, plain)
	fft.Transform2D(re, im, grid, false)
	local power = ffi.new("float[?]", grid * grid)

	for i = 0, grid * grid - 1 do
		power[i] = re[i] * re[i] + im[i] * im[i]
	end

	return power
end

function eye_psf.GetDegreesPerTexel()
	return math.deg(eye_glare.REFERENCE_WAVELENGTH * 1e-9 / (eye_psf.GRID * eye_psf.SAMPLE_SPACING))
end

function eye_psf.BuildModulation(power)
	local grid = eye_psf.GRID
	local half = grid / 2
	local angles, radii = eye_psf.ANGLES, eye_psf.RADII
	local per_texel = eye_psf.GetDegreesPerTexel()
	local log_min, log_max = math.log(eye_psf.MIN_DEGREES), math.log(eye_psf.GetMaxDegrees())
	local modulation = ffi.new("float[?]", angles * radii)
	local ring = ffi.new("double[?]", angles)
	local prefix = ffi.new("double[?]", angles * 3 + 1)
	local radial_step = (log_max - log_min) / radii

	for ir = 0, radii - 1 do
		for ia = 0, angles - 1 do
			local value = 0

			for radial = 0, SUB_SAMPLES - 1 do
				local degrees = math.exp(log_min + (ir + (radial + 0.5) / SUB_SAMPLES) * radial_step)
				local texels = degrees / per_texel

				for sub = 0, SUB_SAMPLES - 1 do
					local angle = (ia + (sub + 0.5) / SUB_SAMPLES) / angles * 2 * math.pi
					local fx = half + math.cos(angle) * texels
					local fy = half + math.sin(angle) * texels
					local x0, y0 = math.floor(fx), math.floor(fy)
					local tx, ty = fx - x0, fy - y0
					local a = power[y0 * grid + x0]
					local b = power[y0 * grid + x0 + 1]
					local c = power[(y0 + 1) * grid + x0]
					local d = power[(y0 + 1) * grid + x0 + 1]
					value = value + (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
				end
			end

			ring[ia] = value
		end

		local degrees = math.exp(log_min + (ir + 0.5) * radial_step)
		local width = math.clamp(
			math.floor(eye_psf.PREFILTER_DEGREES * angles / (2 * math.pi * degrees) + 0.5),
			1,
			angles
		)

		for i = 0, angles * 3 - 1 do
			prefix[i + 1] = prefix[i] + ring[i % angles]
		end

		local sum = 0

		for ia = 0, angles - 1 do
			local low = ia + angles - math.floor(width / 2)
			local value = (prefix[low + width] - prefix[low]) / width
			modulation[ir * angles + ia] = value
			sum = sum + value
		end

		local mean = sum / angles

		for ia = 0, angles - 1 do
			modulation[ir * angles + ia] = modulation[ir * angles + ia] / mean
		end
	end

	return modulation
end

function eye_psf.BuildSpreadTable(entries, min_degrees, max_degrees)
	local table = ffi.new("float[?]", entries * 4)

	for i = 0, entries - 1 do
		local degrees = math.exp(
			math.log(min_degrees) + (
					i + 0.5
				) / entries * (
					math.log(max_degrees) - math.log(min_degrees)
				)
		)

		for channel = 1, 3 do
			table[i * 4 + channel - 1] = eye_glare.GetSpread(degrees, eye_glare.CHANNEL_WAVELENGTH[channel] / eye_glare.REFERENCE_WAVELENGTH)
		end

		table[i * 4 + 3] = 0
	end

	return table
end

return eye_psf
