local file_formats = require("file_formats")
local ffi = require("ffi")
-- Add debug version of jpg_decode
local Buffer = require("structs.buffer")

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

-- Just load to see component order info
local path = "/home/caps/projects/glTF-Sample-Assets-main/Models/Sponza/glTF/8481240838833932244.jpg"
-- Debug: Use the standard decoder and check what getData receives
local jpg_decode = require("file_formats.jpg.decode")
local inputbuf, err = buffer_from_path(path)

if not inputbuf then error(err) end

-- Call with custom opts to capture debug info
local result = jpg_decode(inputbuf, {formatAsRGBA = true})
print("Decoded result:")
print("  Width:", result.width)
print("  Height:", result.height)
-- Check component data
local resbuffer = result.buffer
local channels = 4 -- RGBA
local rowSize = result.width * channels

-- Sample a few pixels from different parts of the image
local function samplePixel(x, y)
	local pixoffset = y * rowSize + x * channels
	local r = resbuffer:GetByte(pixoffset)
	local g = resbuffer:GetByte(pixoffset + 1)
	local b = resbuffer:GetByte(pixoffset + 2)
	local a = resbuffer:GetByte(pixoffset + 3)
	print(string.format("Pixel (%d, %d): R=%d, G=%d, B=%d, A=%d", x, y, r, g, b, a))
end

print("\nSampling pixels:")
samplePixel(0, 0)
samplePixel(math.floor(result.width / 2), math.floor(result.height / 2))
samplePixel(result.width - 1, result.height - 1)
samplePixel(10, 10)
samplePixel(100, 100)
-- Let's also check what the raw line values are
print("\nDebug: Checking if lines contain data...")-- Since scaleX, scaleY are 1 for h=1,v=1 and maxH=1,maxV=1
-- the getData loop accesses lines[y] for y from 0 to height-1
-- Let's see if lines actually have varying data
