-- The MIT License (MIT)
-- Copyright (c) 2013 DelusionalLogic
-- Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
-- the Software, and to permit persons to whom the Software is furnished to do so,
-- subject to the following conditions:
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
-- FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
-- COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
-- IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
-- CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
local Buffer = require("helpers.buffer")
local deflate = require("helpers.png.deflatelua")
local requiredDeflateVersion = "0.3.20111128"

if (deflate._VERSION ~= requiredDeflateVersion) then
	error(
		"Incorrect deflate version: must be " .. requiredDeflateVersion .. ", not " .. deflate._VERSION
	)
end

local function getDataIHDR(buffer, length)
	local data = {}
	data["width"] = buffer:ReadU32BE()
	data["height"] = buffer:ReadU32BE()
	data["bitDepth"] = buffer:ReadByte()
	data["colorType"] = buffer:ReadByte()
	data["compression"] = buffer:ReadByte()
	data["filter"] = buffer:ReadByte()
	data["interlace"] = buffer:ReadByte()
	return data
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

local function makePixel(buffer, depth, colorType, palette)
	local bps = math.floor(depth / 8) --bits per sample
	local pixelData = {R = 0, G = 0, B = 0, A = 0}
	local grey
	local index
	local color

	-- Helper function to read value based on bytes per sample
	local function readValue()
		if bps == 1 then
			return buffer:ReadByte()
		elseif bps == 2 then
			return buffer:ReadU16BE()
		else
			error("Unsupported bit depth: " .. (bps * 8))
		end
	end

	if colorType == 0 then
		grey = readValue()
		pixelData.R = grey
		pixelData.G = grey
		pixelData.B = grey
		pixelData.A = 255
	elseif colorType == 2 then
		pixelData.R = readValue()
		pixelData.G = readValue()
		pixelData.B = readValue()
		pixelData.A = 255
	elseif colorType == 3 then
		index = readValue() + 1
		color = palette.colors[index]
		pixelData.R = color.R
		pixelData.G = color.G
		pixelData.B = color.B
		pixelData.A = 255
	elseif colorType == 4 then
		grey = readValue()
		pixelData.R = grey
		pixelData.G = grey
		pixelData.B = grey
		pixelData.A = readValue()
	elseif colorType == 6 then
		pixelData.R = readValue()
		pixelData.G = readValue()
		pixelData.B = readValue()
		pixelData.A = readValue()
	end

	return pixelData
end

local function bitFromColorType(colorType)
	if colorType == 0 then return 1 end

	if colorType == 2 then return 3 end

	if colorType == 3 then return 1 end

	if colorType == 4 then return 2 end

	if colorType == 6 then return 4 end

	error("Invalid colortype")
end

-- Get the list of fields that should be filtered based on color type
local function getFilteredFields(colorType)
	if colorType == 0 then
		-- Grayscale
		return {"R", "G", "B"} -- R=G=B for grayscale, but we still filter all three
	elseif colorType == 2 then
		-- RGB (no alpha in PNG data)
		return {"R", "G", "B"}
	elseif colorType == 3 then
		-- Indexed (palette)
		return {"R", "G", "B"}
	elseif colorType == 4 then
		-- Grayscale + Alpha
		return {"R", "G", "B", "A"}
	elseif colorType == 6 then
		-- RGBA
		return {"R", "G", "B", "A"}
	end

	error("Invalid colortype")
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

local function filterType1(curPixel, lastPixel)
	local lastByte
	local newPixel = {}

	for fieldName, curByte in pairs(curPixel) do
		lastByte = lastPixel and lastPixel[fieldName] or 0
		newPixel[fieldName] = (curByte + lastByte) % 256
	end

	return newPixel
end

local prevPixelRow = {}

