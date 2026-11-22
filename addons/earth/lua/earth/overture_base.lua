local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local deflate = import("goluwa/codecs/deflate.lua")
local geo = import("lua/earth/geo.lua")
local Archive = import("lua/earth/pmtiles_archive.lua")
-- Overture's base theme tiles (water, land, land use, land cover, infrastructure) at its deepest zoom, cached on disk and
-- shared by everything that reads them
local overture_base = {}
overture_base.RELEASE = "2026-10-21.0"
overture_base.ZOOM = 13
local ZOOM = overture_base.ZOOM
local directory = vfs.GetStorageDirectory("cache") .. "earth/overture/" .. overture_base.RELEASE .. "/base/"
local fetching = {}

local function get_archive()
	overture_base.archive = overture_base.archive or
		Archive.New{
			url = "https://tiles.overturemaps.org/" .. overture_base.RELEASE .. "/base.pmtiles",
			directory = directory,
			host_limit = 4,
		}
	return overture_base.archive
end

function overture_base.GetPath(x, y)
	return string.format("%s%d/%d/%d.mvt", directory, ZOOM, x, y)
end

function overture_base.GetKey(x, y)
	return y * 2 ^ ZOOM + x % 2 ^ ZOOM
end

-- calls done(err) once the tile's file is on disk (an empty file where the archive has no tile), at once when it is
function overture_base.Fetch(x, y, done)
	local path = overture_base.GetPath(x, y)

	if fs.is_file(path) then
		done()
		return
	end

	local key = overture_base.GetKey(x, y)

	if fetching[key] then
		table.insert(fetching[key], done)
		return
	end

	fetching[key] = {done}
	local archive = get_archive()

	archive:Fetch(
		ZOOM,
		x,
		y,
		function(result, body)
			local err

			if result == "missing" then
				body = ""
			elseif result ~= "ok" then
				err = tostring(body)
			elseif archive.header.tile_compression == "gzip" then
				local out, size = deflate.Decode(body, "gzip")
				body = ffi.string(out.Buffer, size)
			end

			if not err then
				fs.create_directory_recursive(path:match("^(.*/)"))
				fs.write_file(path, body)
			end

			local waiting = fetching[key]
			fetching[key] = nil

			for _, callback in ipairs(waiting) do
				callback(err)
			end
		end
	)
end

local function nearest_first(a, b)
	return a.distance < b.distance
end

-- the tiles within radius meters of a world position, nearest first, made in tiles ({x, y, state = "new"}) by key when
-- not there; tiles beyond keep_radius are taken out of tiles and passed to removed
function overture_base.GetTilesAround(source, x, z, tiles, radius, keep_radius, removed)
	local lat, lon = source:WorldToLatLon(x, z)
	local cx, cy = geo.ToMercator(lat, lon, ZOOM, 1)
	local tile_size = geo.GetPixelSize(lat, ZOOM, 1)
	local reach = math.ceil(radius / tile_size) + 1

	for key, tile in pairs(tiles) do
		local dx = math.max(math.abs(tile.x + 0.5 - cx) - 0.5, 0) * tile_size
		local dy = math.max(math.abs(tile.y + 0.5 - cy) - 0.5, 0) * tile_size

		if dx * dx + dy * dy > keep_radius * keep_radius then
			tiles[key] = nil
			removed(tile)
		end
	end

	local wanted = {}

	for ty = math.floor(cy) - reach, math.floor(cy) + reach do
		for tx = math.floor(cx) - reach, math.floor(cx) + reach do
			local dx = math.max(math.abs(tx + 0.5 - cx) - 0.5, 0) * tile_size
			local dy = math.max(math.abs(ty + 0.5 - cy) - 0.5, 0) * tile_size
			local distance = dx * dx + dy * dy

			if distance <= radius * radius and ty >= 0 and ty < 2 ^ ZOOM then
				local key = overture_base.GetKey(tx, ty)
				tiles[key] = tiles[key] or {x = tx % 2 ^ ZOOM, y = ty, state = "new"}
				wanted[#wanted + 1] = {tile = tiles[key], distance = distance}
			end
		end
	end

	table.sort(wanted, nearest_first)
	return wanted
end

-- the world box a tile covers: min x, min z, max x, max z, nil when it is not in front of the origin's frame
function overture_base.GetWorldBox(source, tile)
	local min_x, min_z, max_x, max_z = math.huge, math.huge, -math.huge, -math.huge

	for _, corner in ipairs{{0, 0}, {1, 0}, {0, 1}, {1, 1}} do
		local x, z = source:LatLonToWorld(geo.FromMercator(tile.x + corner[1], tile.y + corner[2], ZOOM, 1))

		if x then
			min_x, min_z = math.min(min_x, x), math.min(min_z, z)
			max_x, max_z = math.max(max_x, x), math.max(max_z, z)
		end
	end

	if min_x < max_x then return min_x, min_z, max_x, max_z end
end

return overture_base
