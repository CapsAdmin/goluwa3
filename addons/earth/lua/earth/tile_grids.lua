local ffi = require("ffi")
local fs = import("goluwa/filesystem/fs.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local overture_tiles = import("lua/earth/overture_tiles.lua")
-- grids made from Overture's tiles around the camera on the thread pool, which EarthSource bakes from as a mosaic over
-- each chunk (land_grid.lua, road_grid.lua)
local tile_grids = {}
local META = {}
META.__index = META
local UPDATE_INTERVAL = 0.25
local MAX_MOSAIC = 256

-- config: Name, Theme and Zoom (the Overture tiles), Size (grid texels across a tile), Bytes (per texel), Job (a
-- thread pool job given {mvt, x, y, zoom} returning meta {any (whether the grid has anything)} and the grid's bytes,
-- rows from the tile's north), Radius and KeepRadius (meters around the camera tiles are made and kept within),
-- MaxBuilding (jobs at once), MaxMosaicStep (chunks so large that their mosaic would skip more texels than this get none)
function tile_grids.New(config)
	return setmetatable(
		{
			Name = config.Name,
			Size = config.Size,
			Bytes = config.Bytes,
			Job = config.Job,
			Radius = config.Radius,
			KeepRadius = config.KeepRadius,
			MaxBuilding = config.MaxBuilding or 2,
			MaxMosaicStep = config.MaxMosaicStep,
			tiles_source = overture_tiles.Get(config.Theme, config.Zoom),
			Zoom = config.Zoom,
		},
		META
	)
end

-- the terrain bakes the tile's area again
function META:Invalidate(tile)
	local min_x, min_z, max_x, max_z = self.tiles_source:GetWorldBox(self.source, tile)

	if min_x then self.terrain:Invalidate(min_x, min_z, max_x, max_z) end
end

function META:BuildTile(tile)
	tile.state = "building"
	self.building = self.building + 1
	local bytes = self.Size * self.Size * self.Bytes

	thread_pool.Run(
		self.Job,
		{
			mvt = fs.read_file(self.tiles_source:GetPath(tile.x, tile.y)),
			x = tile.x,
			y = tile.y,
			zoom = self.Zoom,
		},
		math.huge
	):OnDone(function(job)
		self.building = self.building - 1

		if tile.removed then return end

		if job.err then
			llog("earth: %s %d/%d: %s", self.Name, tile.x, tile.y, tostring(job.err))
			tile.state = "failed"
			return
		end

		if job.meta.any then
			tile.grid = ffi.new("uint8_t[?]", bytes)
			ffi.copy(tile.grid, job.blob.ptr, bytes)
		end

		tile.state = "built"
		local key = self.tiles_source:GetKey(tile.x, tile.y)

		if self.missed[key] then
			self.missed[key] = nil

			if tile.grid then self:Invalidate(tile) end
		end
	end)
end

function META:LoadTile(tile)
	tile.state = "loading"

	self.tiles_source:Fetch(tile.x, tile.y, function(err)
		if tile.removed then return end

		if err then
			llog("earth: %s %d/%d failed: %s", self.Name, tile.x, tile.y, err)
			tile.state = "failed"
			return
		end

		tile.state = "fetched"
	end)
end

local function remove_tile(tile)
	tile.removed = true
end

function META:Update()
	local camera = render3d.GetCamera():GetPosition()
	local wanted = self.tiles_source:GetTilesAround(
		self.source,
		camera.x,
		camera.z,
		self.tiles,
		self.Radius,
		self.KeepRadius,
		remove_tile
	)

	for _, entry in ipairs(wanted) do
		local tile = entry.tile

		if tile.state == "new" then
			self:LoadTile(tile)
		elseif tile.state == "fetched" and self.building < self.MaxBuilding then
			self:BuildTile(tile)
		end
	end
end

-- the mosaic over a chunk's height mosaic: the grids' texels, every so many so it stays small; nil while a tile under it
-- is on its way, false where none has anything or the chunk is too large. Tiles not wanted yet are taken as empty, and
-- the terrain bakes them again once they are built
function META:PlanMosaic(heights)
	local size = self.Size
	local tiles = self.tiles
	local tiles_source = self.tiles_source
	local per_pixel = size / (heights.set.TileSize * 2 ^ (heights.zoom - self.Zoom))
	local x0 = math.floor(heights.x0 * per_pixel) - 1
	local y0 = math.floor(heights.y0 * per_pixel) - 1
	local x1 = math.ceil((heights.x0 + heights.width) * per_pixel) + 1
	local y1 = math.ceil((heights.y0 + heights.height) * per_pixel) + 1
	local step = math.max(1, math.ceil(math.max(x1 - x0, y1 - y0) / MAX_MOSAIC))

	if step > self.MaxMosaicStep then return false end

	local found = false

	for ty = math.floor(y0 / size), math.floor(y1 / size) do
		for tx = math.floor(x0 / size), math.floor(x1 / size) do
			local key = tiles_source:GetKey(tx, ty)
			local tile = tiles[key]

			if not tile then
				self.missed[key] = true
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

-- writes the planned mosaic's texels into bytes, rows of stride texels, zeros where no tile has a grid
function META:FillMosaic(plan, pixels, stride)
	local size = self.Size
	local bytes = self.Bytes
	local tiles = self.tiles
	local tiles_source = self.tiles_source
	local step = plan.step

	for b = 0, plan.height - 1 do
		local gy = plan.y0 + b * step
		local ty = math.floor(gy / size)
		local row = (gy - ty * size) * size
		local a = 0

		while a < plan.width do
			local gx = plan.x0 + a * step
			local tx = math.floor(gx / size)
			local run = math.min(math.floor(((tx + 1) * size - 1 - gx) / step) + 1, plan.width - a)
			local tile = tiles[tiles_source:GetKey(tx, ty)]
			local grid = tile and tile.grid
			local o = (b * stride + a) * bytes

			if not grid then
				ffi.fill(pixels + o, run * bytes)
			elseif step == 1 then
				ffi.copy(pixels + o, grid + (row + gx - tx * size) * bytes, run * bytes)
			else
				for n = 0, run - 1 do
					local i = (row + gx + n * step - tx * size) * bytes

					for k = 0, bytes - 1 do
						pixels[o + n * bytes + k] = grid[i + k]
					end
				end
			end

			a = a + run
		end
	end
end

-- source[field] is set to this while it runs
function META:Start(source, terrain, field)
	self:Stop()
	self.tiles = {}
	self.building = 0
	self.field = field
	self:SetSource(source, terrain)
	local next_update = 0

	event.AddListener("Update", "earth_" .. self.Name, function()
		local now = system.GetElapsedTime()

		if now < next_update then return end

		next_update = now + UPDATE_INTERVAL
		self:Update()
	end)
end

-- the grids are in map tiles, so they stay when the origin moves
function META:SetSource(source, terrain)
	if self.source then self.source[self.field] = nil end

	self.source = source
	self.terrain = terrain
	self.missed = {}
	source[self.field] = self
	self:Update()
end

function META:Stop()
	event.RemoveListener("Update", "earth_" .. self.Name)

	if self.tiles then
		for _, tile in pairs(self.tiles) do
			tile.removed = true
		end
	end

	if self.source then self.source[self.field] = nil end

	self.tiles = nil
	self.source = nil
	self.terrain = nil
end

-- built, pending (fetching or building) and failed tiles
function META:GetStats()
	local stats = {built = 0, pending = 0, failed = 0}

	for _, tile in pairs(self.tiles or {}) do
		local key = tile.state == "built" and
			"built" or
			tile.state == "failed" and
			"failed" or
			"pending"
		stats[key] = stats[key] + 1
	end

	return stats
end

return tile_grids
