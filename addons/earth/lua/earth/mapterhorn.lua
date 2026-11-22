local json = import("goluwa/codecs/json.lua")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local system = import("goluwa/system.lua")
local TileSet = import("lua/earth/tile_set.lua")
local Archive = import("lua/earth/pmtiles_archive.lua")
local geo = import("lua/earth/geo.lua")
-- Mapterhorn's terrain tiles read out of its pmtiles archives with range requests, as its maintainer asks apps to:
-- planet.pmtiles holds zoom 0-12, the 6-x-y.pmtiles archives the deeper zooms where national lidar exists
local mapterhorn = {}
local LIST_URL = "https://download.mapterhorn.com/download_urls.json"
local LIST_MAX_AGE = 7 * 24 * 3600
local LIST_RETRY = 600
local HOST_LIMIT = 6
mapterhorn.Directory = vfs.GetStorageDirectory("cache") .. "earth/mapterhorn_archives/"
local list
local list_waiters
local list_failed_at
local archives = {}

local function parse_list(str)
	local items = json.decode(str).items
	local parsed = {regions = {}}

	for _, item in ipairs(items) do
		if item.name == "planet.pmtiles" then
			parsed.planet = item
		else
			local x, y = item.name:match("^6%-(%d+)%-(%d+)%.pmtiles$")

			if x then parsed.regions[tonumber(x) * 64 + tonumber(y)] = item end
		end
	end

	assert(parsed.planet, "mapterhorn: the archive list has no planet.pmtiles")
	return parsed
end

local function with_list(callback)
	if list then return callback(list) end

	if list_waiters then
		list_waiters[#list_waiters + 1] = callback
		return
	end

	local path = mapterhorn.Directory .. "download_urls.json"
	local cached = fs.read_file(path)
	local age = cached and os.time() - fs.get_attributes(path).last_modified or math.huge

	if cached and age < LIST_MAX_AGE then
		list = parse_list(cached)
		return callback(list)
	end

	if list_failed_at and system.GetElapsedTime() - list_failed_at < LIST_RETRY then
		if cached then
			list = parse_list(cached)
			return callback(list)
		end

		return callback(nil)
	end

	list_waiters = {callback}

	local function finish(parsed)
		list = parsed
		local waiters = list_waiters
		list_waiters = nil

		for _, waiter in ipairs(waiters) do
			waiter(parsed)
		end
	end

	TileSet.HostRequest(
		LIST_URL,
		{},
		HOST_LIMIT,
		function(response)
			if response.code ~= 200 then
				list_failed_at = system.GetElapsedTime()
				finish(cached and parse_list(cached) or nil)
				return
			end

			fs.create_directory_recursive(mapterhorn.Directory)
			fs.write_file(path, response.body)
			finish(parse_list(response.body))
		end,
		function()
			list_failed_at = system.GetElapsedTime()
			finish(cached and parse_list(cached) or nil)
		end
	)
end

-- the archive item holding a tile, or nil and "unavailable" when no archive goes this deep there
local function find_item(parsed, z, x, y)
	if z <= parsed.planet.max_zoom then return parsed.planet end

	local shift = 2 ^ (z - 6)
	local item = parsed.regions[math.floor(x / shift) * 64 + math.floor(y / shift)]

	if item and z >= item.min_zoom and z <= item.max_zoom then return item end
end

local function get_archive(item)
	local key = item.name .. ":" .. item.md5sum
	local archive = archives[key]

	if not archive then
		archive = Archive.New{
			url = item.url,
			directory = mapterhorn.Directory .. item.name:gsub("%.pmtiles$", "") .. "-" .. item.md5sum .. "/",
			host_limit = HOST_LIMIT,
			on_changed = function()
				-- the archive was replaced under its name: read the list again
				list = nil
				archives[key] = nil
			end,
		}
		archives[key] = archive
	end

	return archive
end

-- a TileSet fetch: tiles where Mapterhorn has no data (the open sea) are "missing", zooms deeper than its data there "unavailable"
function mapterhorn.Fetch(set, tile, done)
	with_list(function(parsed)
		if not parsed then return done("error", "no mapterhorn archive list") end

		local item = find_item(parsed, tile.z, tile.x, tile.y)

		if not item then return done("unavailable") end

		get_archive(item):Fetch(tile.z, tile.x, tile.y, done)
	end)
end

-- the deepest zoom of the data at a latitude and longitude (the national lidar's), the planet's until the list is read
function mapterhorn.GetNativeZoom(lat, lon)
	if not list then return 12 end

	local x, y = geo.ToMercator(lat, lon, 6, 1)
	local item = list.regions[math.floor(x % 64) * 64 + math.clamp(math.floor(y), 0, 63)]
	return item and item.max_zoom or list.planet.max_zoom
end

return mapterhorn
