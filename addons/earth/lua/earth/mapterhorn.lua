local json = import("goluwa/codecs/json.lua")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local system = import("goluwa/system.lua")
local pmtiles = import("goluwa/codecs/pmtiles.lua")
local TileSet = import("lua/earth/tile_set.lua")
local geo = import("lua/earth/geo.lua")
-- Mapterhorn's terrain tiles read out of its pmtiles archives with range requests, as its maintainer asks apps to:
-- planet.pmtiles holds zoom 0-12, the 6-x-y.pmtiles archives the deeper zooms where national lidar exists
local mapterhorn = {}
local LIST_URL = "https://download.mapterhorn.com/download_urls.json"
local LIST_MAX_AGE = 7 * 24 * 3600
local LIST_RETRY = 600
local HOST_LIMIT = 6
local MAX_LEAF_DEPTH = 4
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
	local age = cached and
		os.time() - (
			fs.get_last_modified and
			fs.get_last_modified(path) or
			0
		)
		or
		math.huge

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
		archive = {
			item = item,
			url = item.url,
			directory = mapterhorn.Directory .. item.name:gsub("%.pmtiles$", "") .. "-" .. item.md5sum .. "/",
			leaves = {},
			waiters = {},
		}
		archives[key] = archive
	end

	return archive
end

local function range_request(archive, offset, length, callback)
	local header = {Range = string.format("bytes=%d-%d", offset, offset + length - 1)}

	if archive.etag then header["If-Match"] = archive.etag end

	TileSet.HostRequest(
		archive.url,
		header,
		HOST_LIMIT,
		function(response)
			if response.code == 206 then
				callback(response.body, response.header)
			elseif response.code == 412 then
				-- the archive was replaced under its name: read the list again
				list = nil
				archives[archive.item.name .. ":" .. archive.item.md5sum] = nil
				callback(nil, "the archive changed")
			else
				callback(nil, "http " .. tostring(response.code))
			end
		end,
		function(reason)
			callback(nil, reason)
		end
	)
end

local function with_header(archive, callback)
	if archive.header then return callback(true) end

	if archive.loading then
		archive.waiters[#archive.waiters + 1] = callback
		return
	end

	local function load(head, etag)
		archive.header = pmtiles.ParseHeader(head)
		assert(archive.header.tile_type == "webp", "mapterhorn: expected webp tiles")
		assert(
			archive.header.root_offset + archive.header.root_length <= #head,
			"mapterhorn: root directory beyond the first read"
		)
		archive.root = pmtiles.DecodeDirectory(
			head:sub(archive.header.root_offset + 1, archive.header.root_offset + archive.header.root_length),
			archive.header.internal_compression
		)
		archive.etag = etag
	end

	local head = fs.read_file(archive.directory .. "head.bin")

	if head then
		load(head, fs.read_file(archive.directory .. "etag.txt"))
		return callback(true)
	end

	archive.loading = true
	archive.waiters = {callback}

	range_request(
		archive,
		0,
		pmtiles.ROOT_READ_SIZE,
		function(body, response_header)
			archive.loading = false
			local ok = body ~= nil

			if ok then
				local etag = response_header.etag
				load(body, etag)
				fs.create_directory_recursive(archive.directory)
				fs.write_file(archive.directory .. "head.bin", body)

				if etag then fs.write_file(archive.directory .. "etag.txt", etag) end
			end

			local waiters = archive.waiters
			archive.waiters = {}

			for _, waiter in ipairs(waiters) do
				waiter(ok, response_header)
			end
		end
	)
end

local function with_leaf(archive, offset, length, callback)
	local leaf = archive.leaves[offset]

	if leaf and leaf.directory then return callback(leaf.directory) end

	if leaf then
		leaf.waiters[#leaf.waiters + 1] = callback
		return
	end

	local path = archive.directory .. "leaf_" .. offset .. "_" .. length .. ".bin"
	local cached = fs.read_file(path)

	if cached then
		leaf = {
			directory = pmtiles.DecodeDirectory(cached, archive.header.internal_compression),
		}
		archive.leaves[offset] = leaf
		return callback(leaf.directory)
	end

	leaf = {waiters = {callback}}
	archive.leaves[offset] = leaf

	range_request(
		archive,
		archive.header.leaf_offset + offset,
		length,
		function(body, reason)
			local waiters = leaf.waiters
			leaf.waiters = nil

			if body then
				fs.write_file(path, body)
				leaf.directory = pmtiles.DecodeDirectory(body, archive.header.internal_compression)
			else
				archive.leaves[offset] = nil
			end

			for _, waiter in ipairs(waiters) do
				waiter(leaf.directory, reason)
			end
		end
	)
end

local function find_tile(archive, directory, id, depth, done)
	local i = pmtiles.FindEntry(directory, id)

	if not i then return done("missing") end

	if directory.runs[i] > 0 then
		range_request(
			archive,
			archive.header.data_offset + directory.offsets[i],
			directory.lengths[i],
			function(body, reason)
				if body then done("ok", body) else done("error", reason) end
			end
		)

		return
	end

	if depth >= MAX_LEAF_DEPTH then
		return done("error", "pmtiles directories nest too deep")
	end

	with_leaf(
		archive,
		directory.offsets[i],
		directory.lengths[i],
		function(leaf, reason)
			if not leaf then return done("error", reason) end

			find_tile(archive, leaf, id, depth + 1, done)
		end
	)
end

-- a TileSet fetch: tiles where Mapterhorn has no data (the open sea) are "missing", zooms deeper than its data there "unavailable"
function mapterhorn.Fetch(set, tile, done)
	with_list(function(parsed)
		if not parsed then return done("error", "no mapterhorn archive list") end

		local item = find_item(parsed, tile.z, tile.x, tile.y)

		if not item then return done("unavailable") end

		local archive = get_archive(item)

		with_header(archive, function(ok, reason)
			if not ok then return done("error", reason) end

			find_tile(archive, archive.root, pmtiles.TileId(tile.z, tile.x, tile.y), 0, done)
		end)
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
