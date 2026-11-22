local ffi = require("ffi")
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

local function new_mesh()
	return {
		vertices = VertexType(1024),
		capacity = 1024,
		count = 0,
		indices = Index32Array(2048),
		index_capacity = 2048,
		index_count = 0,
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
	local count = 0

	for _, feature in ipairs(layer and layer.features or {}) do
		local properties = feature.properties

		if feature.type == mvt.POLYGON and not properties.is_underground then
			local height = get_height(properties)

			for _, polygon in ipairs(mvt.GetPolygons(feature)) do
				local ground = math.huge
				local rings = {}

				for r, ring in ipairs(polygon) do
					local projected = {}

					for i = 1, #ring, 2 do
						local lat, lon = geo.FromMercator(input.x + ring[i] / layer.extent, input.y + ring[i + 1] / layer.extent, input.zoom, 1)
						local x, z = geo.LatLonToWorld(anchor, lat, lon)

						if r == 1 then
							ground = math.min(ground, sample_ground(input, heights, lat, lon))
						end

						projected[#projected + 1] = x - input.origin_x
						projected[#projected + 1] = z - input.origin_z
					end

					rings[r] = projected
				end

				local drop = planet.GetDrop(rings[1][1] + input.origin_x, rings[1][2] + input.origin_z)

				for _, ring in ipairs(rings) do
					add_walls(walls, ring, ground - drop - building_mesh.FOOTING, ground - drop + height)
				end

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
