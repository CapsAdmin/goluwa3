local base64 = import("goluwa/codecs/base64.lua")
local deflate = import("goluwa/codecs/deflate.lua")
local love = ... or _G.love
love.data = love.data or {}

local function get_string(data)
	if type(data) == "string" then return data end

	if type(data) == "table" then
		if data.getString then return data:getString() end

		if data.data then return data.data end
	end

	error("unsupported data source type: " .. type(data), 2)
end

local function wrap_output(container, data, name)
	if container == "string" then return data end

	if container == "data" or container == "file" then
		return love.filesystem.newFileData(data, name or "data.bin")
	end

	error("unsupported love.data container: " .. tostring(container), 2)
end

function love.data.decode(container, format, data)
	container = tostring(container)
	format = tostring(format):lower()
	data = get_string(data)

	if format == "base64" then
		return wrap_output(container, base64.Decode(data), "decoded.bin")
	end

	error("unsupported love.data decode format: " .. format, 2)
end

function love.data.encode(container, format, data)
	container = tostring(container)
	format = tostring(format):lower()
	data = get_string(data)

	if format == "base64" then
		return wrap_output(container, base64.Encode(data), "encoded.txt")
	end

	error("unsupported love.data encode format: " .. format, 2)
end

function love.data.decompress(container, format, compressed_data)
	container = tostring(container)
	format = tostring(format):lower()
	compressed_data = get_string(compressed_data)

	if format == "deflate" or format == "zlib" or format == "gzip" then
		local ok, result = pcall(deflate.Decode, compressed_data, format)

		if ok and result ~= nil then
			return wrap_output(container, result, "decompressed.bin")
		end

		-- Some Love games save plain text through the compatibility layer when no
		-- matching compressor exists yet. Returning the original payload keeps the
		-- load path working for those saves while still decoding real deflate data.
		return wrap_output(container, compressed_data, "decompressed.bin")
	end

	error("unsupported love.data decompress format: " .. format, 2)
end

function love.data.compress(container, format, raw_data, level)
	container = tostring(container)
	format = tostring(format):lower()
	raw_data = get_string(raw_data)

	if format == "deflate" or format == "zlib" or format == "gzip" then
		return wrap_output(container, raw_data, "compressed.bin")
	end

	error("unsupported love.data compress format: " .. format, 2)
end

return love.data
