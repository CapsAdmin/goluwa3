local Buffer = require("structs.buffer")
local png_decode = require("file_formats.png.decode")
local jpg_decode = require("file_formats.jpg.decode")
local file_formats = {}

local function buffer_from_path(path)
	local file, err = io.open(path, "rb")

	if not file then return nil, err end

	local file_data = file:read("*a")

	if not file_data then
		file:close()
		return nil, "File is empty"
	end

	file:close()
	return Buffer.New(file_data, #file_data)
end

function file_formats.LoadPNG(path)
	local buffer, err = buffer_from_path(path)

	if not buffer then return nil, err end

	return png_decode(buffer)
end

function file_formats.LoadJPG(path)
	local buffer, err = buffer_from_path(path)

	if not buffer then return nil, err end

	return jpg_decode(buffer)
end

return file_formats
