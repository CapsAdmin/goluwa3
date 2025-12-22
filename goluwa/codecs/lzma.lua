-- LZMA file decoder
-- Based on LZMA SDK and .lzma file format specification
local ffi = require("ffi")
local bit = require("bit")
local Buffer = require("structs.buffer")
local bit_band = bit.band
local bit_bor = bit.bor
local bit_rshift = bit.rshift
local bit_lshift = bit.lshift
-- LZMA constants
local LZMA_PROPS_SIZE = 5
local LZMA_MAGIC = "\xFD\x37\x7A\x58\x5A\x00" -- XZ magic (for .xz format)
local LZMA_ALONE_MAGIC_SIZE = 13 -- LZMA alone header size
-- Bit reader for LZMA range decoder
local BitReader = {}
BitReader.__index = BitReader

function BitReader.new(buffer)
	local self = setmetatable({}, BitReader)
	self.buffer = buffer
	self.range = 0xFFFFFFFF
	self.code = 0

	-- Initialize range decoder
	for i = 1, 5 do
		self.code = bit_lshift(self.code, 8)

		if buffer:GetPosition() < buffer:GetSize() then
			self.code = bit_bor(self.code, buffer:ReadU8())
		end
	end

	return self
end

function BitReader:normalize()
	if self.range < 0x01000000 then
		self.range = bit_lshift(self.range, 8)
		self.code = bit_lshift(self.code, 8)

		if self.buffer:GetPosition() < self.buffer:GetSize() then
			self.code = bit_bor(self.code, self.buffer:ReadU8())
		end

		-- Keep values in 32-bit range
		self.range = bit_band(self.range, 0xFFFFFFFF)
		self.code = bit_band(self.code, 0xFFFFFFFF)
	end
end

function BitReader:decodeBit(prob_index, probs)
	self:normalize()
	local prob = probs[prob_index] or 1024
	local bound = bit_rshift(self.range, 11) * prob
	bound = bit_band(bound, 0xFFFFFFFF)
	local bit_val

	if self.code < bound then
		self.range = bound
		probs[prob_index] = prob + bit_rshift(2048 - prob, 5)
		bit_val = 0
	else
		self.range = self.range - bound
		self.code = self.code - bound
		probs[prob_index] = prob - bit_rshift(prob, 5)
		bit_val = 1
	end

	self.range = bit_band(self.range, 0xFFFFFFFF)
	self.code = bit_band(self.code, 0xFFFFFFFF)
	return bit_val
end

function BitReader:decodeDirectBits(count)
	local result = 0

	for i = 1, count do
		self:normalize()
		self.range = bit_rshift(self.range, 1)
		self.code = bit_band(self.code, 0xFFFFFFFF)
		local t = bit_rshift(self.code - self.range, 31)
		self.code = self.code - bit_band(self.range, (t - 1))
		result = bit_bor(bit_lshift(result, 1), (1 - t))
		result = bit_band(result, 0xFFFFFFFF)
	end

	return result
end

-- LZMA Decoder
local LZMADecoder = {}
LZMADecoder.__index = LZMADecoder

function LZMADecoder.new(properties)
	local self = setmetatable({}, LZMADecoder)
	-- Parse properties byte
	local d = properties

	if d >= 9 * 5 * 5 then error("Invalid LZMA properties") end

	self.lc = d % 9
	d = math.floor(d / 9)
	self.pb = math.floor(d / 5)
	self.lp = d % 5
	-- Initialize probability arrays
	self.probs = {}

	for i = 0, 1983 do -- Total number of probabilities for LZMA
		self.probs[i] = 1024
	end

	return self
end

