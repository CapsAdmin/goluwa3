local http = require("sockets.http")
local legal_uri_characters = {
	["-"] = true,
	["."] = true,
	["_"] = true,
	["~"] = true,
	[":"] = true,
	["/"] = true,
	["?"] = true,
	["#"] = true,
	["["] = true,
	["]"] = true,
	["@"] = true,
	["!"] = true,
	["$"] = true,
	["&"] = true,
	["'"] = true,
	["("] = true,
	[")"] = true,
	["*"] = true,
	["+"] = true,
	[","] = true,
	[";"] = true,
	["="] = true,
	["%"] = true,
}

function http.DecodeURI(uri)
	local scheme
	local path
	local authority
	local host
	local port
	scheme, path = uri:match("^(%l[%l%d+.-]+):(.+)")

	if not scheme then return nil, "unable to parse URI: " .. uri end

	if path:starts_with("//") then
		path = path:sub(3)
		host, rest = path:match("^(.-)(/.*)$")

		if rest then
			path = rest:gsub("[^%w%-_%.%!%~%*%'%(%)]", function(c)
				if not legal_uri_characters[c] then
					return string.format("%%%02X", c:byte(1, 1))
				end
			end)
		else
			host = path
			path = "/"
		end

		if host:find("@", 1, true) then
			local temp = host:split("@")
			authority = temp[1]
			host = temp[2]
		end

		local temp = host:split(":")
		host = temp[1]
		port = temp[2]
	end

	return {
		scheme = scheme,
		path = path,
		authority = authority,
		host = host,
		port = port,
	}
end

function http.EncodeURI(tbl)
	local uri = ""

	if tbl.scheme then uri = uri .. tbl.scheme .. "://" end

	if tbl.authority then uri = uri .. tbl.authority .. "@" end

	if tbl.host then uri = uri .. tbl.host .. "/" end

	if tbl.path or tbl.query then
		local str = ""

		if tbl.path then str = str .. tbl.path end

		if tbl.query then
			str = str .. "?"

			for k, v in pairs(tbl.query) do
				str = str .. k .. "=" .. v .. "&"
			end

			if str:ends_with("&") then str = str:sub(0, -2) end
		end

		str = str:gsub("[^%w%-_%.%!%~%*%'%(%)]", function(c)
			if not legal_uri_characters[c] then
				return string.format("%%%02X", c:byte(1, 1))
			end
		end)
		uri = uri .. str
	end

	return uri
end

function http.EncodeQuery(tbl)
	local str = "?"

	for k, v in pairs(tbl) do
		str = str .. k .. "=" .. v .. "&"
	end

	if str:ends_with("&") then str = str:sub(0, -2) end

	return str
end
