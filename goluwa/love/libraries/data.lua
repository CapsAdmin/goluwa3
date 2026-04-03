local base64 = import("goluwa/codecs/base64.lua")
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

return love.data
