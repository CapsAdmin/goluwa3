local T = require("test.t")
local ffi = require("ffi")
local Buffer = require("structs.buffer")
local vtf_decode = require("file_formats.vtf.decode")
local vfs = require("vfs")
local VTF = "/home/caps/.steam/steam/steamapps/common/GarrysMod/garrysmod/garrysmod_dir.vpk/materials/gm_construct/grass1.vtf"

-- Helper to load VTF file into buffer using vfs
local function load_vtf_file(path)
	local file = vfs.Open(path)

	if not file then error("Could not open VTF file: " .. path) end

	local file_data = file:ReadAll()
	file:Close()
	local file_buffer_data = ffi.new("uint8_t[?]", #file_data)
	ffi.copy(file_buffer_data, file_data, #file_data)
	return Buffer.New(file_buffer_data, #file_data)
end

-- Test basic VTF decoding functionality with real VTF file
T.test("VTF decode gm_construct grass1.vtf", function()
	local file_buffer = load_vtf_file(VTF)
	local img = vtf_decode(file_buffer)
	T(img)["~="](nil)
	T(img.width)[">"](0)
	T(img.height)[">"](0)
	T(img.depth)["~="](nil)
	T(img.format)["~="](nil)
	T(img.mip_count)["~="](nil)
	T(img.frames)["~="](nil)
	T(img.buffer:GetSize())[">"](0)
	T(img.buffer:GetSize())["=="](img.width * img.height * 4) -- RGBA output
end)

T.test("VTF decode validates signature", function()
	-- Create invalid VTF data
	local invalid_data = "INVALID_DATA"
	local buffer_data = ffi.new("uint8_t[?]", #invalid_data)
	ffi.copy(buffer_data, invalid_data, #invalid_data)
	local buffer = Buffer.New(buffer_data, #invalid_data)
	local img, err = vtf_decode(buffer)
	T(img)["=="](nil)
	T(err)["~="](nil)
	T(tostring(err):find("signature"))["~="](nil)
end)

require("goluwa.main")()
