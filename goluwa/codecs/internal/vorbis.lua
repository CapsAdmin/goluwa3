local bit = require("bit")
local ffi = require("ffi")
local Buffer = import("goluwa/structs/buffer.lua")
local vorbis = {}
local ffi_cast = ffi.cast
local ffi_copy = ffi.copy
local ffi_fill = ffi.fill
local float_size = ffi.sizeof("float")
local bit_band = bit.band
local bit_lshift = bit.lshift
local bit_rshift = bit.rshift
local math_pi = math.pi
local math_cos = math.cos
local math_sin = math.sin
local math_min = math.min
local math_floor = math.floor
local FAST_DECODE_TABLE_MAX_BITS = 10

local function assertf(cond, fmt, ...)
	if cond then return cond end

	error(string.format(fmt, ...), 2)
end

-- Vorbis uses a custom float encoding, NOT IEEE 754
-- See Vorbis I spec section 9.2.1
local function float32_unpack(val)
	local mant = bit.band(val, 0x1fffff) -- 21-bit mantissa
	local sign = bit.band(val, 0x80000000) -- sign bit
	local exp = bit.rshift(bit.band(val, 0x7fe00000), 21) -- 10-bit exponent
	if sign ~= 0 then mant = -mant end

	return mant * (2 ^ (exp - 788))
end

local function ilog(v)
	local ret = 0

	while v > 0 do
		ret = ret + 1
		v = bit.rshift(v, 1)
	end

	return ret
end

local function lookup1_values(entries, dimensions)
	local r = math.floor(math.exp(math.log(entries) / dimensions))

	if (r + 1) ^ dimensions <= entries then r = r + 1 end

	return r
end

local function bit_reverse32(n)
	n = bit.bor(bit.rshift(bit.band(n, 0xAAAAAAAA), 1), bit.lshift(bit.band(n, 0x55555555), 1))
	n = bit.bor(bit.rshift(bit.band(n, 0xCCCCCCCC), 2), bit.lshift(bit.band(n, 0x33333333), 2))
	n = bit.bor(bit.rshift(bit.band(n, 0xF0F0F0F0), 4), bit.lshift(bit.band(n, 0x0F0F0F0F), 4))
	n = bit.bor(bit.rshift(bit.band(n, 0xFF00FF00), 8), bit.lshift(bit.band(n, 0x00FF00FF), 8))
	return bit.tobit(bit.bor(bit.rshift(n, 16), bit.lshift(n, 16)))
end

local function trunc_div(a, b)
	if a < 0 then return math.ceil(a / b) end

	return math.floor(a / b)
end

local function reader_bit_pos(reader)
	local bit_pos = reader.Position * 8 - reader.buf_nbit

	if bit_pos < 0 then return 0 end

	return bit_pos
end

local function reader_set_bit_pos(reader, bit_pos)
	if bit_pos <= 0 then
		reader.Position = 0
		reader.buf_nbit = 0
		reader.buf_byte = 0
		return
	end

	local byte_pos = math_floor(bit_pos / 8)
	local bit_offset = bit_pos % 8

	if bit_offset == 0 then
		reader.Position = byte_pos
		reader.buf_nbit = 0
	else
		reader.Position = byte_pos + 1
		reader.buf_nbit = 8 - bit_offset
	end

	reader.buf_byte = 0
end

local function reader_peek_bits_at(reader, bit_pos, nbits)
	local buffer = reader.Buffer
	local byte_pos = math_floor(bit_pos / 8)
	local bit_offset = bit_pos % 8

	if nbits > 0 and bit_offset + nbits <= 32 and byte_pos + 3 < reader.ByteSize then
		local word = buffer[byte_pos] + bit_lshift(buffer[byte_pos + 1], 8) + bit_lshift(buffer[byte_pos + 2], 16) + bit_lshift(buffer[byte_pos + 3], 24)
		local shifted = bit_rshift(word, bit_offset)

		if nbits == 32 then return shifted end

		return bit_band(shifted, bit_lshift(1, nbits) - 1)
	end

	local out = 0
	local out_shift = 0
	local remaining = nbits
	local current_bit_pos = bit_pos

	while remaining > 0 do
		byte_pos = math_floor(current_bit_pos / 8)
		bit_offset = current_bit_pos % 8
		local chunk = math_min(remaining, 8 - bit_offset)
		local byte = buffer[byte_pos]
		local mask = bit_rshift(0xff, 8 - chunk)
		local chunk_bits = bit_band(bit_rshift(byte, bit_offset), mask)
		out = out + chunk_bits * (2 ^ out_shift)
		current_bit_pos = current_bit_pos + chunk
		out_shift = out_shift + chunk
		remaining = remaining - chunk
	end

	return out
end

local function decode_codebook_table_entry(book, reader)
	if not book then return nil end

	local bit_pos = reader_bit_pos(reader)
	local remaining = reader.ByteSize * 8 - bit_pos

	if remaining <= 0 then return nil end

	if not book.fast_len then
		book.fast_len = math_min(10, book.max_code_len)
		book.fast_mask = (2 ^ book.fast_len) - 1
	end

	local peek_fast = math_min(book.fast_len, remaining)
	local val_fast = reader_peek_bits_at(reader, bit_pos, peek_fast)

	if book.dec_table_len then
		local mask = book.fast_mask
		local idx = bit_band(val_fast, mask)
		local entry_len = book.dec_table_len[idx]

		if entry_len > 0 and entry_len <= peek_fast then
			reader_set_bit_pos(reader, bit_pos + entry_len)
			return book.dec_table_val[idx] - 1
		end
	end

	local peek_len = math_min(book.max_code_len, remaining)
	local val = reader_peek_bits_at(reader, bit_pos, peek_len)
	local decode_lengths = book.decode_lengths
	local decode_tables_dense = book.decode_tables_dense
	local decode_masks_dense = book.decode_masks_dense

	for i = 1, #decode_lengths do
		local len = decode_lengths[i]

		if len > peek_len then break end

		if len > 10 then
			local entry = decode_tables_dense[i][bit_band(val, decode_masks_dense[i])]

			if entry then
				reader_set_bit_pos(reader, bit_pos + len)
				return entry.value - 1
			end
		end
	end

	return nil
end

function vorbis.DecodeCodebookEntry(book, reader)
	local entry = decode_codebook_table_entry(book, reader)

	if not entry then return nil end

	return entry
end

function vorbis.DecodeCodebookVector(book, reader)
	local table_entry = decode_codebook_table_entry(book, reader)

	if not table_entry then return nil end

	local entry_idx = table_entry
	local lookup_entry = entry_idx

	if not entry_idx then return nil end

	if book.lookup_vectors_flat then
		return book.lookup_vectors_flat, lookup_entry * book.dimensions, book.dimensions
	end

	if book.lookup_vectors then return book.lookup_vectors[lookup_entry + 1] end

	if book.zero_vector then return book.zero_vector end

	local dim = book.dimensions
	local res = {}

	if book.lookup_type == 1 then
		local last = 0
		local lookup_offset = lookup_entry

		for j = 1, dim do
			local mult_idx = lookup_offset % book.lookup_values
			local mult = book.multiplicands[mult_idx + 1]
			local val = mult * book.delta_value + book.minimum_value + last
			res[j] = val

			if book.sequence_p then last = val end

			lookup_offset = math.floor(lookup_offset / book.lookup_values)
		end
	elseif book.lookup_type == 2 then
		local last = 0

		for j = 1, dim do
			local mult = book.multiplicands[lookup_entry * dim + j]
			local val = mult * book.delta_value + book.minimum_value + last
			res[j] = val

			if book.sequence_p then last = val end
		end
	else
		-- No VQ lookup table (lookup_type 0)
		-- This codebook has no vector quantization - it's a scalar codebook
		-- used only for Huffman classification. Should not be called for VQ decode.
		-- Return zeros to avoid corrupting spectral data.
		for j = 1, dim do
			res[j] = 0
		end
	end

	return res
