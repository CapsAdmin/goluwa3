-- initially based on https://github.com/DelusionalLogic/pngLua
local ffi = require("ffi")
local bit_band = require("bit").band
local bit_rshift = require("bit").rshift
local Buffer = import("goluwa/structs/buffer.lua")
local deflate = import("goluwa/codecs/deflate.lua")
local math_ceil = math.ceil
local math_floor = math.floor
local table_concat = table.concat
local png = library()
png.file_extensions = {"png"}
png.magic_headers = {"\137PNG\r\n\26\n"}

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
	local data = oldData or {parts = {}, total_length = 0}
	data.total_length = data.total_length + length
	data.parts[#data.parts + 1] = buffer:ReadBytes(length)
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

local function getDataTRNS(buffer, length, ihdr)
	if not ihdr then
		buffer:ReadBytes(length)
		return nil
	end

	if ihdr.colorType == 3 then
		local data = {palette_alpha = {}}

		for i = 1, length do
			data.palette_alpha[i] = buffer:ReadByte()
		end

		return data
	elseif ihdr.colorType == 0 then
		return {gray = buffer:ReadU16BE()}
	elseif ihdr.colorType == 2 then
		return {
			r = buffer:ReadU16BE(),
			g = buffer:ReadU16BE(),
			b = buffer:ReadU16BE(),
		}
	end

	buffer:ReadBytes(length)
	return nil
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
		elseif (type == "tRNS") then
			chunkData[type] = getDataTRNS(buffer, length, chunkData.IHDR)
		else
			buffer:ReadBytes(length)
		end

		crc = buffer:ReadBytes(4)
	end

	local idat = chunkData.IDAT

	if idat and idat.parts then
		idat.data = #idat.parts == 1 and idat.parts[1] or table_concat(idat.parts)
		idat.parts = nil
		idat.total_length = nil
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

local function get_packed_sample(row, x, bitDepth)
	local bitOffset = x * bitDepth
	local byteIndex = math_floor(bitOffset / 8)
	local bitIndex = bitOffset % 8
	local shift = 8 - bitDepth - bitIndex
	local mask = 2 ^ bitDepth - 1
	return bit_band(bit_rshift(row[byteIndex], shift), mask)
end

-- Optimized getPixels that writes directly to output buffer
-- Returns the output buffer with RGBA pixels, flipped vertically for Vulkan
local function getPixels(buffer, data)
	local colorType = data.IHDR.colorType
	local width = data.IHDR.width
	local height = data.IHDR.height
	local bitDepth = data.IHDR.bitDepth
	local src = buffer.Buffer
	local src_pos = buffer.Position
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
	local bitsPerInputPixel = samplesPerPixel * bitDepth
	local bytesPerInputPixel = math.max(1, math_ceil(bitsPerInputPixel / 8))
	-- Create output buffer for RGBA pixels
	local outputSize = width * height * bytesPerPixel
	local outputData = is16bit and
		ffi.new("uint16_t[?]", width * height * 4) or
		ffi.new("uint8_t[?]", outputSize)
	local out = outputData
	-- Previous and current row buffers store RAW BYTES (not reconstructed values)
	-- For PNG filtering, we work with bytes regardless of bit depth
	local rowBytes = math_ceil(width * bitsPerInputPixel / 8)
	local prevRow = ffi.new("uint8_t[?]", rowBytes)
	local currRow = ffi.new("uint8_t[?]", rowBytes)
	-- Maximum value for alpha channel (255 for 8-bit, 65535 for 16-bit)
	local maxAlpha = is16bit and 65535 or 255
	local packedSamples = bitDepth < 8
	local packedScale = packedSamples and math.floor(255 / (2 ^ bitDepth - 1)) or 1
	local transparency = data.tRNS
	local transparency_gray = transparency and transparency.gray
	local has_gray_transparency = transparency_gray ~= nil
	local transparency_r = transparency and transparency.r
	local transparency_g = transparency and transparency.g
	local transparency_b = transparency and transparency.b
	local has_rgb_transparency = transparency_r ~= nil
	local palette = data.PLTE and data.PLTE.colors
	local palette_alpha = transparency and transparency.palette_alpha

	for y = 1, height do
		local filterType = src[src_pos]
		src_pos = src_pos + 1

		if filterType == FILTER_NONE then
			for i = 0, rowBytes - 1 do
				currRow[i] = src[src_pos + i]
			end
		elseif filterType == FILTER_SUB then
			for i = 0, rowBytes - 1 do
				local left = i >= bytesPerInputPixel and currRow[i - bytesPerInputPixel] or 0
				currRow[i] = bit_band(src[src_pos + i] + left, 0xFF)
			end
		elseif filterType == FILTER_UP then
			for i = 0, rowBytes - 1 do
				currRow[i] = bit_band(src[src_pos + i] + prevRow[i], 0xFF)
			end
		elseif filterType == FILTER_AVERAGE then
			for i = 0, rowBytes - 1 do
				local left = i >= bytesPerInputPixel and currRow[i - bytesPerInputPixel] or 0
				local up = prevRow[i]
				currRow[i] = bit_band(src[src_pos + i] + bit_rshift(left + up, 1), 0xFF)
			end
		elseif filterType == FILTER_PAETH then
			for i = 0, rowBytes - 1 do
				local left = i >= bytesPerInputPixel and currRow[i - bytesPerInputPixel] or 0
				local up = prevRow[i]
				local upLeft = i >= bytesPerInputPixel and prevRow[i - bytesPerInputPixel] or 0
				currRow[i] = bit_band(src[src_pos + i] + paethPredict(left, up, upLeft), 0xFF)
			end
		else
			error("Unsupported filter type: " .. tostring(filterType))
		end

		src_pos = src_pos + rowBytes
		-- Now convert the reconstructed bytes to output format (RGBA)
		local outIdx = (height - y) * width * 4

		if is16bit then
			if colorType == COLOR_TYPE_RGB then
				local inIdx = 0

				for _ = 1, width do
					local R = currRow[inIdx] * 256 + currRow[inIdx + 1]
					local G = currRow[inIdx + 2] * 256 + currRow[inIdx + 3]
					local B = currRow[inIdx + 4] * 256 + currRow[inIdx + 5]
					out[outIdx + 0] = R
					out[outIdx + 1] = G
					out[outIdx + 2] = B
					out[outIdx + 3] = has_rgb_transparency and
						R == transparency_r and
						G == transparency_g and
						B == transparency_b and
						0 or
						maxAlpha
					inIdx = inIdx + 6
					outIdx = outIdx + 4
				end
			elseif colorType == COLOR_TYPE_RGBA then
				local inIdx = 0

				for _ = 1, width do
					out[outIdx + 0] = currRow[inIdx] * 256 + currRow[inIdx + 1]
					out[outIdx + 1] = currRow[inIdx + 2] * 256 + currRow[inIdx + 3]
					out[outIdx + 2] = currRow[inIdx + 4] * 256 + currRow[inIdx + 5]
					out[outIdx + 3] = currRow[inIdx + 6] * 256 + currRow[inIdx + 7]
					inIdx = inIdx + 8
					outIdx = outIdx + 4
				end
			elseif colorType == COLOR_TYPE_GRAYSCALE then
				local inIdx = 0

				for _ = 1, width do
					local grey = currRow[inIdx] * 256 + currRow[inIdx + 1]
					out[outIdx + 0] = grey
					out[outIdx + 1] = grey
					out[outIdx + 2] = grey
					out[outIdx + 3] = has_gray_transparency and transparency_gray == grey and 0 or maxAlpha
					inIdx = inIdx + 2
					outIdx = outIdx + 4
				end
			elseif colorType == COLOR_TYPE_GRAYSCALE_ALPHA then
				local inIdx = 0

				for _ = 1, width do
					local grey = currRow[inIdx] * 256 + currRow[inIdx + 1]
					out[outIdx + 0] = grey
					out[outIdx + 1] = grey
					out[outIdx + 2] = grey
					out[outIdx + 3] = currRow[inIdx + 2] * 256 + currRow[inIdx + 3]
					inIdx = inIdx + 4
					outIdx = outIdx + 4
				end
			end
		else
			if packedSamples and colorType == COLOR_TYPE_GRAYSCALE then
				for x = 0, width - 1 do
					local sample = get_packed_sample(currRow, x, bitDepth)
					local grey = sample * packedScale
					out[outIdx + 0] = grey
					out[outIdx + 1] = grey
					out[outIdx + 2] = grey
					out[outIdx + 3] = has_gray_transparency and transparency_gray == sample and 0 or 255
					outIdx = outIdx + 4
				end
			elseif packedSamples and colorType == COLOR_TYPE_INDEXED then
				for x = 0, width - 1 do
					local index = get_packed_sample(currRow, x, bitDepth) + 1
					local color = palette and palette[index]

					if color then
						out[outIdx + 0] = color.R
						out[outIdx + 1] = color.G
						out[outIdx + 2] = color.B
						out[outIdx + 3] = palette_alpha and palette_alpha[index] or 255
					else
						out[outIdx + 0] = 255
						out[outIdx + 1] = 0
						out[outIdx + 2] = 255
						out[outIdx + 3] = 255
					end

					outIdx = outIdx + 4
				end
			elseif colorType == COLOR_TYPE_RGB then
				local inIdx = 0

				for _ = 1, width do
					local R = currRow[inIdx]
					local G = currRow[inIdx + 1]
					local B = currRow[inIdx + 2]
					out[outIdx + 0] = R
					out[outIdx + 1] = G
					out[outIdx + 2] = B
					out[outIdx + 3] = has_rgb_transparency and
						R == transparency_r and
						G == transparency_g and
						B == transparency_b and
						0 or
						255
					inIdx = inIdx + 3
					outIdx = outIdx + 4
				end
			elseif colorType == COLOR_TYPE_RGBA then
				local inIdx = 0

				for _ = 1, width do
					out[outIdx + 0] = currRow[inIdx]
					out[outIdx + 1] = currRow[inIdx + 1]
					out[outIdx + 2] = currRow[inIdx + 2]
					out[outIdx + 3] = currRow[inIdx + 3]
					inIdx = inIdx + 4
					outIdx = outIdx + 4
				end
			elseif colorType == COLOR_TYPE_GRAYSCALE then
				local inIdx = 0

				for _ = 1, width do
					local grey = currRow[inIdx]
					out[outIdx + 0] = grey
					out[outIdx + 1] = grey
					out[outIdx + 2] = grey
					out[outIdx + 3] = has_gray_transparency and transparency_gray == grey and 0 or 255
					inIdx = inIdx + 1
					outIdx = outIdx + 4
				end
			elseif colorType == COLOR_TYPE_GRAYSCALE_ALPHA then
				local inIdx = 0

				for _ = 1, width do
					local grey = currRow[inIdx]
					out[outIdx + 0] = grey
					out[outIdx + 1] = grey
					out[outIdx + 2] = grey
					out[outIdx + 3] = currRow[inIdx + 1]
					inIdx = inIdx + 2
					outIdx = outIdx + 4
				end
			elseif colorType == COLOR_TYPE_INDEXED then
				local inIdx = 0

				for _ = 1, width do
					local index = currRow[inIdx] + 1
					local color = palette and palette[index]

					if color then
						out[outIdx + 0] = color.R
						out[outIdx + 1] = color.G
						out[outIdx + 2] = color.B
						out[outIdx + 3] = palette_alpha and palette_alpha[index] or 255
					else
						out[outIdx + 0] = 255
						out[outIdx + 1] = 0
						out[outIdx + 2] = 255
						out[outIdx + 3] = 255
					end

					inIdx = inIdx + 1
					outIdx = outIdx + 4
				end
			else
				for _ = 1, width do
					out[outIdx + 0] = 255
					out[outIdx + 1] = 0
					out[outIdx + 2] = 255
					out[outIdx + 3] = 255
					outIdx = outIdx + 4
				end
			end
		end

		-- Swap buffers for next iteration
		prevRow, currRow = currRow, prevRow
	end

	buffer.Position = src_pos
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
	local pixelData, pixelSize = getPixels(deflate.inflate_zlib{
		input = data.IDAT.data,
		disable_crc = true,
	}, data)
	local decodedBuffer = Buffer.New(pixelData, pixelSize)
	return {
		width = data.IHDR.width,
		height = data.IHDR.height,
		depth = bitDepth,
		colorType = colorType,
		vulkan_format = vulkan_format,
		-- Provide both data (raw buffer pointer) and buffer (Buffer wrapper)
		data = decodedBuffer.Buffer,
		buffer = decodedBuffer,
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

	self.crc = crc
end

---Finalizes the CRC, returning the result
function Png:finalizeCrc()
	return bnot(self.crc)
end

---Updates the Adler32
---@param data userdata|table The data to update the Adler32 with
---@param index number|nil The index of the first byte to update
---@param len number|nil The number of bytes to update
function Png:adler32(data, index, len)
	local s1 = ffi.new("uint64_t", band(self.adler, 0xFFFF))
	local s2 = ffi.new("uint64_t", rshift(self.adler, 16))

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
						data[i + 1] * 1 + data[i + 2] * 2 + data[i + 3] * 3 + data[i + 4] * 4 + data[i + 5] * 5 + data[i + 6] * 6 + data[i + 7] * 7
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

	self.adler = tonumber(bor(lshift(tonumber(s1 == 0 and 0 or s2), 16), tonumber(s1)))
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
