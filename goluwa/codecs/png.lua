-- initially based on https://github.com/DelusionalLogic/pngLua
local ffi = require("ffi")
local bit_band = require("bit").band
local Buffer = require("structs.buffer")
local deflate = require("codecs.deflate")
local png = library()
png.file_extensions = {"png"}

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

function png.DecodeBuffer(inputBuffer)
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

--ffipng.lua
local bit = require("bit")
local Png = {}
Png.__index = Png
local DEFLATE_MAX_BLOCK_SIZE = 65535
local WRITE_BUFFER_SIZE = 32768
local band, bxor, rshift, lshift, bnot, bor = bit.band, bit.bxor, bit.rshift, bit.lshift, bit.bnot, bit.bor
local min, ceil = math.min, math.ceil
local ffi_cast = ffi.cast
local crc_table = ffi.new("uint32_t[256]")

for i = 0, 255 do
	local c = i

	for j = 0, 7 do
		if band(c, 1) == 1 then
			c = bxor(rshift(c, 1), 0xEDB88320)
		else
			c = rshift(c, 1)
		end
	end

	crc_table[i] = c
end

local function putBigUint32(val, buf, offset)
	buf[offset] = band(rshift(val, 24), 0xFF)
	buf[offset + 1] = band(rshift(val, 16), 0xFF)
	buf[offset + 2] = band(rshift(val, 8), 0xFF)
	buf[offset + 3] = band(val, 0xFF)
end

---Writes bytes to the output buffer
---@param data userdata|table The data to write
---@param index number|nil The index of the first byte to write
---@param len number|nil The number of bytes to write
function Png:writeBytes(data, index, len)
	index = index or 1
	len = len or #data
	local output = self.output
	local buffer = self.write_buffer
	local buffer_pos = self.buffer_pos

	if type(data) == "table" then
		local end_idx = index + len - 1
		local i = index

		while i <= end_idx do
			local available_buffer = WRITE_BUFFER_SIZE - buffer_pos
			local chunk_size = min(available_buffer, end_idx - i + 1)

			for j = 0, chunk_size - 1 do
				buffer[buffer_pos + j] = data[i + j]
			end

			buffer_pos = buffer_pos + chunk_size
			i = i + chunk_size

			if buffer_pos >= WRITE_BUFFER_SIZE or i > end_idx then
				output[#output + 1] = ffi.string(buffer, buffer_pos)
				buffer_pos = 0
			end
		end
	else
		output[#output + 1] = ffi.string(ffi_cast("uint8_t*", data) + index - 1, len)
	end

	self.buffer_pos = buffer_pos
end

---Initializes the CRC
function Png:initCrc()
	self.crc = 0xFFFFFFFF
end

---Updates the CRC
---@param data userdata|table The data to update the CRC with
---@param index number|nil The index of the first byte to update
---@param len number|nil The number of bytes to update
function Png:crc32(data, index, len)
	local crc = self.crc

	if type(data) == "table" then
		local end_idx = index + len - 1
		local i = index

		while i <= end_idx - 15 do
			for j = 0, 15 do
				crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, data[i + j]), 0xFF)])
			end

			i = i + 16
		end

		while i <= end_idx do
			crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, data[i]), 0xFF)])
			i = i + 1
		end
	else
		local ptr = ffi_cast("uint8_t*", data) + index - 1

		for i = 0, len - 1 do
			crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, ptr[i]), 0xFF)])
		end
	end

	self.crc = bnot(crc)
end

---Finalizes the CRC, returning the result
function Png:finalizeCrc()
	return self.crc
end

---Updates the Adler32
---@param data userdata|table The data to update the Adler32 with
---@param index number|nil The index of the first byte to update
---@param len number|nil The number of bytes to update
function Png:adler32(data, index, len)
	local s1 = band(self.adler, 0xFFFF)
	local s2 = rshift(self.adler, 16)

	if type(data) == "table" then
		local pos = index
		local remaining = len

		while remaining > 0 do
			local current_chunk = min(5552, remaining)
			local end_pos = pos + current_chunk - 1
			local i = pos

			while i <= end_pos - 7 do
				local sum = data[i] + data[i + 1] + data[i + 2] + data[i + 3] + data[i + 4] + data[i + 5] + data[i + 6] + data[i + 7]
				s1 = s1 + sum
				s2 = s2 + s1 * 8 - (
						data[i] * 7 + data[i + 1] * 6 + data[i + 2] * 5 + data[i + 3] * 4 + data[i + 4] * 3 + data[i + 5] * 2 + data[i + 6]
					)
				i = i + 8
			end

			while i <= end_pos do
				s1 = s1 + data[i]
				s2 = s2 + s1
				i = i + 1
			end

			s1 = s1 % 65521
			s2 = s2 % 65521
			pos = end_pos + 1
			remaining = remaining - current_chunk
		end
	else
		local ptr = ffi_cast("uint8_t*", data) + index - 1

		for i = 0, len - 1 do
			s1 = (s1 + ptr[i]) % 65521
			s2 = (s2 + s1) % 65521
		end
	end

	self.adler = bor(lshift(s2, 16), s1)
end

