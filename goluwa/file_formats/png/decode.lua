-- initially based on https://github.com/DelusionalLogic/pngLua
local ffi = require("ffi")
local bit_band = require("bit").band
local Buffer = require("structs.buffer")
local deflate = require("helpers.deflate")

local function getDataIHDR(buffer, length)
	return {
		width = buffer:ReadU32BE(),
		height = buffer:ReadU32BE(),
		bitDepth = buffer:ReadByte(),
		colorType = buffer:ReadByte(),
		compression = buffer:ReadByte(),
		filter = buffer:ReadByte(),
		interlace = buffer:ReadByte(),
	}
end

local function getDataIDAT(buffer, length, oldData)
	local data = {}

	if (oldData == nil) then
		data.data = buffer:ReadBytes(length)
	else
		data.data = oldData.data .. buffer:ReadBytes(length)
	end

	return data
end

local function getDataPLTE(buffer, length)
	local data = {}
	data["numColors"] = math.floor(length / 3)
	data["colors"] = {}

	for i = 1, data["numColors"] do
		data.colors[i] = {
			R = buffer:ReadByte(),
			G = buffer:ReadByte(),
			B = buffer:ReadByte(),
		}
	end

	return data
end

local function extractChunkData(buffer)
	local chunkData = {}
	local length
	local type
	local crc

	while type ~= "IEND" do
		length = buffer:ReadU32BE()
		type = buffer:ReadBytes(4)

		if (type == "IHDR") then
			chunkData[type] = getDataIHDR(buffer, length)
		elseif (type == "IDAT") then
			chunkData[type] = getDataIDAT(buffer, length, chunkData[type])
		elseif (type == "PLTE") then
			chunkData[type] = getDataPLTE(buffer, length)
		else
			buffer:ReadBytes(length)
		end

		crc = buffer:ReadBytes(4)
	end

	return chunkData
end

local function paethPredict(a, b, c)
	local p = a + b - c
	local varA = math.abs(p - a)
	local varB = math.abs(p - b)
	local varC = math.abs(p - c)

	if varA <= varB and varA <= varC then
		return a
	elseif varB <= varC then
		return b
	else
		return c
	end
end

local FILTER_NONE = 0
local FILTER_SUB = 1
local FILTER_UP = 2
local FILTER_AVERAGE = 3
local FILTER_PAETH = 4
--
local COLOR_TYPE_GRAYSCALE = 0
local COLOR_TYPE_RGB = 2
local COLOR_TYPE_INDEXED = 3
local COLOR_TYPE_GRAYSCALE_ALPHA = 4
local COLOR_TYPE_PALETTE_ALPHA = 5
local COLOR_TYPE_RGBA = 6
local FLIP_Y = false

-- Helper function to read value based on bytes per sample
local function readValue(buffer, bps)
	if bps == 1 then
		return buffer:ReadByte()
	elseif bps == 2 then
		return buffer:ReadU16BE()
	else
		error("Unsupported bit depth: " .. (bps * 8))
	end
end

-- Read raw pixel from input buffer into R, G, B, A values
local function readPixel(buffer, bps, colorType, palette, maxAlpha)
	local R, G, B, A

	if colorType == 0 then
		-- Grayscale
		local grey = readValue(buffer, bps)
		R, G, B, A = grey, grey, grey, maxAlpha
	elseif colorType == 2 then
		-- RGB
		R = readValue(buffer, bps)
		G = readValue(buffer, bps)
		B = readValue(buffer, bps)
		A = maxAlpha
	elseif colorType == 3 then
		-- Indexed
		local index = readValue(buffer, bps) + 1
		local color = palette.colors[index]
		R, G, B, A = color.R, color.G, color.B, maxAlpha
	elseif colorType == 4 then
		-- Grayscale + Alpha
		local grey = readValue(buffer, bps)
		R, G, B = grey, grey, grey
		A = readValue(buffer, bps)
	elseif colorType == 6 then
		-- RGBA
		R = readValue(buffer, bps)
		G = readValue(buffer, bps)
		B = readValue(buffer, bps)
		A = readValue(buffer, bps)
	end

	return R, G, B, A
end

