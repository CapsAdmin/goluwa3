local encode = require("file_formats.png.encode")
local decode = require("file_formats.png.decode")
local png = {}

function png.encode(pixels, width, height, color_mode)
	local o = encode.new(width, height, color_mode)
	o:write(pixels)
	return o:getData()
end

function png.decode(buffer)
	return decode(buffer)
end

return png