function LZMADecoder:decode(bitReader, uncompressedSize)
	-- Create output buffer with initial size using malloc
	local initialSize = math.max(uncompressedSize, 1024)
	local outputBuffer = Buffer.New(nil, initialSize)
	outputBuffer:MakeWritable()
	outputBuffer:SetPosition(0)
	local state = 0
	local rep0, rep1, rep2, rep3 = 1, 1, 1, 1

	local function getPos()
		return outputBuffer:GetPosition()
	end

	local function getByte(distance)
		local pos = outputBuffer:GetPosition()

		if distance > pos then return 0 end

		local savedPos = pos
		outputBuffer:SetPosition(pos - distance)
		local byte = outputBuffer:ReadByte()
		outputBuffer:SetPosition(savedPos)
		return byte
	end

	local function putByte(b)
		outputBuffer:WriteByte(b)
	end

	-- Simplified LZMA decoding (basic implementation)
	while getPos() < uncompressedSize do
		local posState = bit_band(getPos(), (bit_lshift(1, self.pb) - 1))

		-- Decode literal or match
		if bitReader:decodeBit(0, self.probs) == 0 then
			-- Literal
			local prevByte = getByte(1)
			local symbol = 1

			if state >= 7 then
				local matchByte = getByte(rep0)

				while symbol < 256 do
					local matchBit = bit_band(bit_rshift(matchByte, 7), 1)
					matchByte = bit_lshift(matchByte, 1)
					local bit_val = bitReader:decodeBit(symbol, self.probs)
					symbol = bit_bor(bit_lshift(symbol, 1), bit_val)

					if matchBit ~= bit_val then break end
				end
			end

			while symbol < 256 do
				local bit_val = bitReader:decodeBit(symbol, self.probs)
				symbol = bit_bor(bit_lshift(symbol, 1), bit_val)
			end

			local byte = bit_band(symbol, 0xFF)
			putByte(byte)
			state = state < 4 and 0 or (state < 10 and (state - 3) or (state - 6))
		else
			-- Match or rep
			local len

			if bitReader:decodeBit(1, self.probs) == 0 then
				-- Simple match
				rep3 = rep2
				rep2 = rep1
				rep1 = rep0
				len = 2
				state = state < 7 and 7 or 10
				-- Decode distance
				local distance = 0
				local lenState = math.min(len - 2, 3)
				-- Simplified distance decoding
				local distSlot = 0

				for i = 0, 5 do
					distSlot = bit_bor(bit_lshift(distSlot, 1), bitReader:decodeBit(10 + i, self.probs))
				end

				if distSlot < 4 then
					distance = distSlot
				else
					local numDirectBits = bit_rshift(distSlot, 1) - 1
					distance = bit_bor(
						bit_lshift(2 + bit_band(distSlot, 1), numDirectBits),
						bitReader:decodeDirectBits(numDirectBits)
					)
				end

				rep0 = distance + 1
			else
				-- Rep match
				if bitReader:decodeBit(2, self.probs) == 0 then
					len = 1
					state = state < 7 and 9 or 11
				else
					local distance

					if bitReader:decodeBit(3, self.probs) == 0 then
						distance = rep1
					else
						if bitReader:decodeBit(4, self.probs) == 0 then
							distance = rep2
						else
							distance = rep3
							rep3 = rep2
						end

						rep2 = rep1
					end

					rep1 = rep0
					rep0 = distance
					len = 2
					state = state < 7 and 8 or 11
				end
			end

			-- Copy match
			for i = 1, len do
				local byte = getByte(rep0)
				putByte(byte)
			end
		end
	end

	-- Reset buffer position to beginning for reading
	outputBuffer:SetPosition(0)
	return outputBuffer
end

-- Parse LZMA alone format header
local function parseLZMAAloneHeader(buffer)
	local header = {}
	-- Read properties (1 byte)
	header.properties = buffer:ReadU8()
	-- Read dictionary size (4 bytes, little-endian)
	header.dictSize = buffer:ReadU32LE()
	-- Read uncompressed size (8 bytes, little-endian)
	local sizeLow = buffer:ReadU32LE()
	local sizeHigh = buffer:ReadU32LE()

	-- Handle 0xFFFFFFFF_FFFFFFFF as unknown size
	if sizeLow == 0xFFFFFFFF and sizeHigh == 0xFFFFFFFF then
		header.uncompressedSize = nil
	else
		-- For simplicity, assume size fits in 32 bits
		header.uncompressedSize = sizeLow
	end

	return header
end

-- Check if buffer contains XZ format
local function isXZFormat(buffer)
	local savedPos = buffer:GetPosition()
	buffer:SetPosition(0)

	if buffer:GetSize() < 6 then
		buffer:SetPosition(savedPos)
		return false
	end

	local magic = buffer:ReadBytes(6)
	buffer:SetPosition(savedPos)
	return magic == LZMA_MAGIC
end

-- Decompress LZMA data
local function decompressLZMA(buffer)
	-- Save current position
	local savedPos = buffer:GetPosition()
	buffer:SetPosition(0)

	-- Check format
	if isXZFormat(buffer) then
		error("XZ format is not yet supported, only LZMA alone format")
	end

	-- Parse LZMA alone header
	local header = parseLZMAAloneHeader(buffer)

	if not header.uncompressedSize then
		error("LZMA streams with unknown size are not supported")
	end

	-- Create LZMA decoder
	local decoder = LZMADecoder.new(header.properties)
	-- Create bit reader for compressed data
	local bitReader = BitReader.new(buffer)
	-- Decode
	local outputBuffer = decoder:decode(bitReader, header.uncompressedSize)
	-- Restore position
	buffer:SetPosition(savedPos)
	return outputBuffer
end

-- Main entry point - decode LZMA file
local function lzmaFile(inputBuffer)
	-- Verify this is an LZMA file
	local savedPos = inputBuffer:GetPosition()
	inputBuffer:SetPosition(0)
	-- LZMA alone format doesn't have a distinct magic number
	-- but we can validate the properties byte
	local props = inputBuffer:ReadU8()
	inputBuffer:SetPosition(savedPos)

	if props >= 9 * 5 * 5 then
		error("Not a valid LZMA file (invalid properties byte)")
	end

	-- Decompress the data
	local outputBuffer = decompressLZMA(inputBuffer)
	return outputBuffer
end

local lzma = {}
lzma.DecodeBuffer = lzmaFile

function lzma.Decode(str)
	local buf = Buffer.New(str, #str)
	return lib(buf):GetString()
end

return lzma
