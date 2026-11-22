local ffi = require("ffi")
local mvt = import("goluwa/codecs/mvt.lua")
local geo = import("lua/earth/geo.lua")
-- the lakes, ponds and rivers of one map tile (Overture's water layer) as grids over the tile and a margin around it: the
-- signed distance to the shore (meters, negative in the water) and the level of the nearest water, which the terrain is
-- carved by (water_grid.Carve), and boxes of one level each that cover the water for water volumes
local water_grid = {}
water_grid.SIZE = 1024
water_grid.MARGIN = 16
water_grid.FAR = 10000
-- the shore profile: the ground is cut down (in the water) or raised (on the bank) towards a slope through the shore
water_grid.SHORE_OFFSET = 0.05
water_grid.BANK_SLOPE = 0.25
water_grid.MAX_DEPTH = 3
water_grid.LIFT = 0.5
water_grid.RING = 25
-- the earth's relief finer than its data fades out over these meters from the water, so it cannot poke through
water_grid.NOISE_FADE = 60
-- how far above a box's level the carved ground must stay where the box reaches over land: on the raised bank, and
-- beyond it, where the terrain is the height data smoothed differently than here
water_grid.BANK_FREEBOARD = 0.4
water_grid.FREEBOARD = 0.5
water_grid.MIN_AREA = 350
water_grid.MIN_LEVEL = 0.3
-- land is never carved below this, or the ocean would fill the bed
water_grid.MIN_BED = 0.05
water_grid.MAX_LAKE_SPREAD = 1.5
water_grid.RIVER_BLOCK = 64
water_grid.BOX_MAX = 128
water_grid.MAX_SAMPLES = 4096
local LAKE_SUBTYPES = {lake = "lake", pond = "pond", reservoir = "lake", water = "lake"}
local RIVER_SUBTYPES = {river = true, stream = true, canal = true}
local DROPPED_CLASSES = {
	swimming_pool = true,
	fountain = true,
	basin = true,
	wastewater = true,
	drain = true,
	fish_pass = true,
	ditch = true,
	reflecting_pool = true,
}
local NO_DATA = -32768
local FloatArray = ffi.typeof("float[?]")
local Int32Array = ffi.typeof("int32_t[?]")

function water_grid.Carve(h, sd, level)
	local profile = math.clamp(
		level - water_grid.SHORE_OFFSET + sd * water_grid.BANK_SLOPE,
		level - water_grid.MAX_DEPTH,
		level + water_grid.LIFT
	)

	if sd < 0 then
		return math.min(h, math.max(profile, math.min(h, water_grid.MIN_BED)))
	end

	return math.lerp(
		math.smoothstep(water_grid.RING, water_grid.RING * 2, sd),
		math.max(h, profile),
		h
	)
end

water_grid.GLSL = (
	[=[
float earth_carve(float h, float sd, float level) {
	float profile = clamp(level - %f + sd * %f, level - %f, level + %f);

	if (sd < 0.0) return min(h, max(profile, min(h, %f)));

	return mix(max(h, profile), h, smoothstep(%f, %f, sd));
}

float earth_water_noise(float sd) {
	return smoothstep(%f, %f, sd);
}
]=]
):format(
	water_grid.SHORE_OFFSET,
	water_grid.BANK_SLOPE,
	water_grid.MAX_DEPTH,
	water_grid.LIFT,
	water_grid.MIN_BED,
	water_grid.RING,
	water_grid.RING * 2,
	water_grid.RING * 2,
	water_grid.NOISE_FADE
)

-- the water features of a decoded tile worth carving: {kind ("lake" or "river"), medium, id, rings}
function water_grid.GetFeatures(layers, texel_meters)
	local layer = layers.water
	local out = {}

	if not layer then return out end

	local unit = texel_meters * water_grid.SIZE / layer.extent

	for _, feature in ipairs(layer.features) do
		local p = feature.properties
		local lake = LAKE_SUBTYPES[p.subtype]

		if
			feature.type == mvt.POLYGON and
			(
				lake or
				RIVER_SUBTYPES[p.subtype]
			)
			and
			not DROPPED_CLASSES[p.class] and
			p.is_intermittent ~= true and
			(
				tonumber(p.level) or
				0
			) >= 0
		then
			local area = 0
			local clipped = false

			for _, ring in ipairs(feature.rings) do
				area = area + mvt.GetRingArea(ring)

				for i = 1, #ring do
					if ring[i] < 0 or ring[i] > layer.extent then clipped = true end
				end
			end

			if clipped or area * unit * unit >= water_grid.MIN_AREA then
				local rings = {}

				for r, ring in ipairs(feature.rings) do
					local scaled = {}

					for i = 1, #ring do
						scaled[i] = ring[i] / layer.extent * water_grid.SIZE + water_grid.MARGIN
					end

					rings[r] = scaled
				end

				out[#out + 1] = {
					kind = lake and "lake" or "river",
					medium = lake == "pond" and "pond" or lake and "lake" or "pond",
					id = p.id or tostring(feature.id),
					rings = rings,
				}
			end
		end
	end

	return out
end

-- chamfer distance (in texels) to the texels where dist starts at 0, carrying their source along
local function chamfer(dist, source, width)
	local diagonal = math.sqrt(2)

	for y = 0, width - 1 do
		for x = 0, width - 1 do
			local i = y * width + x
			local d = dist[i]

			if d > 0 then
				local s = source[i]

				if x > 0 and dist[i - 1] + 1 < d then
					d, s = dist[i - 1] + 1, source[i - 1]
				end

				if y > 0 then
					local up = i - width

					if dist[up] + 1 < d then d, s = dist[up] + 1, source[up] end

					if x > 0 and dist[up - 1] + diagonal < d then
						d, s = dist[up - 1] + diagonal, source[up - 1]
					end

					if x < width - 1 and dist[up + 1] + diagonal < d then
						d, s = dist[up + 1] + diagonal, source[up + 1]
					end
				end

				dist[i], source[i] = d, s
			end
		end
	end

	for y = width - 1, 0, -1 do
		for x = width - 1, 0, -1 do
			local i = y * width + x
			local d = dist[i]

			if d > 0 then
				local s = source[i]

				if x < width - 1 and dist[i + 1] + 1 < d then
					d, s = dist[i + 1] + 1, source[i + 1]
				end

				if y < width - 1 then
					local down = i + width

					if dist[down] + 1 < d then d, s = dist[down] + 1, source[down] end

					if x < width - 1 and dist[down + 1] + diagonal < d then
						d, s = dist[down + 1] + diagonal, source[down + 1]
					end

					if x > 0 and dist[down - 1] + diagonal < d then
						d, s = dist[down - 1] + diagonal, source[down - 1]
					end
				end

				dist[i], source[i] = d, s
			end
		end
	end
end

local function distance_to_water(region, width, dist, source)
	for i = 0, width * width - 1 do
		if region[i] > 0 then
			dist[i], source[i] = 0, region[i]
		else
			dist[i], source[i] = math.huge, 0
		end
	end

	chamfer(dist, source, width)
end

local function percentile(values, p)
	table.sort(values)
	return values[math.clamp(math.floor(#values * p) + 1, 1, #values)]
end

-- input: {zoom, x, y (the tile), features (water_grid.GetFeatures), dem = {pixels (float string, NO_DATA for the sea),
-- x0, y0, width, height, zoom, tile_size}, known_levels ({[feature id] = level} of lakes already levelled in other
-- tiles)}; returns meta {levels ({[feature id] = level} of the lakes), boxes ({x0, y0, x1, y1 (tile texels, end
-- exclusive), level, medium}), water (whether any texel is near water)} and a blob of the signed distance then the level
-- grids, (SIZE + 2 * MARGIN)^2 floats each
function water_grid.Build(input)
	local size, margin = water_grid.SIZE, water_grid.MARGIN
	local width = size + margin * 2
	local count = width * width
	local lat = geo.FromMercator(input.x + 0.5, input.y + 0.5, input.zoom, 1)
	local texel_meters = geo.GetPixelSize(lat, input.zoom, size)
	local features = input.features
	local ids = Int32Array(count)

	for index, feature in ipairs(features) do
		mvt.FillRings(ids, width, width, feature.rings, index)
	end

	local dem = FloatArray(count)

	do
		local d = input.dem
		local pixels = ffi.cast("const float *", d.pixels)
		local scale = 2 ^ (d.zoom - input.zoom) * d.tile_size

		local function sample(px, py)
			px = math.clamp(px - d.x0 - 0.5, 0, d.width - 1.001)
			py = math.clamp(py - d.y0 - 0.5, 0, d.height - 1.001)
			local ix, iy = math.floor(px), math.floor(py)
			local fx, fy = px - ix, py - iy
			local o = iy * d.width + ix
			local a, b, c, e = pixels[o], pixels[o + 1], pixels[o + d.width], pixels[o + d.width + 1]
			a, b, c, e = a == NO_DATA and 0 or a,
			b == NO_DATA and 0 or b,
			c == NO_DATA and 0 or c,
			e == NO_DATA and 0 or e
			return math.lerp(fy, math.lerp(fx, a, b), math.lerp(fx, c, e))
		end

		for j = 0, width - 1 do
			local py = (input.y + (j - margin + 0.5) / size) * scale

			for i = 0, width - 1 do
				dem[j * width + i] = sample((input.x + (i - margin + 0.5) / size) * scale, py)
			end
		end
	end

	local inside = FloatArray(count)
	local scratch = Int32Array(count)

	for i = 0, count - 1 do
		inside[i] = ids[i] > 0 and math.huge or 0
	end

	chamfer(inside, scratch, width)
	-- a lake is one region, a river one per block of RIVER_BLOCK texels, as it falls along its course
	local region = Int32Array(count)
	local regions = {}
	local region_keys = {}
	local blocks = math.ceil(width / water_grid.RIVER_BLOCK)

	for j = 0, width - 1 do
		for i = 0, width - 1 do
			local index = ids[j * width + i]

			if index > 0 then
				local bx, by = math.floor(i / water_grid.RIVER_BLOCK), math.floor(j / water_grid.RIVER_BLOCK)
				local key = features[index].kind == "river" and
					index + #features * (
						1 + by * blocks + bx
					)
					or
					index
				local r = region_keys[key]

				if not r then
					r = #regions + 1
					region_keys[key] = r
					regions[r] = {
						feature = features[index],
						index = index,
						bx = bx,
						by = by,
						count = 0,
						interior = 0,
						shore = 0,
					}
				end

				region[j * width + i] = r
				regions[r].count = regions[r].count + 1

				if inside[j * width + i] >= 2.5 then
					regions[r].interior = regions[r].interior + 1
				end
			end
		end
	end

	local outside = FloatArray(count)
	local nearest = Int32Array(count)
	distance_to_water(region, width, outside, nearest)

	for i = 0, count - 1 do
		if outside[i] >= 1 and outside[i] <= 3 and nearest[i] > 0 then
			regions[nearest[i]].shore = regions[nearest[i]].shore + 1
		end
	end

	-- the ground under a region (rivers: and the blocks around, so a block's level follows the course smoothly) and
	-- along its shore, every so many texels
	for _, r in ipairs(regions) do
		r.step = math.max(1, math.floor(r.count / water_grid.MAX_SAMPLES))
		r.interior_step = math.max(1, math.floor(r.interior / water_grid.MAX_SAMPLES))
		r.shore_step = math.max(1, math.floor(r.shore / water_grid.MAX_SAMPLES))
		r.samples, r.interior_samples, r.shore_samples = {}, {}, {}
		r.seen, r.interior_seen, r.shore_seen = 0, 0, 0
	end

	for i = 0, count - 1 do
		local r = regions[region[i]]

		if r then
			r.seen = r.seen + 1

			if r.seen % r.step == 0 then r.samples[#r.samples + 1] = dem[i] end

			if inside[i] >= 2.5 then
				r.interior_seen = r.interior_seen + 1

				if r.interior_seen % r.interior_step == 0 then
					r.interior_samples[#r.interior_samples + 1] = dem[i]
				end
			end
		elseif outside[i] >= 1 and outside[i] <= 3 and nearest[i] > 0 then
			r = regions[nearest[i]]
			r.shore_seen = r.shore_seen + 1

			if r.shore_seen % r.shore_step == 0 then
				r.shore_samples[#r.shore_samples + 1] = dem[i]
			end
		end
	end

	local known = input.known_levels or {}
	local levels = {}
	local rejected = false

	for _, r in ipairs(regions) do
		local feature = r.feature
		local level

		if feature.kind == "lake" then
			level = known[feature.id]

			if not level then
				local samples = #r.interior_samples >= 4 and r.interior_samples or r.samples

				if percentile(samples, 0.9) - percentile(samples, 0.1) <= water_grid.MAX_LAKE_SPREAD then
					level = percentile(samples, 0.5)
				end
			end
		else
			local samples = {}

			for by = r.by - 1, r.by + 1 do
				for bx = r.bx - 1, r.bx + 1 do
					local other = bx >= 0 and
						bx < blocks and
						region_keys[r.index + #features * (
							1 + by * blocks + bx
						)]

					if other then
						for _, v in ipairs(regions[other].samples) do
							samples[#samples + 1] = v
						end
					end
				end
			end

			level = percentile(samples, 0.2)
		end

		if level and not known[feature.id] and r.shore_samples[1] then
			level = math.min(level, percentile(r.shore_samples, 0.25) - 0.3)
		end

		if level then level = math.floor(level * 10 + 0.5) / 10 end

		if level and level < water_grid.MIN_LEVEL then level = nil end

		r.level = level

		if not level then
			rejected = true
		elseif feature.kind == "lake" then
			levels[feature.id] = level
		end
	end

	if rejected then
		for i = 0, count - 1 do
			if region[i] > 0 and not regions[region[i]].level then region[i] = 0 end
		end

		distance_to_water(region, width, outside, nearest)
	end

	-- next to the shore the distance is to the outlines themselves, so the shore is not the texels' stairs
	local exact = FloatArray(count)

	for i = 0, count - 1 do
		exact[i] = math.huge
	end

	for _, r in ipairs(regions) do
		if r.level then r.feature.kept = true end
	end

	for _, feature in ipairs(features) do
		if feature.kept then
			for _, ring in ipairs(feature.rings) do
				local n = #ring
				local ax, ay = ring[n - 1], ring[n]

				for k = 1, n, 2 do
					local bx, by = ring[k], ring[k + 1]
					local pieces = math.max(1, math.ceil(math.max(math.abs(bx - ax), math.abs(by - ay)) / 8))

					for piece = 0, pieces - 1 do
						local px, py = ax + (bx - ax) * piece / pieces, ay + (by - ay) * piece / pieces
						local qx, qy = ax + (bx - ax) * (piece + 1) / pieces, ay + (by - ay) * (piece + 1) / pieces
						local dx, dy = qx - px, qy - py
						local length2 = dx * dx + dy * dy

						for ty = math.max(math.floor(math.min(py, qy) - 2), 0), math.min(math.floor(math.max(py, qy) + 2), width - 1) do
							for tx = math.max(math.floor(math.min(px, qx) - 2), 0), math.min(math.floor(math.max(px, qx) + 2), width - 1) do
								local cx, cy = tx + 0.5, ty + 0.5
								local t = length2 > 0 and
									math.clamp(((cx - px) * dx + (cy - py) * dy) / length2, 0, 1) or
									0
								local ex, ey = px + t * dx - cx, py + t * dy - cy
								local d = math.sqrt(ex * ex + ey * ey)
								local i = ty * width + tx

								if d < exact[i] then exact[i] = d end
							end
						end
					end

					ax, ay = bx, by
				end
			end
		end
	end

	local sd = FloatArray(count * 2)
	local level_grid = sd + count
	local near_water = false

	for i = 0, count - 1 do
		local r = region[i] > 0 and region[i] or nearest[i]
		level_grid[i] = r > 0 and regions[r].level or 0
		local d = region[i] > 0 and inside[i] or outside[i]

		if nearest[i] == 0 and region[i] == 0 then
			d = math.huge
		elseif d <= 1.5 and exact[i] < 3 then
			d = exact[i]
		else
			d = d - 0.5
		end

		sd[i] = math.min(d * texel_meters, water_grid.FAR) * (region[i] > 0 and -1 or 1)

		if sd[i] < water_grid.NOISE_FADE then near_water = true end
	end

	-- boxes of one level each that flood no ground the carved terrain keeps dry
	local boxes = {}

	local function ok(i, level)
		local r = region[i]

		if r > 0 then return math.abs(regions[r].level - level) < 0.01 end

		if sd[i] < texel_meters then return true end

		local ground = water_grid.Carve(dem[i], sd[i], level_grid[i])

		if sd[i] < water_grid.RING then
			return ground >= level + water_grid.BANK_FREEBOARD
		end

		return ground >= level + water_grid.FREEBOARD and
			(
				sd[i] < water_grid.NOISE_FADE or
				ground >= level + 2
			)
	end

	-- greedy rectangles: from each water texel not yet covered, grow a side at a time over texels of its level not yet
	-- covered and over ground the box may reach
	local covered = ffi.new("uint8_t[?]", count)
	local first, last = margin, margin + size - 1

	local function free(i, level)
		local r = region[i]

		if r > 0 then
			return covered[i] == 0 and math.abs(regions[r].level - level) < 0.01
		end

		return ok(i, level)
	end

	local function free_span(level, from_x, to_x, from_y, to_y)
		for yy = from_y, to_y do
			for xx = from_x, to_x do
				if not free(yy * width + xx, level) then return false end
			end
		end

		return true
	end

	-- deepest texels first, so a box grows from the middle of a blob out
	local seeds = {}

	for y = first, last do
		for x = first, last do
			local i = y * width + x

			if region[i] > 0 then
				local depth = math.floor(math.min(inside[i], 1000))
				seeds[depth] = seeds[depth] or {}
				local bucket = seeds[depth]
				bucket[#bucket + 1] = i
			end
		end
	end

	local depths = {}

	for depth in pairs(seeds) do
		depths[#depths + 1] = depth
	end

	table.sort(depths, function(a, b)
		return a > b
	end)

	for _, depth in ipairs(depths) do
		for _, start in ipairs(seeds[depth]) do
			local r = region[start]
			local x, y = start % width, math.floor(start / width)

			if covered[start] == 0 then
				local level = regions[r].level
				local x0, x1, y0, y1 = x, x, y, y
				local growing = true

				while growing do
					growing = false

					if x1 - x0 + 1 < water_grid.BOX_MAX then
						if x1 < last and free_span(level, x1 + 1, x1 + 1, y0, y1) then
							x1 = x1 + 1
							growing = true
						end

						if
							x0 > first and
							x1 - x0 + 1 < water_grid.BOX_MAX and
							free_span(level, x0 - 1, x0 - 1, y0, y1)
						then
							x0 = x0 - 1
							growing = true
						end
					end

					if y1 - y0 + 1 < water_grid.BOX_MAX then
						if y1 < last and free_span(level, x0, x1, y1 + 1, y1 + 1) then
							y1 = y1 + 1
							growing = true
						end

						if
							y0 > first and
							y1 - y0 + 1 < water_grid.BOX_MAX and
							free_span(level, x0, x1, y0 - 1, y0 - 1)
						then
							y0 = y0 - 1
							growing = true
						end
					end
				end

				local min_x, min_y, max_x, max_y = math.huge, math.huge, -1, -1

				for yy = y0, y1 do
					for xx = x0, x1 do
						local i = yy * width + xx

						if
							region[i] > 0 and
							covered[i] == 0 and
							math.abs(regions[region[i]].level - level) < 0.01
						then
							covered[i] = 1
							min_x, min_y = math.min(min_x, xx), math.min(min_y, yy)
							max_x, max_y = math.max(max_x, xx), math.max(max_y, yy)
						end
					end
				end

				boxes[#boxes + 1] = {
					x0 = math.max(min_x - 1, x0) - margin,
					y0 = math.max(min_y - 1, y0) - margin,
					x1 = math.min(max_x + 1, x1) + 1 - margin,
					y1 = math.min(max_y + 1, y1) + 1 - margin,
					level = level,
					medium = regions[r].feature.medium,
				}
			end
		end
	end

	return {levels = levels, boxes = boxes, water = near_water}, sd
end

water_grid.JOB = [[
	local input = ...
	local water_grid = import("lua/earth/water_grid.lua")
	local mvt = import("goluwa/codecs/mvt.lua")
	local geo = import("lua/earth/geo.lua")
	local lat = geo.FromMercator(input.x + 0.5, input.y + 0.5, input.zoom, 1)
	input.features = water_grid.GetFeatures(mvt.Decode(input.mvt), geo.GetPixelSize(lat, input.zoom, water_grid.SIZE))
	return water_grid.Build(input)
]]
return water_grid
