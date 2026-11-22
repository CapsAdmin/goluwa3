local ffi = require("ffi")
local bit = require("bit")
local mvt = import("goluwa/codecs/mvt.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local planet = import("goluwa/planet.lua")
local geo = import("lua/earth/geo.lua")
local tint_mesh = import("lua/earth/tint_mesh.lua")
-- a building tile's blocks as wall and roof meshes, built on the thread pool (BuildJob)
local building_mesh = {}
building_mesh.FLOOR_HEIGHT = 3.2
-- a wall's uv has a whole number of bays about this wide across and a floor per unit up, the wall's bottom at -FOOTING
building_mesh.BAY_WIDTH = 4
-- the walls reach this far under the lowest ground of their footprint, so slopes do not show the gap under them
building_mesh.FOOTING = 3
building_mesh.CLASS_HEIGHTS = {
	garage = 3,
	garages = 3,
	shed = 3,
	carport = 3,
	hut = 3,
	kiosk = 3,
	roof = 4,
	house = 7,
	detached = 7,
	semidetached_house = 7,
	terrace = 8,
	residential = 10,
	apartments = 15,
}
building_mesh.DEFAULT_HEIGHT = 8
-- sRGB colours a building is picked from by a hash of its id, weights first: plaster, brick, paint
building_mesh.WALL_COLORS = {
	{6, 0.86, 0.84, 0.80},
	{5, 0.90, 0.85, 0.72},
	{4, 0.82, 0.74, 0.60},
	{4, 0.70, 0.70, 0.68},
	{3, 0.62, 0.58, 0.54},
	{2, 0.55, 0.32, 0.24},
	{2, 0.42, 0.26, 0.20},
	{1, 0.93, 0.84, 0.55},
	{1, 0.68, 0.78, 0.85},
	{1, 0.86, 0.66, 0.62},
	{1, 0.72, 0.80, 0.66},
}
building_mesh.ROOF_COLORS = {
	{5, 0.42, 0.42, 0.41},
	{4, 0.32, 0.32, 0.33},
	{2, 0.52, 0.50, 0.47},
	{2, 0.55, 0.31, 0.23},
	{1, 0.34, 0.36, 0.40},
}
building_mesh.JITTER = 0.06
-- a roof's colour from the photo: its pixels at least this far inside its outline, not in shadow, at least this many
building_mesh.PHOTO_INSET = 1.0
building_mesh.PHOTO_SHADOW = 120
building_mesh.PHOTO_MIN_PIXELS = 6
-- a mapped colour is muted toward grey by this much: they are named colours, saturated
building_mesh.MAPPED_MUTE = 0.35
building_mesh.COLOR_NAMES = {
	white = {0.92, 0.92, 0.90},
	black = {0.15, 0.15, 0.15},
	grey = {0.55, 0.55, 0.55},
	gray = {0.55, 0.55, 0.55},
	silver = {0.72, 0.72, 0.72},
	red = {0.70, 0.25, 0.20},
	maroon = {0.45, 0.18, 0.15},
	brown = {0.50, 0.34, 0.24},
	beige = {0.86, 0.80, 0.66},
	tan = {0.80, 0.70, 0.55},
	orange = {0.85, 0.52, 0.28},
	yellow = {0.92, 0.82, 0.45},
	cream = {0.92, 0.88, 0.74},
	green = {0.42, 0.58, 0.38},
	blue = {0.40, 0.52, 0.70},
	pink = {0.90, 0.68, 0.68},
}
local VERTEX_SIZE = tint_mesh.VERTEX_SIZE

local function get_height(properties)
	if properties.height then return properties.height end

	if properties.num_floors then
		return properties.num_floors * building_mesh.FLOOR_HEIGHT
	end

	return building_mesh.CLASS_HEIGHTS[properties.class] or building_mesh.DEFAULT_HEIGHT
end

local function hash01(id, salt)
	local h = 2166136261

	for i = 1, #id do
		h = bit.bxor(h, id:byte(i))
		h = bit.tobit(bit.band(h, 0xffff) * 16777619 + bit.tobit(bit.rshift(h, 16) * 16777619) * 65536)
	end

	h = bit.bxor(h, salt * 2654435761 % 4294967296)
	h = bit.tobit(bit.band(h, 0xffff) * 16777619 + bit.tobit(bit.rshift(h, 16) * 16777619) * 65536)
	return (h % 4294967296) / 4294967296
end

local function to_linear(c)
	return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

-- an sRGB colour weighted from a list by a hash, with a little brightness jitter, as linear rgb
local function pick(list, id, salt)
	local total = 0

	for _, entry in ipairs(list) do
		total = total + entry[1]
	end

	local t = hash01(id, salt) * total
	local chosen = list[#list]

	for _, entry in ipairs(list) do
		t = t - entry[1]

		if t < 0 then
			chosen = entry

			break
		end
	end

	local jitter = 1 + (hash01(id, salt + 1) * 2 - 1) * building_mesh.JITTER
	return to_linear(chosen[2] * jitter),
	to_linear(chosen[3] * jitter),
	to_linear(chosen[4] * jitter)
end

-- a mapped colour ("#rrggbb" or a name) muted toward grey, as linear rgb, nil when unknown
local function parse_color(value)
	if type(value) ~= "string" then return end

	local r, g, b
	local hex = value:match("^#(%x%x%x%x%x%x)$")

	if hex then
		r, g, b = tonumber(hex:sub(1, 2), 16) / 255,
		tonumber(hex:sub(3, 4), 16) / 255,
		tonumber(hex:sub(5, 6), 16) / 255
	else
		local named = building_mesh.COLOR_NAMES[value:lower()]

		if not named then return end

		r, g, b = named[1], named[2], named[3]
	end

	local grey = (r + g + b) / 3
	local mute = building_mesh.MAPPED_MUTE
	return to_linear(math.lerp(mute, r, grey)),
	to_linear(math.lerp(mute, g, grey)),
	to_linear(math.lerp(mute, b, grey))
end

-- the mean colour of a roof in the photo (its pixels inside the outline, inset, out of shadow) as linear rgb, nil when
-- too few are left; rings are flat {x, y, ...} in the photo's pixels
local function photo_color(photo, rings)
	local pixels = photo.data
	local width, height = photo.width, photo.height
	local inset = building_mesh.PHOTO_INSET / photo.meters
	local min_x, min_y, max_x, max_y = math.huge, math.huge, -math.huge, -math.huge
	local outer = rings[1]

	for i = 1, #outer, 2 do
		min_x, max_x = math.min(min_x, outer[i]), math.max(max_x, outer[i])
		min_y, max_y = math.min(min_y, outer[i + 1]), math.max(max_y, outer[i + 1])
	end

	local r, g, b, count = 0, 0, 0, 0

	for py = math.max(math.floor(min_y), 0), math.min(math.ceil(max_y), height - 1) do
		local cy = py + 0.5

		for px = math.max(math.floor(min_x), 0), math.min(math.ceil(max_x), width - 1) do
			local cx = px + 0.5
			local crossings = 0
			local nearest = math.huge

			for _, ring in ipairs(rings) do
				local n = #ring
				local ax, ay = ring[n - 1], ring[n]

				for i = 1, n, 2 do
					local bx, by = ring[i], ring[i + 1]

					if (ay > cy) ~= (by > cy) and cx < ax + (cy - ay) * (bx - ax) / (by - ay) then
						crossings = crossings + 1
					end

					local dx, dy = bx - ax, by - ay
					local t = math.clamp(((cx - ax) * dx + (cy - ay) * dy) / math.max(dx * dx + dy * dy, 1e-9), 0, 1)
					local ex, ey = ax + dx * t - cx, ay + dy * t - cy
					nearest = math.min(nearest, ex * ex + ey * ey)
					ax, ay = bx, by
				end
			end

			if crossings % 2 == 1 and nearest >= inset * inset then
				local o = (py * width + px) * 4
				local pr, pg, pb = pixels[o], pixels[o + 1], pixels[o + 2]

				if pr + pg + pb >= building_mesh.PHOTO_SHADOW then
					r, g, b, count = r + pr, g + pg, b + pb, count + 1
				end
			end
		end
	end

	if count < building_mesh.PHOTO_MIN_PIXELS then return end

	return to_linear(r / count / 255),
	to_linear(g / count / 255),
	to_linear(b / count / 255)
end

-- walls from bottom to top (a height, or a height per ring vertex)
local function add_walls(mesh, ring, bottom, top)
	local n = #ring / 2
	tint_mesh.Reserve(mesh, n * 4, n * 6)

	for i = 1, n do
		local ax, az = ring[i * 2 - 1], ring[i * 2]
		local j = i % n + 1
		local bx, bz = ring[j * 2 - 1], ring[j * 2]
		local dx, dz = bx - ax, bz - az
		local length = math.sqrt(dx * dx + dz * dz)

		if length > 0.01 then
			local top_a = type(top) == "table" and top[i] or top
			local top_b = type(top) == "table" and top[j] or top
			local nx, nz = dz / length, -dx / length
			local tx, tz = dx / length, dz / length
			local u = math.max(math.floor(length / building_mesh.BAY_WIDTH + 0.5), 1)
			local v0 = -building_mesh.FOOTING / building_mesh.FLOOR_HEIGHT
			local a0 = tint_mesh.AddVertex(mesh, ax, bottom, az, nx, 0, nz, 0, v0, tx, tz)
			local b0 = tint_mesh.AddVertex(mesh, bx, bottom, bz, nx, 0, nz, u, v0, tx, tz)
			local b1 = tint_mesh.AddVertex(
				mesh,
				bx,
				top_b,
				bz,
				nx,
				0,
				nz,
				u,
				v0 + (top_b - bottom) / building_mesh.FLOOR_HEIGHT,
				tx,
				tz
			)
			local a1 = tint_mesh.AddVertex(
				mesh,
				ax,
				top_a,
				az,
				nx,
				0,
				nz,
				0,
				v0 + (top_a - bottom) / building_mesh.FLOOR_HEIGHT,
				tx,
				tz
			)
			tint_mesh.AddTriangle(mesh, a0, b1, a1)
			tint_mesh.AddTriangle(mesh, a0, b0, b1)
		end
	end
end

-- a flat roof at top over rings, or facing down (the underside of a part off the ground)
local function add_roof(mesh, rings, top, down)
	local triangles = math2d.TriangulateContoursEvenOdd(rings)
	local count = #triangles / 6
	tint_mesh.Reserve(mesh, count * 3, count * 3)

	for t = 0, count - 1 do
		local o = t * 6
		local ax, az = triangles[o + 1], triangles[o + 2]
		local bx, bz = triangles[o + 3], triangles[o + 4]
		local cx, cz = triangles[o + 5], triangles[o + 6]
		local ny = down and -1 or 1
		local a = tint_mesh.AddVertex(mesh, ax, top, az, 0, ny, 0, ax / 8, az / 8, 1, 0)
		local b = tint_mesh.AddVertex(mesh, bx, top, bz, 0, ny, 0, bx / 8, bz / 8, 1, 0)
		local c = tint_mesh.AddVertex(mesh, cx, top, cz, 0, ny, 0, cx / 8, cz / 8, 1, 0)

		if ((bz - az) * (cx - ax) - (bx - ax) * (cz - az) > 0) ~= (down == true) then
			tint_mesh.AddTriangle(mesh, a, c, b)
		else
			tint_mesh.AddTriangle(mesh, a, b, c)
		end
	end
end

-- a roof triangle at its own heights, facing up
local function add_roof_triangle(mesh, ax, ay, az, bx, by, bz, cx, cy, cz)
	local ux, uy, uz = bx - ax, by - ay, bz - az
	local vx, vy, vz = cx - ax, cy - ay, cz - az
	local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
	local length = math.sqrt(nx * nx + ny * ny + nz * nz)

	if length < 1e-9 then return end

	local flip = ny > 0
	nx, ny, nz = nx / length, ny / length, nz / length

	if not flip then nx, ny, nz = -nx, -ny, -nz end

	tint_mesh.Reserve(mesh, 3, 3)
	local a = tint_mesh.AddVertex(mesh, ax, ay, az, nx, ny, nz, ax / 8, az / 8, 1, 0)
	local b = tint_mesh.AddVertex(mesh, bx, by, bz, nx, ny, nz, bx / 8, bz / 8, 1, 0)
	local c = tint_mesh.AddVertex(mesh, cx, cy, cz, nx, ny, nz, cx / 8, cz / 8, 1, 0)

	if flip then
		tint_mesh.AddTriangle(mesh, a, c, b)
	else
		tint_mesh.AddTriangle(mesh, a, b, c)
	end
end

-- roofs that are a cross section across a ridge: heights (0 at the eaves, 1 at the top) at points across the roof from
-- -1 to 1, linear between; the ridge runs along the outline's longest side
building_mesh.SECTIONS = {
	gabled = {{-1, 0}, {0, 1}, {1, 0}},
	half_hipped = {{-1, 0}, {0, 1}, {1, 0}},
	saltbox = {{-1, 0}, {0.35, 1}, {1, 0}},
	gambrel = {{-1, 0}, {-0.6, 0.7}, {0, 1}, {0.6, 0.7}, {1, 0}},
	round = {{-1, 0}, {-0.87, 0.5}, {-0.5, 0.87}, {0, 1}, {0.5, 0.87}, {0.87, 0.5}, {1, 0}},
	skillion = {{-1, 1}, {1, 0}},
}
-- roofs that are rings toward the outline's centre: {scale of the outline, height}, a last scale above 0 is a flat top
building_mesh.RINGS = {
	pyramidal = {{1, 0}, {0, 1}},
	cone = {{1, 0}, {0, 1}},
	hipped = {{1, 0}, {0.3, 1}},
	mansard = {{1, 0}, {0.8, 0.75}, {0.55, 1}},
	dome = {
		{1, 0},
		{0.97, 0.26},
		{0.87, 0.5},
		{0.71, 0.71},
		{0.5, 0.87},
		{0.26, 0.97},
		{0, 1},
	},
	onion = {{1, 0}, {1.15, 0.2}, {1.1, 0.4}, {0.85, 0.6}, {0.45, 0.8}, {0.15, 0.92}, {0, 1}},
}
-- a roof's height when the data has none: a share of its half width across the ridge, or of its outline's distance
-- from the centre for rings
building_mesh.ROOF_PITCH = 0.6

local function section_height(section, t)
	for k = 2, #section do
		local a, b = section[k - 1], section[k]

		if t <= b[1] or k == #section then
			return math.lerp(math.clamp((t - a[1]) / (b[1] - a[1]), 0, 1), a[2], b[2])
		end
	end
end

-- the polygon (convex, flat {x, z, ...}) on the side of the line d = cut (d along ux, uz) that keep says
local function clip(poly, ux, uz, cut, keep_below)
	local out = {}
	local n = #poly / 2

	for i = 1, n do
		local j = i % n + 1
		local ax, az, bx, bz = poly[i * 2 - 1], poly[i * 2], poly[j * 2 - 1], poly[j * 2]
		local da, db = ax * ux + az * uz - cut, bx * ux + bz * uz - cut

		if keep_below then da, db = -da, -db end

		if da >= 0 then
			out[#out + 1] = ax
			out[#out + 1] = az
		end

		if (da >= 0) ~= (db >= 0) then
			local t = da / (da - db)
			out[#out + 1] = ax + (bx - ax) * t
			out[#out + 1] = az + (bz - az) * t
		end
	end

	return out
end

-- every ring with a vertex added where it crosses one of the cuts (d along ux, uz)
local function split_rings(rings, ux, uz, cuts)
	local out = {}

	for r, ring in ipairs(rings) do
		local split = {}
		local n = #ring / 2

		for i = 1, n do
			local j = i % n + 1
			local ax, az, bx, bz = ring[i * 2 - 1], ring[i * 2], ring[j * 2 - 1], ring[j * 2]
			local da, db = ax * ux + az * uz, bx * ux + bz * uz
			split[#split + 1] = ax
			split[#split + 1] = az
			local crossings = {}

			for _, cut in ipairs(cuts) do
				if (da - cut) * (db - cut) < 0 then
					crossings[#crossings + 1] = (cut - da) / (db - da)
				end
			end

			table.sort(crossings)

			for _, t in ipairs(crossings) do
				split[#split + 1] = ax + (bx - ax) * t
				split[#split + 1] = az + (bz - az) * t
			end
		end

		out[r] = split
	end

	return out
end

-- a roof of a cross section over rings (the first the outline) up to top, at most max_roof tall: the rings split where
-- the section bends and the walls' tops per vertex of them
local function add_section_roof(mesh, rings, top, max_roof, section, properties)
	local outline = rings[1]
	local n = #outline / 2
	local lx, lz, longest = 1, 0, 0

	for i = 1, n do
		local j = i % n + 1
		local dx, dz = outline[j * 2 - 1] - outline[i * 2 - 1], outline[j * 2] - outline[i * 2]
		local length = dx * dx + dz * dz

		if length > longest then lx, lz, longest = dx, dz, length end
	end

	longest = math.sqrt(longest)
	lx, lz = lx / longest, lz / longest
	-- across the ridge
	local ux, uz = -lz, lx

	if properties.roof_orientation == "across" then ux, uz = lx, lz end

	local low, high = math.huge, -math.huge

	for i = 1, n do
		local d = outline[i * 2 - 1] * ux + outline[i * 2] * uz
		low, high = math.min(low, d), math.max(high, d)
	end

	local middle, half = (low + high) / 2, math.max((high - low) / 2, 0.01)
	local roof_height = math.min(properties.roof_height or half * building_mesh.ROOF_PITCH, max_roof)
	local eave = top - roof_height
	local cuts = {}

	for k = 2, #section - 1 do
		cuts[#cuts + 1] = middle + section[k][1] * half
	end

	local function height_at(x, z)
		return eave + roof_height * section_height(section, (x * ux + z * uz - middle) / half)
	end

	local split = split_rings(rings, ux, uz, cuts)
	local tops = {}

	for r, ring in ipairs(split) do
		tops[r] = {}

		for i = 1, #ring / 2 do
			tops[r][i] = height_at(ring[i * 2 - 1], ring[i * 2])
		end
	end

	local triangles = math2d.TriangulateContoursEvenOdd(split)

	for t = 0, #triangles / 6 - 1 do
		local pieces = {
			{
				triangles[t * 6 + 1],
				triangles[t * 6 + 2],
				triangles[t * 6 + 3],
				triangles[t * 6 + 4],
				triangles[t * 6 + 5],
				triangles[t * 6 + 6],
			},
		}

		for _, cut in ipairs(cuts) do
			local next_pieces = {}

			for _, piece in ipairs(pieces) do
				for _, keep_below in ipairs{true, false} do
					local part = clip(piece, ux, uz, cut, keep_below)

					if #part >= 6 then next_pieces[#next_pieces + 1] = part end
				end
			end

			pieces = next_pieces
		end

		for _, piece in ipairs(pieces) do
			local ax, az = piece[1], piece[2]

			for k = 2, #piece / 2 - 1 do
				local bx, bz, cx, cz = piece[k * 2 - 1], piece[k * 2], piece[k * 2 + 1], piece[k * 2 + 2]
				add_roof_triangle(
					mesh,
					ax,
					height_at(ax, az),
					az,
					bx,
					height_at(bx, bz),
					bz,
					cx,
					height_at(cx, cz),
					cz
				)
			end
		end
	end

	return split, tops
end

-- a roof of rings toward the outline's centre (its holes are covered) up to top, at most max_roof tall; returns the eaves'
-- height
local function add_ring_roof(mesh, outline, top, max_roof, rings_profile, properties)
	local n = #outline / 2
	local cx, cz, area = 0, 0, 0

	for i = 1, n do
		local j = i % n + 1
		local ax, az, bx, bz = outline[i * 2 - 1], outline[i * 2], outline[j * 2 - 1], outline[j * 2]
		local cross = ax * bz - bx * az
		area = area + cross
		cx, cz = cx + (ax + bx) * cross, cz + (az + bz) * cross
	end

	if math.abs(area) < 1e-6 then return top end

	cx, cz = cx / (3 * area), cz / (3 * area)
	local reach = math.huge

	for i = 1, n do
		reach = math.min(reach, math.sqrt((outline[i * 2 - 1] - cx) ^ 2 + (outline[i * 2] - cz) ^ 2))
	end

	local roof_height = math.min(properties.roof_height or reach * building_mesh.ROOF_PITCH, max_roof)
	local eave = top - roof_height

	local function at(i, k)
		local scale, h = rings_profile[k][1], rings_profile[k][2]
		return cx + (outline[i * 2 - 1] - cx) * scale,
		eave + roof_height * h,
		cz + (outline[i * 2] - cz) * scale
	end

	for k = 2, #rings_profile do
		for i = 1, n do
			local j = i % n + 1
			local ax, ay, az = at(i, k - 1)
			local bx, by, bz = at(j, k - 1)
			local cx2, cy2, cz2 = at(j, k)
			local dx, dy, dz = at(i, k)
			add_roof_triangle(mesh, ax, ay, az, bx, by, bz, cx2, cy2, cz2)

			if rings_profile[k][1] > 0 then
				add_roof_triangle(mesh, ax, ay, az, cx2, cy2, cz2, dx, dy, dz)
			end
		end
	end

	local last = rings_profile[#rings_profile]

	if last[1] > 0 then
		local cap = {}

		for i = 1, n do
			local x, _, z = at(i, #rings_profile)
			cap[#cap + 1] = x
			cap[#cap + 1] = z
		end

		add_roof(mesh, {cap}, eave + roof_height * last[2])
	end

	return eave
end

-- the ground height under a latitude and longitude from the tile's grid of heights, bilinear
local function sample_ground(input, heights, lat, lon)
	local n = input.grid_size
	local gx = math.clamp((lon - input.grid_lon0) / input.grid_dlon, 0, n - 1.001)
	local gy = math.clamp((lat - input.grid_lat0) / input.grid_dlat, 0, n - 1.001)
	local ix, iy = math.floor(gx), math.floor(gy)
	local fx, fy = gx - ix, gy - iy
	local o = iy * n + ix
	return math.lerp(
		fy,
		math.lerp(fx, heights[o], heights[o + 1]),
		math.lerp(fx, heights[o + n], heights[o + n + 1])
	)
end

-- input: path (the tile's decoded mvt), x, y, zoom, anchor_lat, anchor_lon, origin_x, origin_z (the meshes' origin in
-- the world) and a grid of ground heights over the tile (grid_size, grid_lat0, grid_lon0, grid_dlat, grid_dlon, grid:
-- floats as a string); returns the counts and one blob of the wall then roof vertices, then the wall then roof indices
function building_mesh.Build(input)
	local file = assert(io.open(input.path, "rb"))
	local data = file:read("*a")
	file:close()
	local decoded = #data > 0 and mvt.Decode(data)
	local layer = decoded and decoded.building
	local part_layer = decoded and decoded.building_part
	local walls, roofs = tint_mesh.New(), tint_mesh.New()
	local anchor = geo.NewAnchor(input.anchor_lat, input.anchor_lon)
	local heights = ffi.cast("const float *", input.grid)
	local photo = input.photo

	if photo then photo.data = ffi.cast("const uint8_t *", photo.pixels) end

	local count = 0
	-- a building with parts in the tile is drawn as its parts, which take what they do not say from it
	local shapes = {}
	local parents, has_parts = {}, {}

	for _, part in ipairs(part_layer and part_layer.features or {}) do
		if part.properties.building_id then
			has_parts[part.properties.building_id] = true
		end
	end

	for _, feature in ipairs(layer and layer.features or {}) do
		local id = tostring(feature.properties.id or feature.id)
		parents[id] = feature.properties

		if not has_parts[id] then
			shapes[#shapes + 1] = {feature = feature, properties = feature.properties, id = id, layer = layer}
		end
	end

	for _, part in ipairs(part_layer and part_layer.features or {}) do
		local parent = parents[part.properties.building_id]

		if parent then
			shapes[#shapes + 1] = {
				feature = part,
				properties = setmetatable(part.properties, {__index = parent}),
				id = part.properties.building_id,
				layer = part_layer,
			}
		end
	end

	for _, shape in ipairs(shapes) do
		local feature, properties, id = shape.feature, shape.properties, shape.id

		if feature.type == mvt.POLYGON and not properties.is_underground then
			local height = get_height(properties)
			local wall_r, wall_g, wall_b = parse_color(properties.facade_color)

			if not wall_r then
				wall_r, wall_g, wall_b = pick(building_mesh.WALL_COLORS, id, 1)
			end

			local roof_r, roof_g, roof_b = parse_color(properties.roof_color)
			local min_height = properties.min_height or
				properties.min_floor and
				properties.min_floor * building_mesh.FLOOR_HEIGHT or
				0

			for _, polygon in ipairs(mvt.GetPolygons(feature)) do
				local ground = math.huge
				local rings = {}
				local photo_rings = photo and {}
				local extent = shape.layer.extent

				for r, ring in ipairs(polygon) do
					local projected = {}

					for i = 1, #ring, 2 do
						local lat, lon = geo.FromMercator(input.x + ring[i] / extent, input.y + ring[i + 1] / extent, input.zoom, 1)
						local x, z = geo.LatLonToWorld(anchor, lat, lon)

						if r == 1 then
							ground = math.min(ground, sample_ground(input, heights, lat, lon))
						end

						if photo then
							local px, py = geo.ToMercator(lat, lon, photo.zoom, photo.tile_size)
							photo_rings[r] = photo_rings[r] or {}
							table.insert(photo_rings[r], px - photo.x0)
							table.insert(photo_rings[r], py - photo.y0)
						end

						projected[#projected + 1] = x - input.origin_x
						projected[#projected + 1] = z - input.origin_z
					end

					rings[r] = projected
				end

				local base = ground - planet.GetDrop(rings[1][1] + input.origin_x, rings[1][2] + input.origin_z)
				local top = base + height
				local bottom = min_height > 0 and base + min_height or base - building_mesh.FOOTING
				local max_roof = (height - min_height) * 0.6
				local r, g, b = roof_r, roof_g, roof_b

				if not r and photo then r, g, b = photo_color(photo, photo_rings) end

				if not r then r, g, b = pick(building_mesh.ROOF_COLORS, id, 3) end

				roofs.color[1], roofs.color[2], roofs.color[3] = r, g, b
				local section = building_mesh.SECTIONS[properties.roof_shape]
				local ring_profile = building_mesh.RINGS[properties.roof_shape]
				local wall_rings, wall_tops = rings, top

				if section then
					local tops
					wall_rings, tops = add_section_roof(roofs, rings, top, max_roof, section, properties)
					wall_tops = tops
				elseif ring_profile then
					wall_tops = add_ring_roof(roofs, rings[1], top, max_roof, ring_profile, properties)
				else
					add_roof(roofs, rings, top)
				end

				walls.color[1], walls.color[2], walls.color[3] = wall_r, wall_g, wall_b

				for k, ring in ipairs(wall_rings) do
					add_walls(walls, ring, bottom, type(wall_tops) == "table" and wall_tops[k] or wall_tops)
				end

				if min_height > 0 then add_roof(walls, rings, bottom, true) end

				count = count + 1
			end
		end
	end

	local vertex_bytes = (walls.count + roofs.count) * VERTEX_SIZE
	local blob = ffi.new("uint8_t[?]", vertex_bytes + (walls.index_count + roofs.index_count) * 4)
	ffi.copy(blob, walls.vertices, walls.count * VERTEX_SIZE)
	ffi.copy(blob + walls.count * VERTEX_SIZE, roofs.vertices, roofs.count * VERTEX_SIZE)
	ffi.copy(blob + vertex_bytes, walls.indices, walls.index_count * 4)
	ffi.copy(blob + vertex_bytes + walls.index_count * 4, roofs.indices, roofs.index_count * 4)
	return {
		buildings = count,
		wall_vertices = walls.count,
		roof_vertices = roofs.count,
		wall_indices = walls.index_count,
		roof_indices = roofs.index_count,
	},
	blob
end

building_mesh.JOB = [[
	return import("lua/earth/building_mesh.lua").Build(...)
]]
return building_mesh
