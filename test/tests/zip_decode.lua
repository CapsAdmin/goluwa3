local T = require("test.t")
local ffi = require("ffi")
local Buffer = require("structs.buffer")
local zip_decode = require("file_formats.zip.decode")

-- Helper to load ZIP file into buffer
local function load_zip_file(path)
	local file = assert(io.open(path, "rb"), "Could not open ZIP file: " .. path)
	local file_data = file:read("*a")
	file:close()
	local file_buffer_data = ffi.new("uint8_t[?]", #file_data)
	ffi.copy(file_buffer_data, file_data, #file_data)
	return Buffer.New(file_buffer_data, #file_data)
end

T.test("ZIP decode basic functionality", function()
	local ZIP_PATH = "game/storage/temp_bsp.zip"
	local file_buffer = load_zip_file(ZIP_PATH)
	local archive = zip_decode(file_buffer)
	-- Basic structure checks
	T(archive.fileCount)[">="](1)
	T(#archive.files)[">="](1)
	T(archive.files)["~="](nil)

	-- Check that files have expected fields
	for i, file in ipairs(archive.files) do
		T(file.name)["~="](nil)
		T(type(file.isDirectory))["=="]("boolean")
		T(type(file.compressionMethod))["=="]("number")
		T(type(file.compressedSize))["=="]("number")
		T(type(file.uncompressedSize))["=="]("number")
		T(file.data)["~="](nil)
	end
end)

T.test("ZIP decode invalid file", function()
	local invalid_data = "This is not a ZIP file"
	local file_buffer_data = ffi.new("uint8_t[?]", #invalid_data)
	ffi.copy(file_buffer_data, invalid_data, #invalid_data)
	local buffer = Buffer.New(file_buffer_data, #invalid_data)
	local success, err = pcall(function()
		zip_decode(buffer)
	end)
	T(success)["=="](false)
	T(err:find("PK signature"))["~="](nil)
end)
