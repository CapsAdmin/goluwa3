local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local deflate = import("goluwa/codecs/deflate.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local planet = import("goluwa/planet.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local water = import("goluwa/render3d/water.lua")
local geo = import("lua/earth/geo.lua")
local Archive = import("lua/earth/pmtiles_archive.lua")
local water_grid = import("lua/earth/water_grid.lua")
-- Overture's lakes, ponds and rivers around the camera: the terrain is carved under them (EarthSource bakes the water
-- mosaic this hands it) and the nearest are filled with water volumes, boxes of one level each
local water_bodies = {}
water_bodies.ATTRIBUTION = "Water: Overture Maps Foundation (OpenStreetMap contributors ODbL)"
water_bodies.RELEASE = "2026-10-21.0"
local ZOOM = 13
local RADIUS = 5000
local KEEP_RADIUS = 8000
local VOLUME_RADIUS = 2000
local MAX_BUILDING = 2
local UPDATE_INTERVAL = 0.25
local HEIGHT_MAX_ZOOM = 14
local MAX_MOSAIC = 256
-- chunks so large that their mosaic would skip more water texels than this are not carved
local MAX_MOSAIC_STEP = 4
local SIZE, MARGIN = water_grid.SIZE, water_grid.MARGIN
local WIDTH = SIZE + MARGIN * 2
local FloatArray = ffi.typeof("float[?]")
local directory = vfs.GetStorageDirectory("cache") .. "earth/overture/" .. water_bodies.RELEASE .. "/base/"

local function get_archive()
	water_bodies.archive = water_bodies.archive or
		Archive.New{
			url = "https://tiles.overturemaps.org/" .. water_bodies.RELEASE .. "/base.pmtiles",
			directory = directory,
			host_limit = 4,
		}
	return water_bodies.archive
end

local function get_path(tile)
	return string.format("%s%d/%d/%d.mvt", directory, ZOOM, tile.x, tile.y)
end

local function tile_key(x, y)
	return y * 2 ^ ZOOM + x % 2 ^ ZOOM
end

-- the world box a tile covers, for the terrain to bake again
local function invalidate(tile)
	local terrain = water_bodies.terrain
	local source = water_bodies.source
	local min_x, min_z, max_x, max_z = math.huge, math.huge, -math.huge, -math.huge

	for _, corner in ipairs{{0, 0}, {1, 0}, {0, 1}, {1, 1}} do
		local x, z = source:LatLonToWorld(geo.FromMercator(tile.x + corner[1], tile.y + corner[2], ZOOM, 1))

		if x then
			min_x, min_z = math.min(min_x, x), math.min(min_z, z)
			max_x, max_z = math.max(max_x, x), math.max(max_z, z)
		end
	end

	if min_x < max_x then terrain:Invalidate(min_x, min_z, max_x, max_z) end
end

