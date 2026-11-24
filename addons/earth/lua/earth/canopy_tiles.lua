local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local TileSet = import("lua/earth/tile_set.lua")
local map_tiles = import("lua/earth/map_tiles.lua")
-- zoom 14 tiles of SIZE^2 texel pairs: the tallest canopy in the texel and the canopy around it blurred, in meters
local canopy_tiles = {}
canopy_tiles.ATTRIBUTION = "Canopy height: Meta and World Resources Institute (CC BY 4.0)"
canopy_tiles.SIZE = 512
canopy_tiles.ZOOM = 14
canopy_tiles.BLUR = 3
local URL = "https://dataforgood-fb-data.s3.amazonaws.com/forests/v1/alsgedi_global_v6_float/chm/%s.tif"
local FILE_ZOOM = 9
local PER_FILE = 2 ^ (canopy_tiles.ZOOM - FILE_ZOOM)
local HOST_LIMIT = 4
local META = setmetatable({}, {__index = map_tiles.META})
META.__index = META
local directory = vfs.GetStorageDirectory("cache") .. "earth/canopy/"

local function quadkey(x, y, zoom)
	local digits = {}

	for i = zoom, 1, -1 do
		local mask = 2 ^ (i - 1)
		digits[#digits + 1] = (math.floor(x / mask) % 2) + (math.floor(y / mask) % 2) * 2
	end

	return table.concat(digits)
end

local function read_u64(p, o)
	local v = 0

	for i = 7, 0, -1 do
		v = v * 256 + p[o + i]
	end

	return v
end

local function request(url, offset, length, callback)
	TileSet.HostRequest(
		url,
		{Range = string.format("bytes=%d-%d", offset, offset + length - 1)},
		HOST_LIMIT,
		function(response)
			if response.code == 206 then
				callback(response.body)
			elseif response.code == 403 or response.code == 404 then
				callback(nil, "missing")
			else
				callback(nil, "http " .. tostring(response.code))
			end
		end,
		function(reason)
			callback(nil, reason)
		end
	)
end

local function get_strips(file, callback)
	local path = directory .. file.key .. ".strips"

	if fs.is_file(path) then
		local data = fs.read_file(path)
		callback(data ~= "" and data or nil, data == "" and "missing" or nil)
		return
	end

	request(
		file.url,
		0,
		65536,
		function(head, err)
			if not head then
				if err == "missing" then fs.write_file(path, "") end

				callback(nil, err)
				return
			end

			local p = ffi.cast("const uint8_t *", head)
			assert(p[2] == 43, "the canopy map is a BigTIFF")
			local ifd = read_u64(p, 8)
			assert(ifd + 8 <= #head, "the canopy map's first directory is in its first 64 KB")
			local tags = {}

			for i = 0, read_u64(p, ifd) - 1 do
				local e = ifd + 8 + i * 20
				tags[p[e] + p[e + 1] * 256] = {count = read_u64(p, e + 4), value = read_u64(p, e + 12)}
			end

			assert(
				tags[256].value == tags[257].value and tags[278].value == 1,
				"the canopy map is square with a strip per row"
			)
			assert(
				tags[259].value == 8 and tags[317].value == 2,
				"the canopy map is deflated with horizontal differencing"
			)
			local rows = tags[273].count
			local offsets, counts = tags[273].value, tags[279].value
			local from = math.min(offsets, counts)
			local to = math.max(offsets, counts) + rows * 8

			request(
				file.url,
				from,
				to - from,
				function(body, err)
					if not body then
						callback(nil, err)
						return
					end

					local strips = body:sub(offsets - from + 1, offsets - from + rows * 8) .. body:sub(counts - from + 1, counts - from + rows * 8)
					fs.create_directory_recursive(directory)
					fs.write_file(path, strips)
					callback(strips)
				end
			)
		end
	)
end

-- input: data, first, strips (offsets then counts, u64), rows, width, file_x, file_y, band, directory; writes the
-- band's tiles to directory/<x>/<y>.bin
canopy_tiles.JOB = [=[
	local input = ...
	local ffi = require("ffi")
	local deflate = import("goluwa/codecs/deflate.lua")
	local fs = import("goluwa/filesystem/fs.lua")
	local size, blur, per_file = input.size, input.blur, input.per_file
	local width = input.width
	local pool = width / per_file / size
	local strips = ffi.cast("const uint8_t *", input.strips)
	local data = input.data
	local rows = input.rows

	local function u64(o)
		local v = 0

		for i = 7, 0, -1 do
			v = v * 256 + strips[o + i]
		end

		return v
	end

	local grid_width = size * per_file
	local tallest = ffi.new("uint8_t[?]", grid_width * size)

	for r = 0, rows - 1 do
		local offset = u64(r * 8) - input.first
		local count = u64((rows + r) * 8)
		local out = deflate.Decode(data:sub(offset + 1, offset + count), "zlib")
		local row = ffi.cast("const uint8_t *", out.Buffer)
		local o = math.floor(r / pool) * grid_width
		local value = 0

		for x = 0, width - 1 do
			value = (value + row[x]) % 256
			local i = o + math.floor(x / pool)

			if value > tallest[i] then tallest[i] = value end
		end
	end

	-- the band's own rows only, so the blur is cut at its edges
	local sum = ffi.new("float[?]", grid_width * size)
	local tmp = ffi.new("float[?]", grid_width * size)

	for y = 0, size - 1 do
		for x = 0, grid_width - 1 do
			local s, n = 0, 0

			for k = math.max(x - blur, 0), math.min(x + blur, grid_width - 1) do
				s, n = s + tallest[y * grid_width + k], n + 1
			end

			tmp[y * grid_width + x] = s / n
		end
	end

	for y = 0, size - 1 do
		for x = 0, grid_width - 1 do
			local s, n = 0, 0

			for k = math.max(y - blur, 0), math.min(y + blur, size - 1) do
				s, n = s + tmp[k * grid_width + x], n + 1
			end

			sum[y * grid_width + x] = s / n
		end
	end

	local tile = ffi.new("uint8_t[?]", size * size * 2)
	local y14 = input.file_y * per_file + input.band

	for column = 0, per_file - 1 do
		for y = 0, size - 1 do
			for x = 0, size - 1 do
				local i = y * grid_width + column * size + x
				local o = (y * size + x) * 2
				tile[o] = tallest[i]
				tile[o + 1] = math.floor(sum[i] + 0.5)
			end
		end

		local path = string.format("%s%d/%d.bin", input.directory, input.file_x * per_file + column, y14)
		fs.create_directory_recursive(path:match("^(.*/)"))
		fs.write_file(path, ffi.string(tile, size * size * 2))
	end

	return {}
]=]
canopy_tiles.GRID_JOB = [[
	local input = ...
	local data = input.data

	if #data == 0 then return {any = false} end

	return {any = data:find("[^%z]") ~= nil}, data
]]

function canopy_tiles.Get()
	canopy_tiles.tiles = canopy_tiles.tiles or setmetatable({Zoom = canopy_tiles.ZOOM, bands = {}}, META)
	return canopy_tiles.tiles
end

function META:GetPath(x, y)
	return string.format("%s%d/%d.bin", directory, x, y)
end

-- the file is empty where the map has no data
function META:Fetch(x, y, done)
	local path = self:GetPath(x, y)

	if fs.is_file(path) then
		done()
		return
	end

	local file_x, file_y = math.floor(x / PER_FILE), math.floor(y / PER_FILE)
	local band = y % PER_FILE
	local key = file_x .. "/" .. file_y .. "/" .. band

	if self.bands[key] then
		table.insert(self.bands[key], done)
		return
	end

	self.bands[key] = {done}

	local function finish(err)
		local waiting = self.bands[key]
		self.bands[key] = nil

		for _, callback in ipairs(waiting) do
			callback(err)
		end
	end

	local file = {key = quadkey(file_x, file_y, FILE_ZOOM)}
	file.url = string.format(URL, file.key)

	get_strips(file, function(strips, err)
		if not strips then
			if err == "missing" then
				for column = 0, PER_FILE - 1 do
					local empty = self:GetPath(file_x * PER_FILE + column, y)
					fs.create_directory_recursive(empty:match("^(.*/)"))
					fs.write_file(empty, "")
				end

				finish()
			else
				finish(err)
			end

			return
		end

		local file_rows = #strips / 16
		local rows = file_rows / PER_FILE
		local p = ffi.cast("const uint8_t *", strips)
		local row0 = band * rows
		local first = read_u64(p, row0 * 8)
		local last = read_u64(p, (row0 + rows - 1) * 8) + read_u64(p, (file_rows + row0 + rows - 1) * 8)
		local band_strips = strips:sub(row0 * 8 + 1, (row0 + rows) * 8) .. strips:sub((file_rows + row0) * 8 + 1, (file_rows + row0 + rows) * 8)

		request(
			file.url,
			first,
			last - first,
			function(data, err)
				if not data then
					finish(err)
					return
				end

				thread_pool.Run(
					canopy_tiles.JOB,
					{
						data = data,
						first = first,
						strips = band_strips,
						rows = rows,
						width = file_rows,
						file_x = file_x,
						file_y = file_y,
						band = band,
						size = canopy_tiles.SIZE,
						blur = canopy_tiles.BLUR,
						per_file = PER_FILE,
						directory = directory,
					},
					math.huge
				):OnDone(function(job)
					finish(job.err and tostring(job.err) or nil)
				end)
			end
		)
	end)
end

return canopy_tiles
