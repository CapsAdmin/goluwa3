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
local water_grid = import("lua/earth/water_grid.lua")
local land_grid = import("lua/earth/land_grid.lua")
local mvt = import("goluwa/codecs/mvt.lua")
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
	T(roof.vertex_color[3])["=="](1)
	T(vertices[0].vertex_color[3])["=="](1)
	T(roof.vertex_color[0] > 0 and roof.vertex_color[0] <= 1)["=="](true)
end)

-- a square lake from texel 400 to 600 of a tile whose height data has one pixel per grid texel: inside_height under
-- the lake (or inside_height(x, y)), 8 around it
local function build_lake(inside_height)
	local size, margin = water_grid.SIZE, water_grid.MARGIN
	local width = size + margin * 2
	local dem = ffi.new("float[?]", width * width)

	for y = 0, width - 1 do
		for x = 0, width - 1 do
			local inside = x >= 400 + margin and x < 600 + margin and y >= 400 + margin and y < 600 + margin
			dem[y * width + x] = inside and
				(
					type(inside_height) == "function" and
					inside_height(x, y) or
					inside_height
				)
				or
				8
		end
	end

	local a, b = 400 + margin, 600 + margin
	local tx, ty = geo.ToMercator(LAT, LON, 13, 1)
	tx, ty = math.floor(tx), math.floor(ty)
	local meta, grid = water_grid.Build{
		zoom = 13,
		x = tx,
		y = ty,
		features = {
			{kind = "lake", medium = "lake", id = "lake", rings = {{a, a, b, a, b, b, a, b}}},
		},
		dem = {
			pixels = ffi.string(dem, width * width * 4),
			x0 = tx * size - margin,
			y0 = ty * size - margin,
			width = width,
			height = width,
			zoom = 13,
			tile_size = size,
		},
	}
	return meta, grid, width
end

T.Test("earth water grids level a lake, carve under it and cover it with boxes", function()
	local margin = water_grid.MARGIN
	local meta, grid, width = build_lake(5)
	T(meta.levels.lake)["=="](5)
	T(meta.water)["=="](true)
	local center = (500 + margin) * width + 500 + margin
	T(grid[center] < 0)["=="](true)
	T(grid[center + width * width])["=="](5)
	T(grid[(100 + margin) * width + 100 + margin] > water_grid.NOISE_FADE)["=="](true)
	T(water_grid.Carve(5, grid[center], 5) <= 5 - water_grid.MAX_DEPTH + 0.01)["=="](true)
	T(water_grid.Carve(8, water_grid.FAR, 5))["=="](8)
	T(water_grid.Carve(4, water_grid.RING / 2, 5))["=="](5 + water_grid.LIFT)
	local shore = grid[(500 + margin) * width + 400 + margin]
	T(shore < 0 and shore > -2 * geo.GetPixelSize(LAT, 13, water_grid.SIZE))["=="](true)
	local covered = 0

	for y = 400, 599 do
		for x = 400, 599 do
			for _, box in ipairs(meta.boxes) do
				if x >= box.x0 and x < box.x1 and y >= box.y0 and y < box.y1 then
					covered = covered + 1

					break
				end
			end
		end
	end

	T(covered)["=="](200 * 200)

	for _, box in ipairs(meta.boxes) do
		T(box.level)["=="](5)
	end

	T(#meta.boxes <= 9)["=="](true)
end)

T.Test("earth water grids leave lakes whose ground is uneven or at the sea", function()
	local margin = water_grid.MARGIN
	local meta = build_lake(function(x)
		return 2 + (x - margin - 400) * 0.05
	end)
	T(meta.levels.lake)["=="](nil)
	T(#meta.boxes)["=="](0)
	meta = build_lake(0.1)
	T(#meta.boxes)["=="](0)
end)

T.Test("earth land grids draw land use and land over the land cover, smaller polygons over larger", function()
	local function square(x0, y0, x1, y1, properties)
		return {
			type = mvt.POLYGON,
			properties = properties,
			rings = {{x0, y0, x1, y0, x1, y1, x0, y1}},
		}
	end

	local meta, grid = land_grid.Build{
		land_cover = {extent = 4096, features = {square(0, 0, 4096, 4096, {subtype = "crop"})}},
		land_use = {
			extent = 4096,
			features = {
				square(1024, 1024, 1536, 1536, {subtype = "park", class = "park"}),
				square(0, 0, 2048, 2048, {subtype = "residential", class = "residential"}),
				square(0, 0, 2048, 2048, {subtype = "developed", class = "industrial"}),
			},
		},
		land = {
			extent = 4096,
			features = {square(1200, 1200, 1300, 1300, {subtype = "forest", class = "wood"})},
		},
	}
	local size = land_grid.SIZE

	local function class_at(x, y)
		return land_grid.CLASSES[grid[math.floor(y / 4096 * size) * size + math.floor(x / 4096 * size)]]
	end

	T(meta.any)["=="](true)
	T(class_at(3000, 3000))["=="]("crop")
	T(class_at(500, 500))["=="]("urban")
	T(class_at(1400, 1400))["=="]("grass")
	T(class_at(1250, 1250))["=="]("forest")
	meta = land_grid.Build{}
	T(meta.any)["=="](false)
end)

local function solid_tile(r, g, b)
	local pixels = ffi.new("uint8_t[?]", 256 * 256 * 3)

	for i = 0, 256 * 256 - 1 do
		pixels[i * 3], pixels[i * 3 + 1], pixels[i * 3 + 2] = r, g, b
	end

	local file = png.Encode(256, 256, "rgb")
	file:write(pixels)
	return file:getData()
end

T.Test3D("earth imagery falls through to the next source where one answers blank tiles", function()
	local directory = vfs.GetStorageDirectory("temp") .. "earth_test_imagery_" .. os.time() .. "/"
	local heights = TileSet.New{
		name = "synthetic_heights",
		directory = directory .. "heights/",
		fetch = function(_, tile, done)
			done("ok", synthetic_tile(tile.z, tile.x, tile.y))
		end,
		extension = "png",
		tile_size = 256,
		max_zoom = 15,
		kind = "terrarium",
	}
	local regional = TileSet.New{
		name = "blank_regional",
		directory = directory .. "regional/",
		fetch = function(_, tile, done)
			done("ok", solid_tile(255, 255, 255))
		end,
		extension = "img",
		tile_size = 256,
		max_zoom = 18,
		kind = "photo",
		bounds = {LAT - 1, LON - 1, LAT + 1, LON + 1},
	}
	local worldwide = TileSet.New{
		name = "worldwide",
		directory = directory .. "worldwide/",
		fetch = function(_, tile, done)
			done("ok", solid_tile(40, 90, 30))
		end,
		extension = "img",
		tile_size = 256,
		max_zoom = 14,
		kind = "image",
	}
	local source = EarthSource.New{Anchor = {LAT, LON}, Heights = heights, Imagery = {regional, worldwide}}
	local chunk

	source:RequestChunk({min_x = 0, min_z = 0, size = 512, samples = 17, color_size = 32}, function(result)
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

	local used = source:GetImageryInUse(60)
	T(#used)["=="](1)
	T(used[1])["=="](worldwide)
	source:ReleaseChunk(chunk)
	source:Finish()
	heights:Clear()
	regional:Clear()
	worldwide:Clear()
	fs.remove_directory_recursive(directory)
end)