local function getPixelRow(buffer, depth, colorType, palette, length)
	local pixelRow = {}
	local bpp = math.floor(depth / 8) * bitFromColorType(colorType)
	local bpl = bpp * length
	local filterType = buffer:ReadByte()
	local filteredFields = getFilteredFields(colorType)

	if filterType == 0 then
		for x = 1, length do
			pixelRow[x] = makePixel(buffer, depth, colorType, palette)
		end
	elseif filterType == 1 then
		-- Sub: add left pixel
		local curPixel
		local lastPixel
		local newPixel
		local lastByte

		for x = 1, length do
			curPixel = makePixel(buffer, depth, colorType, palette)
			lastPixel = pixelRow[x - 1]
			newPixel = {A = curPixel.A} -- Preserve alpha (255 for RGB images)
			for _, fieldName in ipairs(filteredFields) do
				local curByte = curPixel[fieldName]
				lastByte = lastPixel and lastPixel[fieldName] or 0
				newPixel[fieldName] = (curByte + lastByte) % 256
			end

			pixelRow[x] = newPixel
		end
	elseif filterType == 2 then
		-- Up: add pixel above
		for x = 1, length do
			local curPixel = makePixel(buffer, depth, colorType, palette)
			local abovePixel = prevPixelRow[x]
			newPixel = {A = curPixel.A} -- Preserve alpha (255 for RGB images)
			for _, fieldName in ipairs(filteredFields) do
				local curByte = curPixel[fieldName]
				local aboveByte = abovePixel and abovePixel[fieldName] or 0
				newPixel[fieldName] = (curByte + aboveByte) % 256
			end

			pixelRow[x] = newPixel
		end
	elseif filterType == 3 then
		-- Average: add average of left and above pixels
		for x = 1, length do
			local curPixel = makePixel(buffer, depth, colorType, palette)
			local lastPixel = pixelRow[x - 1]
			local abovePixel = prevPixelRow[x]
			newPixel = {A = curPixel.A} -- Preserve alpha (255 for RGB images)
			for _, fieldName in ipairs(filteredFields) do
				local curByte = curPixel[fieldName]
				local lastByte = lastPixel and lastPixel[fieldName] or 0
				local aboveByte = abovePixel and abovePixel[fieldName] or 0
				local avgByte = math.floor((lastByte + aboveByte) / 2)
				newPixel[fieldName] = (curByte + avgByte) % 256
			end

			pixelRow[x] = newPixel
		end
	elseif filterType == 4 then
		-- Paeth: use Paeth predictor
		for x = 1, length do
			local curPixel = makePixel(buffer, depth, colorType, palette)
			local lastPixel = pixelRow[x - 1]
			local abovePixel = prevPixelRow[x]
			local upperLeftPixel = prevPixelRow[x - 1]
			newPixel = {A = curPixel.A} -- Preserve alpha (255 for RGB images)
			for _, fieldName in ipairs(filteredFields) do
				local curByte = curPixel[fieldName]
				local lastByte = lastPixel and lastPixel[fieldName] or 0
				local aboveByte = abovePixel and abovePixel[fieldName] or 0
				local upperLeftByte = upperLeftPixel and upperLeftPixel[fieldName] or 0
				local paethByte = paethPredict(lastByte, aboveByte, upperLeftByte)
				newPixel[fieldName] = (curByte + paethByte) % 256
			end

			pixelRow[x] = newPixel
		end
	else
		error("Unsupported filter type: " .. tostring(filterType))
	end

	prevPixelRow = pixelRow
	return pixelRow
end

local ffi = require("ffi")

local function pngImage(inputBuffer, progCallback, verbose)
	local chunkData
	local width = 0
	local height = 0
	local depth = 0
	local colorType = 0

	local function printV(msg)
		if (verbose) then print(msg) end
	end

	if inputBuffer:ReadBytes(8) ~= "\137\080\078\071\013\010\026\010" then
		error("Not a png")
	end

	local ok, chunks = pcall(extractChunkData, inputBuffer)

	if not ok then
		print("Chunk extraction failed: " .. tostring(chunks))
		error(chunks)
	end

	chunkData = chunks
	width = chunkData.IHDR.width
	height = chunkData.IHDR.height
	depth = chunkData.IHDR.bitDepth
	colorType = chunkData.IHDR.colorType
	local success, result = pcall(function()
		return deflate.inflate_zlib({
			input = chunkData.IDAT.data,
			disable_crc = true,
		})
	end)

	if not success then
		printV("Decompression failed: " .. tostring(result))
		error(result)
	end

	local pixelDataBuffer = result
	pixelDataBuffer:SetPosition(0)
	printV("Decompressed buffer size: " .. pixelDataBuffer:GetSize())
	printV("Creating pixelmap...")
	-- Create output buffer for RGBA pixels (4 bytes per pixel)
	local outputSize = width * height * 4
	local outputData = ffi.new("uint8_t[?]", outputSize)
	local outputBuffer = Buffer.New(outputData, outputSize)
	local outputPos = 0

	for y = 1, height do
		local pixelRow = getPixelRow(pixelDataBuffer, depth, colorType, chunkData.PLTE, width)

		if progCallback ~= nil then progCallback(y, height, pixelRow) end

		-- Write pixel row to output buffer
		for x = 1, width do
			local pixel = pixelRow[x]
			outputBuffer.Buffer[outputPos] = pixel.R
			outputBuffer.Buffer[outputPos + 1] = pixel.G
			outputBuffer.Buffer[outputPos + 2] = pixel.B
			outputBuffer.Buffer[outputPos + 3] = pixel.A
			outputPos = outputPos + 4
		end
	end

	printV("Done.")
	return {
		width = width,
		height = height,
		depth = depth,
		colorType = colorType,
		buffer = outputBuffer,
	}
end

return pngImage
