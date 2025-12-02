local file_formats = require("file_formats")
local ffi = require("ffi")
local Buffer = require("structs.buffer")
local profiler = require("helpers.profiler")
local stop_profiler = profiler.Start()

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

-- Test DDS loading
local path = "/home/caps/projects/RTXDI-Assets/bistro/textures/decals/circulargrunge_01/circulargrunge_01_diff.dds"
local dds_decode = require("file_formats.dds.decode")
local inputbuf, err = buffer_from_path(path)

if not inputbuf then error(err) end

local result = dds_decode(inputbuf)
print("Decoded DDS result:")
print("  Width:", result.width)
print("  Height:", result.height)
print("  Format:", result.format)
print("  Vulkan format:", result.vulkan_format)
print("  Mip count:", result.mip_count)
print("  Is compressed:", result.is_compressed)
print("  Data size:", result.data_size)

if result.mip_info then
	print("\nMip levels:")
	for i, mip in ipairs(result.mip_info) do
		print(string.format("  Mip %d: %dx%d, offset=%d, size=%d", 
			i-1, mip.width, mip.height, mip.offset, mip.size))
	end
end

stop_profiler()