-- the world placement of a box: the center of its top (at its level, under which the planet's surface drops away),
-- its size and its turn about the vertical
local function place_box(tile, box)
	local source = water_bodies.source

	local function corner(x, y)
		return source:LatLonToWorld(geo.FromMercator(tile.x + x / SIZE, tile.y + y / SIZE, ZOOM, 1))
	end

	local nw_x, nw_z = corner(box.x0, box.y0)
	local ne_x, ne_z = corner(box.x1, box.y0)
	local sw_x, sw_z = corner(box.x0, box.y1)

	if not nw_x or not ne_x or not sw_x then return end

	local ex, ez = ne_x - nw_x, ne_z - nw_z
	local sx, sz = sw_x - nw_x, sw_z - nw_z
	local cx, cz = nw_x + (ex + sx) / 2, nw_z + (ez + sz) / 2
	local yaw = math.atan2(-ez, ex)
	box.position = Vec3(cx, box.level - planet.GetDrop(cx, cz), cz)
	box.size = Vec3(math.sqrt(ex * ex + ez * ez), water_grid.MAX_DEPTH + 2, math.sqrt(sx * sx + sz * sz))
	box.rotation = Quat(0, math.sin(yaw / 2), 0, math.cos(yaw / 2))
	box.radius = math.sqrt(box.size.x * box.size.x + box.size.z * box.size.z) / 2
end

local function finish_tile(tile, meta, blob)
	tile.grid = FloatArray(WIDTH * WIDTH * 2)
	ffi.copy(tile.grid, blob.ptr, WIDTH * WIDTH * 2 * 4)
	tile.water = meta.water
	tile.boxes = meta.boxes

	for id, level in pairs(meta.levels) do
		water_bodies.levels[id] = water_bodies.levels[id] or level
	end

	for _, box in ipairs(tile.boxes) do
		place_box(tile, box)
	end

	tile.state = "built"

	if tile.water then invalidate(tile) end
end

-- the job's input, nil while the ground under the tile is not loaded
local function build_input(tile)
	local source = water_bodies.source
	local margin = MARGIN / SIZE

	if not tile.height_state then
		local north, west = geo.FromMercator(tile.x - margin, tile.y - margin, ZOOM, 1)
		local south, east = geo.FromMercator(tile.x + 1 + margin, tile.y + 1 + margin, ZOOM, 1)
		local heights = source.Heights
		tile.height_state = {
			south = south,
			west = west,
			north = north,
			east = east,
			zoom = math.min(
				heights.NativeZoom((north + south) / 2, (west + east) / 2),
				heights.MaxZoom,
				HEIGHT_MAX_ZOOM
			),
		}
	end

	local dem = source:RequestHeights(tile.height_state)

	if dem == nil then return end

	if dem == false then
		tile.state = "failed"
		return
	end

	return {
		mvt = fs.read_file(get_path(tile)),
		zoom = ZOOM,
		x = tile.x,
		y = tile.y,
		dem = dem,
		known_levels = water_bodies.levels,
	}
end

local function build_tile(tile)
	local input = build_input(tile)

	if not input then return end

	tile.state = "building"
	water_bodies.building = water_bodies.building + 1

	thread_pool.Run(water_grid.JOB, input, math.huge):OnDone(function(job)
		water_bodies.building = water_bodies.building - 1

		if tile.removed then return end

		if job.err then
			llog("earth: water %d/%d: %s", tile.x, tile.y, tostring(job.err))
			tile.state = "failed"
			return
		end

		finish_tile(tile, job.meta, job.blob)
	end)
end

local function load_tile(tile)
	if fs.is_file(get_path(tile)) then
		tile.state = "fetched"
		return
	end

	tile.state = "loading"
	local archive = get_archive()

	archive:Fetch(
		ZOOM,
		tile.x,
		tile.y,
		function(result, body)
			if tile.removed then return end

			if result == "missing" then
				body = ""
			elseif result ~= "ok" then
				llog("earth: water %d/%d failed: %s", tile.x, tile.y, tostring(body))
				tile.state = "failed"
				return
			elseif archive.header.tile_compression == "gzip" then
				local out, size = deflate.Decode(body, "gzip")
				body = ffi.string(out.Buffer, size)
			end

			local path = get_path(tile)
			fs.create_directory_recursive(path:match("^(.*/)"))
			fs.write_file(path, body)
			tile.state = "fetched"
		end
	)
end

local function remove_tile(tile)
	tile.removed = true

	if tile.state == "built" and tile.water then invalidate(tile) end
end

local function nearest_first(a, b)
	return a.distance < b.distance
end

local function update_volumes(camera)
	local wanted = {}

	for _, tile in pairs(water_bodies.tiles) do
		if tile.state == "built" then
			for _, box in ipairs(tile.boxes) do
				if box.position then
					local dx, dz = box.position.x - camera.x, box.position.z - camera.z
					local distance = math.max(math.sqrt(dx * dx + dz * dz) - box.radius, 0)

					if distance < VOLUME_RADIUS then
						wanted[#wanted + 1] = {box = box, distance = distance}
					end
				end
			end
		end
	end

	table.sort(wanted, nearest_first)
	local keep = {}

	for i = 1, math.min(#wanted, water.MAX_VOLUMES) do
		local box = wanted[i].box
		keep[box] = true

		if not water_bodies.volumes[box] then
			water_bodies.volumes[box] = Entity.New{
				Name = "earth_water",
				Parent = water_bodies.root,
				transform = {Position = box.position, Rotation = box.rotation},
				water_volume = {Size = box.size, Medium = box.medium, Foam = 0, Open = true},
			}
		end
	end

	for box, entity in pairs(water_bodies.volumes) do
		if not keep[box] then
			entity:Remove()
			water_bodies.volumes[box] = nil
		end
	end
end

local function update()
	local source = water_bodies.source
	local camera = render3d.GetCamera():GetPosition()
	local lat, lon = source:WorldToLatLon(camera.x, camera.z)
	local cx, cy = geo.ToMercator(lat, lon, ZOOM, 1)
	local tile_size = geo.GetPixelSize(lat, ZOOM, 1)
	local reach = math.ceil(RADIUS / tile_size) + 1
	local tiles = water_bodies.tiles

	for key, tile in pairs(tiles) do
		local dx = math.max(math.abs(tile.x + 0.5 - cx) - 0.5, 0) * tile_size
		local dy = math.max(math.abs(tile.y + 0.5 - cy) - 0.5, 0) * tile_size

		if dx * dx + dy * dy > KEEP_RADIUS * KEEP_RADIUS then
			tiles[key] = nil
			remove_tile(tile)
		end
	end

	local wanted = {}

	for ty = math.floor(cy) - reach, math.floor(cy) + reach do
		for tx = math.floor(cx) - reach, math.floor(cx) + reach do
			local dx = math.max(math.abs(tx + 0.5 - cx) - 0.5, 0) * tile_size
			local dy = math.max(math.abs(ty + 0.5 - cy) - 0.5, 0) * tile_size
			local distance = dx * dx + dy * dy

			if distance <= RADIUS * RADIUS and ty >= 0 and ty < 2 ^ ZOOM then
				local key = tile_key(tx, ty)
				tiles[key] = tiles[key] or {x = tx % 2 ^ ZOOM, y = ty, state = "new"}
				wanted[#wanted + 1] = {tile = tiles[key], distance = distance}
			end
		end
	end

	table.sort(wanted, nearest_first)

	for _, entry in ipairs(wanted) do
		local tile = entry.tile

		if tile.state == "new" then
			load_tile(tile)
		elseif tile.state == "fetched" and water_bodies.building < MAX_BUILDING then
			build_tile(tile)
		end
	end

	update_volumes(camera)
end

-- the water mosaic over a chunk's height mosaic: the water grids' texels, every so many so it stays small, nil where no
-- built tile has water near or the chunk is too large to carve
function water_bodies.PlanMosaic(_, heights)
	local tiles = water_bodies.tiles
	local per_pixel = SIZE / (heights.set.TileSize * 2 ^ (heights.zoom - ZOOM))
	local x0 = math.floor(heights.x0 * per_pixel) - 1
	local y0 = math.floor(heights.y0 * per_pixel) - 1
	local x1 = math.ceil((heights.x0 + heights.width) * per_pixel) + 1
	local y1 = math.ceil((heights.y0 + heights.height) * per_pixel) + 1
	local step = math.max(1, math.ceil(math.max(x1 - x0, y1 - y0) / MAX_MOSAIC))

	if step > MAX_MOSAIC_STEP then return end

	local found = false

	for ty = math.floor(y0 / SIZE), math.floor(y1 / SIZE) do
		for tx = math.floor(x0 / SIZE), math.floor(x1 / SIZE) do
			local tile = tiles[tile_key(tx, ty)]

			if tile and tile.state == "built" and tile.water then found = true end
		end
	end

	if not found then return end

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

-- writes the planned mosaic's (signed distance, level) pairs into pixels, rows of stride texels
function water_bodies.FillMosaic(_, plan, pixels, stride)
	local tiles = water_bodies.tiles
	local far = water_grid.FAR

	for b = 0, plan.height - 1 do
		local gy = plan.y0 + b * plan.step
		local ty = math.floor(gy / SIZE)
		local row = (gy - ty * SIZE + MARGIN) * WIDTH
		local tile_x, grid

		for a = 0, plan.width - 1 do
			local gx = plan.x0 + a * plan.step
			local tx = math.floor(gx / SIZE)

			if tx ~= tile_x then
				tile_x = tx
				local tile = tiles[tile_key(tx, ty)]
				grid = tile and tile.state == "built" and tile.grid or nil
			end

			local o = (b * stride + a) * 2

			if grid then
				local i = row + gx - tx * SIZE + MARGIN
				pixels[o] = grid[i]
				pixels[o + 1] = grid[i + WIDTH * WIDTH]
			else
				pixels[o] = far
				pixels[o + 1] = 0
			end
		end
	end
end

function water_bodies.Start(source, terrain)
	water_bodies.Stop()
	water_bodies.source = source
	water_bodies.terrain = terrain
	water_bodies.tiles = {}
	water_bodies.levels = {}
	water_bodies.volumes = {}
	water_bodies.building = 0
	water_bodies.root = Entity.New{Name = "earth_water"}
	water_bodies.root:SetTransient(true)
	water_bodies.root:AddComponent("transform")
	source.Water = water_bodies
	local next_update = 0

	event.AddListener("Update", "earth_water", function()
		local now = system.GetElapsedTime()

		if now < next_update then return end

		next_update = now + UPDATE_INTERVAL
		update()
	end)
end

-- the tiles are built again around the new origin
function water_bodies.SetSource(source, terrain)
	water_bodies.Start(source, terrain)
end

function water_bodies.Stop()
	event.RemoveListener("Update", "earth_water")

	if water_bodies.tiles then
		for _, tile in pairs(water_bodies.tiles) do
			tile.removed = true
		end
	end

	if water_bodies.root then water_bodies.root:Remove() end

	if water_bodies.source then water_bodies.source.Water = nil end

	water_bodies.root = nil
	water_bodies.tiles = nil
	water_bodies.volumes = nil
	water_bodies.source = nil
	water_bodies.terrain = nil
end

-- built, pending (on its way: fetching, waiting for the ground, building) and failed tiles, and the water volumes
function water_bodies.GetStats()
	local stats = {built = 0, pending = 0, failed = 0, boxes = 0, volumes = 0}

	for _, tile in pairs(water_bodies.tiles or {}) do
		local key = tile.state == "built" and
			"built" or
			tile.state == "failed" and
			"failed" or
			"pending"
		stats[key] = stats[key] + 1

		if tile.boxes then stats.boxes = stats.boxes + #tile.boxes end
	end

	for _ in pairs(water_bodies.volumes or {}) do
		stats.volumes = stats.volumes + 1
	end

	return stats
end

return water_bodies
