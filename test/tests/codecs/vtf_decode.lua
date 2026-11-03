local T = import("test/environment.lua")
local ffi = require("ffi")
local Buffer = import("goluwa/structs/buffer.lua")
local vtf = import("goluwa/codecs/vtf.lua")
local resource = import("goluwa/resource.lua")
local vfs = import("goluwa/vfs.lua")
local VTF = "https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/extras/materials/nature/grassfloor002a.vtf"

local function load_vtf_file(path)
	local full_path = resource.Download(path):Get()

	if not full_path then error("Could not open VTF file: " .. path) end

	local file = assert(vfs.Open(full_path))
	local file_data = file:ReadAll()
	file:Close()
	local file_buffer_data = ffi.new("uint8_t[?]", #file_data)
	ffi.copy(file_buffer_data, file_data, #file_data)
	return Buffer.New(file_buffer_data, #file_data)
end

T.Test("VTF decode", function()
	local file_buffer = load_vtf_file(VTF)
	local img, data = vtf.DecodeBuffer(file_buffer)
	T(img)["~="](nil)
	T(img.width)[">"](0)
	T(img.height)[">"](0)
	T(img.depth)["~="](nil)
	T(img.vtf_format)["~="](nil)
	T(img.vulkan_format)["~="](nil)
	T(img.mip_count)["~="](nil)
	T(img.frames)["~="](nil)
	T(img.data_size)[">"](0)
	T(ffi.sizeof(data))["=="](img.data_size)
	T(#img.mip_info)["=="](img.mip_count)
	T(img.mip_info[1].width)["=="](img.width)
	T(img.mip_info[1].height)["=="](img.height)
	T(img.mip_info[img.mip_count].width)["=="](1)
	T(img.mip_info[img.mip_count].height)["=="](1)
end)

T.Test("VTF decode validates signature", function()
	local invalid_data = "INVALID_DATA"
	local buffer_data = ffi.new("uint8_t[?]", #invalid_data)
	ffi.copy(buffer_data, invalid_data, #invalid_data)
	local buffer = Buffer.New(buffer_data, #invalid_data)
	local img, err = vtf.DecodeBuffer(buffer)
	T(img)["=="](nil)
	T(err)["~="](nil)
	T(tostring(err):find("signature"))["~="](nil)
end)

local function build_sheet_vtf()
	local function u32(value)
		return ffi.string(ffi.new("uint32_t[1]", value), 4)
	end

	local function u16(value)
		return ffi.string(ffi.new("uint16_t[1]", value), 2)
	end

	local function f32(value)
		return ffi.string(ffi.new("float[1]", value), 4)
	end

	local sheet = u32(0) .. u32(2)

	for id = 0, 1 do
		sheet = sheet .. u32(id) .. u32(1) .. u32(1) .. f32(1) .. f32(0.1) .. f32(id * 0.5) .. f32(0) .. f32(id * 0.5 + 0.5) .. f32(1)
	end

	local header_size = 80 + 2 * 8
	local sheet_offset = header_size
	local image_offset = sheet_offset + 4 + #sheet
	local header = "VTF\0" .. u32(7) .. u32(3) .. u32(header_size) .. u16(1) .. u16(1) .. u32(0) .. u16(1) .. u16(0) .. string.rep("\0", 4) .. f32(0) .. f32(0) .. f32(0) .. string.rep("\0", 4) .. f32(1) .. u32(12) .. "\1" .. u32(0xffffffff) .. "\0\0" .. u16(1) .. "\0\0\0" .. u32(2) .. string.rep("\0", 8)
	local entries = "\16\0\0\0" .. u32(sheet_offset) .. "\48\0\0\0" .. u32(image_offset)
	return header .. entries .. u32(#sheet) .. sheet .. "\10\20\30\40"
end

T.Test("VTF sheets are parsed and image data is found through the resource table", function()
	local data = build_sheet_vtf()
	local sheet = vtf.ParseSheet(data)
	T(#sheet.sequences)["=="](2)
	T(sheet.sequences[2].id)["=="](1)
	T(sheet.sequences[2].frames[1].rect[1])["=="](0.5)
	T(sheet.sequences[2].frames[1].rect[3])["=="](1)
	T(sheet.sequences[1].time)["=="](1)
	local buffer_data = ffi.new("uint8_t[?]", #data)
	ffi.copy(buffer_data, data, #data)
	local img, pixels = vtf.DecodeBuffer(Buffer.New(buffer_data, #data))
	T(img.width)["=="](1)
	T(img.data_size)["=="](4)
	T(pixels[0])["=="](10)
	T(pixels[3])["=="](40)
	T(
		vtf.ParseSheet(
			"not a vtf at all, not a vtf at all, not a vtf at all, not a vtf at all, not a vtf at all"
		)
	)["=="](nil)
end)
