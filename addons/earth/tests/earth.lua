local T = import("test/environment.lua")
local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local png = import("goluwa/codecs/png.lua")
local planet = import("goluwa/planet.lua")
local geo = import("lua/earth/geo.lua")
local TileSet = import("lua/earth/tile_set.lua")
local EarthSource = import("lua/earth/source.lua")
local building_mesh = import("lua/earth/building_mesh.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local LAT, LON = 46.5935, 7.9091

T.Test("earth world positions and latitudes, longitudes round trip", function()
	local anchor = geo.NewAnchor(LAT, LON)

	for _, p in ipairs{{0, 0}, {1234.5, -876.25}, {250000, 125000}, {-2000000, 1500000}} do
		local x, z = geo.LatLonToWorld(anchor, geo.WorldToLatLon(anchor, p[1], p[2]))
		T(math.abs(x - p[1]))["<"](1e-4)
		T(math.abs(z - p[2]))["<"](1e-4)
	end

	T(geo.WorldToLatLon(anchor, 0, -10000) > LAT)["=="](true)
	T(select(2, geo.WorldToLatLon(anchor, 10000, 0)) > LON)["=="](true)
end)

T.Test("earth recentering keeps ground points at their latitude, longitude and height", function()
	local from = geo.NewAnchor(LAT, LON)
	local to = geo.NewAnchor(geo.WorldToLatLon(from, 15000, -9000))
	local relation = geo.Relate(from, to)

	for _, p in ipairs{{15000, -9000}, {0, 0}, {-40000, 25000}} do
		local x, z = p[1], p[2]
		local x2, y2, z2 = geo.TransformPoint(relation, x, -planet.GetDrop(x, z), z)
		local lat, lon = geo.WorldToLatLon(from, x, z)
		local lat2, lon2 = geo.WorldToLatLon(to, x2, z2)
		T(math.abs(lat - lat2))["<"](1e-7)
		T(math.abs(lon - lon2))["<"](1e-7)
		T(math.abs(y2 + planet.GetDrop(x2, z2)))["<"](0.01)
	end
end)

local function synthetic_height(lat, lon)
	return 500 + 300 * math.sin(math.rad(lat) * 2000) * math.cos(math.rad(lon) * 1500)
end

-- a terrarium png of synthetic_height, as the real tile servers send them
local function synthetic_tile(z, tx, ty)
	local pixels = ffi.new("uint8_t[?]", 256 * 256 * 3)

	for y = 0, 255 do
		for x = 0, 255 do
			local lat, lon = geo.FromMercator(tx * 256 + x + 0.5, ty * 256 + y + 0.5, z, 256)
			local v = synthetic_height(lat, lon) + 32768
			local o = (y * 256 + x) * 3
			pixels[o] = math.floor(v / 256)
			pixels[o + 1] = math.floor(v) % 256
			pixels[o + 2] = math.floor((v - math.floor(v)) * 256)
		end
	end

	local file = png.Encode(256, 256, "rgb")
	file:write(pixels)
	return file:getData()
end

T.Test3D("earth source bakes heights from its tiles at the latitude and longitude of each sample", function()
	local directory = vfs.GetStorageDirectory("temp") .. "earth_test_" .. os.time() .. "/"
	local set = TileSet.New{
		name = "synthetic",
		directory = directory,
		fetch = function(_, tile, done)
			done("ok", synthetic_tile(tile.z, tile.x, tile.y))
		end,
		extension = "png",
		tile_size = 256,
		max_zoom = 15,
		kind = "terrarium",
	}
	local source = EarthSource.New{Anchor = {LAT, LON}, Heights = set}
	local request = {min_x = 1024, min_z = -2048, size = 2048, samples = 17, detail_size = 64}
	local chunk

	source:RequestChunk(request, function(result)
		chunk = result
	end)

	T.WaitUntilReal(
		function()
			source:Update()
			source:Submit()
			return chunk
		end,
		30,
		"the chunk to bake"
	)

	for j = 0, 16 do
		for i = 0, 16 do
			local x, z = 1024 + i * 128, -2048 + j * 128
			local expected = synthetic_height(geo.WorldToLatLon(source.Anchor, x, z))
			T(math.abs(chunk.heights[j * 17 + i] + planet.GetDrop(x, z) - expected))["<"](0.05)
		end
	end

	source:ReleaseChunk(chunk)
	source:Finish()
	set:Clear()
	fs.remove_directory_recursive(directory)
end)

local function varint(n)
	local out = {}

	repeat
		local byte = n % 128
		n = math.floor(n / 128)
		out[#out + 1] = string.char(n > 0 and byte + 128 or byte)	
	until n == 0

	return table.concat(out)
end

local function field(number, payload)
	return varint(number * 8 + 2) .. varint(#payload) .. payload
end

-- a zoom 14 tile with one building: a 1024 x 1024 square of the tile's 4096 with height 12.5
local function building_tile()
	local ring = {1024, 1024, 2048, 1024, 2048, 2048, 1024, 2048}
	local commands = {9, ring[1] * 2, ring[2] * 2, 2 + 8 * 3}
	local cx, cy = ring[1], ring[2]

	for i = 3, #ring, 2 do
		local dx, dy = ring[i] - cx, ring[i + 1] - cy
		commands[#commands + 1] = dx >= 0 and dx * 2 or -dx * 2 - 1
		commands[#commands + 1] = dy >= 0 and dy * 2 or -dy * 2 - 1
		cx, cy = ring[i], ring[i + 1]
	end

	commands[#commands + 1] = 15
	local packed = {}

	for i, v in ipairs(commands) do
		packed[i] = varint(v)
	end

	local height = ffi.new("double[1]", 12.5)
	return field(
		3,
		table.concat{
			field(1, "building"),
			varint(5 * 8) .. varint(4096),
			field(3, "height"),
			field(4, varint(3 * 8 + 1) .. ffi.string(height, 8)),
			field(
				2,
				table.concat{
					field(2, varint(0) .. varint(0)),
					varint(3 * 8) .. varint(3),
					field(4, table.concat(packed)),
				}
			),
		}
	)
end

T.Test("earth building blocks stand on the ground under them to their height", function()
	local path = vfs.GetStorageDirectory("temp") .. "earth_test_building_" .. os.time() .. ".mvt"
	fs.write_file(path, building_tile())
	local anchor = geo.NewAnchor(LAT, LON)
	local tx, ty = geo.ToMercator(LAT, LON, 14, 1)
	tx, ty = math.floor(tx), math.floor(ty)
	local grid = ffi.new("float[4]", 100, 100, 100, 100)
	local north, west = geo.FromMercator(tx, ty, 14, 1)
	local south, east = geo.FromMercator(tx + 1, ty + 1, 14, 1)
	local origin_x, origin_z = geo.LatLonToWorld(anchor, geo.FromMercator(tx + 0.5, ty + 0.5, 14, 1))
	local meta, blob = building_mesh.Build{
		path = path,
		x = tx,
		y = ty,
		zoom = 14,
		anchor_lat = LAT,
		anchor_lon = LON,
		origin_x = origin_x,
		origin_z = origin_z,
		grid_size = 2,
		grid_lat0 = south,
		grid_lon0 = west,
		grid_dlat = north - south,
		grid_dlon = east - west,
		grid = ffi.string(grid, 16),
	}
	os.remove(path)
	T(meta.buildings)["=="](1)
	T(meta.wall_vertices)["=="](16)
	T(meta.roof_vertices)["=="](6)
	local vertices = ffi.cast(vertex_layout.PointerType, blob)
	local roof = vertices[meta.wall_vertices]
	local drop = planet.GetDrop(roof.position[0] + origin_x, roof.position[2] + origin_z)
	T(math.abs(roof.position[1] - (100 - drop + 12.5)))["<"](0.1)
	T(math.abs(vertices[0].position[1] - (100 - drop - building_mesh.FOOTING)))["<"](0.1)
	T(roof.normal[1])["=="](1)
end)
