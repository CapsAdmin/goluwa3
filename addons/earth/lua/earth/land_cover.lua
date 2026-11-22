local ffi = require("ffi")
local fs = import("goluwa/filesystem/fs.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local overture_tiles = import("lua/earth/overture_tiles.lua")
local land_grid = import("lua/earth/land_grid.lua")
-- what the ground is around the camera (land_grid.lua): EarthSource bakes the land mosaic this hands it into the layers
-- and the relief finer than the height data
local land_cover = {}
land_cover.ATTRIBUTION = "Land cover: ESA WorldCover 2021 (CC BY 4.0), Overture Maps Foundation (OpenStreetMap contributors ODbL)"
local ZOOM = 13
local base = overture_tiles.Get("base", ZOOM)
local RADIUS = 6000
local KEEP_RADIUS = 9000
local MAX_BUILDING = 2
local UPDATE_INTERVAL = 0.25
local MAX_MOSAIC = 256
-- chunks so large that their mosaic would skip more land texels than this get none
local MAX_MOSAIC_STEP = 16
local SIZE = land_grid.SIZE
local function tile_key(x, y)
	return base:GetKey(x, y)
end

-- the terrain bakes the tile's area again
local function invalidate(tile)
	local min_x, min_z, max_x, max_z = base:GetWorldBox(land_cover.source, tile)

	if min_x then land_cover.terrain:Invalidate(min_x, min_z, max_x, max_z) end
end

local function build_tile(tile)
	tile.state = "building"
	land_cover.building = land_cover.building + 1

	thread_pool.Run(land_grid.JOB, {mvt = fs.read_file(base:GetPath(tile.x, tile.y))}, math.huge):OnDone(function(job)
		land_cover.building = land_cover.building - 1

		if tile.removed then return end

		if job.err then
			llog("earth: land %d/%d: %s", tile.x, tile.y, tostring(job.err))
			tile.state = "failed"
			return
		end

		if job.meta.land then
			tile.grid = ffi.new("uint8_t[?]", SIZE * SIZE)
			ffi.copy(tile.grid, job.blob.ptr, SIZE * SIZE)
		end

		tile.state = "built"
		local key = tile_key(tile.x, tile.y)

		if land_cover.missed[key] then
			land_cover.missed[key] = nil

			if tile.grid then invalidate(tile) end
		end
	end)
end

local function load_tile(tile)
	tile.state = "loading"

	base:Fetch(tile.x, tile.y, function(err)
		if tile.removed then return end

		if err then
			llog("earth: land %d/%d failed: %s", tile.x, tile.y, err)
			tile.state = "failed"
			return
		end

		tile.state = "fetched"
	end)
end

local function remove_tile(tile)
	tile.removed = true
end

local function update()
	local camera = render3d.GetCamera():GetPosition()
	local wanted = base:GetTilesAround(
		land_cover.source,
		camera.x,
		camera.z,
		land_cover.tiles,
		RADIUS,
		KEEP_RADIUS,
		remove_tile
	)

	for _, entry in ipairs(wanted) do
		local tile = entry.tile

		if tile.state == "new" then
			load_tile(tile)
		elseif tile.state == "fetched" and land_cover.building < MAX_BUILDING then
			build_tile(tile)
		end
	end
end

-- the land mosaic over a chunk's height mosaic: the land grids' texels, every so many so it stays small; nil while a
-- tile under it is on its way, false where none has land or the chunk is too large. Tiles not wanted yet are taken as
-- having none, and the terrain bakes them again once they are built
function land_cover.PlanMosaic(_, heights)
	local tiles = land_cover.tiles
	local per_pixel = SIZE / (heights.set.TileSize * 2 ^ (heights.zoom - ZOOM))
	local x0 = math.floor(heights.x0 * per_pixel) - 1
	local y0 = math.floor(heights.y0 * per_pixel) - 1
	local x1 = math.ceil((heights.x0 + heights.width) * per_pixel) + 1
	local y1 = math.ceil((heights.y0 + heights.height) * per_pixel) + 1
	local step = math.max(1, math.ceil(math.max(x1 - x0, y1 - y0) / MAX_MOSAIC))

	if step > MAX_MOSAIC_STEP then return false end

	local found = false

	for ty = math.floor(y0 / SIZE), math.floor(y1 / SIZE) do
		for tx = math.floor(x0 / SIZE), math.floor(x1 / SIZE) do
			local key = tile_key(tx, ty)
			local tile = tiles[key]

			if not tile then
				land_cover.missed[key] = true
			elseif tile.state == "built" then
				if tile.grid then found = true end
			elseif tile.state ~= "failed" then
				return nil
			end
		end
	end

	if not found then return false end

	return {
		x0 = x0,
		y0 = y0,
		step = step,
		width = math.floor((x1 - x0) / step) + 1,
		height = math.floor((y1 - y0) / step) + 1,
		scale = per_pixel / step,
		offset_x = heights.x0 * per_pixel / step + 0.5 - (x0 + 0.5) / step,
		offset_y = heights.y0 * per_pixel / step + 0.5 - (y0 + 0.5) / step,
	}
end

-- writes the planned mosaic's land classes into bytes, rows of stride texels
function land_cover.FillMosaic(_, plan, pixels, stride)
	local tiles = land_cover.tiles

	for b = 0, plan.height - 1 do
		local gy = plan.y0 + b * plan.step
		local ty = math.floor(gy / SIZE)
		local row = (gy - ty * SIZE) * SIZE
		local tile_x, grid

		for a = 0, plan.width - 1 do
			local gx = plan.x0 + a * plan.step
			local tx = math.floor(gx / SIZE)

			if tx ~= tile_x then
				tile_x = tx
				local tile = tiles[tile_key(tx, ty)]
				grid = tile and tile.grid or nil
			end

			pixels[b * stride + a] = grid and grid[row + gx - tx * SIZE] or 0
		end
	end
end

function land_cover.Start(source, terrain)
	land_cover.Stop()
	land_cover.tiles = {}
	land_cover.building = 0
	land_cover.SetSource(source, terrain)
	local next_update = 0

	event.AddListener("Update", "earth_land", function()
		local now = system.GetElapsedTime()

		if now < next_update then return end

		next_update = now + UPDATE_INTERVAL
		update()
	end)
end

-- the grids are in map tiles, so they stay when the origin moves
function land_cover.SetSource(source, terrain)
	if land_cover.source then land_cover.source.Land = nil end

	land_cover.source = source
	land_cover.terrain = terrain
	land_cover.missed = {}
	source.Land = land_cover
	update()
end

function land_cover.Stop()
	event.RemoveListener("Update", "earth_land")

	if land_cover.tiles then
		for _, tile in pairs(land_cover.tiles) do
			tile.removed = true
		end
	end

	if land_cover.source then land_cover.source.Land = nil end

	land_cover.tiles = nil
	land_cover.source = nil
	land_cover.terrain = nil
end

-- built, pending (fetching or building) and failed tiles
function land_cover.GetStats()
	local stats = {built = 0, pending = 0, failed = 0}

	for _, tile in pairs(land_cover.tiles or {}) do
		local key = tile.state == "built" and
			"built" or
			tile.state == "failed" and
			"failed" or
			"pending"
		stats[key] = stats[key] + 1
	end

	return stats
end

return land_cover
