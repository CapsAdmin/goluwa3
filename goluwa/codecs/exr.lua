local ffi = require("ffi")
local bit = require("bit")
local Buffer = require("structs.buffer")
local deflate = require("codecs.deflate")

local function half_to_float(h)
	local s = bit.band(bit.rshift(h, 15), 0x00000001)
	local e = bit.band(bit.rshift(h, 10), 0x0000001f)
	local m = bit.band(h, 0x000003ff)

	if e == 0 then
		if m == 0 then
			return s == 1 and -0.0 or 0.0
		else
			while bit.band(m, 0x00000400) == 0 do
				m = bit.lshift(m, 1)
				e = e - 1
			end

			e = e + 1
			m = bit.band(m, bit.bnot(0x00000400))
		end
	elseif e == 31 then
		if m == 0 then
			return s == 1 and -math.huge or math.huge
		else
			return 0 / 0
		end
	end

	e = e + (127 - 15)
	m = bit.lshift(m, 13)
	local f_bits = bit.bor(bit.lshift(s, 31), bit.lshift(e, 23), m)
	local f_ptr = ffi.new("uint32_t[1]", f_bits)
	return ffi.cast("float*", f_ptr)[0]
end

local half_to_float_table = ffi.new("float[65536]")

for i = 0, 65535 do
	half_to_float_table[i] = half_to_float(i)
end

local function read_null_terminated_string(buffer)
	local str = {}

	while true do
		local b = buffer:ReadByte()

		if b == 0 then break end

		table.insert(str, string.char(b))
	end

	return table.concat(str)
end

local function predictor(data, size)
	local ptr = ffi.cast("uint8_t*", data)

	for i = 1, size - 1 do
		ptr[i] = bit.band(ptr[i] + ptr[i - 1] - 128, 0xFF)
	end
end

local reorder_tmp = nil
local reorder_tmp_size = 0

local function reorder(data, size)
	if not reorder_tmp or reorder_tmp_size < size then
		reorder_tmp = ffi.new("uint8_t[?]", size)
		reorder_tmp_size = size
	end

	local src = ffi.cast("uint8_t*", data)
	local t1 = 0
	local t2 = math.floor((size + 1) / 2)

	for i = 0, size - 1, 2 do
		reorder_tmp[i] = src[t1]
		t1 = t1 + 1

		if i + 1 < size then
			reorder_tmp[i + 1] = src[t2]
			t2 = t2 + 1
		end
	end

	ffi.copy(data, reorder_tmp, size)
end

