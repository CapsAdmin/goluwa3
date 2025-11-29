local Buffer = require("structs.buffer")
local png = require("file_formats.png.init")
local file_formats = {}

function file_formats.LoadPNG(path)
	local file = io.open(path, "rb")
	local file_data = file:read("*a")
	file:close()
	local file_buffer = Buffer.New(file_data, #file_data)
	local img = png.decode(file_buffer)
	return img
end

return file_formats
