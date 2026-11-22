local ffi = require("ffi")
local http = import("goluwa/sockets/http.lua")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local system = import("goluwa/system.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local threads = import("goluwa/bindings/threads.lua")
local TileSet = {}
TileSet.__index = TileSet
TileSet.USER_AGENT = "goluwa-earth/1.0 (+https://github.com/CapsAdmin/goluwa)"
local RETRY_DELAYS = {1, 4, 15}
local FAILED_RETRY_SECONDS = 60
local DECODE_JOB = [=[
	local ffi = require("ffi")
	local input = ...
	local kind, path, dehaze = input.kind, input.path, input.dehaze
	local Buffer = import("goluwa/structs/buffer.lua")
	local file = assert(io.open(path, "rb"))
	local data = file:read("*a")
	file:close()

	if kind == "terrarium" and data:sub(1, 4) == "RIFF" then
		local width, height, argb = import("goluwa/codecs/webp.lua").DecodeARGB(data, #data)
		local heights = ffi.new("float[?]", width * height)
		local bit = require("bit")

		for i = 0, width * height - 1 do
			local p = argb[i]
			heights[i] = bit.band(bit.rshift(p, 16), 255) * 256 + bit.band(bit.rshift(p, 8), 255) + bit.band(p, 255) / 256 - 32768
		end

		return {width = width, height = height}, heights
	end

	if kind == "terrarium" then
		local image = import("goluwa/codecs/png.lua").DecodeBuffer(Buffer.New(data, #data))
		assert(image.depth == 8, "terrarium tiles are 8 bit")
		local width, height = image.width, image.height
		local pixels = ffi.cast("const uint8_t *", image.data)
		local heights = ffi.new("float[?]", width * height)

		-- the png decoder writes the rows bottom up
		for y = 0, height - 1 do
			local row = pixels + (height - 1 - y) * width * 4

			for x = 0, width - 1 do
				local p = row + x * 4
				heights[y * width + x] = p[0] * 256 + p[1] + p[2] / 256 - 32768
			end
		end

		return {width = image.width, height = image.height}, heights
	end

	local image, pixels

	if data:sub(1, 8) == "\137PNG\r\n\26\n" then
		image = import("goluwa/codecs/png.lua").DecodeBuffer(Buffer.New(data, #data))
		assert(image.depth == 8, "photo tiles are 8 bit")
		local row_bytes = image.width * 4
		local flipped = ffi.new("uint8_t[?]", row_bytes * image.height)
		local source = ffi.cast("const uint8_t *", image.data)

		-- the png decoder writes the rows bottom up
		for y = 0, image.height - 1 do
			ffi.copy(flipped + y * row_bytes, source + (image.height - 1 - y) * row_bytes, row_bytes)
		end

		pixels = flipped
	else
		image = import("goluwa/codecs/jpg.lua").DecodeBuffer(Buffer.New(data, #data))
		pixels = ffi.cast("uint8_t *", image.buffer.Buffer)
	end

	local count = image.width * image.height * 4

	-- a service outside its data answers a blank tile: one colour, or mostly white, or black around the data's edge
	if kind == "photo" then
		local white, black = 0, 0
		local low_r, low_g, low_b, high_r, high_g, high_b = 255, 255, 255, 0, 0, 0

		for i = 0, count - 1, 4 do
			local r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]

			if r >= 250 and g >= 250 and b >= 250 then white = white + 1 end

			if r <= 6 and g <= 6 and b <= 6 then black = black + 1 end

			low_r, low_g, low_b = math.min(low_r, r), math.min(low_g, g), math.min(low_b, b)
			high_r, high_g, high_b = math.max(high_r, r), math.max(high_g, g), math.max(high_b, b)
		end

		local pixel_count = count / 4

		if
			white > pixel_count * 0.25 or
			black > pixel_count * 0.02 or
			math.max(high_r - low_r, high_g - low_g, high_b - low_b) <= 2
		then
			return {width = image.width, height = image.height, blank = true}
		end
	end

	-- haze and thin cloud taken out by the dark channel prior: where even the darkest channel around a pixel is far from
	-- black, the pixel is that much the haze's colour (air), which is taken back out; the haze's colour is fixed per source
	-- (not estimated per tile) so neighbouring tiles agree
	if dehaze then
		local width, height = image.width, image.height
		local n = width * height
		local air_r, air_g, air_b = dehaze.air[1], dehaze.air[2], dehaze.air[3]
		local dark = ffi.new("float[?]", n)
		local pass = ffi.new("float[?]", n)

		for i = 0, n - 1 do
			local o = i * 4
			dark[i] = math.min(pixels[o] / air_r, pixels[o + 1] / air_g, pixels[o + 2] / air_b)
		end

		local function filter(src, dst, radius, step, along, across, minimum)
			for a = 0, across - 1 do
				for b = 0, along - 1 do
					local value = minimum and math.huge or 0

					for k = math.max(b - radius, 0), math.min(b + radius, along - 1) do
						local v = src[a * (step == 1 and along or 1) + k * step]
						value = minimum and math.min(value, v) or value + v
					end

					dst[a * (step == 1 and along or 1) + b * step] = minimum and value or value / (math.min(b + radius, along - 1) - math.max(b - radius, 0) + 1)
				end
			end
		end

		filter(dark, pass, dehaze.radius, 1, width, height, true)
		filter(pass, dark, dehaze.radius, width, height, width, true)
		filter(dark, pass, dehaze.blur, 1, width, height, false)
		filter(pass, dark, dehaze.blur, width, height, width, false)

		for i = 0, n - 1 do
			local o = i * 4
			local t = 1 / math.max(1 - dehaze.strength * dark[i], dehaze.floor)
			pixels[o] = math.min(math.max((pixels[o] - air_r) * t + air_r + 0.5, 0), 255)
			pixels[o + 1] = math.min(math.max((pixels[o + 1] - air_g) * t + air_g + 0.5, 0), 255)
			pixels[o + 2] = math.min(math.max((pixels[o + 2] - air_b) * t + air_b + 0.5, 0), 255)
		end
	end

	local tone = _G.earth_tone_lut

	if not tone then
		tone = ffi.new("uint8_t[256]")

		-- the photos carry the capture sun's shading and the renderer lights them again: lift the darks, hold back the brights
		for i = 0, 255 do
			local x = i / 255
			tone[i] = math.floor(math.min(math.max(x + 0.06 * (1 - x) ^ 3 - 0.1 * x ^ 3, 0), 1) * 255 + 0.5)
		end

		_G.earth_tone_lut = tone
	end

	for i = 0, count - 1, 4 do
		pixels[i] = tone[pixels[i]]
		pixels[i + 1] = tone[pixels[i + 1]]
		pixels[i + 2] = tone[pixels[i + 2]]
		pixels[i + 3] = 255
	end

	return {width = image.width, height = image.height}, ffi.string(pixels, count)
]=]

do
	local hosts = {}

	local function pump(host)
		while host.active < host.limit and host.queue[1] do
			local item = table.remove(host.queue, 1)
			host.active = host.active + 1
			local done = false

			local function release()
				if done then return false end

				done = true
				host.active = host.active - 1
				pump(host)
				return true
			end

			http.Request{
				url = item.url,
				header = item.header,
				timeout = 30,
				callback = function(response)
					if release() then item.callback(response) end
				end,
				error_callback = function(reason)
					if release() then item.error_callback(reason) end
				end,
			}
		end
	end

	-- a GET that waits its turn among the requests to the url's host, at most limit at once
	function TileSet.HostRequest(url, header, limit, callback, error_callback)
		local name = url:match("^%a+://([^/]+)")
		local host = hosts[name]

		if not host then
			host = {active = 0, limit = limit, queue = {}}
			hosts[name] = host
		end

		header["User-Agent"] = TileSet.USER_AGENT
		host.queue[#host.queue + 1] = {
			url = url,
			header = header,
			callback = callback,
			error_callback = error_callback,
		}
		pump(host)
	end
end

-- fetches a tile from its url: done("ok", body), done("missing") on a 404, done("error", reason)
function TileSet.UrlFetch(set, tile, done)
	TileSet.HostRequest(
		set.Url(tile.z, tile.x, tile.y),
		{},
		set.HostLimit,
		function(response)
			if response.code == 404 then
				done("missing")
			elseif response.code == 200 then
				done("ok", response.body)
			else
				done("error", "http " .. tostring(response.code))
			end
		end,
		function(reason)
			done("error", reason)
		end
	)
end

-- config: name (the cache folder), url(z, x, y) or fetch(set, tile, done) (see UrlFetch, done also takes "unavailable":
-- the tile exists at no zoom this deep there, it is not cached), extension, tile_size, max_zoom,
-- kind ("terrarium", "image" or "photo": an image whose blank tiles count as missing), bounds ({south, west, north,
-- east}: it has no tiles outside), min_zoom, host_limit (requests at once to its host), max_resident (decoded tiles kept in memory),
-- missing_is_sea (a tile that does not exist is open sea rather than a hole),
-- native_zoom(lat, lon) (the zoom whose pixels match the resolution of the source data there, max_zoom by default),
-- dehaze ({air (the haze's sRGB colour, 0-255), strength, floor (the least transmission), radius (texels of the dark
-- channel's minimum), blur}: haze taken out of photos as they are decoded)
function TileSet.New(config)
	local self = setmetatable({}, TileSet)
	self.Name = config.name
	self.Url = config.url
	self.Fetch = config.fetch or TileSet.UrlFetch
	self.Extension = config.extension
	self.TileSize = config.tile_size
	self.MaxZoom = config.max_zoom
	self.MinZoom = config.min_zoom or 0
	self.Bounds = config.bounds
	self.Attribution = config.attribution
	self.Kind = config.kind
	self.Dehaze = config.dehaze
	self.HostLimit = config.host_limit or 6
	self.MaxResident = config.max_resident or 512
	self.MissingIsSea = config.missing_is_sea or false
	self.NativeZoom = config.native_zoom or function()
		return self.MaxZoom
	end
	self.Directory = config.directory or
		(
			vfs.GetStorageDirectory("cache") .. "earth/" .. self.Name .. "/"
		)
	self.Tiles = {}
	self.Resident = 0
	self.Stamp = 0
	self.Stats = {downloaded = 0, decoded = 0, failed = 0, bytes = 0}
	return self
end

local function tile_key(z, x, y)
	return z * 4294967296 + y * 65536 + x
end

function TileSet:GetPath(z, x, y)
	return string.format("%s%d/%d/%d.%s", self.Directory, z, x, y, self.Extension)
end

function TileSet:Touch(tile)
	self.Stamp = self.Stamp + 1
	tile.stamp = self.Stamp
end

-- the tile if it is decoded, else nil; state is "ready", "loading", "missing" (does not exist), "unavailable" or "failed"
function TileSet:Get(z, x, y)
	local tile = self.Tiles[tile_key(z, x, y)]

	if tile and tile.state == "ready" then
		self:Touch(tile)
		return tile
	end
end

function TileSet:GetState(z, x, y)
	local tile = self.Tiles[tile_key(z, x, y)]
	return tile and tile.state or nil
end

-- starts loading a tile (disk, else network) and returns its state
function TileSet:Request(z, x, y)
	local key = tile_key(z, x, y)
	local tile = self.Tiles[key]

	if tile then
		self:Touch(tile)

		if tile.state == "failed" and system.GetElapsedTime() >= tile.retry_at then
			tile.state = "loading"
			tile.attempt = 0
			self:Download(tile)
		end

		return tile.state
	end

	tile = {z = z, x = x, y = y, key = key, state = "loading", attempt = 0}
	self.Tiles[key] = tile
	self:Touch(tile)
	local path = self:GetPath(z, x, y)

	if fs.is_file(path) then
		self:Decode(tile, path)
	elseif fs.is_file(path .. ".missing") then
		self:Finish(tile, "missing")
	else
		self:Download(tile)
	end

	return tile.state
end

function TileSet:Finish(tile, state)
	tile.state = state

	if state == "failed" then
		self.Stats.failed = self.Stats.failed + 1
		tile.retry_at = system.GetElapsedTime() + FAILED_RETRY_SECONDS
	end
end

function TileSet:Decode(tile, path)
	thread_pool.Run(DECODE_JOB, {kind = self.Kind, path = path, dehaze = self.Dehaze}, math.huge):OnDone(function(job)
		if self.Tiles[tile.key] ~= tile then return end

		if job.err or not job.meta then
			llog("earth: decoding %s failed: %s", path, tostring(job.err))
			os.remove(path)
			self:Finish(tile, "failed")
			return
		end

		if job.meta.blank then
			os.remove(path)
			fs.write_file(path .. ".missing", "")
			self:Finish(tile, "missing")
			return
		end

		tile.width = job.meta.width
		tile.height = job.meta.height
		tile.blob = job.blob
		tile.data = self.Kind == "terrarium" and
			ffi.cast("const float *", job.blob.ptr) or
			ffi.cast("const uint8_t *", job.blob.ptr)
		self.Stats.decoded = self.Stats.decoded + 1
		self.Resident = self.Resident + 1
		self:Finish(tile, "ready")
		self:Evict()
	end)
end

function TileSet:Evict()
	if self.Resident <= self.MaxResident then return end

	local list = {}

	for _, tile in pairs(self.Tiles) do
		if tile.state == "ready" then list[#list + 1] = tile end
	end

	table.sort(list, function(a, b)
		return a.stamp < b.stamp
	end)

	for i = 1, #list - math.floor(self.MaxResident * 0.75) do
		local tile = list[i]
		self.Tiles[tile.key] = nil
		threads.release_blob(tile.blob)
		tile.blob = nil
		tile.data = nil
		tile.state = "evicted"
		self.Resident = self.Resident - 1
	end
end

function TileSet:Download(tile)
	self.Fetch(self, tile, function(result, body)
		if self.Tiles[tile.key] ~= tile or tile.state ~= "loading" then return end

		local path = self:GetPath(tile.z, tile.x, tile.y)

		if result == "ok" then
			self.Stats.downloaded = self.Stats.downloaded + 1
			self.Stats.bytes = self.Stats.bytes + #body
			fs.create_directory_recursive(path:match("^(.*/)"))
			fs.write_file(path .. ".part", body)
			os.rename(path .. ".part", path)
			self:Decode(tile, path)
		elseif result == "missing" then
			fs.create_directory_recursive(path:match("^(.*/)"))
			fs.write_file(path .. ".missing", "")
			self:Finish(tile, "missing")
		elseif result == "unavailable" then
			self:Finish(tile, "unavailable")
		else
			tile.attempt = tile.attempt + 1
			local delay = RETRY_DELAYS[tile.attempt]

			if not delay then
				llog(
					"earth: %s %d/%d/%d failed: %s",
					self.Name,
					tile.z,
					tile.x,
					tile.y,
					tostring(body)
				)
				self:Finish(tile, "failed")
				return
			end

			tile.retry_download_at = system.GetElapsedTime() + delay * (0.5 + math.random() * 0.5)
			self.Retrying = self.Retrying or {}
			self.Retrying[#self.Retrying + 1] = tile
		end
	end)
end

function TileSet:Update()
	local retrying = self.Retrying

	if not retrying or not retrying[1] then return end

	local now = system.GetElapsedTime()
	local i = 1

	while retrying[i] do
		local tile = retrying[i]

		if now >= tile.retry_download_at then
			table.remove(retrying, i)

			if self.Tiles[tile.key] == tile and tile.state == "loading" then
				self:Download(tile)
			end
		else
			i = i + 1
		end
	end
end

function TileSet:Clear()
	for _, tile in pairs(self.Tiles) do
		if tile.blob then threads.release_blob(tile.blob) end

		tile.state = "evicted"
	end

	self.Tiles = {}
	self.Resident = 0
end

return TileSet
