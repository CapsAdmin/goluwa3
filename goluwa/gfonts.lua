local http = require("http")
local resource = require("resource")
local callback = require("callback")
local sockets = require("sockets.sockets")
local gfonts = library()
local weight_map = {
	thin = 100,
	extralight = 200,
	light = 300,
	regular = 400,
	medium = 500,
	semibold = 600,
	bold = 700,
	extrabold = 800,
	black = 900,
}
local _Download = callback.WrapKeyedTask(function(self, key, options)
	local name = options.name
	local weight = options.weight or "regular"

	if type(weight) == "string" then
		weight = tonumber(weight) or weight_map[weight:lower()] or 400
	end

	local resolve = self.callbacks.resolve
	local reject = self.callbacks.reject
	-- Construct URL for CSS API v1
	local url = (
		"http://fonts.googleapis.com/css?family=%s:%d"
	):format(name:gsub(" ", "+"), weight)
	-- We need to spoof the User-Agent to get TTF files. 
	-- Android 2.2 User-Agent is known to return TTF.
	local headers = {
		["User-Agent"] = "Mozilla/5.0 (Linux; U; Android 2.2; en-us; Nexus One Build/FRF91) AppleWebKit/533.1 (KHTML, like Gecko) Version/4.0 Mobile Safari/533.1",
	}
	sockets.Request(
		{
			url = url,
			method = "GET",
			header = headers,
			callback = function(res)
				if res.code ~= 200 then
					reject(("Failed to fetch CSS from Google Fonts (Status: %d)"):format(res.code))
					return
				end

				local body = res.body
				-- Look for src: url(http://...)
				local ttf_url = body:match("src: url%((https?://.-)%)")

				if not ttf_url then
					reject("Could not find TTF URL in Google Fonts CSS response")
					return
				end

				-- Use resource.Download to actually get the file and cache it
				resource.Download(ttf_url):Then(function(full_path, changed)
					resolve(full_path, changed)
				end):Catch(function(err)
					reject(("Failed to download font file: %s"):format(err or "unknown error"))
				end)
			end,
			error_callback = function(err)
				reject(("Network error while fetching CSS: %s"):format(err or "unknown error"))
			end,
		}
	)
end)

function gfonts.Download(options)
	local key = options.name .. ":" .. (options.weight or "regular")
	return _Download(key, options)
end

return gfonts
