local T = require("test.environment")
local ffi = require("ffi")
local Buffer = require("structs.buffer")
local vtf = require("codecs.vtf")
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
T.Test("VTF decode gm_construct grass1.vtf", function()
	local file_buffer = load_vtf_file(VTF)
	local img = vtf.DecodeBuffer(file_buffer)
	T(img)["~="](nil)
	T(img.width)[">"](0)
	T(img.height)[">"](0)
	T(img.depth)["~="](nil)
	T(img.vtf_format)["~="](nil)
	T(img.vulkan_format)["~="](nil)
	T(img.mip_count)["~="](nil)
	T(img.frames)["~="](nil)
	T(img.data_size)[">"](0)
	T(img.buffer:GetSize())["=="](img.data_size)
	-- Verify mipmap info
	T(#img.mip_info)["=="](img.mip_count)
	-- Mip 1 (index 1) should be largest (mip level 0)
	T(img.mip_info[1].width)["=="](img.width)
	T(img.mip_info[1].height)["=="](img.height)
	-- Last mip should be smallest (1x1 for 2048x2048 with 12 mips)
	T(img.mip_info[img.mip_count].width)["=="](1)
	T(img.mip_info[img.mip_count].height)["=="](1)
end)

T.Test("VTF decode validates signature", function()
	-- Create invalid VTF data
	local invalid_data = "INVALID_DATA"
	local buffer_data = ffi.new("uint8_t[?]", #invalid_data)
	ffi.copy(buffer_data, invalid_data, #invalid_data)
	local buffer = Buffer.New(buffer_data, #invalid_data)
	local img, err = vtf.DecodeBuffer(buffer)
	T(img)["=="](nil)
	T(err)["~="](nil)
	T(tostring(err):find("signature"))["~="](nil)
end)
