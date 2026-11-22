local ffi = require("ffi")
local mvt = import("goluwa/codecs/mvt.lua")
local geo = import("lua/earth/geo.lua")
-- the roads, paths and railways of one map tile (Overture's transportation segments, which have no widths: the class
-- gives one) as a grid over the tile: the distance to the nearest edge in meters (negative on it, within RANGE) and that
-- road's class; bridges, tunnels and anything above or below the ground are left out
local road_grid = {}
road_grid.ATTRIBUTION = "Roads: Overture Maps Foundation (OpenStreetMap contributors ODbL)"
road_grid.SIZE = 1024
road_grid.RANGE = 16
road_grid.UNPAVED = 32
-- name, half width (m), shoulder (m over which the ground beside blends to the road's), paved and unpaved colour
-- (linear), how much the colour covers the photo, unpaved unless the data says
road_grid.CLASSES = {
	{"motorway", 10, 8, {0.06, 0.06, 0.06}, 0.95},
	{"trunk", 7.5, 6, {0.065, 0.065, 0.065}, 0.95},
	{"primary", 6, 5, {0.07, 0.07, 0.068}, 0.95},
	{"secondary", 5, 4, {0.075, 0.075, 0.072}, 0.9},
	{"tertiary", 4, 4, {0.08, 0.08, 0.077}, 0.9},
	{"residential", 3, 3, {0.13, 0.125, 0.12}, 0.85},
	{"unclassified", 3, 3, {0.1, 0.098, 0.095}, 0.85},
	{"living_street", 2.5, 2, {0.15, 0.145, 0.14}, 0.8},
	{"service", 2, 2, {0.13, 0.125, 0.12}, 0.8},
	{"pedestrian", 2.5, 1, {0.2, 0.19, 0.18}, 0.75},
	{"track", 1.5, 1.5, {0.13, 0.125, 0.12}, 0.7, true},
	{"path", 0.6, 0, {0.2, 0.19, 0.18}, 0.6, true},
	{"footway", 0.8, 0, {0.2, 0.19, 0.18}, 0.65},
	{"cycleway", 1, 0.5, {0.12, 0.115, 0.11}, 0.7},
	{"bridleway", 0.6, 0, {0.2, 0.19, 0.18}, 0.6, true},
	{"unknown", 2.5, 2, {0.12, 0.115, 0.11}, 0.8},
	{"rail", 2, 3, {0.12, 0.112, 0.105}, 0.85},
}
road_grid.UNPAVED_COLOR = {0.2, 0.145, 0.1}
local CLASS = {}

for id, class in ipairs(road_grid.CLASSES) do
	CLASS[class[1]] = id
end

local RAIL_CLASSES = {standard_gauge = true, narrow_gauge = true, light_rail = true}
local SKIPPED_SUBCLASSES = {sidewalk = true, crosswalk = true}
local UNPAVED_SURFACES = {unpaved = true, gravel = true, dirt = true}

do
	local function array(index)
		local values = {}

		for id, class in ipairs(road_grid.CLASSES) do
			local v = class[index]
			values[id] = type(v) == "table" and
				string.format("vec3(%f, %f, %f)", v[1], v[2], v[3]) or
				string.format("%f", v)
		end

		return table.concat(values, ", ")
	end

	local count = #road_grid.CLASSES + 1
	road_grid.GLSL = string.format(
		[=[
const float EARTH_ROAD_HALF_WIDTH[%d] = float[](0.0, %s);
const float EARTH_ROAD_SHOULDER[%d] = float[](0.0, %s);
const vec3 EARTH_ROAD_COLOR[%d] = vec3[](vec3(0.0), %s);
const float EARTH_ROAD_COVER[%d] = float[](0.0, %s);
const vec3 EARTH_ROAD_UNPAVED = vec3(%f, %f, %f);
]=],
		count,
		array(2),
		count,
		array(3),
		count,
		array(4),
		count,
		array(5),
		road_grid.UNPAVED_COLOR[1],
		road_grid.UNPAVED_COLOR[2],
		road_grid.UNPAVED_COLOR[3]
	)
end

-- a segment's class id, nil for what is not drawn
function road_grid.Classify(p)
	if p.subtype == "rail" then return RAIL_CLASSES[p.class] and CLASS.rail end

	if p.subtype ~= "road" or SKIPPED_SUBCLASSES[p.subclass] or p.class == "steps" then
		return
	end

	return CLASS[p.class] or CLASS.unknown
end

local function add_range(ranges, rule, raised)
	local a, b = rule:match("\"between\":%[([^,%]]+),([^%]]+)%]")
	ranges[#ranges + 1] = {tonumber(a) or 0, tonumber(b) or 1, raised = raised}
end

-- the parts along a segment (fractions of its length, {from, to, raised}) that are not on the ground: bridges and levels
-- above 0 (raised), tunnels and levels below, from Overture's rules ([{values or value, between}], a rule without between
-- holds for the whole segment)
function road_grid.GetOffGround(p)
	local ranges = {}

	for _, flags in ipairs{p.road_flags or "", p.rail_flags or ""} do
		for rule in flags:gmatch("%b{}") do
			if rule:find("\"is_bridge\"", 1, true) then
				add_range(ranges, rule, true)
			elseif rule:find("\"is_tunnel\"", 1, true) then
				add_range(ranges, rule, false)
			end
		end
	end

	for rule in (p.level_rules or ""):gmatch("%b{}") do
		local level = tonumber(rule:match("\"value\":(%-?%d+)"))

		if level and level ~= 0 then add_range(ranges, rule, level > 0) end
	end

	return ranges
end

-- whether a segment's surface is unpaved, from its data or else its class
function road_grid.IsUnpaved(p, id)
	local surface = p.road_surface and p.road_surface:match("\"value\":\"([%w_]+)\"")

	if surface then return UNPAVED_SURFACES[surface] == true end

	return road_grid.CLASSES[id][6] == true
end

-- layers: a decoded tile (mvt.Decode), x, y, zoom: the tile; returns meta {any (whether any road is on it)} and a blob
-- of SIZE^2 texel pairs (distance from -RANGE to RANGE over 0 to 255, class id plus UNPAVED for unpaved surfaces), rows
-- from the tile's north
function road_grid.Build(layers, x, y, zoom)
	local size = road_grid.SIZE
	local range = road_grid.RANGE
	local layer = layers.segment
	local dist = ffi.new("float[?]", size * size)
	local class_grid = ffi.new("uint8_t[?]", size * size)

	for i = 0, size * size - 1 do
		dist[i] = range
	end

	local any = false

	if layer then
		local texel_meters = geo.GetPixelSize(geo.FromMercator(x + 0.5, y + 0.5, zoom, 1), zoom, size)
		local scale = size / layer.extent

		for _, feature in ipairs(layer.features) do
			local p = feature.properties
			local id = feature.type == mvt.LINESTRING and road_grid.Classify(p)

			if id then
				local class = road_grid.CLASSES[id]
				local half_width = class[2]
				local reach = (half_width + class[3] + 1) / texel_meters + 1.5
				local value = id + (road_grid.IsUnpaved(p, id) and road_grid.UNPAVED or 0)
				local ranges = road_grid.GetOffGround(p)

				for _, line in ipairs(feature.rings) do
					local n = #line
					local total = 0

					for i = 3, n, 2 do
						total = total + math.sqrt((line[i] - line[i - 2]) ^ 2 + (line[i + 1] - line[i - 1]) ^ 2)
					end

					local along = 0

					for i = 3, n, 2 do
						local ax, ay = line[i - 2] * scale, line[i - 1] * scale
						local bx, by = line[i] * scale, line[i + 1] * scale
						local length = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
						local pieces = math.max(1, math.ceil(length / 8))

						for piece = 0, pieces - 1 do
							local t0, t1 = piece / pieces, (piece + 1) / pieces
							local middle = (along + length * (t0 + t1) / 2) / math.max(total * scale, 1e-9)
							local grounded = true

							for _, r in ipairs(ranges) do
								if middle >= r[1] and middle <= r[2] then grounded = false end
							end

							if grounded then
								local px, py = ax + (bx - ax) * t0, ay + (by - ay) * t0
								local qx, qy = ax + (bx - ax) * t1, ay + (by - ay) * t1
								local dx, dy = qx - px, qy - py
								local length2 = dx * dx + dy * dy

								for ty = math.max(math.floor(math.min(py, qy) - reach), 0), math.min(math.floor(math.max(py, qy) + reach), size - 1) do
									for tx = math.max(math.floor(math.min(px, qx) - reach), 0), math.min(math.floor(math.max(px, qx) + reach), size - 1) do
										local cx, cy = tx + 0.5, ty + 0.5
										local t = length2 > 0 and
											math.clamp(((cx - px) * dx + (cy - py) * dy) / length2, 0, 1) or
											0
										local ex, ey = px + t * dx - cx, py + t * dy - cy
										local d = math.sqrt(ex * ex + ey * ey) * texel_meters - half_width
										local i = ty * size + tx

										if d < dist[i] then
											dist[i] = d
											class_grid[i] = value
											any = true
										end
									end
								end
							end
						end

						along = along + length
					end
				end
			end
		end
	end

	local out = ffi.new("uint8_t[?]", size * size * 2)

	for i = 0, size * size - 1 do
		out[i * 2] = math.floor(math.clamp((dist[i] + range) / (2 * range), 0, 1) * 255 + 0.5)
		out[i * 2 + 1] = class_grid[i]
	end

	return {any = any}, out
end

road_grid.JOB = [[
	local input = ...
	local mvt = import("goluwa/codecs/mvt.lua")
	return import("lua/earth/road_grid.lua").Build(mvt.Decode(input.data), input.x, input.y, input.zoom)
]]
return road_grid
