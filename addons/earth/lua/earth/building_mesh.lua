local ffi = require("ffi")
local bit = require("bit")
local mvt = import("goluwa/codecs/mvt.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local planet = import("goluwa/planet.lua")
local geo = import("lua/earth/geo.lua")
-- a building tile's blocks as wall and roof meshes, built on the thread pool (BuildJob)
local building_mesh = {}
building_mesh.FLOOR_HEIGHT = 3.2
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
local VertexType = vertex_layout.ArrayType
local VERTEX_SIZE = ffi.sizeof(VertexType(1))
local Index32Array = ffi.typeof("uint32_t[?]")

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

local function new_mesh()
	return {
		vertices = VertexType(1024),
		capacity = 1024,
		count = 0,
		indices = Index32Array(2048),
		index_capacity = 2048,
		index_count = 0,
		color = {1, 1, 1},
	}
end

local function reserve(mesh, vertices, indices)
	if mesh.count + vertices > mesh.capacity then
		local capacity = math.max(mesh.capacity * 2, mesh.count + vertices)
		local grown = VertexType(capacity)
		ffi.copy(grown, mesh.vertices, VERTEX_SIZE * mesh.count)
		mesh.vertices, mesh.capacity = grown, capacity
	end

	if mesh.index_count + indices > mesh.index_capacity then
		local capacity = math.max(mesh.index_capacity * 2, mesh.index_count + indices)
		local grown = Index32Array(capacity)
		ffi.copy(grown, mesh.indices, 4 * mesh.index_count)
		mesh.indices, mesh.index_capacity = grown, capacity
	end
end

local function add_vertex(mesh, x, y, z, nx, ny, nz, u, v, tx, tz)
	local vertex = mesh.vertices[mesh.count]
	local color = mesh.color
	vertex.vertex_color[0], vertex.vertex_color[1], vertex.vertex_color[2], vertex.vertex_color[3] = color[1], color[2], color[3], 1
	vertex.position[0], vertex.position[1], vertex.position[2] = x, y, z
	vertex.normal[0], vertex.normal[1], vertex.normal[2] = nx, ny, nz
	vertex.uv[0], vertex.uv[1] = u, v
	vertex.tangent[0], vertex.tangent[1], vertex.tangent[2], vertex.tangent[3] = tx, 0, tz, -1
	mesh.count = mesh.count + 1
	return mesh.count - 1
end

-- front faces wind so that (b - a) x (c - a) points away from their normal, as the terrain's do
local function add_triangle(mesh, a, b, c)
	local i = mesh.index_count
	mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2] = a, b, c
	mesh.index_count = i + 3
end

local function add_walls(mesh, ring, bottom, top)
	local n = #ring / 2
	reserve(mesh, n * 4, n * 6)
	local height = top - bottom

	for i = 1, n do
		local ax, az = ring[i * 2 - 1], ring[i * 2]
		local j = i % n + 1
		local bx, bz = ring[j * 2 - 1], ring[j * 2]
		local dx, dz = bx - ax, bz - az
		local length = math.sqrt(dx * dx + dz * dz)

		if length > 0.01 then
			local nx, nz = dz / length, -dx / length
			local tx, tz = dx / length, dz / length
			local u = length / 4
			local a0 = add_vertex(mesh, ax, bottom, az, nx, 0, nz, 0, 0, tx, tz)
			local b0 = add_vertex(mesh, bx, bottom, bz, nx, 0, nz, u, 0, tx, tz)
			local b1 = add_vertex(mesh, bx, top, bz, nx, 0, nz, u, height / 3, tx, tz)
			local a1 = add_vertex(mesh, ax, top, az, nx, 0, nz, 0, height / 3, tx, tz)
			add_triangle(mesh, a0, b1, a1)
			add_triangle(mesh, a0, b0, b1)
		end
	end
end

local function add_roof(mesh, rings, top)
	local triangles = math2d.TriangulateContoursEvenOdd(rings)
	local count = #triangles / 6
	reserve(mesh, count * 3, count * 3)

	for t = 0, count - 1 do
		local o = t * 6
		local ax, az = triangles[o + 1], triangles[o + 2]
		local bx, bz = triangles[o + 3], triangles[o + 4]
		local cx, cz = triangles[o + 5], triangles[o + 6]
		local a = add_vertex(mesh, ax, top, az, 0, 1, 0, ax / 8, az / 8, 1, 0)
		local b = add_vertex(mesh, bx, top, bz, 0, 1, 0, bx / 8, bz / 8, 1, 0)
		local c = add_vertex(mesh, cx, top, cz, 0, 1, 0, cx / 8, cz / 8, 1, 0)

		if (bz - az) * (cx - ax) - (bx - ax) * (cz - az) > 0 then
			add_triangle(mesh, a, c, b)
		else
			add_triangle(mesh, a, b, c)
		end
	end
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
	local layer = #data > 0 and mvt.Decode(data).building
	local walls, roofs = new_mesh(), new_mesh()
	local anchor = geo.NewAnchor(input.anchor_lat, input.anchor_lon)
	local heights = ffi.cast("const float *", input.grid)
	local photo = input.photo

	if photo then photo.data = ffi.cast("const uint8_t *", photo.pixels) end

	local count = 0

	for _, feature in ipairs(layer and layer.features or {}) do
		local properties = feature.properties

		if feature.type == mvt.POLYGON and not properties.is_underground then
			local height = get_height(properties)
			local id = tostring(properties.id or feature.id)
			local wall_r, wall_g, wall_b = parse_color(properties.facade_color)

			if not wall_r then
				wall_r, wall_g, wall_b = pick(building_mesh.WALL_COLORS, id, 1)
			end

			local roof_r, roof_g, roof_b = parse_color(properties.roof_color)

			for _, polygon in ipairs(mvt.GetPolygons(feature)) do
				local ground = math.huge
				local rings = {}
				local photo_rings = photo and {}

				for r, ring in ipairs(polygon) do
					local projected = {}

					for i = 1, #ring, 2 do
						local lat, lon = geo.FromMercator(input.x + ring[i] / layer.extent, input.y + ring[i + 1] / layer.extent, input.zoom, 1)
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

				local drop = planet.GetDrop(rings[1][1] + input.origin_x, rings[1][2] + input.origin_z)
				walls.color[1], walls.color[2], walls.color[3] = wall_r, wall_g, wall_b

				for _, ring in ipairs(rings) do
					add_walls(walls, ring, ground - drop - building_mesh.FOOTING, ground - drop + height)
				end

				local r, g, b = roof_r, roof_g, roof_b

				if not r and photo then r, g, b = photo_color(photo, photo_rings) end

				if not r then r, g, b = pick(building_mesh.ROOF_COLORS, id, 3) end

				roofs.color[1], roofs.color[2], roofs.color[3] = r, g, b
				add_roof(roofs, rings, ground - drop + height)
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