end

-- 1. IDENTIFICATION HEADER (Already partially handled in ogg_new.lua, but let's centralize)
function vorbis.DecodeIdentification(packet)
	local reader = type(packet) == "string" and
		Buffer.New(packet, #packet) or
		Buffer.New(packet:GetBuffer(), packet.ByteSize or packet:GetSize())
	reader:RestartReadBits()
	local type = reader:Read(8) -- Should be 1
	local magic = ""

	for i = 1, 6 do
		magic = magic .. string.char(reader:Read(8))
	end

	if magic ~= "vorbis" then return nil, "Invalid magic" end

	local info = {}
	info.vorbis_version = reader:Read(32)
	info.channels = reader:Read(8)
	info.sample_rate = reader:Read(32)
	info.bitrate_max = reader:Read(32)
	info.bitrate_nominal = reader:Read(32)
	info.bitrate_min = reader:Read(32)
	local block_sizes = reader:Read(8)
	info.blocksize_0 = 2 ^ bit.band(block_sizes, 0x0F)
	info.blocksize_1 = 2 ^ bit.rshift(bit.band(block_sizes, 0xF0), 4)
	-- Store for later use in packet decoding
	info.exponent_0 = bit.band(block_sizes, 0x0F)
	info.exponent_1 = bit.rshift(bit.band(block_sizes, 0xF0), 4)
	info.framing_flag = reader:Read(1)
	return info
end

-- 2. COMMENT HEADER (Packet type 3)
function vorbis.DecodeComment(packet)
	local reader = type(packet) == "string" and
		Buffer.New(packet, #packet) or
		Buffer.New(packet:GetBuffer(), packet.ByteSize or packet:GetSize())
	reader:RestartReadBits()
	reader:Read(8) -- Type 3
	reader:Read(48) -- "vorbis"
	local comments = {}
	local vendor_len = reader:Read(32)
	local vendor = "" -- actually vendor_len bytes
	for i = 1, vendor_len do
		vendor = vendor .. string.char(reader:Read(8))
	end

	comments.vendor = vendor
	local list_len = reader:Read(32)

	for i = 1, list_len do
		local len = reader:Read(32)
		local comment = ""

		for j = 1, len do
			comment = comment .. string.char(reader:Read(8))
		end

		table.insert(comments, comment)
	end

	return comments
end

-- 3. SETUP HEADER (Packet type 5) - Complex
-- This includes Codebooks, Time-domain transforms, Floors, Residues, Mappings, and Modes.
function vorbis.DecodeSetup(packet, info)
	local reader = type(packet) == "string" and
		Buffer.New(packet, #packet) or
		Buffer.New(packet:GetBuffer(), packet.ByteSize or packet:GetSize())
	reader:RestartReadBits()
	local type_ = reader:Read(8) -- Type 5
	if type_ ~= 5 then return nil, "Invalid setup packet" end

	local magic = ""

	for i = 1, 6 do
		magic = magic .. string.char(reader:Read(8))
	end

	if magic ~= "vorbis" then return nil, "Invalid magic" end

	local setup = {}
	-- 1. Codebooks
	local codebook_count = reader:Read(8) + 1
	setup.codebooks = {}

	for i = 0, codebook_count - 1 do
		local cb = {}
		local sync = reader:Read(24)

		if sync ~= 0x564342 then return nil, "Invalid codebook sync" end

		cb.dimensions = reader:Read(16)
		cb.entries = reader:Read(24)
		assertf(cb.dimensions >= 1, "Invalid codebook dimensions: %d", cb.dimensions)
		assertf(cb.entries >= 1, "Invalid codebook entries: %d", cb.entries)
		-- Codebook length list
		local ordered = reader:Read(1) == 1
		cb.lengths = {}

		if not ordered then
			local sparse = reader:Read(1) == 1

			for j = 1, cb.entries do
				if sparse then
					if reader:Read(1) == 1 then
						cb.lengths[j] = reader:Read(5) + 1
					else
						cb.lengths[j] = false -- changed from 0 to false for clarity
					end
				else
					cb.lengths[j] = reader:Read(5) + 1
				end
			end
		else
			local current_length = reader:Read(5) + 1
			local j = 1

			while j <= cb.entries do
				local remaining_entries = cb.entries - j + 1
				local bits = ilog(remaining_entries)
				local count = reader:ReadBits(bits)
				assertf(count, "Truncated ordered codebook length run at entry %d/%d", j, cb.entries)
				assertf(
					count <= remaining_entries,
					"Invalid ordered codebook length run: count=%d remaining=%d at entry %d/%d",
					count,
					remaining_entries,
					j,
					cb.entries
				)

				for k = 1, count do
					if j <= cb.entries then
						cb.lengths[j] = current_length
						j = j + 1
					end
				end

				current_length = current_length + 1
			end
		end

		-- Value lookup table
		local lookup_type = reader:Read(4)
		cb.lookup_type = lookup_type
		assertf(lookup_type >= 0 and lookup_type <= 2, "Unsupported lookup type: %d", lookup_type)

		if lookup_type > 0 then
			cb.minimum_value = float32_unpack(reader:Read(32))
			cb.delta_value = float32_unpack(reader:Read(32))
			cb.value_bits = reader:Read(4) + 1
			cb.sequence_p = reader:Read(1) == 1
			local lookup_values_count = 0

			if lookup_type == 1 then
				lookup_values_count = lookup1_values(cb.entries, cb.dimensions)
			else
				lookup_values_count = cb.entries * cb.dimensions
			end

			cb.lookup_values = lookup_values_count
			cb.multiplicands = {}
			assertf(lookup_values_count >= 0, "Invalid lookup_values_count: %d", lookup_values_count)

			for j = 1, lookup_values_count do
				cb.multiplicands[j] = reader:Read(cb.value_bits)
			end
		end

		local max_code_len = 0

		for j = 1, cb.entries do
			local len = cb.lengths[j]

			if len and len > max_code_len then max_code_len = len end
		end

		cb.max_code_len = max_code_len

		if max_code_len > 0 then
			local available = {}
			local code_entries = {}
			local first = nil

			for j = 1, cb.entries do
				if cb.lengths[j] then
					first = j

					break
				end
			end

			assertf(first, "Codebook has max len but no entries")
			table.insert(code_entries, {reversed = 0, len = cb.lengths[first], value = first})

			for j = 1, cb.lengths[first] do
				available[j] = 2 ^ (32 - j)
			end

			for j = first + 1, cb.entries do
				local len = cb.lengths[j]

				if len then
					local z = len

					while z > 0 and not available[z] do
						z = z - 1
					end

					assertf(z > 0, "Invalid Huffman tree in codebook")
					local res = available[z]
					available[z] = nil
					local reversed = bit.band(bit_reverse32(res), 2 ^ len - 1)
					table.insert(code_entries, {reversed = reversed, len = len, value = j})

					if z ~= len then
						for y = len, z + 1, -1 do
							assertf(not available[y], "Duplicate available leaf at depth %d", y)
							available[y] = res + 2 ^ (32 - y)
						end
					end
				end
			end

			for i = 1, #code_entries do
				local code_entry = code_entries[i]
				local len = code_entry.len
				local decode_table = cb.decode_tables and cb.decode_tables[len]

				if not decode_table then
					cb.decode_tables = cb.decode_tables or {}
					cb.decode_lengths = cb.decode_lengths or {}
					cb.decode_masks = cb.decode_masks or {}
					decode_table = {}
					cb.decode_tables[len] = decode_table
					cb.decode_lengths[#cb.decode_lengths + 1] = len
					cb.decode_masks[len] = 2 ^ len - 1
				end

				decode_table[code_entry.reversed] = code_entry
			end

			local fast_len = math.min(max_code_len, FAST_DECODE_TABLE_MAX_BITS)
			local dec_table_len = ffi.new("uint8_t[?]", 2 ^ fast_len)
			local dec_table_val = ffi.new("uint32_t[?]", 2 ^ fast_len)

			for i = 1, #code_entries do
				local code_entry = code_entries[i]

				if code_entry.len <= fast_len then
					local span = bit_lshift(1, code_entry.len)
					local fill_count = bit_lshift(1, fast_len - code_entry.len)
					local idx = code_entry.reversed

					for _ = 1, fill_count do
						dec_table_len[idx] = code_entry.len
						dec_table_val[idx] = code_entry.value
						idx = idx + span
					end
				end
			end

			cb.dec_table_len = dec_table_len
			cb.dec_table_val = dec_table_val
			table.sort(cb.decode_lengths)
			cb.decode_tables_dense = {}
			cb.decode_masks_dense = {}

			for i = 1, #cb.decode_lengths do
				local len = cb.decode_lengths[i]
				cb.decode_tables_dense[i] = cb.decode_tables[len]
				cb.decode_masks_dense[i] = cb.decode_masks[len]
			end

			if cb.lookup_type == 0 then
				cb.zero_vector = ffi.new("float[?]", cb.dimensions)
			else
				cb.lookup_vectors_flat = ffi.new("float[?]", cb.entries * cb.dimensions)

				for i = 1, #code_entries do
					local code_entry = code_entries[i]
					local lookup_entry = code_entry.value - 1
					local base = lookup_entry * cb.dimensions

					if cb.lookup_type == 1 then
						local last = 0
						local lookup_offset = lookup_entry

						for j = 1, cb.dimensions do
							local mult_idx = lookup_offset % cb.lookup_values
							local mult = cb.multiplicands[mult_idx + 1]
							local val = mult * cb.delta_value + cb.minimum_value + last
							cb.lookup_vectors_flat[base + j - 1] = val

							if cb.sequence_p then last = val end

							lookup_offset = math.floor(lookup_offset / cb.lookup_values)
						end
					else
						local last = 0

						for j = 1, cb.dimensions do
							local mult = cb.multiplicands[lookup_entry * cb.dimensions + j]
							local val = mult * cb.delta_value + cb.minimum_value + last
							cb.lookup_vectors_flat[base + j - 1] = val

							if cb.sequence_p then last = val end
						end
					end
				end
			end
		end

		setup.codebooks[i + 1] = cb
	end

	-- 2. Time-domain transforms (placeholder/zeros)
	local time_count = reader:Read(6) + 1

	for i = 1, time_count do
		reader:Read(16)
	end -- always zeros in Vorbis I
	-- 3. Floors
	local floor_count = reader:Read(6) + 1
	setup.floors = {}

	for i = 1, floor_count do
		local floor_type = reader:Read(16)

		if floor_type == 0 then
			local floor0 = {type = 0}
			floor0.order = reader:Read(8)
			floor0.rate = reader:Read(16)
			floor0.bark_map_size = reader:Read(16)
			floor0.amplitude_bits = reader:Read(6)
			floor0.amplitude_offset = reader:Read(8)
			floor0.num_books = reader:Read(4) + 1
			floor0.books = {}

			for j = 1, floor0.num_books do
				floor0.books[j] = reader:Read(8)
			end

			setup.floors[i] = floor0
		elseif floor_type == 1 then
			-- Floor type 1 logic (most common)
			local floor = {type = 1}
			local partitions = reader:Read(5)
			floor.partition_class = {}
			local max_class = -1

			for j = 1, partitions do
				local class_idx = reader:Read(4)
				floor.partition_class[j] = class_idx

				if class_idx > max_class then max_class = class_idx end
			end

			floor.class_dimensions = {}
			floor.class_subclasses = {}
			floor.class_masterbook = {}
			floor.subclass_books = {}

			for j = 0, max_class do
				floor.class_dimensions[j] = reader:Read(3) + 1
				floor.class_subclasses[j] = reader:Read(2)

				if floor.class_subclasses[j] > 0 then
					floor.class_masterbook[j] = reader:Read(8)
				end

				floor.subclass_books[j] = {}

				for k = 1, 2 ^ floor.class_subclasses[j] do
					floor.subclass_books[j][k] = reader:Read(8) - 1
				end
			end

			floor.multiplier = reader:Read(2) + 1
			floor.rangebits = reader:Read(4)
			floor.x_list = {0, 2 ^ floor.rangebits}
			local sort_list = {{x = 0, original_index = 1}, {x = 2 ^ floor.rangebits, original_index = 2}}

			for j = 1, partitions do
				local class_idx = floor.partition_class[j]
				local dim = floor.class_dimensions[class_idx]

				for k = 1, dim do
					local val = reader:Read(floor.rangebits)
					table.insert(floor.x_list, val)
					table.insert(sort_list, {x = val, original_index = #floor.x_list})
				end
			end

			-- Sort x_list but keep track of indices for neighbor logic
			table.sort(sort_list, function(a, b)
				return a.x < b.x
			end)

			floor.sorted_indices = {}

			for idx, item in ipairs(sort_list) do
				floor.sorted_indices[idx] = item.original_index or idx
			end

			-- Precompute neighbors for lookup
			floor.neighbors = {}

			for j = 1, #floor.x_list do
				local low, high = -1, -1
				local low_val, high_val = -1, 2 ^ floor.rangebits + 1

				for k = 1, j - 1 do
					if floor.x_list[k] < floor.x_list[j] and floor.x_list[k] > low_val then
						low = k - 1
						low_val = floor.x_list[k]
					end

					if floor.x_list[k] > floor.x_list[j] and floor.x_list[k] < high_val then
						high = k - 1
						high_val = floor.x_list[k]
					end
				end

				floor.neighbors[j] = {low = low, high = high}
			end

			floor.sorted_x = sort_list
			setup.floors[i] = floor
		end
	end

	-- 4. Residues
	local residue_count = reader:Read(6) + 1
	setup.residues = {}

	for i = 1, residue_count do
		local res = {type = reader:Read(16)}
		assertf(res.type >= 0 and res.type <= 2, "Unsupported residue type: %d", res.type)
		res.begin = reader:Read(24)
		res.end_ = reader:Read(24)
		res.partition_size = reader:Read(24) + 1
		res.classifications = reader:Read(6) + 1
		res.classbook = reader:Read(8)
		assertf(res.end_ >= res.begin, "Residue end before begin: %d < %d", res.end_, res.begin)
		assertf(res.partition_size >= 1, "Invalid residue partition_size: %d", res.partition_size)
		res.cascade = {}

		for j = 1, res.classifications do
			local b = reader:Read(3)

			if reader:Read(1) == 1 then b = b + reader:Read(5) * 8 end

			res.cascade[j] = b
		end

		res.books = {}

		for j = 1, res.classifications do
			for k = 0, 7 do
				if bit.band(res.cascade[j], bit.lshift(1, k)) ~= 0 then
					res.books[j * 8 + k] = reader:Read(8)
				end
			end
		end

		setup.residues[i] = res
	end

	-- 5. Mappings
	local mapping_count = reader:Read(6) + 1
	setup.mappings = {}

	for i = 1, mapping_count do
		local map = {type = reader:Read(16)}

		if map.type == 0 then
			local submaps = 1

			if reader:Read(1) == 1 then submaps = reader:Read(4) + 1 end

			map.submaps = submaps
			map.coupling = {}

			if reader:Read(1) == 1 then
				local steps = reader:Read(8) + 1

				for j = 1, steps do
					local bits = ilog(info.channels - 1)
					local mag = reader:Read(bits)
					local ang = reader:Read(bits)
					assertf(
						mag < info.channels and ang < info.channels,
						"Invalid coupling pair: %d/%d for %d channels",
						mag,
						ang,
						info.channels
					)
					assertf(mag ~= ang, "Invalid coupling pair with identical channels: %d", mag)
					map.coupling[j] = {magnitude = mag, angle = ang}
				end
			end

			if reader:Read(2) ~= 0 then return nil, "Mapping reserved field non-zero" end

			if submaps > 1 then
				map.mux = {}

				for j = 1, info.channels do
					map.mux[j] = reader:Read(4)
					assertf(map.mux[j] < submaps, "Invalid channel mux %d for submaps=%d", map.mux[j], submaps)
				end
			end

			map.submap_floor = {}
			map.submap_residue = {}

			for j = 1, submaps do
				reader:Read(8) -- unused
				map.submap_floor[j] = reader:Read(8)
				map.submap_residue[j] = reader:Read(8)
				assertf(
					map.submap_floor[j] < floor_count,
					"Invalid floor index %d for floor_count=%d",
					map.submap_floor[j],
					floor_count
				)
				assertf(
					map.submap_residue[j] < residue_count,
					"Invalid residue index %d for residue_count=%d",
					map.submap_residue[j],
					residue_count
				)
			end

			map.submap_channels = {}

			for j = 1, submaps do
				map.submap_channels[j] = {}
			end

			for j = 1, info.channels do
				local submap_idx = (submaps > 1) and ((map.mux[j] or 0) + 1) or 1
				local channels_for_submap = map.submap_channels[submap_idx]
				channels_for_submap[#channels_for_submap + 1] = j
			end

			setup.mappings[i] = map
		else
			print("Warning: Unsupported mapping type:", map.type)
		end
	end

	-- 6. Modes
	local mode_count = reader:Read(6) + 1
	setup.modes = {}

	for i = 1, mode_count do
		setup.modes[i] = {
			blockflag = reader:Read(1) == 1,
			windowtype = reader:Read(16),
			transformtype = reader:Read(16),
			mapping = reader:Read(8),
		}
	end

	if reader:Read(1) ~= 1 then return nil, "Framing flag missing" end

	return setup
end

-- Vorbis Window functions
function vorbis.GetWindow(n, type)
	local window = ffi.new("float[?]", n)

	if type == 0 then -- Vorbis window
		for i = 0, n - 1 do
			local s = math.sin((math.pi / n) * (i + 0.5))
			window[i] = math.sin(0.5 * math.pi * s * s)
		end
	end

	return window
end

-- Vorbis I spec section 7.2.1: range depends on multiplier, NOT rangebits
local floor1_range_list = {256, 128, 86, 64}
local floor1_inverse_db_table = ffi.new(
	"float[256]",
	{
		1.0649863e-07,
		1.1341951e-07,
		1.2079015e-07,
		1.2863978e-07,
		1.3699951e-07,
		1.4590251e-07,
		1.5538408e-07,
		1.6548181e-07,
		1.7623575e-07,
		1.8768855e-07,
		1.9988561e-07,
		2.128753e-07,
		2.2670913e-07,
		2.4144197e-07,
		2.5713223e-07,
		2.7384213e-07,
		2.9163793e-07,
		3.1059021e-07,
		3.3077411e-07,
		3.5226968e-07,
		3.7516214e-07,
		3.9954229e-07,
		4.2550680e-07,
		4.5315863e-07,
		4.8260743e-07,
		5.1396998e-07,
		5.4737065e-07,
		5.8294187e-07,
		6.2082472e-07,
		6.6116941e-07,
		7.0413592e-07,
		7.4989464e-07,
		7.9862701e-07,
		8.5052630e-07,
		9.0579828e-07,
		9.6466216e-07,
		1.0273513e-06,
		1.0941144e-06,
		1.1652161e-06,
		1.2409384e-06,
		1.3215816e-06,
		1.4074654e-06,
		1.4989305e-06,
		1.5963394e-06,
		1.7000785e-06,
		1.8105592e-06,
		1.9282195e-06,
		2.0535261e-06,
		2.1869758e-06,
		2.3290978e-06,
		2.4804557e-06,
		2.6416497e-06,
		2.8133190e-06,
		2.9961443e-06,
		3.1908506e-06,
		3.3982101e-06,
		3.6190449e-06,
		3.8542308e-06,
		4.1047004e-06,
		4.3714470e-06,
		4.6555282e-06,
		4.9580707e-06,
		5.2802740e-06,
		5.6234160e-06,
		5.9888572e-06,
		6.3780469e-06,
		6.7925283e-06,
		7.2339451e-06,
		7.7040476e-06,
		8.2047000e-06,
		8.7378876e-06,
		9.3057248e-06,
		9.9104632e-06,
		1.0554501e-05,
		1.1240392e-05,
		1.1970856e-05,
		1.2748789e-05,
		1.3577278e-05,
		1.4459606e-05,
		1.5399272e-05,
		1.6400004e-05,
		1.7465768e-05,
		1.8600792e-05,
		1.9809576e-05,
		2.1096914e-05,
		2.2467911e-05,
		2.3928002e-05,
		2.5482978e-05,
		2.7139006e-05,
		2.8902651e-05,
		3.0780908e-05,
		3.2781225e-05,
		3.4911534e-05,
		3.7180282e-05,
		3.9596466e-05,
		4.2169667e-05,
		4.4910090e-05,
		4.7828601e-05,
		5.0936773e-05,
		5.4246931e-05,
		5.7772202e-05,
		6.1526565e-05,
		6.5524908e-05,
		6.9783085e-05,
		7.4317983e-05,
		7.9147585e-05,
		8.4291040e-05,
		8.9768747e-05,
		9.5602426e-05,
		0.00010181521,
		0.00010843174,
		0.00011547824,
		0.00012298267,
		0.00013097477,
		0.00013948625,
		0.00014855085,
		0.00015820453,
		0.00016848555,
		0.00017943469,
		0.00019109536,
		0.00020351382,
		0.00021673929,
		0.00023082423,
		0.00024582449,
		0.00026179955,
		0.00027881276,
		0.00029693158,
		0.00031622787,
		0.00033677814,
		0.00035866388,
		0.00038197188,
		0.00040679456,
		0.00043323036,
		0.00046138411,
		0.00049136745,
		0.00052329927,
		0.00055730621,
		0.00059352311,
		0.00063209358,
		0.00067317058,
		0.00071691700,
		0.00076350630,
		0.00081312324,
		0.00086596457,
		0.00092223983,
		0.00098217216,
		0.0010459992,
		0.0011139742,
		0.0011863665,
		0.0012634633,
		0.0013455702,
		0.0014330129,
		0.0015261382,
		0.0016253153,
		0.0017309374,
		0.0018434235,
		0.0019632195,
		0.0020908006,
		0.0022266726,
		0.0023713743,
		0.0025254795,
		0.0026895994,
		0.0028643847,
		0.0030505286,
		0.0032487691,
		0.0034598925,
		0.0036847358,
		0.0039241906,
		0.0041792066,
		0.0044507950,
		0.0047400328,
		0.0050480668,
		0.0053761186,
		0.0057254891,
		0.0060975636,
		0.0064938176,
		0.0069158225,
		0.0073652516,
		0.0078438871,
		0.0083536271,
		0.0088964928,
		0.009474637,
		0.010090352,
		0.010746080,
		0.011444421,
		0.012188144,
		0.012980198,
		0.013823725,
		0.014722068,
		0.015678791,
		0.016697687,
		0.017782797,
		0.018938423,
		0.020169149,
		0.021479854,
		0.022875735,
		0.024362330,
		0.025945531,
		0.027631618,
		0.029427276,
		0.031339626,
		0.033376252,
		0.035545228,
		0.037855157,
		0.040315199,
		0.042935108,
		0.045725273,
		0.048696758,
		0.051861348,
		0.055231591,
		0.058820850,
		0.062643361,
		0.066714279,
		0.071049749,
		0.075666962,
		0.080584227,
		0.085821044,
		0.091398179,
		0.097337747,
		0.10366330,
		0.11039993,
		0.11757434,
		0.12521498,
		0.13335215,
		0.14201813,
		0.15124727,
		0.16107617,
		0.17154380,
		0.18269168,
		0.19456402,
		0.20720788,
		0.22067342,
		0.23501402,
		0.25028656,
		0.26655159,
		0.28387361,
		0.30232132,
		0.32196786,
		0.34289114,
		0.36517414,
		0.38890521,
		0.41417847,
		0.44109412,
		0.46975890,
		0.50028648,
		0.53279791,
		0.56742212,
		0.60429640,
		0.64356699,
		0.68538959,
		0.72993007,
		0.77736504,
		0.82788260,
		0.88168307,
		0.9389798,
		1.0,
	}
)

function vorbis.DecodeFloorType1(reader, setup, floor, n)
	local partitions = #floor.partition_class
	local range = floor1_range_list[floor.multiplier]
	local y_bits = ilog(range - 1)
	local posts = {}
	posts[0 + 1] = reader:Read(y_bits)
	posts[1 + 1] = reader:Read(y_bits)

	for i = 1, partitions do
		local class_idx = floor.partition_class[i]
		local dim = floor.class_dimensions[class_idx]
		local subclass = floor.class_subclasses[class_idx]
		local subclass_mask = (2 ^ subclass) - 1
		local masterbook = floor.class_masterbook[class_idx]
		local c = 0

		if subclass > 0 then
			c = vorbis.DecodeCodebookEntry(setup.codebooks[masterbook + 1], reader) or 0
		end

		for j = 1, dim do
			local book_idx = floor.subclass_books[class_idx][bit.band(c, subclass_mask) + 1]
			c = bit.rshift(c, subclass)

			if book_idx >= 0 then
				local entry = vorbis.DecodeCodebookEntry(setup.codebooks[book_idx + 1], reader) or 0
				posts[#posts + 1] = entry
			else
				posts[#posts + 1] = 0
			end
		end
	end

	-- Floor 1 synthesis: compute final_Y values with step2_flag (Vorbis I spec section 7.2.2)
	local n2 = n / 2
	local res = ffi.new("float[?]", n2)
	local final_posts = {}
	local step2_flag = {}
	final_posts[1] = posts[1]
	final_posts[2] = posts[2]
	step2_flag[1] = true
	step2_flag[2] = true

	for i = 3, #posts do
		local val = posts[i]
		local low_idx = (floor.neighbors[i] and floor.neighbors[i].low or 0) + 1
		local high_idx = (floor.neighbors[i] and floor.neighbors[i].high or 1) + 1
		local predicted = vorbis.RenderPoint(
			floor.x_list[low_idx],
			final_posts[low_idx],
			floor.x_list[high_idx],
			final_posts[high_idx],
			floor.x_list[i]
		)
		local highroom = range - predicted
		local lowroom = predicted
		local room

		if lowroom < highroom then
			room = lowroom * 2
		else
			room = highroom * 2
		end

		if val ~= 0 then
			step2_flag[low_idx] = true
			step2_flag[high_idx] = true
			step2_flag[i] = true

			if val >= room then
				if highroom > lowroom then
					final_posts[i] = val - lowroom + predicted
				else
					final_posts[i] = predicted - val + highroom - 1
				end
			else
				if bit.band(val, 1) == 1 then -- odd
					final_posts[i] = predicted - math.floor((val + 1) / 2)
				else -- even
					final_posts[i] = predicted + math.floor(val / 2)
				end
			end
		else
			step2_flag[i] = false
			final_posts[i] = predicted
		end
	end

	-- Floor curve synthesis with step2_flag (Vorbis I spec section 7.2.3)
	-- Iterate through sorted posts, drawing lines only between active (step2_flag) posts
	local sorted_indices = floor.sorted_indices
	local lx = 0
	local ly = final_posts[1] * floor.multiplier -- post 0 is always at X=0, always active
	ly = math.max(0, math.min(ly, 255))
	local segments_rendered = 0

	for si = 2, #sorted_indices do
		local idx = sorted_indices[si]

		if step2_flag[idx] then
			local hx = math.min(floor.x_list[idx], n2)
			local hy = final_posts[idx] * floor.multiplier
			hy = math.max(0, math.min(hy, 255))

			if lx < hx then
				vorbis.RenderLine(n2, lx, hx, ly, hy, res, floor1_inverse_db_table)
			end

			segments_rendered = segments_rendered + 1
			lx = hx
			ly = hy
		end
	end

	-- Fill remaining range with last active Y value
	if lx < n2 then
		local db_val = floor1_inverse_db_table[math.min(ly, 255)] or 0

		for x = lx, n2 - 1 do
			res[x] = db_val
		end
	end

	return res
end

function vorbis.RenderPoint(x0, y0, x1, y1, x)
	local dy = y1 - y0
	local ady = math.abs(dy)
	local dx = x1 - x0
	local err = ady * (x - x0)
	local off = math.floor(err / dx)

	if dy < 0 then return y0 - off end

	return y0 + off
end

function vorbis.RenderLine(n, x0, x1, y0, y1, out, lookup)
	local dy = y1 - y0
	local adx = x1 - x0
	local ady = math.abs(dy)
	local base = trunc_div(dy, adx)
	local sy = dy < 0 and (base - 1) or (base + 1)
	local x = x0
	local y = y0
	local err = 0
	ady = ady - math.abs(base * adx)

	if n > x1 then n = x1 end

	if x < n then out[x] = lookup[y] end

	while true do
		x = x + 1

		if x >= n then break end

		err = err + ady

		if err >= adx then
			err = err - adx
			y = y + sy
		else
			y = y + base
		end

		out[x] = lookup[y]
	end
end

-- Decode residue types 0, 1, and 2
-- Type 2 interleaves all channels into one vector, decodes as one, then deinterleaves
-- Returns a table of per-channel FFI float arrays (1-indexed by channel)
local function get_scratch_float(state, id, size)
	state.scratch_floats = state.scratch_floats or {}
	state.scratch_floats[id] = state.scratch_floats[id] or {}

	if not state.scratch_floats[id].ptr or state.scratch_floats[id].size < size then
		state.scratch_floats[id].ptr = ffi.new("float[?]", size)
		state.scratch_floats[id].size = size
	end

	ffi.fill(state.scratch_floats[id].ptr, size * 4)
	return state.scratch_floats[id].ptr
end

function vorbis.DecodeResidue(reader, setup, res, n, ch_count, no_residue, state)
	local actual_size = n / 2
	-- For type 2, check if ALL channels have no_residue (skip entirely)
	local all_no_residue = true

	for i = 1, ch_count do
		if not no_residue[i] then
			all_no_residue = false

			break
		end
	end

	if all_no_residue then
		local result = {}

		for i = 1, ch_count do
			result[i] = get_scratch_float(state, "res_ch_" .. i, actual_size)
		end

		return result
	end

	-- For type 2, decode into one interleaved vector
	local decode_n
	local decode_ch

	if res.type == 2 then
		decode_n = actual_size * ch_count
		decode_ch = 1
	else
		decode_n = actual_size
		decode_ch = ch_count
	end

	local limit_begin = math.min(res.begin, decode_n)
	local limit_end = math.min(res.end_, decode_n)
	local n_to_read = limit_end - limit_begin

	if n_to_read <= 0 then
		local result = {}

		for i = 1, ch_count do
			result[i] = get_scratch_float(state, "res_ch_" .. i, actual_size)
		end

		return result
	end

	local partitions_to_read = math.floor(n_to_read / res.partition_size)
	local classbook = setup.codebooks[res.classbook + 1]

	if not classbook then
		local result = {}

		for i = 1, ch_count do
			result[i] = get_scratch_float(state, "res_ch_" .. i, actual_size)
		end

		return result
	end

	local classwords = classbook.dimensions
	-- Allocate decode vectors
	local vectors = {}

	for i = 1, decode_ch do
		vectors[i] = get_scratch_float(state, "res_dec_" .. i, decode_n)
	end

	-- do_not_decode per decode-channel
	local do_not_decode = {}

	if res.type == 2 then
		do_not_decode[1] = false -- type 2 always decodes the single interleaved channel
	else
		for i = 1, ch_count do
			do_not_decode[i] = no_residue[i]
		end
	end

	-- Classification storage per decode-channel
	local class_table = {}

	for i = 1, decode_ch do
		class_table[i] = {}
	end

	for pass = 0, 7 do
		local partition_count = 0

		while partition_count < partitions_to_read do
			if pass == 0 then
				for j = 1, decode_ch do
					if not do_not_decode[j] then
						local temp = vorbis.DecodeCodebookEntry(classbook, reader) or 0

						for i = classwords - 1, 0, -1 do
							if partition_count + i < partitions_to_read then
								class_table[j][partition_count + i] = temp % res.classifications
							end

							temp = math.floor(temp / res.classifications)
						end
					end
				end
			end

			for i = 0, classwords - 1 do
				if partition_count >= partitions_to_read then break end

				for j = 1, decode_ch do
					if not do_not_decode[j] then
						local vq_class = class_table[j][partition_count] or 0
						-- res.books is keyed by (1-based classification) * 8 + pass
						local vq_book_idx = res.books[(vq_class + 1) * 8 + pass]

						if vq_book_idx then
							local vq_book = setup.codebooks[vq_book_idx + 1]

							if vq_book then
								local offset = limit_begin + partition_count * res.partition_size
								local partition_end = math.min(offset + res.partition_size, decode_n)
								local vec_dim = vq_book.dimensions
								local lookup_vectors_flat = vq_book.lookup_vectors_flat
								local target = vectors[j]

								if res.type == 0 then
									-- Format 0: de-interleaved VQ
									local step = math.floor(res.partition_size / vq_book.dimensions)

									for s = 0, step - 1 do
										local table_entry = decode_codebook_table_entry(vq_book, reader)
										local entry_idx = table_entry

										if entry_idx then
											local vec_base = entry_idx * vec_dim
											local last_idx = offset + s + (vec_dim - 1) * step

											if last_idx < partition_end then
												for m = 0, vec_dim - 1 do
													local idx = offset + s + m * step
													target[idx] = target[idx] + lookup_vectors_flat[vec_base + m]
												end
											else
												for m = 0, vec_dim - 1 do
													local idx = offset + s + m * step

													if idx < partition_end then
														target[idx] = target[idx] + lookup_vectors_flat[vec_base + m]
													end
												end
											end
										end
									end
								else
									-- Format 1 (type 1 and 2): sequential VQ
									local k = 0

									while offset + k < partition_end do
										local table_entry = decode_codebook_table_entry(vq_book, reader)
										local entry_idx = table_entry

										if entry_idx then
											local vec_base = entry_idx * vec_dim
											local idx = offset + k

											if idx + vec_dim <= partition_end then
												for m = 0, vec_dim - 1 do
													target[idx] = target[idx] + lookup_vectors_flat[vec_base + m]
													idx = idx + 1
												end

												k = k + vec_dim
											else
												for m = 0, vec_dim - 1 do
													if idx >= partition_end then break end

													target[idx] = target[idx] + lookup_vectors_flat[vec_base + m]
													idx = idx + 1
													k = k + 1
												end
											end
										else
											break
										end
									end
								end
							end
						end
					end
				end

				partition_count = partition_count + 1
			end
		end
	end

	-- De
	-- For type 2, deinterleave the single vector back to per-channel
	if res.type == 2 then
		local result = {}

		for i = 1, ch_count do
			result[i] = get_scratch_float(state, "res_ch_" .. i, actual_size)
		end

		for i = 0, actual_size - 1 do
			for j = 1, ch_count do
				result[j][i] = vectors[1][i * ch_count + (j - 1)]
			end
		end

		return result
	else
		return vectors
	end
end

local function get_window(state, win_n)
	local window = state.window[win_n]

	if not window then
		window = ffi.new("float[?]", win_n)

		for i = 0, win_n - 1 do
			local s = math.sin(math.pi / win_n * (i + 0.5))
			window[i] = math.sin(0.5 * math.pi * s * s)
		end

		state.window[win_n] = window
	end

	return window
end

local function get_imdct_plan(state, n)
	state.imdct_plan = state.imdct_plan or {}
	local plan = state.imdct_plan[n]

	if not plan then
		local n2 = n / 2
		local n4 = n / 4
		-- Pre-twiddle factors: angle = pi*(4r+1)/(2N)
		local pre_cos = ffi.new("float[?]", n4)
		local pre_sin = ffi.new("float[?]", n4)

		for r = 0, n4 - 1 do
			local angle = math_pi * (4 * r + 1) / (2 * n)
			pre_cos[r] = math_cos(angle)
			pre_sin[r] = math_sin(angle)
		end

		-- Post-twiddle factors: angle = pi*k/(2*H) where H=N/4
		local post_cos = ffi.new("float[?]", n4)
		local post_sin = ffi.new("float[?]", n4)

		for k = 0, n4 - 1 do
			local angle = math_pi * k / (2 * n4)
			post_cos[k] = math_cos(angle)
			post_sin[k] = math_sin(angle)
		end

		-- FFT twiddle factors for N/4-size FFT
		local twiddle_cos = ffi.new("float[?]", n4 / 2)
		local twiddle_sin = ffi.new("float[?]", n4 / 2)

		for i = 0, n4 / 2 - 1 do
			local angle = 2 * math_pi * i / n4
			twiddle_cos[i] = math_cos(angle)
			twiddle_sin[i] = -math_sin(angle)
		end

		-- Bit-reversal table for N/4-size FFT
		local log2n4 = ilog(n4 - 1)
		local bitrev = ffi.new("uint32_t[?]", n4)

		for i = 0, n4 - 1 do
			bitrev[i] = bit.rshift(bit_reverse32(i), 32 - log2n4)
		end

		plan = {
			n = n,
			n2 = n2,
			n4 = n4,
			fft_size = n4,
			bitrev = bitrev,
			twiddle_cos = twiddle_cos,
			twiddle_sin = twiddle_sin,
			pre_cos = pre_cos,
			pre_sin = pre_sin,
			post_cos = post_cos,
			post_sin = post_sin,
			real_buffer = ffi.new("float[?]", n4),
			imag_buffer = ffi.new("float[?]", n4),
		}
		state.imdct_plan[n] = plan
	end

	return plan
end

local function get_imdct_output_buffer(state, n)
	state.imdct_output_buffer = state.imdct_output_buffer or {}
	local buffer = state.imdct_output_buffer[n]

	if not buffer then
		buffer = ffi.new("float[?]", n)
		state.imdct_output_buffer[n] = buffer
	end

	return buffer
end

local function run_fft(fft_size, real, imag, bitrev, twiddle_cos, twiddle_sin)
	for i = 0, fft_size - 1 do
		local j = bitrev[i]

		if j > i then
			local real_i = real[i]
			local imag_i = imag[i]
			real[i] = real[j]
			imag[i] = imag[j]
			real[j] = real_i
			imag[j] = imag_i
		end
	end

	local len = 2

	while len <= fft_size do
		local half = len / 2
		local twiddle_step = fft_size / len

		for offset = 0, fft_size - 1, len do
			local twiddle_idx = 0

			for j = 0, half - 1 do
				local left = offset + j
				local right = left + half
				local wr = twiddle_cos[twiddle_idx]
				local wi = twiddle_sin[twiddle_idx]
				local right_real = real[right]
				local right_imag = imag[right]
				local temp_real = right_real * wr - right_imag * wi
				local temp_imag = right_real * wi + right_imag * wr
				local left_real = real[left]
				local left_imag = imag[left]
				real[left] = left_real + temp_real
				imag[left] = left_imag + temp_imag
				real[right] = left_real - temp_real
				imag[right] = left_imag - temp_imag
				twiddle_idx = twiddle_idx + twiddle_step
			end
		end

		len = len * 2
	end
end

-- IMDCT via N/4 complex FFT
-- Folds N/2 spectral coefficients into N/4 complex numbers via pre-twiddle,
-- runs N/4-size FFT, then post-twiddles and reorders to produce the N-point output.
local function run_fast_imdct(spectrum, imdct_plan, imdct_out, n, n2)
	local n4 = imdct_plan.n4
	local real = imdct_plan.real_buffer
	local imag = imdct_plan.imag_buffer
	local pre_cos = imdct_plan.pre_cos
	local pre_sin = imdct_plan.pre_sin
	local post_cos = imdct_plan.post_cos
	local post_sin = imdct_plan.post_sin

	-- Pre-twiddle: fold N/2 spectrum into N/4 complex values
	-- w_re = spectrum[N/2-1-2r], w_im = spectrum[2r]
	-- v = (w_re*cos - w_im*sin) + j*(w_re*sin + w_im*cos)
	for r = 0, n4 - 1 do
		local wr = spectrum[n2 - 1 - 2 * r]
		local wi = spectrum[2 * r]
		local pc = pre_cos[r]
		local ps = pre_sin[r]
		real[r] = wr * pc - wi * ps
		imag[r] = wr * ps + wi * pc
	end

	-- N/4-size FFT
	run_fft(n4, real, imag, imdct_plan.bitrev, imdct_plan.twiddle_cos, imdct_plan.twiddle_sin)

	-- Post-twiddle: multiply by exp(-j * pi*k/(2*H))
	-- zt_re = Zr*cos + Zi*sin, zt_im = -Zr*sin + Zi*cos
	for k = 0, n4 - 1 do
		local re = real[k]
		local im = imag[k]
		local pc = post_cos[k]
		local ps = post_sin[k]
		real[k] = re * pc + im * ps
		imag[k] = -re * ps + im * pc
	end

	-- Output mapping: fill Q2 and Q3 directly, then derive Q1 and Q4 by symmetry
	local Q = n4 -- N/4
	local H = n4
	local H2 = H / 2
	-- Q2: imdct_out[Q .. 2Q-1]
	imdct_out[Q] = real[0]

	for m = 1, Q - 1 do
		if m % 2 == 1 then
			imdct_out[Q + m] = -real[(m + 1) / 2]
		else
			imdct_out[Q + m] = -imag[H - m / 2]
		end
	end

	-- Q3: imdct_out[2Q .. 3Q-1]
	imdct_out[2 * Q] = -imag[H2]

	for m = 1, Q - 2 do
		if m % 2 == 1 then
			imdct_out[2 * Q + m] = -real[H2 + (m + 1) / 2]
		else
			imdct_out[2 * Q + m] = -imag[H2 - m / 2]
		end
	end

	imdct_out[3 * Q - 1] = -imag[0]

	-- Q1: antisymmetric from Q2: out[Q-1-j] = -out[Q+j]
	for j = 0, Q - 1 do
		imdct_out[Q - 1 - j] = -imdct_out[Q + j]
	end

	-- Q4: symmetric from Q3: out[3Q+j] = out[3Q-1-j]
	for j = 0, Q - 1 do
		imdct_out[3 * Q + j] = imdct_out[3 * Q - 1 - j]
	end
end

local function get_packet_window(state, n, bs0, blockflag, prev_window_flag, next_window_flag)
	state.packet_window = state.packet_window or {}
	local key = table.concat({n, bs0, blockflag and 1 or 0, prev_window_flag or 0, next_window_flag or 0}, ":")
	local cached = state.packet_window[key]

	if cached then return cached end

	local left_start
	local left_end
	local right_start
	local right_end

	if blockflag and prev_window_flag == 0 then
		left_start = (n - bs0) / 4
		left_end = left_start + bs0 / 2
	else
		left_start = 0
		left_end = n / 2
	end

	if blockflag and next_window_flag == 0 then
		right_start = (n * 3 - bs0) / 4
		right_end = right_start + bs0 / 2
	else
		right_start = n / 2
		right_end = n
	end

	local left_len = left_end - left_start
	local right_len = right_end - right_start
	local left_weights = ffi.new("float[?]", math.max(left_len, 1))
	local right_weights = ffi.new("float[?]", math.max(right_len, 1))

	if left_len > 0 then
		local scale = math_pi / (2 * left_len)

		for i = 0, left_len - 1 do
			local s = math.sin((i + 0.5) * scale)
			left_weights[i] = math.sin(0.5 * math_pi * s * s)
		end
	end

	if right_len > 0 then
		local scale = math_pi / (2 * right_len)

		for i = 0, right_len - 1 do
			local s = math.sin((right_len - i - 0.5) * scale)
			right_weights[i] = math.sin(0.5 * math_pi * s * s)
		end
	end

	cached = {
		left_start = left_start,
		left_end = left_end,
		right_start = right_start,
		right_end = right_end,
		left_weights = left_weights,
		right_weights = right_weights,
	}
	state.packet_window[key] = cached
	return cached
end

local function apply_packet_window(state, samples, n, bs0, blockflag, prev_window_flag, next_window_flag)
	local window = get_packet_window(state, n, bs0, blockflag, prev_window_flag, next_window_flag)
	local left_start = window.left_start
	local left_end = window.left_end
	local right_start = window.right_start
	local right_end = window.right_end

	if left_start > 0 then ffi_fill(samples, left_start * float_size) end

	for i = left_start, left_end - 1 do
		samples[i] = samples[i] * window.left_weights[i - left_start]
	end

	for i = right_start, right_end - 1 do
		samples[i] = samples[i] * window.right_weights[i - right_start]
	end

	if right_end < n then
		ffi_fill(samples + right_end, (n - right_end) * float_size)
	end

	return left_start, left_end, right_start, right_end
end

function vorbis.DecodePacket(packet, info, setup, state)
	local reader = type(packet) == "string" and
		Buffer.New(packet, #packet) or
		Buffer.New(packet:GetBuffer(), packet.ByteSize or packet:GetSize())
	reader:RestartReadBits()

	if reader:Read(1) ~= 0 then return nil, "Not an audio packet" end

	local mode_count = #setup.modes
	local mode_bits = ilog(mode_count - 1)
	local mode_idx = reader:Read(mode_bits) + 1
	local mode = setup.modes[mode_idx]

	if not mode then return nil, "Unknown mode" end

	assertf(
		mode.mapping + 1 >= 1 and mode.mapping + 1 <= #setup.mappings,
		"Invalid mode mapping index: %d",
		mode.mapping
	)
	local n = mode.blockflag and info.blocksize_1 or info.blocksize_0
	local n2 = n / 2
	local prev_window_flag, next_window_flag

	-- Vorbis I spec section 4.3.1: long blocks have window shape flags
	if mode.blockflag then
		prev_window_flag = reader:Read(1)
		next_window_flag = reader:Read(1)
	end

	local mapping = setup.mappings[mode.mapping + 1]
	local channels = info.channels
	assertf(mapping, "Missing mapping %d", mode.mapping + 1)
	local no_residue = {}
	local floors = {}

	for i = 1, channels do
		local submap_idx = (mapping.submaps > 1) and (mapping.mux[i] or 0) + 1 or 1
		assertf(
			submap_idx >= 1 and submap_idx <= mapping.submaps,
			"Invalid submap index %d for channel %d",
			submap_idx,
			i
		)
		local floor_idx = mapping.submap_floor[submap_idx] + 1
		local floor = setup.floors[floor_idx]
		assertf(floor, "Missing floor %d for channel %d", floor_idx, i)
		local nonzero_bit = reader:Read(1)

		if nonzero_bit == 1 then
			local bp_before = reader:BitPos()
			floors[i] = vorbis.DecodeFloorType1(reader, setup, floor, n)
			no_residue[i] = false
		else
			no_residue[i] = true
		end
	end

	if mapping.coupling then
		for j = 1, #mapping.coupling do
			local mag_ch = mapping.coupling[j].magnitude + 1
			local ang_ch = mapping.coupling[j].angle + 1

			if not no_residue[mag_ch] or not no_residue[ang_ch] then
				no_residue[mag_ch] = false
				no_residue[ang_ch] = false
			end
		end
	end

	-- Reuse per-packet scratch tables from state
	state.residue_results = state.residue_results or {}
	local residue_results = state.residue_results

	for ch = 1, channels do
		residue_results[ch] = get_scratch_float(state, "pkt_res_" .. ch, n2)
	end

	local submap_no_residue_scratch = state.submap_no_residue_scratch or {}
	state.submap_no_residue_scratch = submap_no_residue_scratch

	for i = 1, mapping.submaps do
		local res_idx = mapping.submap_residue[i] + 1
		local res = setup.residues[res_idx]
		assertf(res, "Missing residue %d for submap %d", res_idx, i)

		if res then
			local submap_channels = mapping.submap_channels[i]
			local submap_no_residue = submap_no_residue_scratch[i] or {}
			submap_no_residue_scratch[i] = submap_no_residue

			for j = 1, #submap_channels do
				submap_no_residue[j] = no_residue[submap_channels[j]]
			end

			if #submap_channels > 0 then
				local vectors = vorbis.DecodeResidue(
					reader,
					setup,
					res,
					n,
					#submap_channels,
					submap_no_residue,
					state
				)

				for j = 1, #submap_channels do
					if vectors[j] then residue_results[submap_channels[j]] = vectors[j] end
				end
			end
		end
	end

	if mapping.coupling then
		for j = #mapping.coupling, 1, -1 do
			local mag_ch = mapping.coupling[j].magnitude + 1
			local ang_ch = mapping.coupling[j].angle + 1
			local mag_buf = residue_results[mag_ch]
			local ang_buf = residue_results[ang_ch]

			for k = 0, n2 - 1 do
				local m = mag_buf[k]
				local a = ang_buf[k]

				if m > 0 then
					if a > 0 then
						ang_buf[k] = m - a
						mag_buf[k] = m
					else
						ang_buf[k] = m
						mag_buf[k] = m + a
					end
				else
					if a > 0 then
						ang_buf[k] = m + a
						mag_buf[k] = m
					else
						ang_buf[k] = m
						mag_buf[k] = m - a
					end
				end
			end
		end
	end

	local bs0 = info.blocksize_0
	local output_n = 0
	local pcm
	state.previous_window = state.previous_window or {}
	state.previous_window_capacity = state.previous_window_capacity or info.blocksize_1
	state.window = state.window or {}
	local imdct_plan = get_imdct_plan(state, n)
	local next_overlap_len = 0

	for ch = 1, channels do
		local spectrum = residue_results[ch]
		local floor_data = floors[ch]
		local has_signal = false

		if floor_data then
			for i = 0, n2 - 1 do
				local value = spectrum[i] * floor_data[i]
				spectrum[i] = value

				if value ~= 0 then has_signal = true end
			end
		else
			ffi_fill(spectrum, n2 * float_size)
		end

		local imdct_out = get_imdct_output_buffer(state, n)

		if has_signal then
			run_fast_imdct(spectrum, imdct_plan, imdct_out, n, n2)
		else
			ffi_fill(imdct_out, n * float_size)
		end

		local left_start, left_end, right_start, right_end = apply_packet_window(
			state,
			imdct_out,
			n,
			bs0,
			mode.blockflag,
			prev_window_flag,
			next_window_flag
		)
		local block_output_n = right_start - left_start

		if ch == 1 then
			output_n = state.previous_length and block_output_n or 0
			pcm = get_scratch_float(state, "pkt_pcm", channels * math.max(output_n, 1))
		end

		local prev_window = state.previous_window[ch]

		if prev_window and state.previous_length then
			local overlap_len = math.min(state.previous_length, left_end - left_start)

			for i = 0, overlap_len - 1 do
				pcm[(i * channels) + (ch - 1)] = prev_window[i] + imdct_out[left_start + i]
			end

			for i = overlap_len, block_output_n - 1 do
				pcm[(i * channels) + (ch - 1)] = imdct_out[left_start + i]
			end
		end

		local next_len = right_end - right_start

		if ch == 1 then next_overlap_len = next_len end

		local next_window = state.previous_window[ch]

		if not next_window then
			next_window = ffi.new("float[?]", state.previous_window_capacity)
			state.previous_window[ch] = next_window
		end

		ffi_copy(next_window, imdct_out + right_start, next_len * float_size)
	end

	state.previous_length = next_overlap_len
	return pcm, output_n
end

if HOTRELOAD and false then
	import.loaded["goluwa/codecs/internal/vorbis.lua"] = vorbis
	import.loaded["goluwa/codecs/ogg.lua"] = nil
	local profiler = import("goluwa/profiler.lua")
	profiler.Start("ogg")
	local fs = import("goluwa/fs.lua")
	local ogg = import("goluwa/codecs/ogg.lua")
	local f = fs.read_file("./test.ogg")
	local res = assert(ogg.Decode(f))
	profiler.Stop()
end

return vorbis
