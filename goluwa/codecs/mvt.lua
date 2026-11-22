local ffi = require("ffi")
local bit = require("bit")
local band, rshift, bxor = bit.band, bit.rshift, bit.bxor
-- decodes Mapbox vector tiles (protobuf, already decompressed): layers of features with their properties and geometry
local mvt = {}
mvt.POINT = 1
mvt.LINESTRING = 2
mvt.POLYGON = 3

local function varint(data, pos)
	local value, scale = 0, 1

	while true do
		local byte = data[pos]
		pos = pos + 1
		value = value + band(byte, 0x7f) * scale

		if byte < 0x80 then return value, pos end

		scale = scale * 128
	end
end

local function zigzag(n)
	return n % 2 == 0 and n / 2 or -(n + 1) / 2
end

-- calls fn(field, wire_type, value, pos, length) for every field of the message in data[from, to): a varint value, or
-- for length delimited fields the start and length of its bytes
local function each_field(data, from, to, fn, ctx)
	local pos = from

	while pos < to do
		local key
		key, pos = varint(data, pos)
		local field, wire = math.floor(key / 8), key % 8

		if wire == 0 then
			local value
			value, pos = varint(data, pos)
			fn(ctx, field, wire, value)
		elseif wire == 2 then
			local length
			length, pos = varint(data, pos)
			fn(ctx, field, wire, nil, pos, length)
			pos = pos + length
		elseif wire == 5 then
			fn(ctx, field, wire, nil, pos, 4)
			pos = pos + 4
		elseif wire == 1 then
			fn(ctx, field, wire, nil, pos, 8)
			pos = pos + 8
		else
			error("mvt: unsupported wire type " .. wire)
		end
	end
end

local float_box = ffi.new("float[1]")
local double_box = ffi.new("double[1]")

local function read_value(ctx, field, wire, value, pos, length)
	local data = ctx.data

	if field == 1 then
		ctx.value = ffi.string(data + pos, length)
	elseif field == 2 then
		ffi.copy(float_box, data + pos, 4)
		ctx.value = float_box[0]
	elseif field == 3 then
		ffi.copy(double_box, data + pos, 8)
		ctx.value = double_box[0]
	elseif field == 4 or field == 5 then
		ctx.value = value
	elseif field == 6 then
		ctx.value = zigzag(value)
	elseif field == 7 then
		ctx.value = value ~= 0
	end
end