-- Optimized getPixels that writes directly to output buffer
-- Returns the output buffer with RGBA pixels, flipped vertically for Vulkan
local function getPixels(buffer, data)
	local colorType = data.IHDR.colorType
	local width = data.IHDR.width
	local height = data.IHDR.height
	local bitDepth = data.IHDR.bitDepth
	local bps = math.floor(bitDepth / 8) -- bytes per sample
	local hasAlpha = (colorType == COLOR_TYPE_GRAYSCALE_ALPHA or colorType == COLOR_TYPE_RGBA)
	-- Determine output format: 8-bit or 16-bit RGBA
	local is16bit = (bitDepth == 16)
	local bytesPerPixel = is16bit and 8 or 4 -- 16-bit = 8 bytes (R16G16B16A16), 8-bit = 4 bytes (R8G8B8A8)
	-- Calculate bytes per pixel in the input (before adding alpha)
	local samplesPerPixel = (
			colorType == COLOR_TYPE_RGB and
			3
		)
		or
		(
			colorType == COLOR_TYPE_RGBA and
			4
		)
		or
		(
			colorType == COLOR_TYPE_GRAYSCALE and
			1
		)
		or
		(
			colorType == COLOR_TYPE_GRAYSCALE_ALPHA and
			2
		)
		or
		1
	local bytesPerInputPixel = samplesPerPixel * bps
	-- Create output buffer for RGBA pixels
	local outputSize = width * height * bytesPerPixel
	local outputData = is16bit and
		ffi.new("uint16_t[?]", width * height * 4) or
		ffi.new("uint8_t[?]", outputSize)
	local out = outputData
	-- Previous and current row buffers store RAW BYTES (not reconstructed values)
	-- For PNG filtering, we work with bytes regardless of bit depth
	local rowBytes = width * bytesPerInputPixel
	local prevRow = ffi.new("uint8_t[?]", rowBytes)
	local currRow = ffi.new("uint8_t[?]", rowBytes)
	-- Maximum value for alpha channel (255 for 8-bit, 65535 for 16-bit)
	local maxAlpha = is16bit and 65535 or 255

	for y = 1, height do
		local filterType = buffer:ReadByte()

		-- Read and reconstruct the scanline byte-by-byte
		for i = 0, rowBytes - 1 do
			local rawByte = buffer:ReadByte()
			local reconstructed

			if filterType == FILTER_NONE then
				reconstructed = rawByte
			elseif filterType == FILTER_SUB then
				local left = i >= bytesPerInputPixel and currRow[i - bytesPerInputPixel] or 0
				reconstructed = (rawByte + left) % 256
			elseif filterType == FILTER_UP then
				local up = prevRow[i]
				reconstructed = (rawByte + up) % 256
			elseif filterType == FILTER_AVERAGE then
				local left = i >= bytesPerInputPixel and currRow[i - bytesPerInputPixel] or 0
				local up = prevRow[i]
				reconstructed = (rawByte + math.floor((left + up) / 2)) % 256
			elseif filterType == FILTER_PAETH then
				local left = i >= bytesPerInputPixel and currRow[i - bytesPerInputPixel] or 0
				local up = prevRow[i]
				local upLeft = i >= bytesPerInputPixel and prevRow[i - bytesPerInputPixel] or 0
				reconstructed = (rawByte + paethPredict(left, up, upLeft)) % 256
			else
				error("Unsupported filter type: " .. tostring(filterType))
			end

			currRow[i] = reconstructed
		end

		-- Now convert the reconstructed bytes to output format (RGBA)
		for x = 0, width - 1 do
			local inIdx = x * bytesPerInputPixel
			local outIdx = (y - 1) * width + x

			if is16bit then
				-- Combine bytes into 16-bit values
				local R, G, B, A

				if colorType == COLOR_TYPE_RGB then
					R = currRow[inIdx] * 256 + currRow[inIdx + 1]
					G = currRow[inIdx + 2] * 256 + currRow[inIdx + 3]
					B = currRow[inIdx + 4] * 256 + currRow[inIdx + 5]
					A = maxAlpha
				elseif colorType == COLOR_TYPE_RGBA then
					R = currRow[inIdx] * 256 + currRow[inIdx + 1]
					G = currRow[inIdx + 2] * 256 + currRow[inIdx + 3]
					B = currRow[inIdx + 4] * 256 + currRow[inIdx + 5]
					A = currRow[inIdx + 6] * 256 + currRow[inIdx + 7]
				elseif colorType == COLOR_TYPE_GRAYSCALE then
					local grey = currRow[inIdx] * 256 + currRow[inIdx + 1]
					R, G, B, A = grey, grey, grey, maxAlpha
				elseif colorType == COLOR_TYPE_GRAYSCALE_ALPHA then
					local grey = currRow[inIdx] * 256 + currRow[inIdx + 1]
					R, G, B = grey, grey, grey
					A = currRow[inIdx + 2] * 256 + currRow[inIdx + 3]
				end

				out[outIdx * 4 + 0] = R
				out[outIdx * 4 + 1] = G
				out[outIdx * 4 + 2] = B
				out[outIdx * 4 + 3] = A
			else
				-- 8-bit: bytes are already the right values
				local R, G, B, A

				if colorType == COLOR_TYPE_RGB then
					R, G, B, A = currRow[inIdx], currRow[inIdx + 1], currRow[inIdx + 2], 255
				elseif colorType == COLOR_TYPE_RGBA then
					R, G, B, A = currRow[inIdx], currRow[inIdx + 1], currRow[inIdx + 2], currRow[inIdx + 3]
				elseif colorType == COLOR_TYPE_GRAYSCALE then
					local grey = currRow[inIdx]
					R, G, B, A = grey, grey, grey, 255
				elseif colorType == COLOR_TYPE_GRAYSCALE_ALPHA then
					local grey = currRow[inIdx]
					R, G, B, A = grey, grey, currRow[inIdx + 1]
				elseif colorType == COLOR_TYPE_INDEXED then
					local index = currRow[inIdx] + 1
					local color = data.PLTE.colors[index]
					R, G, B, A = color.R, color.G, color.B, 255
				else
					R, G, B, A = 255, 0, 255, 255 -- Pink for unknown
				end

				out[outIdx * 4 + 0] = R
				out[outIdx * 4 + 1] = G
				out[outIdx * 4 + 2] = B
				out[outIdx * 4 + 3] = A
			end
		end

		-- Swap buffers for next iteration
		prevRow, currRow = currRow, prevRow
	end

	-- Return raw buffer data and size
	return outputData, outputSize