local function exrImage(inputBuffer)
	if inputBuffer:ReadU32LE() ~= 0x01312f76 then error("Not an EXR file") end

	local version_field = inputBuffer:ReadU32LE()
	local version = bit.band(version_field, 0xFF)

	-- local flags = bit.rshift(version_field, 8)
	if version ~= 2 then error("Unsupported EXR version: " .. version) end

	local header = {}

	while true do
		local name = read_null_terminated_string(inputBuffer)

		if name == "" then break end

		local type = read_null_terminated_string(inputBuffer)
		local size = inputBuffer:ReadU32LE()
		local start_pos = inputBuffer:GetPosition()
		local value

		if type == "box2i" then
			value = {
				xMin = inputBuffer:ReadI32LE(),
				yMin = inputBuffer:ReadI32LE(),
				xMax = inputBuffer:ReadI32LE(),
				yMax = inputBuffer:ReadI32LE(),
			}
		elseif type == "chlist" then
			value = {}

			while true do
				local ch_name = read_null_terminated_string(inputBuffer)

				if ch_name == "" then break end

				table.insert(
					value,
					{
						name = ch_name,
						pixel_type = inputBuffer:ReadI32LE(), -- 0=UINT, 1=HALF, 2=FLOAT
						pLinear = inputBuffer:ReadByte(),
						reserved = inputBuffer:ReadBytes(3),
						xSampling = inputBuffer:ReadI32LE(),
						ySampling = inputBuffer:ReadI32LE(),
					}
				)
			end
		elseif type == "compression" then
			value = inputBuffer:ReadByte()
		elseif type == "lineOrder" then
			value = inputBuffer:ReadByte()
		elseif type == "float" then
			value = inputBuffer:ReadFloatLE()
		elseif type == "v2f" then
			value = {inputBuffer:ReadFloatLE(), inputBuffer:ReadFloatLE()}
		elseif type == "int" then
			value = inputBuffer:ReadI32LE()
		else

		-- Skip unknown attribute
		end

		header[name] = value
		inputBuffer:SetPosition(start_pos + size)
	end

	local dataWindow = header.dataWindow
	local width = dataWindow.xMax - dataWindow.xMin + 1
	local height = dataWindow.yMax - dataWindow.yMin + 1
	local compression = header.compression or 0
	local linesPerBlock = 1

	if compression == 3 then -- ZIP
		linesPerBlock = 16
	elseif compression == 2 then -- ZIPS
		linesPerBlock = 1
	elseif compression == 4 or compression == 5 then -- PIZ, PXR24
		linesPerBlock = 32
	elseif compression == 6 or compression == 7 then -- B44, B44A
		linesPerBlock = 32
	end

	local numBlocks = math.ceil(height / linesPerBlock)
	local offsets = {}

	for i = 1, numBlocks do
		offsets[i] = inputBuffer:ReadU64LE()
	end

	-- Prepare output buffer (RGBA float32)
	local outputSize = width * height * 4 * 4
	local outputData = ffi.new("float[?]", width * height * 4)

	-- Initialize Alpha to 1.0
	for i = 0, width * height - 1 do
		outputData[i * 4 + 3] = 1.0
	end

	-- EXR channels are stored alphabetically in the file
	table.sort(header.channels, function(a, b)
		return a.name < b.name
	end)

	local channel_map = {}

	for i, ch in ipairs(header.channels) do
		local name = ch.name

		if name == "R" then
			channel_map[i] = 0
		elseif name == "G" then
			channel_map[i] = 1
		elseif name == "B" then
			channel_map[i] = 2
		elseif name == "A" then
			channel_map[i] = 3
		else
			channel_map[i] = -1
		end
	end

	for i = 1, numBlocks do
		local offset = tonumber(offsets[i])
		inputBuffer:SetPosition(offset)
		local block_y = inputBuffer:ReadI32LE()
		local data_size = inputBuffer:ReadU32LE()
		local numLinesInThisBlock = math.min(linesPerBlock, height - (block_y - dataWindow.yMin))
		local block_buffer

		if compression == 0 then -- NONE
			block_buffer = inputBuffer
		elseif compression == 2 or compression == 3 then -- ZIPS or ZIP
			local compressed_data = inputBuffer:ReadBytes(data_size)
			local expected_size = 0

			for _, ch in ipairs(header.channels) do
				expected_size = expected_size + (ch.pixel_type == 1 and 2 or 4) * width * numLinesInThisBlock
			end

			local decompressed_buffer = deflate.inflate_zlib(
				{
					input = compressed_data,
					output = Buffer.New(ffi.new("uint8_t[?]", expected_size), expected_size):MakeWritable(),
					disable_crc = true,
				}
			)
			local decompressed_data = decompressed_buffer:GetBuffer()
			local decompressed_size = decompressed_buffer:GetSize()
			predictor(decompressed_data, decompressed_size)
			reorder(decompressed_data, decompressed_size)
			block_buffer = decompressed_buffer
			block_buffer:SetPosition(0)
		else
			error("Unsupported compression: " .. tostring(compression))
		end

		for ch_idx, ch in ipairs(header.channels) do
			local pixel_type = ch.pixel_type
			local target_ch_idx = channel_map[ch_idx]
			local bytes_per_pixel = (pixel_type == 1 and 2 or 4)

			for ly = 0, numLinesInThisBlock - 1 do
				local y = block_y - dataWindow.yMin + ly

				if y >= 0 and y < height then
					local out_row_offset = y * width * 4

					if target_ch_idx ~= -1 then
						local out_ptr = outputData + out_row_offset + target_ch_idx
						local src_ptr = block_buffer:GetBuffer() + block_buffer:GetPosition()

						if pixel_type == 1 then -- HALF
							local src = ffi.cast("uint16_t*", src_ptr)

							for x = 0, width - 1 do
								out_ptr[x * 4] = half_to_float_table[src[x]]
							end
						elseif pixel_type == 2 then -- FLOAT
							local src = ffi.cast("float*", src_ptr)

							for x = 0, width - 1 do
								out_ptr[x * 4] = src[x]
							end
						elseif pixel_type == 0 then -- UINT
							local src = ffi.cast("uint32_t*", src_ptr)

							for x = 0, width - 1 do
								out_ptr[x * 4] = src[x] / 4294967295
							end
						end
					end
				end

				block_buffer:Advance(width * bytes_per_pixel)
			end
		end

		-- Force GC to free decompressed buffers
		if i % 10 == 0 then collectgarbage("step") end
	end

	return {
		width = width,
		height = height,
		vulkan_format = "r32g32b32a32_sfloat",
		data = outputData,
		buffer = Buffer.New(outputData, outputSize),
	}
end

local exr = {}
exr.DecodeBuffer = exrImage
exr.file_extensions = {"exr"}
return exr