---Writes pixels to the PNG file
---@param pixels table The pixels to write
function Png:write(pixels)
	local count = #pixels
	local pixelPointer = 1
	local lineSize = self.lineSize
	local uncompRemain = self.uncompRemain
	local deflateFilled = self.deflateFilled
	local positionX = self.positionX
	local positionY = self.positionY
	local height = self.height
	local filterByte = self.filterByte or {0}
	local header = self.header_buffer or {}
	self.filterByte = filterByte
	self.header_buffer = header

	while count > 0 and not self.done do
		if deflateFilled == 0 then
			local size = min(DEFLATE_MAX_BLOCK_SIZE, uncompRemain)
			local isLast = (uncompRemain <= DEFLATE_MAX_BLOCK_SIZE) and 1 or 0
			header[1] = band(isLast, 0xFF)
			header[2] = band(size, 0xFF)
			header[3] = band(rshift(size, 8), 0xFF)
			header[4] = band(bxor(size, 0xFFFF), 0xFF)
			header[5] = band(rshift(bxor(size, 0xFFFF), 8), 0xFF)
			self:writeBytes(header, 1, 5)
			self:crc32(header, 1, 5)
		end

		if positionX == 0 then
			self:writeBytes(filterByte)
			self:crc32(filterByte, 1, 1)
			self:adler32(filterByte, 1, 1)
			positionX = 1
			uncompRemain = uncompRemain - 1
			deflateFilled = deflateFilled + 1
		else
			local n = min(DEFLATE_MAX_BLOCK_SIZE - deflateFilled, lineSize - positionX, count)
			self:writeBytes(pixels, pixelPointer, n)
			self:crc32(pixels, pixelPointer, n)
			self:adler32(pixels, pixelPointer, n)
			count = count - n
			pixelPointer = pixelPointer + n
			positionX = positionX + n
			uncompRemain = uncompRemain - n
			deflateFilled = deflateFilled + n
		end

		if deflateFilled >= DEFLATE_MAX_BLOCK_SIZE then deflateFilled = 0 end

		if positionX == lineSize then
			positionX = 0
			positionY = positionY + 1

			if positionY == height then
				if self.buffer_pos > 0 then
					local output = self.output
					output[#output + 1] = ffi.string(self.write_buffer, self.buffer_pos)
				end

				local footer = self.footer_buffer or {}
				putBigUint32(self.adler, footer, 1)
				self:crc32(footer, 1, 4)
				local final_crc = self:finalizeCrc()
				putBigUint32(final_crc, footer, 5)
				footer[9] = 0x00
				footer[10] = 0x00
				footer[11] = 0x00
				footer[12] = 0x00
				footer[13] = 0x49
				footer[14] = 0x45
				footer[15] = 0x4E
				footer[16] = 0x44
				footer[17] = 0xAE
				footer[18] = 0x42
				footer[19] = 0x60
				footer[20] = 0x82
				self:writeBytes(footer, 1, 8)
				self:writeBytes(footer, 9, 12)
				self.footer_buffer = footer
				self.done = true

				break
			end
		end
	end

	self.uncompRemain = uncompRemain
	self.deflateFilled = deflateFilled
	self.positionX = positionX
	self.positionY = positionY
end

local PNG_SIGNATURE = ffi.new("uint8_t[8]", {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A})
local IHDR_TYPE = ffi.new("uint8_t[4]", {0x49, 0x48, 0x44, 0x52})
local IDAT_TYPE = ffi.new("uint8_t[4]", {0x49, 0x44, 0x41, 0x54})
local DEFLATE_HEADER = ffi.new("uint8_t[2]", {0x08, 0x1D})

local function begin(width, height, colorMode)
	colorMode = colorMode or "rgb"
	local bytesPerPixel, colorType

	if colorMode == "rgb" then
		bytesPerPixel, colorType = 3, 2
	elseif colorMode == "rgba" then
		bytesPerPixel, colorType = 4, 6
	else
		error("Invalid colorMode: " .. tostring(colorMode))
	end

	local state = setmetatable(
		{
			width = width,
			height = height,
			done = false,
			output = {},
			lineSize = width * bytesPerPixel + 1,
			positionX = 0,
			positionY = 0,
			deflateFilled = 0,
			crc = 0,
			adler = 1,
			write_buffer = ffi.new("uint8_t[?]", WRITE_BUFFER_SIZE),
			buffer_pos = 0,
		},
		Png
	)
	state.uncompRemain = state.lineSize * height
	local numBlocks = ceil(state.uncompRemain / DEFLATE_MAX_BLOCK_SIZE)
	local idatSize = numBlocks * 5 + 6 + state.uncompRemain
	local header = {}
	local idx = 1

	for i = 0, 7 do
		header[idx] = PNG_SIGNATURE[i]
		idx = idx + 1
	end

	putBigUint32(13, header, idx)
	idx = idx + 4

	for i = 0, 3 do
		header[idx] = IHDR_TYPE[i]
		idx = idx + 1
	end

	putBigUint32(width, header, idx)
	idx = idx + 4
	putBigUint32(height, header, idx)
	idx = idx + 4
	header[idx] = 8
	header[idx + 1] = colorType
	header[idx + 2] = 0
	header[idx + 3] = 0
	header[idx + 4] = 0
	idx = idx + 5
	state:initCrc()
	state:crc32(header, 13, 17)
	local ihdr_crc = state:finalizeCrc()
	putBigUint32(ihdr_crc, header, idx)
	idx = idx + 4
	putBigUint32(idatSize, header, idx)
	idx = idx + 4

	for i = 0, 3 do
		header[idx] = IDAT_TYPE[i]
		idx = idx + 1
	end

	header[idx] = DEFLATE_HEADER[0]
	header[idx + 1] = DEFLATE_HEADER[1]
	state:writeBytes(header)
	state:initCrc()
	state:crc32(header, idx - 4, 6)
	return state
end

---Returns the PNG data to be written to a file
function Png:getData()
	return table.concat(self.output)
end

---Creates a new Png object
---@param width number
---@param height number
---@param colorMode string One of "rgb" or "rgba"
function png.Encode(width, height, colorMode)
	return begin(width, height, colorMode)
end

return png