end

-- Map PNG format to Vulkan format name
-- Supports both 8-bit and 16-bit RGBA outputs
local function png_to_vulkan_format(colorType, bitDepth)
	if bitDepth == 8 then
		-- 8-bit output: R8G8B8A8_UNORM
		return "r8g8b8a8_unorm"
	elseif bitDepth == 16 then
		-- 16-bit output: R16G16B16A16_UNORM
		return "r16g16b16a16_unorm"
	else
		-- Fallback for unusual bit depths
		return "r8g8b8a8_unorm"
	end
end

local function pngImage(inputBuffer)
	if inputBuffer:ReadBytes(8) ~= "\137\080\078\071\013\010\026\010" then
		error("Not a png")
	end

	local data = extractChunkData(inputBuffer)
	local colorType = data.IHDR.colorType
	local bitDepth = data.IHDR.bitDepth
	-- Determine Vulkan format based on source format
	local vulkan_format = png_to_vulkan_format(colorType, bitDepth)
	-- Get the decoded pixel buffer
	local pixelData, pixelSize = getPixels(deflate.inflate_zlib({
		input = data.IDAT.data,
		disable_crc = true,
	}), data)
	-- Cast to uint8_t* for consistency (pixelData might be uint16_t* for 16-bit images)
	local pixelDataPtr = ffi.cast("uint8_t*", pixelData)
	return {
		width = data.IHDR.width,
		height = data.IHDR.height,
		depth = bitDepth,
		colorType = colorType,
		vulkan_format = vulkan_format,
		-- Provide both data (raw buffer pointer) and buffer (Buffer wrapper)
		data = pixelDataPtr,
		buffer = Buffer.New(pixelDataPtr, pixelSize),
	}
end

return pngImage
