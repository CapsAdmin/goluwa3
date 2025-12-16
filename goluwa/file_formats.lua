local Buffer = require("structs.buffer")
local png_decode = require("file_formats.png.decode")
local jpg_decode = require("file_formats.jpg.decode")
local dds_decode = require("file_formats.dds.decode")
local zip_decode = require("file_formats.zip.decode")
local file_formats = {}

local function buffer_from_path(path)
	local file = assert(io.open(path, "rb"))
	local file_data = file:read("*a")

	if not file_data then
		file:close()
		error("File is empty")
	end

	file:close()
	return Buffer.New(file_data, #file_data)
end

function file_formats.LoadPNG(path)
	return png_decode(buffer_from_path(path))
end

function file_formats.LoadJPG(path)
	return jpg_decode(buffer_from_path(path))
end

function file_formats.LoadDDS(path)
	return dds_decode(buffer_from_path(path))
end

function file_formats.LoadZIP(path)
	return zip_decode(buffer_from_path(path))
end

function file_formats.Load(path)
	local real_path = path
	local path = path:lower()

	if path:ends_with(".png") then
		return file_formats.LoadPNG(real_path)
	elseif path:ends_with(".jpg") or path:ends_with(".jpeg") then
		return file_formats.LoadJPG(real_path)
	elseif path:ends_with(".dds") then
		return file_formats.LoadDDS(real_path)
	elseif path:ends_with(".zip") then
		return file_formats.LoadZIP(real_path)
	end

	error("Unsupported image format: " .. real_path)
end

return file_formats
