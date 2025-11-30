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
local function readPixel(buffer, bps, colorType, palette)
	local R, G, B, A

	if colorType == 0 then
		-- Grayscale
		local grey = readValue(buffer, bps)
		R, G, B, A = grey, grey, grey, 255
	elseif colorType == 2 then
		-- RGB
		R = readValue(buffer, bps)
		G = readValue(buffer, bps)
		B = readValue(buffer, bps)
		A = 255
	elseif colorType == 3 then
		-- Indexed
		local index = readValue(buffer, bps) + 1
		local color = palette.colors[index]
		R, G, B, A = color.R, color.G, color.B, 255
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
	local bps = math.floor(data.IHDR.bitDepth / 8) -- bytes per sample
	local hasAlpha = (colorType == COLOR_TYPE_GRAYSCALE_ALPHA or colorType == COLOR_TYPE_RGBA)
	-- Create output buffer for RGBA pixels (4 bytes per pixel)
	local outputSize = width * height * 4
	local outputData = ffi.new("uint8_t[?]", outputSize)
	local outputBuffer = Buffer.New(outputData, outputSize)
	local out = outputBuffer.Buffer
	-- Previous row buffer for filtering (stores RGBA values, 4 bytes per pixel)
	local prevRow = ffi.new("uint8_t[?]", width * 4)
	local currRow = ffi.new("uint8_t[?]", width * 4)

	for y = 1, height do
		local filterType = buffer:ReadByte()

		for x = 1, width do
			local R, G, B, A = readPixel(buffer, bps, colorType, data.PLTE)
			local idx = (x - 1) * 4

			if filterType == FILTER_NONE then
				-- No filter
				currRow[idx] = R
				currRow[idx + 1] = G
				currRow[idx + 2] = B
				currRow[idx + 3] = A
			elseif filterType == FILTER_SUB then
				-- Sub: add left pixel
				local leftR = x > 1 and currRow[idx - 4] or 0
				local leftG = x > 1 and currRow[idx - 3] or 0
				local leftB = x > 1 and currRow[idx - 2] or 0
				local leftA = x > 1 and currRow[idx - 1] or 0
				currRow[idx] = bit_band(R + leftR, 255)
				currRow[idx + 1] = bit_band(G + leftG, 255)
				currRow[idx + 2] = bit_band(B + leftB, 255)
				currRow[idx + 3] = hasAlpha and bit_band(A + leftA, 255) or A
			elseif filterType == FILTER_UP then
				-- Up: add pixel above
				currRow[idx] = bit_band(R + prevRow[idx], 255)
				currRow[idx + 1] = bit_band(G + prevRow[idx + 1], 255)
				currRow[idx + 2] = bit_band(B + prevRow[idx + 2], 255)
				currRow[idx + 3] = hasAlpha and bit_band(A + prevRow[idx + 3], 255) or A
			elseif filterType == FILTER_AVERAGE then
				-- Average: add average of left and above
				local leftR = x > 1 and currRow[idx - 4] or 0
				local leftG = x > 1 and currRow[idx - 3] or 0
				local leftB = x > 1 and currRow[idx - 2] or 0
				local leftA = x > 1 and currRow[idx - 1] or 0
				local floor = math.floor
				currRow[idx] = bit_band(R + floor((leftR + prevRow[idx]) / 2), 255)
				currRow[idx + 1] = bit_band(G + floor((leftG + prevRow[idx + 1]) / 2), 255)
				currRow[idx + 2] = bit_band(B + floor((leftB + prevRow[idx + 2]) / 2), 255)
				currRow[idx + 3] = hasAlpha and bit_band(A + floor((leftA + prevRow[idx + 3]) / 2), 255) or A
			elseif filterType == FILTER_PAETH then
				-- Paeth predictor
				local leftR = x > 1 and currRow[idx - 4] or 0
				local leftG = x > 1 and currRow[idx - 3] or 0
				local leftB = x > 1 and currRow[idx - 2] or 0
				local leftA = x > 1 and currRow[idx - 1] or 0
				local upR = prevRow[idx]
				local upG = prevRow[idx + 1]
				local upB = prevRow[idx + 2]
				local upA = prevRow[idx + 3]
				local upLeftR = x > 1 and prevRow[idx - 4] or 0
				local upLeftG = x > 1 and prevRow[idx - 3] or 0
				local upLeftB = x > 1 and prevRow[idx - 2] or 0
				local upLeftA = x > 1 and prevRow[idx - 1] or 0
				currRow[idx] = bit_band(R + paethPredict(leftR, upR, upLeftR), 255)
				currRow[idx + 1] = bit_band(G + paethPredict(leftG, upG, upLeftG), 255)
				currRow[idx + 2] = bit_band(B + paethPredict(leftB, upB, upLeftB), 255)
				currRow[idx + 3] = hasAlpha and bit_band(A + paethPredict(leftA, upA, upLeftA), 255) or A
			else
				error("Unsupported filter type: " .. tostring(filterType))
			end
		end

		if FLIP_Y then
			-- Optimized write row to output buffer (flipped vertically for Vulkan)
			local outY = height - y
			local outRowStart = outY * width * 4
			ffi.copy(out + outRowStart, currRow, width * 4)
		else
			-- Optimized write row to output buffer (normal order)
			local outRowStart = (y - 1) * width * 4
			ffi.copy(out + outRowStart, currRow, width * 4)
		end

		-- Swap buffers for next iteration
		prevRow, currRow = currRow, prevRow
	end

	return outputBuffer
end

local function pngImage(inputBuffer)
	if inputBuffer:ReadBytes(8) ~= "\137\080\078\071\013\010\026\010" then
		error("Not a png")
	end

	local data = extractChunkData(inputBuffer)
	return {
		width = data.IHDR.width,
		height = data.IHDR.height,
		depth = data.IHDR.bitDepth,
		colorType = data.IHDR.colorType,
		buffer = getPixels(deflate.inflate_zlib({
			input = data.IDAT.data,
			disable_crc = true,
		}), data),
	}
end

return pngImage
