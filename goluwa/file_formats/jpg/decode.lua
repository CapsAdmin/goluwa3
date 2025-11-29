-- JPEG decoder ported from jpeg-js (https://github.com/eugeneware/jpeg-js)
-- Original JavaScript code is MIT licensed
local ffi = require("ffi")
local Buffer = require("structs.buffer")
local bit_band = bit.band
local bit_bor = bit.bor
local bit_lshift = bit.lshift
local bit_rshift = bit.rshift
local math_floor = math.floor
local math_ceil = math.ceil
local math_max = math.max
local math_min = math.min
-- DCT zigzag ordering
local dctZigZag = {
	[0] = 0,
	1,
	8,
	16,
	9,
	2,
	3,
	10,
	17,
	24,
	32,
	25,
	18,
	11,
	4,
	5,
	12,
	19,
	26,
	33,
	40,
	48,
	41,
	34,
	27,
	20,
	13,
	6,
	7,
	14,
	21,
	28,
	35,
	42,
	49,
	56,
	57,
	50,
	43,
	36,
	29,
	22,
	15,
	23,
	30,
	37,
	44,
	51,
	58,
	59,
	52,
	45,
	38,
	31,
	39,
	46,
	53,
	60,
	61,
	54,
	47,
	55,
	62,
	63,
}
-- DCT constants
local dctCos1 = 4017 -- cos(pi/16)
local dctSin1 = 799 -- sin(pi/16)
local dctCos3 = 3406 -- cos(3*pi/16)
local dctSin3 = 2276 -- sin(3*pi/16)
local dctCos6 = 1567 -- cos(6*pi/16)
local dctSin6 = 3784 -- sin(6*pi/16)
local dctSqrt2 = 5793 -- sqrt(2)
local dctSqrt1d2 = 2896 -- sqrt(2) / 2
-- Build Huffman table from code lengths and values
local function buildHuffmanTable(codeLengths, values)
	local k = 0
	local code = {}
	local length = 16

	while length > 0 and (not codeLengths[length - 1] or codeLengths[length - 1] == 0) do
		length = length - 1
	end

	code[#code + 1] = {children = {}, index = 0}
	local p = code[1]
	local q

	for i = 0, length - 1 do
		for j = 0, (codeLengths[i] or 0) - 1 do
			p = code[#code]
			table.remove(code)
			p.children[p.index] = values[k]

			while p.index > 0 do
				if #code == 0 then error("Could not recreate Huffman Table") end

				p = code[#code]
				table.remove(code)
			end

			p.index = p.index + 1
			code[#code + 1] = p

			while #code <= i do
				q = {children = {}, index = 0}
				code[#code + 1] = q
				p.children[p.index] = q.children
				p = q
			end

			k = k + 1
		end

		if i + 1 < length then
			q = {children = {}, index = 0}
			code[#code + 1] = q
			p.children[p.index] = q.children
			p = q
		end
	end

	return code[1].children
end

-- Decode scan data
local function decodeScan(
	data,
	offset,
	frame,
	components,
	resetInterval,
	spectralStart,
	spectralEnd,
	successivePrev,
	successive,
	opts
)
	local mcusPerLine = frame.mcusPerLine
	local progressive = frame.progressive
	local startOffset = offset
	local bitsData = 0
	local bitsCount = 0

	local function readBit()
		if bitsCount > 0 then
			bitsCount = bitsCount - 1
			return bit_band(bit_rshift(bitsData, bitsCount), 1)
		end

		bitsData = data:GetByte(offset)
		offset = offset + 1

		if bitsData == 0xFF then
			local nextByte = data:GetByte(offset)
			offset = offset + 1

			if nextByte ~= 0 then
				error(
					"unexpected marker: " .. string.format("%04x", bit_bor(bit_lshift(bitsData, 8), nextByte))
				)
			end
		-- unstuff 0
		end

		bitsCount = 7
		return bit_rshift(bitsData, 7)
	end

	local function decodeHuffman(tree)
		local node = tree

		while true do
			local b = readBit()

			if b == nil then return nil end

			node = node[b]

			if type(node) == "number" then return node end

			if type(node) ~= "table" then error("invalid huffman sequence") end
		end
	end

	local function receive(length)
		local n = 0

		while length > 0 do
			local b = readBit()

			if b == nil then return nil end

			n = bit_bor(bit_lshift(n, 1), b)
			length = length - 1
		end

		return n
	end

	local function receiveAndExtend(length)
		local n = receive(length)

		if n >= bit_lshift(1, length - 1) then return n end

		return n + bit_bor(-bit_lshift(1, length), 1)
	end

	local function decodeBaseline(component, zz)
		local t = decodeHuffman(component.huffmanTableDC)
		local diff = t == 0 and 0 or receiveAndExtend(t)
		component.pred = component.pred + diff
		zz[0] = component.pred
		local k = 1

		while k < 64 do
			local rs = decodeHuffman(component.huffmanTableAC)
			local s = bit_band(rs, 15)
			local r = bit_rshift(rs, 4)

			if s == 0 then
				if r < 15 then break end

				k = k + 16
			else
				k = k + r
				local z = dctZigZag[k]
				zz[z] = receiveAndExtend(s)
				k = k + 1
			end
		end
	end

	local function decodeDCFirst(component, zz)
		local t = decodeHuffman(component.huffmanTableDC)
		local diff = t == 0 and 0 or bit_lshift(receiveAndExtend(t), successive)
		component.pred = component.pred + diff
		zz[0] = component.pred
	end

	local function decodeDCSuccessive(component, zz)
		zz[0] = bit_bor(zz[0], bit_lshift(readBit(), successive))
	end

	local eobrun = 0

	local function decodeACFirst(component, zz)
		if eobrun > 0 then
			eobrun = eobrun - 1
			return
		end

		local k = spectralStart
		local e = spectralEnd

		while k <= e do
			local rs = decodeHuffman(component.huffmanTableAC)
			local s = bit_band(rs, 15)
			local r = bit_rshift(rs, 4)

			if s == 0 then
				if r < 15 then
					eobrun = receive(r) + bit_lshift(1, r) - 1

					break
				end

				k = k + 16
			else
				k = k + r
				local z = dctZigZag[k]
				zz[z] = bit_lshift(receiveAndExtend(s), successive)
				k = k + 1
			end
		end
	end

	local successiveACState = 0
	local successiveACNextValue

	local function decodeACSuccessive(component, zz)
		local k = spectralStart
		local e = spectralEnd
		local r = 0

		while k <= e do
			local z = dctZigZag[k]
			local direction = zz[z] < 0 and -1 or 1

			if successiveACState == 0 then
				local rs = decodeHuffman(component.huffmanTableAC)
				local s = bit_band(rs, 15)
				r = bit_rshift(rs, 4)

				if s == 0 then
					if r < 15 then
						eobrun = receive(r) + bit_lshift(1, r)
						successiveACState = 4
					else
						r = 16
						successiveACState = 1
					end
				else
					if s ~= 1 then error("invalid ACn encoding") end

					successiveACNextValue = receiveAndExtend(s)
					successiveACState = r ~= 0 and 2 or 3
				end
			elseif successiveACState == 1 or successiveACState == 2 then
				if zz[z] ~= 0 then
					zz[z] = zz[z] + bit_lshift(readBit(), successive) * direction
				else
					r = r - 1

					if r == 0 then
						successiveACState = successiveACState == 2 and 3 or 0
					end
				end

				k = k + 1
			elseif successiveACState == 3 then
				if zz[z] ~= 0 then
					zz[z] = zz[z] + bit_lshift(readBit(), successive) * direction
				else
					zz[z] = bit_lshift(successiveACNextValue, successive)
					successiveACState = 0
				end

				k = k + 1
			elseif successiveACState == 4 then
				if zz[z] ~= 0 then
					zz[z] = zz[z] + bit_lshift(readBit(), successive) * direction
				end

				k = k + 1
			end

			if successiveACState == 0 then

			-- continue without incrementing k
			else

			-- k already incremented in state handlers
			end
		end

		if successiveACState == 4 then
			eobrun = eobrun - 1

			if eobrun == 0 then successiveACState = 0 end
		end
	end

	local function decodeMcu(component, decode, mcu, row, col)
		local mcuRow = math_floor(mcu / mcusPerLine)
		local mcuCol = mcu % mcusPerLine
		local blockRow = mcuRow * component.v + row
		local blockCol = mcuCol * component.h + col

		if component.blocks[blockRow] == nil and opts.tolerantDecoding then
			return
		end

		decode(component, component.blocks[blockRow][blockCol])
	end

	local function decodeBlock(component, decode, mcu)
		local blockRow = math_floor(mcu / component.blocksPerLine)
		local blockCol = mcu % component.blocksPerLine

		if component.blocks[blockRow] == nil and opts.tolerantDecoding then
			return
		end

		decode(component, component.blocks[blockRow][blockCol])
	end

	local componentsLength = #components
	local decodeFn

	if progressive then
		if spectralStart == 0 then
			decodeFn = successivePrev == 0 and decodeDCFirst or decodeDCSuccessive
		else
			decodeFn = successivePrev == 0 and decodeACFirst or decodeACSuccessive
		end
	else
		decodeFn = decodeBaseline
	end

	local mcu = 0
	local mcuExpected

	if componentsLength == 1 then
		mcuExpected = components[1].blocksPerLine * components[1].blocksPerColumn
	else
		mcuExpected = mcusPerLine * frame.mcusPerColumn
	end

	if not resetInterval or resetInterval == 0 then
		resetInterval = mcuExpected
	end

	while mcu < mcuExpected do
		-- reset interval stuff
		for i = 1, componentsLength do
			components[i].pred = 0
		end

		eobrun = 0

		if componentsLength == 1 then
			local component = components[1]

			for n = 0, resetInterval - 1 do
				decodeBlock(component, decodeFn, mcu)
				mcu = mcu + 1
			end
		else
			for n = 0, resetInterval - 1 do
				for i = 1, componentsLength do
					local component = components[i]
					local h = component.h
					local v = component.v

					for j = 0, v - 1 do
						for k = 0, h - 1 do
							decodeMcu(component, decodeFn, mcu, j, k)
						end
					end
				end

				mcu = mcu + 1

				if mcu == mcuExpected then break end
			end
		end

		if mcu == mcuExpected then
			-- Skip trailing bytes at the end of the scan
			while offset < data:GetSize() - 2 do
				if data:GetByte(offset) == 0xFF then
					if data:GetByte(offset + 1) ~= 0x00 then break end
				end

				offset = offset + 1
			end
		end

		-- find marker
		bitsCount = 0
		local marker = bit_bor(bit_lshift(data:GetByte(offset), 8), data:GetByte(offset + 1))

		if marker < 0xFF00 then error("marker was not found") end

		if marker >= 0xFFD0 and marker <= 0xFFD7 then -- RSTx
			offset = offset + 2
		else
			break
		end
	end

	return offset - startOffset
end

-- Build component data (IDCT and dequantization)
local function buildComponentData(component)
	local lines = {}
	local blocksPerLine = component.blocksPerLine
	local blocksPerColumn = component.blocksPerColumn
	local samplesPerLine = bit_lshift(blocksPerLine, 3)
	-- Temporary arrays for IDCT
	local R = ffi.new("int32_t[64]")
	local r = ffi.new("uint8_t[64]")

	local function quantizeAndInverse(zz, dataOut, dataIn)
		local qt = component.quantizationTable
		local v0, v1, v2, v3, v4, v5, v6, v7, t
		local p = dataIn

		-- dequant
		for i = 0, 63 do
			p[i] = zz[i] * qt[i]
		end

		-- inverse DCT on rows
		for i = 0, 7 do
			local row = 8 * i

			-- check for all-zero AC coefficients
			if
				p[1 + row] == 0 and
				p[2 + row] == 0 and
				p[3 + row] == 0 and
				p[4 + row] == 0 and
				p[5 + row] == 0 and
				p[6 + row] == 0 and
				p[7 + row] == 0
			then
				t = bit_rshift(dctSqrt2 * p[0 + row] + 512, 10)
				p[0 + row] = t
				p[1 + row] = t
				p[2 + row] = t
				p[3 + row] = t
				p[4 + row] = t
				p[5 + row] = t
				p[6 + row] = t
				p[7 + row] = t
			else
				-- stage 4
				v0 = bit_rshift(dctSqrt2 * p[0 + row] + 128, 8)
				v1 = bit_rshift(dctSqrt2 * p[4 + row] + 128, 8)
				v2 = p[2 + row]
				v3 = p[6 + row]
				v4 = bit_rshift(dctSqrt1d2 * (p[1 + row] - p[7 + row]) + 128, 8)
				v7 = bit_rshift(dctSqrt1d2 * (p[1 + row] + p[7 + row]) + 128, 8)
				v5 = bit_lshift(p[3 + row], 4)
				v6 = bit_lshift(p[5 + row], 4)
				-- stage 3
				t = bit_rshift(v0 - v1 + 1, 1)
				v0 = bit_rshift(v0 + v1 + 1, 1)
				v1 = t
				t = bit_rshift(v2 * dctSin6 + v3 * dctCos6 + 128, 8)
				v2 = bit_rshift(v2 * dctCos6 - v3 * dctSin6 + 128, 8)
				v3 = t
				t = bit_rshift(v4 - v6 + 1, 1)
				v4 = bit_rshift(v4 + v6 + 1, 1)
				v6 = t
				t = bit_rshift(v7 + v5 + 1, 1)
				v5 = bit_rshift(v7 - v5 + 1, 1)
				v7 = t
				-- stage 2
				t = bit_rshift(v0 - v3 + 1, 1)
				v0 = bit_rshift(v0 + v3 + 1, 1)
				v3 = t
				t = bit_rshift(v1 - v2 + 1, 1)
				v1 = bit_rshift(v1 + v2 + 1, 1)
				v2 = t
				t = bit_rshift(v4 * dctSin3 + v7 * dctCos3 + 2048, 12)
				v4 = bit_rshift(v4 * dctCos3 - v7 * dctSin3 + 2048, 12)
				v7 = t
				t = bit_rshift(v5 * dctSin1 + v6 * dctCos1 + 2048, 12)
				v5 = bit_rshift(v5 * dctCos1 - v6 * dctSin1 + 2048, 12)
				v6 = t
				-- stage 1
				p[0 + row] = v0 + v7
				p[7 + row] = v0 - v7
				p[1 + row] = v1 + v6
				p[6 + row] = v1 - v6
				p[2 + row] = v2 + v5
				p[5 + row] = v2 - v5
				p[3 + row] = v3 + v4
				p[4 + row] = v3 - v4
			end
		end

		-- inverse DCT on columns
		for i = 0, 7 do
			local col = i

			-- check for all-zero AC coefficients
			if
				p[1 * 8 + col] == 0 and
				p[2 * 8 + col] == 0 and
				p[3 * 8 + col] == 0 and
				p[4 * 8 + col] == 0 and
				p[5 * 8 + col] == 0 and
				p[6 * 8 + col] == 0 and
				p[7 * 8 + col] == 0
			then
				t = bit_rshift(dctSqrt2 * dataIn[i + 0] + 8192, 14)
				p[0 * 8 + col] = t
				p[1 * 8 + col] = t
				p[2 * 8 + col] = t
				p[3 * 8 + col] = t
				p[4 * 8 + col] = t
				p[5 * 8 + col] = t
				p[6 * 8 + col] = t
				p[7 * 8 + col] = t
			else
				-- stage 4
				v0 = bit_rshift(dctSqrt2 * p[0 * 8 + col] + 2048, 12)
				v1 = bit_rshift(dctSqrt2 * p[4 * 8 + col] + 2048, 12)
				v2 = p[2 * 8 + col]
				v3 = p[6 * 8 + col]
				v4 = bit_rshift(dctSqrt1d2 * (p[1 * 8 + col] - p[7 * 8 + col]) + 2048, 12)
				v7 = bit_rshift(dctSqrt1d2 * (p[1 * 8 + col] + p[7 * 8 + col]) + 2048, 12)
				v5 = p[3 * 8 + col]
				v6 = p[5 * 8 + col]
				-- stage 3
				t = bit_rshift(v0 - v1 + 1, 1)
				v0 = bit_rshift(v0 + v1 + 1, 1)
				v1 = t
				t = bit_rshift(v2 * dctSin6 + v3 * dctCos6 + 2048, 12)
				v2 = bit_rshift(v2 * dctCos6 - v3 * dctSin6 + 2048, 12)
				v3 = t
				t = bit_rshift(v4 - v6 + 1, 1)
				v4 = bit_rshift(v4 + v6 + 1, 1)
				v6 = t
				t = bit_rshift(v7 + v5 + 1, 1)
				v5 = bit_rshift(v7 - v5 + 1, 1)
				v7 = t
				-- stage 2
				t = bit_rshift(v0 - v3 + 1, 1)
				v0 = bit_rshift(v0 + v3 + 1, 1)
				v3 = t
				t = bit_rshift(v1 - v2 + 1, 1)
				v1 = bit_rshift(v1 + v2 + 1, 1)
				v2 = t
				t = bit_rshift(v4 * dctSin3 + v7 * dctCos3 + 2048, 12)
				v4 = bit_rshift(v4 * dctCos3 - v7 * dctSin3 + 2048, 12)
				v7 = t
				t = bit_rshift(v5 * dctSin1 + v6 * dctCos1 + 2048, 12)
				v5 = bit_rshift(v5 * dctCos1 - v6 * dctSin1 + 2048, 12)
				v6 = t
				-- stage 1
				p[0 * 8 + col] = v0 + v7
				p[7 * 8 + col] = v0 - v7
				p[1 * 8 + col] = v1 + v6
				p[6 * 8 + col] = v1 - v6
				p[2 * 8 + col] = v2 + v5
				p[5 * 8 + col] = v2 - v5
				p[3 * 8 + col] = v3 + v4
				p[4 * 8 + col] = v3 - v4
			end
		end

		-- convert to 8-bit integers
		for i = 0, 63 do
			local sample = 128 + bit_rshift(p[i] + 8, 4)
			dataOut[i] = sample < 0 and 0 or (sample > 0xFF and 0xFF or sample)
		end
	end

	for blockRow = 0, blocksPerColumn - 1 do
		local scanLine = bit_lshift(blockRow, 3)

		for i = 0, 7 do
			lines[scanLine + i] = ffi.new("uint8_t[?]", samplesPerLine)
		end

		for blockCol = 0, blocksPerLine - 1 do
			quantizeAndInverse(component.blocks[blockRow][blockCol], r, R)
			local off = 0
			local sample = bit_lshift(blockCol, 3)

			for j = 0, 7 do
				local line = lines[scanLine + j]

				for i = 0, 7 do
					line[sample + i] = r[off]
					off = off + 1
				end
			end
		end
	end

	return lines
end

-- Clamp value to 8-bit range
local function clampTo8bit(a)
	return a < 0 and 0 or (a > 255 and 255 or math_floor(a + 0.5))
end

-- Main decode function
local function decode(inputBuffer, opts)
	opts = opts or {}
	local colorTransform = opts.colorTransform
	local formatAsRGBA = opts.formatAsRGBA ~= false
	local tolerantDecoding = opts.tolerantDecoding ~= false
	local maxResolutionInMP = opts.maxResolutionInMP or 100
	local maxResolutionInPixels = maxResolutionInMP * 1000 * 1000
	local data = inputBuffer
	local offset = 0

	local function readUint16()
		local value = bit_bor(bit_lshift(data:GetByte(offset), 8), data:GetByte(offset + 1))
		offset = offset + 2
		return value
	end

	local function readDataBlock()
		local length = readUint16()
		local start = offset
		offset = offset + length - 2
		return start, length - 2
	end

	local function prepareComponents(frame)
		local maxH = 1
		local maxV = 1

		for componentId, component in pairs(frame.components) do
			if maxH < component.h then maxH = component.h end

			if maxV < component.v then maxV = component.v end
		end

		local mcusPerLine = math_ceil(frame.samplesPerLine / 8 / maxH)
		local mcusPerColumn = math_ceil(frame.scanLines / 8 / maxV)

		for componentId, component in pairs(frame.components) do
			local blocksPerLine = math_ceil(math_ceil(frame.samplesPerLine / 8) * component.h / maxH)
			local blocksPerColumn = math_ceil(math_ceil(frame.scanLines / 8) * component.v / maxV)
			local blocksPerLineForMcu = mcusPerLine * component.h
			local blocksPerColumnForMcu = mcusPerColumn * component.v
			local blocks = {}

			for i = 0, blocksPerColumnForMcu - 1 do
				local row = {}

				for j = 0, blocksPerLineForMcu - 1 do
					row[j] = ffi.new("int32_t[64]")
				end

				blocks[i] = row
			end

			component.blocksPerLine = blocksPerLine
			component.blocksPerColumn = blocksPerColumn
			component.blocks = blocks
		end

		frame.maxH = maxH
		frame.maxV = maxV
		frame.mcusPerLine = mcusPerLine
		frame.mcusPerColumn = mcusPerColumn
	end

	local jfif = nil
	local adobe = nil
	local frame, resetInterval
	local quantizationTables = {}
	local frames = {}
	local huffmanTablesAC = {}
	local huffmanTablesDC = {}
	local comments = {}
	local exifBuffer = nil
	local fileMarker = readUint16()
	local malformedDataOffset = -1

	if fileMarker ~= 0xFFD8 then -- SOI (Start of Image)
		error("SOI not found")
	end

	fileMarker = readUint16()

	while fileMarker ~= 0xFFD9 do -- EOI (End of image)
		if fileMarker == 0xFF00 then

		-- skip
		elseif fileMarker >= 0xFFE0 and fileMarker <= 0xFFEF then
			-- APP0-APP15
			local blockStart, blockLen = readDataBlock()

			if fileMarker == 0xFFFE then
				-- Comment
				local comment = data:GetStringSlice(blockStart, blockStart + blockLen - 1)
				comments[#comments + 1] = comment
			end

			if fileMarker == 0xFFE0 then
				-- JFIF
				if
					data:GetByte(blockStart) == 0x4A and
					data:GetByte(blockStart + 1) == 0x46 and
					data:GetByte(blockStart + 2) == 0x49 and
					data:GetByte(blockStart + 3) == 0x46 and
					data:GetByte(blockStart + 4) == 0
				then
					jfif = {
						version = {
							major = data:GetByte(blockStart + 5),
							minor = data:GetByte(blockStart + 6),
						},
						densityUnits = data:GetByte(blockStart + 7),
						xDensity = bit_bor(bit_lshift(data:GetByte(blockStart + 8), 8), data:GetByte(blockStart + 9)),
						yDensity = bit_bor(bit_lshift(data:GetByte(blockStart + 10), 8), data:GetByte(blockStart + 11)),
						thumbWidth = data:GetByte(blockStart + 12),
						thumbHeight = data:GetByte(blockStart + 13),
					}
				end
			end

			if fileMarker == 0xFFE1 then
				-- EXIF
				if
					data:GetByte(blockStart) == 0x45 and
					data:GetByte(blockStart + 1) == 0x78 and
					data:GetByte(blockStart + 2) == 0x69 and
					data:GetByte(blockStart + 3) == 0x66 and
					data:GetByte(blockStart + 4) == 0
				then
					exifBuffer = data:GetStringSlice(blockStart + 5, blockStart + blockLen - 1)
				end
			end

			if fileMarker == 0xFFEE then
				-- Adobe
				if
					data:GetByte(blockStart) == 0x41 and
					data:GetByte(blockStart + 1) == 0x64 and
					data:GetByte(blockStart + 2) == 0x6F and
					data:GetByte(blockStart + 3) == 0x62 and
					data:GetByte(blockStart + 4) == 0x65 and
					data:GetByte(blockStart + 5) == 0
				then
					adobe = {
						version = data:GetByte(blockStart + 6),
						flags0 = bit_bor(bit_lshift(data:GetByte(blockStart + 7), 8), data:GetByte(blockStart + 8)),
						flags1 = bit_bor(bit_lshift(data:GetByte(blockStart + 9), 8), data:GetByte(blockStart + 10)),
						transformCode = data:GetByte(blockStart + 11),
					}
				end
			end
		elseif fileMarker == 0xFFFE then
			-- COM (Comment)
			local blockStart, blockLen = readDataBlock()
			local comment = data:GetStringSlice(blockStart, blockStart + blockLen - 1)
			comments[#comments + 1] = comment
		elseif fileMarker == 0xFFDB then
			-- DQT (Define Quantization Tables)
			local quantizationTablesLength = readUint16()
			local quantizationTablesEnd = quantizationTablesLength + offset - 2

			while offset < quantizationTablesEnd do
				local quantizationTableSpec = data:GetByte(offset)
				offset = offset + 1
				local tableData = ffi.new("int32_t[64]")

				if bit_rshift(quantizationTableSpec, 4) == 0 then
					-- 8 bit values
					for j = 0, 63 do
						local z = dctZigZag[j]
						tableData[z] = data:GetByte(offset)
						offset = offset + 1
					end
				elseif bit_rshift(quantizationTableSpec, 4) == 1 then
					-- 16 bit values
					for j = 0, 63 do
						local z = dctZigZag[j]
						tableData[z] = readUint16()
					end
				else
					error("DQT: invalid table spec")
				end

				quantizationTables[bit_band(quantizationTableSpec, 15)] = tableData
			end
		elseif fileMarker == 0xFFC0 or fileMarker == 0xFFC1 or fileMarker == 0xFFC2 then
			-- SOF0, SOF1, SOF2 (Start of Frame)
			readUint16() -- skip data length
			frame = {}
			frame.extended = (fileMarker == 0xFFC1)
			frame.progressive = (fileMarker == 0xFFC2)
			frame.precision = data:GetByte(offset)
			offset = offset + 1
			frame.scanLines = readUint16()
			frame.samplesPerLine = readUint16()
			frame.components = {}
			frame.componentsOrder = {}
			local pixelsInFrame = frame.scanLines * frame.samplesPerLine

			if pixelsInFrame > maxResolutionInPixels then
				local exceededAmount = math_ceil((pixelsInFrame - maxResolutionInPixels) / 1e6)
				error("maxResolutionInMP limit exceeded by " .. exceededAmount .. "MP")
			end

			local componentsCount = data:GetByte(offset)
			offset = offset + 1

			for i = 1, componentsCount do
				local componentId = data:GetByte(offset)
				local h = bit_rshift(data:GetByte(offset + 1), 4)
				local v = bit_band(data:GetByte(offset + 1), 15)
				local qId = data:GetByte(offset + 2)

				if h <= 0 or v <= 0 then
					error("Invalid sampling factor, expected values above 0")
				end

				frame.componentsOrder[#frame.componentsOrder + 1] = componentId
				frame.components[componentId] = {h = h, v = v, quantizationIdx = qId}
				offset = offset + 3
			end

			prepareComponents(frame)
			frames[#frames + 1] = frame
		elseif fileMarker == 0xFFC4 then
			-- DHT (Define Huffman Tables)
			local huffmanLength = readUint16()
			local i = 2

			while i < huffmanLength do
				local huffmanTableSpec = data:GetByte(offset)
				offset = offset + 1
				local codeLengths = {}
				local codeLengthSum = 0

				for j = 0, 15 do
					codeLengths[j] = data:GetByte(offset)
					codeLengthSum = codeLengthSum + codeLengths[j]
					offset = offset + 1
				end

				local huffmanValues = {}

				for j = 0, codeLengthSum - 1 do
					huffmanValues[j] = data:GetByte(offset)
					offset = offset + 1
				end

				i = i + 17 + codeLengthSum
				local table

				if bit_rshift(huffmanTableSpec, 4) == 0 then
					table = huffmanTablesDC
				else
					table = huffmanTablesAC
				end

				table[bit_band(huffmanTableSpec, 15)] = buildHuffmanTable(codeLengths, huffmanValues)
			end
		elseif fileMarker == 0xFFDD then
			-- DRI (Define Restart Interval)
			readUint16() -- skip data length
			resetInterval = readUint16()
		elseif fileMarker == 0xFFDC then
			-- Number of Lines marker
			readUint16() -- skip data length
			readUint16() -- ignore this data
		elseif fileMarker == 0xFFDA then
			-- SOS (Start of Scan)
			local scanLength = readUint16()
			local selectorsCount = data:GetByte(offset)
			offset = offset + 1
			local scanComponents = {}

			for i = 1, selectorsCount do
				local componentId = data:GetByte(offset)
				local component = frame.components[componentId]
				local tableSpec = data:GetByte(offset + 1)
				component.huffmanTableDC = huffmanTablesDC[bit_rshift(tableSpec, 4)]
				component.huffmanTableAC = huffmanTablesAC[bit_band(tableSpec, 15)]
				scanComponents[#scanComponents + 1] = component
				offset = offset + 2
			end

			local spectralStart = data:GetByte(offset)
			offset = offset + 1
			local spectralEnd = data:GetByte(offset)
			offset = offset + 1
			local successiveApproximation = data:GetByte(offset)
			offset = offset + 1
			local processed = decodeScan(
				data,
				offset,
				frame,
				scanComponents,
				resetInterval,
				spectralStart,
				spectralEnd,
				bit_rshift(successiveApproximation, 4),
				bit_band(successiveApproximation, 15),
				{tolerantDecoding = tolerantDecoding}
			)
			offset = offset + processed
		elseif fileMarker == 0xFFFF then
			-- Fill bytes
			if data:GetByte(offset) ~= 0xFF then offset = offset - 1 end
		else
			if
				data:GetByte(offset - 3) == 0xFF and
				data:GetByte(offset - 2) >= 0xC0 and
				data:GetByte(offset - 2) <= 0xFE
			then
				offset = offset - 3
			elseif fileMarker == 0xE0 or fileMarker == 0xE1 then
				if malformedDataOffset ~= -1 then
					error(
						string.format(
							"first unknown JPEG marker at offset %x, second unknown JPEG marker %x at offset %x",
							malformedDataOffset,
							fileMarker,
							offset - 1
						)
					)
				end

				malformedDataOffset = offset - 1
				local nextOffset = readUint16()

				if data:GetByte(offset + nextOffset - 2) == 0xFF then
					offset = offset + nextOffset - 2
				end
			else
				error("unknown JPEG marker " .. string.format("%x", fileMarker))
			end
		end

		fileMarker = readUint16()
	end

	if #frames ~= 1 then error("only single frame JPEGs supported") end

	-- set each frame's components quantization table
	for i = 1, #frames do
		local cp = frames[i].components

		for j, comp in pairs(cp) do
			comp.quantizationTable = quantizationTables[comp.quantizationIdx]
			comp.quantizationIdx = nil
		end
	end

	local width = frame.samplesPerLine
	local height = frame.scanLines
	-- Build component data
	local decodedComponents = {}

	for i = 1, #frame.componentsOrder do
		local component = frame.components[frame.componentsOrder[i]]
		decodedComponents[i] = {
			lines = buildComponentData(component),
			scaleX = component.h / frame.maxH,
			scaleY = component.v / frame.maxV,
		}
	end

	-- Get pixel data
	local function getData(w, h)
		local scaleX = width / w
		local scaleY = height / h
		local numComponents = #decodedComponents
		local channels = formatAsRGBA and 4 or 3
		local dataLength = w * h * channels
		local outputData = ffi.new("uint8_t[?]", dataLength)
		local off = 0
		local useColorTransform

		if numComponents == 3 then
			useColorTransform = true

			if adobe and adobe.transformCode then
				useColorTransform = true
			elseif colorTransform ~= nil then
				useColorTransform = colorTransform
			end
		elseif numComponents == 4 then
			if not adobe then error("Unsupported color mode (4 components)") end

			useColorTransform = false

			if adobe and adobe.transformCode then
				useColorTransform = true
			elseif colorTransform ~= nil then
				useColorTransform = colorTransform
			end
		end

		local component1 = decodedComponents[1]
		local component2 = decodedComponents[2]
		local component3 = decodedComponents[3]
		local component4 = decodedComponents[4]

		if numComponents == 1 then
			for y = 0, h - 1 do
				local component1Line = component1.lines[math_floor(y * component1.scaleY * scaleY)]

				for x = 0, w - 1 do
					local Y = component1Line[math_floor(x * component1.scaleX * scaleX)]
					outputData[off] = Y
					outputData[off + 1] = Y
					outputData[off + 2] = Y

					if formatAsRGBA then
						outputData[off + 3] = 255
						off = off + 4
					else
						off = off + 3
					end
				end
			end
		elseif numComponents == 2 then
			for y = 0, h - 1 do
				local component1Line = component1.lines[math_floor(y * component1.scaleY * scaleY)]
				local component2Line = component2.lines[math_floor(y * component2.scaleY * scaleY)]

				for x = 0, w - 1 do
					local Y1 = component1Line[math_floor(x * component1.scaleX * scaleX)]
					local Y2 = component2Line[math_floor(x * component2.scaleX * scaleX)]
					outputData[off] = Y1
					outputData[off + 1] = Y2

					if formatAsRGBA then
						outputData[off + 2] = 255
						outputData[off + 3] = 255
						off = off + 4
					else
						off = off + 3
					end
				end
			end
		elseif numComponents == 3 then
			for y = 0, h - 1 do
				local component1Line = component1.lines[math_floor(y * component1.scaleY * scaleY)]
				local component2Line = component2.lines[math_floor(y * component2.scaleY * scaleY)]
				local component3Line = component3.lines[math_floor(y * component3.scaleY * scaleY)]

				for x = 0, w - 1 do
					local R, G, B

					if not useColorTransform then
						R = component1Line[math_floor(x * component1.scaleX * scaleX)]
						G = component2Line[math_floor(x * component2.scaleX * scaleX)]
						B = component3Line[math_floor(x * component3.scaleX * scaleX)]
					else
						local Y = component1Line[math_floor(x * component1.scaleX * scaleX)]
						local Cb = component2Line[math_floor(x * component2.scaleX * scaleX)]
						local Cr = component3Line[math_floor(x * component3.scaleX * scaleX)]
						R = clampTo8bit(Y + 1.402 * (Cr - 128))
						G = clampTo8bit(Y - 0.3441363 * (Cb - 128) - 0.71413636 * (Cr - 128))
						B = clampTo8bit(Y + 1.772 * (Cb - 128))
					end

					outputData[off] = R
					outputData[off + 1] = G
					outputData[off + 2] = B

					if formatAsRGBA then
						outputData[off + 3] = 255
						off = off + 4
					else
						off = off + 3
					end
				end
			end
		elseif numComponents == 4 then
			for y = 0, h - 1 do
				local component1Line = component1.lines[math_floor(y * component1.scaleY * scaleY)]
				local component2Line = component2.lines[math_floor(y * component2.scaleY * scaleY)]
				local component3Line = component3.lines[math_floor(y * component3.scaleY * scaleY)]
				local component4Line = component4.lines[math_floor(y * component4.scaleY * scaleY)]

				for x = 0, w - 1 do
					local C, M, Ye, K

					if not useColorTransform then
						C = component1Line[math_floor(x * component1.scaleX * scaleX)]
						M = component2Line[math_floor(x * component2.scaleX * scaleX)]
						Ye = component3Line[math_floor(x * component3.scaleX * scaleX)]
						K = component4Line[math_floor(x * component4.scaleX * scaleX)]
					else
						local Y = component1Line[math_floor(x * component1.scaleX * scaleX)]
						local Cb = component2Line[math_floor(x * component2.scaleX * scaleX)]
						local Cr = component3Line[math_floor(x * component3.scaleX * scaleX)]
						K = component4Line[math_floor(x * component4.scaleX * scaleX)]
						C = 255 - clampTo8bit(Y + 1.402 * (Cr - 128))
						M = 255 - clampTo8bit(Y - 0.3441363 * (Cb - 128) - 0.71413636 * (Cr - 128))
						Ye = 255 - clampTo8bit(Y + 1.772 * (Cb - 128))
					end

					-- CMYK to RGB conversion
					local R = 255 - clampTo8bit(C * (1 - K / 255) + K)
					local G = 255 - clampTo8bit(M * (1 - K / 255) + K)
					local B = 255 - clampTo8bit(Ye * (1 - K / 255) + K)
					outputData[off] = R
					outputData[off + 1] = G
					outputData[off + 2] = B

					if formatAsRGBA then
						outputData[off + 3] = 255
						off = off + 4
					else
						off = off + 3
					end
				end
			end
		else
			error("Unsupported color mode")
		end

		return outputData
	end

	-- Create output buffer with pixel data (flipped vertically for Vulkan)
	local channels = formatAsRGBA and 4 or 3
	local outputSize = width * height * channels
	local pixelData = getData(width, height)
	-- Flip vertically for Vulkan (like PNG decoder does)
	local flippedData = ffi.new("uint8_t[?]", outputSize)
	local rowSize = width * channels

	for y = 0, height - 1 do
		local srcRow = y * rowSize
		local dstRow = (height - 1 - y) * rowSize
		ffi.copy(flippedData + dstRow, pixelData + srcRow, rowSize)
	end

	local outputBuffer = Buffer.New(flippedData, outputSize)
	return {
		width = width,
		height = height,
		buffer = outputBuffer,
		jfif = jfif,
		adobe = adobe,
		exifBuffer = exifBuffer,
		comments = #comments > 0 and comments or nil,
	}
end

return decode
