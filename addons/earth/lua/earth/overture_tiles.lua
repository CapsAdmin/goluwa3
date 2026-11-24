local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local deflate = import("goluwa/codecs/deflate.lua")
local Archive = import("lua/earth/pmtiles_archive.lua")
local map_tiles = import("lua/earth/map_tiles.lua")
local overture_tiles = {}
overture_tiles.RELEASE = "2026-10-21.0"
local META = setmetatable({}, {__index = map_tiles.META})
META.__index = META
local themes = {}

function overture_tiles.Get(theme, zoom)
	local key = theme .. ":" .. zoom

	if not themes[key] then
		themes[key] = setmetatable(
			{
				Theme = theme,
				Zoom = zoom,
				directory = vfs.GetStorageDirectory("cache") .. "earth/overture/" .. overture_tiles.RELEASE .. "/" .. theme .. "/",
				fetching = {},
			},
			META
		)
	end

	return themes[key]
end

function META:GetArchive()
	self.archive = self.archive or
		Archive.New{
			url = "https://tiles.overturemaps.org/" .. overture_tiles.RELEASE .. "/" .. self.Theme .. ".pmtiles",
			directory = self.directory,
			host_limit = 4,
		}
	return self.archive
end

function META:GetPath(x, y)
	return string.format("%s%d/%d/%d.mvt", self.directory, self.Zoom, x, y)
end

-- an empty file where the archive has no tile
function META:Fetch(x, y, done)
	local path = self:GetPath(x, y)

	if fs.is_file(path) then
		done()
		return
	end

	local key = self:GetKey(x, y)
	local fetching = self.fetching

	if fetching[key] then
		table.insert(fetching[key], done)
		return
	end

	fetching[key] = {done}
	local archive = self:GetArchive()

	archive:Fetch(
		self.Zoom,
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

return overture_tiles
