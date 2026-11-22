local geo = import("lua/earth/geo.lua")
-- the methods of a set of web mercator tiles at one zoom (Zoom), which tile sources (overture_tiles.lua,
-- canopy_tiles.lua) inherit through META
local map_tiles = {}
local META = {}
META.__index = META
map_tiles.META = META

function META:GetKey(x, y)
	return y * 2 ^ self.Zoom + x % 2 ^ self.Zoom
end

local function nearest_first(a, b)
	return a.distance < b.distance
end

-- the tiles within radius meters of a world position, nearest first ({tile, distance}), made in tiles ({x, y, state =
-- "new"}) by key when not there; tiles beyond keep_radius are taken out of tiles and passed to removed
function META:GetTilesAround(source, x, z, tiles, radius, keep_radius, removed)
	local zoom = self.Zoom
	local lat, lon = source:WorldToLatLon(x, z)
	local cx, cy = geo.ToMercator(lat, lon, zoom, 1)
	local tile_size = geo.GetPixelSize(lat, zoom, 1)
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

			if distance <= radius * radius and ty >= 0 and ty < 2 ^ zoom then
				local key = self:GetKey(tx, ty)
				tiles[key] = tiles[key] or {x = tx % 2 ^ zoom, y = ty, state = "new"}
				wanted[#wanted + 1] = {tile = tiles[key], distance = distance}
			end
		end
	end

	table.sort(wanted, nearest_first)
	return wanted
end

-- the world box a tile covers: min x, min z, max x, max z, nil when it is not in front of the origin's frame
function META:GetWorldBox(source, tile)
	local min_x, min_z, max_x, max_z = math.huge, math.huge, -math.huge, -math.huge

	for _, corner in ipairs{{0, 0}, {1, 0}, {0, 1}, {1, 1}} do
		local x, z = source:LatLonToWorld(geo.FromMercator(tile.x + corner[1], tile.y + corner[2], self.Zoom, 1))

		if x then
			min_x, min_z = math.min(min_x, x), math.min(min_z, z)
			max_x, max_z = math.max(max_x, x), math.max(max_z, z)
		end
	end

	if min_x < max_x then return min_x, min_z, max_x, max_z end
end

return map_tiles