-- the rings (flat {x, y, ...} in tile coordinates, y down) of the geometry commands in data[from, to)
local function decode_geometry(data, from, to)
	local rings = {}
	local ring
	local x, y = 0, 0
	local pos = from

	while pos < to do
		local command
		command, pos = varint(data, pos)
		local id, count = band(command, 7), rshift(command, 3)

		if id == 7 then
			ring = nil
		else
			for _ = 1, count do
				local dx, dy
				dx, pos = varint(data, pos)
				dy, pos = varint(data, pos)
				x, y = x + zigzag(dx), y + zigzag(dy)

				if id == 1 then
					ring = {}
					rings[#rings + 1] = ring
				end

				ring[#ring + 1] = x
				ring[#ring + 1] = y
			end
		end
	end

	return rings
end

local function read_feature(ctx, field, wire, value, pos, length)
	local feature = ctx.feature

	if field == 1 then
		feature.id = value
	elseif field == 3 then
		feature.type = value
	elseif field == 2 then
		local data = ctx.data
		local keys, values = ctx.layer.keys, ctx.layer.values
		local properties = feature.properties
		local p, last = pos, pos + length

		while p < last do
			local k, v
			k, p = varint(data, p)
			v, p = varint(data, p)
			properties[keys[k + 1]] = values[v + 1]
		end
	elseif field == 4 then
		feature.geometry_from = pos
		feature.geometry_to = pos + length
	end
end

local function read_layer(ctx, field, wire, value, pos, length)
	local layer = ctx.layer
	local data = ctx.data

	if field == 1 then
		layer.name = ffi.string(data + pos, length)
	elseif field == 3 then
		layer.keys[#layer.keys + 1] = ffi.string(data + pos, length)
	elseif field == 4 then
		ctx.value = nil
		each_field(data, pos, pos + length, read_value, ctx)
		layer.values[#layer.values + 1] = ctx.value
	elseif field == 5 then
		layer.extent = value
	elseif field == 2 then
		layer.feature_ranges[#layer.feature_ranges + 1] = pos
		layer.feature_ranges[#layer.feature_ranges + 1] = pos + length
	end
end

local function read_tile(ctx, field, wire, value, pos, length)
	if field ~= 3 then return end

	ctx.layer = {keys = {}, values = {}, extent = 4096, feature_ranges = {}, features = {}}
	each_field(ctx.data, pos, pos + length, read_layer, ctx)
	local layer = ctx.layer
	local ranges = layer.feature_ranges

	-- features come after keys and values in practice, but the format does not promise it
	for i = 1, #ranges, 2 do
		ctx.feature = {properties = {}}
		each_field(ctx.data, ranges[i], ranges[i + 1], read_feature, ctx)
		local feature = ctx.feature
		feature.rings = feature.geometry_from and
			decode_geometry(ctx.data, feature.geometry_from, feature.geometry_to) or
			{}
		feature.geometry_from = nil
		feature.geometry_to = nil
		layer.features[#layer.features + 1] = feature
	end

	layer.feature_ranges = nil
	ctx.layers[layer.name] = layer
end

-- returns {[layer name] = {name, extent, keys, values, features = {{id, type, properties, rings}}}}
function mvt.Decode(str)
	local ctx = {data = ffi.cast("const uint8_t *", str), layers = {}, owner = str}
	each_field(ctx.data, 0, #str, read_tile, ctx)
	return ctx.layers
end

-- the signed area of a ring in tile coordinates: positive for an exterior ring (clockwise with y down), negative for a hole
function mvt.GetRingArea(ring)
	local area = 0
	local n = #ring
	local px, py = ring[n - 1], ring[n]

	for i = 1, n, 2 do
		local x, y = ring[i], ring[i + 1]
		area = area + (px * y - x * py)
		px, py = x, y
	end

	return area / 2
end

-- a polygon feature's rings grouped into polygons: {{exterior, hole, hole, ...}, ...}
function mvt.GetPolygons(feature)
	local polygons = {}

	for _, ring in ipairs(feature.rings) do
		local area = mvt.GetRingArea(ring)

		if area > 0 then
			polygons[#polygons + 1] = {ring}
		elseif area < 0 and polygons[#polygons] then
			table.insert(polygons[#polygons], ring)
		end
	end

	return polygons
end

-- writes value into a grid of width x height cells under rings (even-odd; ring coordinates in cells, a cell is filled
-- when its center is inside)
function mvt.FillRings(grid, width, height, rings, value)
	local min_y, max_y = math.huge, -math.huge

	for _, ring in ipairs(rings) do
		for i = 2, #ring, 2 do
			min_y = math.min(min_y, ring[i])
			max_y = math.max(max_y, ring[i])
		end
	end

	local crossings = {}

	for row = math.max(math.floor(min_y), 0), math.min(math.ceil(max_y), height - 1) do
		local y = row + 0.5
		local count = 0

		for _, ring in ipairs(rings) do
			local n = #ring
			local px, py = ring[n - 1], ring[n]

			for i = 1, n, 2 do
				local x, ry = ring[i], ring[i + 1]

				if (py <= y) ~= (ry <= y) then
					count = count + 1
					crossings[count] = px + (y - py) * (x - px) / (ry - py)
				end

				px, py = x, ry
			end
		end

		for i = count + 1, #crossings do
			crossings[i] = nil
		end

		table.sort(crossings)
		local o = row * width

		for i = 1, count - 1, 2 do
			for column = math.max(math.ceil(crossings[i] - 0.5), 0), math.min(math.floor(crossings[i + 1] - 0.5), width - 1) do
				grid[o + column] = value
			end
		end
	end
end

return mvt
