local ffi = require("ffi")
local bit = require("bit")
local compiled_terrain = {}
local HEADER_SIZE = 32
local GROUP_RECORD_SIZE = 332
local NAME_RECORD_SIZE = 260
local NODE_HEADER_SIZE = 45
local NODE_TAIL_SIZE = 20
local SECTOR_SIZE_IN_METERS = 64
local SURFACE_MASK = 15
local SURFACE_TYPE_COUNT = 15
local HEIGHT_MASK = 0xfff0
local HEIGHT_CENTER = 8
local u8 = ffi.typeof("const uint8_t *")
local i32 = ffi.typeof("const int32_t *")
local f32 = ffi.typeof("const float *")
local i16 = ffi.typeof("const int16_t *")
local coarse = ffi.new("uint16_t[?]", 33 * 33)
local surface_ids = ffi.new("uint8_t[?]", 33 * 33)

local function read_i32(base, offset)
	return ffi.cast(i32, base + offset)[0]
end

function compiled_terrain.Parse(data, max_height)
	local base = ffi.cast(u8, data)
	local info = ffi.cast(i32, base + 8)
	local size = info[0]
	local unit_size = info[1]
	local units_per_sector = info[2] / unit_size
	local position = HEADER_SIZE
	position = position + 4 + read_i32(base, position) * GROUP_RECORD_SIZE
	position = position + 4 + read_i32(base, position) * NAME_RECORD_SIZE
	position = position + 4 + read_i32(base, position) * NAME_RECORD_SIZE
	local heights = ffi.new("uint16_t[?]", size * size)
	local surfaces = ffi.new("uint8_t[?]", size * size)
	local to_raw = 65535 / max_height

	local function read_node()
		assert(ffi.cast(i16, base + position)[0] == 5, "unknown terrain node version")
		local bounds = ffi.cast(f32, base + position + 4)
		local min_x, min_y, max_x = bounds[0], bounds[1], bounds[3]
		local offset = ffi.cast(f32, base + position + 29)[0]
		local range = ffi.cast(f32, base + position + 33)[0]
		local count = read_i32(base, position + 37)
		local surface_count = read_i32(base, position + 41)
		local heights_start = position + NODE_HEADER_SIZE
		position = heights_start + count * count * 2 + surface_count + NODE_TAIL_SIZE

		if max_x - min_x > SECTOR_SIZE_IN_METERS then
			for _ = 1, 4 do
				read_node()
			end

			return
		end

		ffi.copy(coarse, base + heights_start, count * count * 2)

		for i = 0, count * count - 1 do
			local id = bit.band(coarse[i], SURFACE_MASK)
			surface_ids[i] = id < SURFACE_TYPE_COUNT and id + 1 or 0
			coarse[i] = bit.band(coarse[i], HEIGHT_MASK) + HEIGHT_CENTER
		end

		local x0 = min_x / unit_size
		local y0 = min_y / unit_size
		local step = (count - 1) / units_per_sector

		for ux = 0, units_per_sector - 1 do
			local fx = ux * step
			local cx = math.min(math.floor(fx), count - 2)
			local tx = fx - cx

			for uy = 0, units_per_sector - 1 do
				local fy = uy * step
				local cy = math.min(math.floor(fy), count - 2)
				local ty = fy - cy
				local a = coarse[cx * count + cy]
				local b = coarse[cx * count + cy + 1]
				local c = coarse[(cx + 1) * count + cy]
				local d = coarse[(cx + 1) * count + cy + 1]
				local value = (a * (1 - ty) + b * ty) * (1 - tx) + (c * (1 - ty) + d * ty) * tx
				local index = (x0 + ux) * size + y0 + uy
				heights[index] = math.floor((offset + value * range) * to_raw + 0.5)
				surfaces[index] = surface_ids[math.floor(fx + 0.5) * count + math.floor(fy + 0.5)]
			end
		end
	end

	read_node()
	return {
		size = size,
		height_data = ffi.string(heights, size * size * 2),
		surface_indices = surfaces,
		instances_offset = position,
	}
end

return compiled_terrain
