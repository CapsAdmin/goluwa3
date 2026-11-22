local T = import("test/environment.lua")
local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local png = import("goluwa/codecs/png.lua")
local planet = import("goluwa/planet.lua")
local geo = import("lua/earth/geo.lua")
local TileSet = import("lua/earth/tile_set.lua")
local EarthSource = import("lua/earth/source.lua")
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
