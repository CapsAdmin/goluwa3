local ffi = require("ffi")
local bit = require("bit")
local band, bor, bxor, rshift, lshift, rol = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift, bit.rol
local meshopt = {}
local byte_array_t = ffi.typeof("uint8_t[?]")
local u32_ptr_t = ffi.typeof("uint32_t *")
local u16_ptr_t = ffi.typeof("uint16_t *")
local VERTEX_BLOCK_SIZE_BYTES = 8192
local VERTEX_BLOCK_MAX_SIZE = 256
local BYTE_GROUP_SIZE = 16
local BITS_V0 = {[0] = 0, 2, 4, 8}
local BITS_V1 = {[0] = 0, 1, 2, 4, 8}
local TAIL_MIN_V0, TAIL_MIN_V1 = 32, 24

local function reverse_bits(b)
	local r = 0

	for i = 0, 7 do
		r = bor(lshift(r, 1), band(rshift(b, i), 1))
	end

	return r
end

do
	local group = byte_array_t(BYTE_GROUP_SIZE)

	-- reads one group of 16 values into out[out_pos..] and returns the new data position
	local function decode_group(data, pos, out, out_pos, bits)
		if bits == 0 then
			ffi.fill(out + out_pos, BYTE_GROUP_SIZE)
			return pos
		elseif bits == 8 then
			ffi.copy(out + out_pos, data + pos, BYTE_GROUP_SIZE)
			return pos + BYTE_GROUP_SIZE
		end

		local per_byte = 8 / bits
		local bytes = BYTE_GROUP_SIZE / per_byte
		local data_pos = pos + bytes
		local mask = lshift(1, bits) - 1
		local o = 0

		for i = 0, bytes - 1 do
			local b = data[pos + i]

			if bits == 1 then b = reverse_bits(b) end

			for _ = 1, per_byte do
				local enc = rshift(b, 8 - bits)
				b = band(lshift(b, bits), 0xff)

				if enc == mask then
					out[out_pos + o] = data[data_pos]
					data_pos = data_pos + 1
				else
					out[out_pos + o] = enc
				end

				o = o + 1
			end
		end

		return data_pos
	end

	function meshopt.DecodeBytes(data, pos, out, out_pos, count, bits_table, bits_offset)
		local header_size = math.ceil(count / BYTE_GROUP_SIZE / 4)
		local header = pos
		pos = pos + header_size

		for i = 0, count - 1, BYTE_GROUP_SIZE do
			local header_offset = i / BYTE_GROUP_SIZE
			local k = band(rshift(data[header + math.floor(header_offset / 4)], (header_offset % 4) * 2), 3)
			pos = decode_group(data, pos, out, out_pos + i, bits_table[bits_offset + k])
		end

		return pos
	end
end

local function decode_vertex_block(
	data,
	pos,
	out,
	out_pos,
	vertex_count,
	vertex_size,
	last_vertex,
	channels,
	version,
	buffer,
	transposed
)
	local aligned = math.ceil(vertex_count / BYTE_GROUP_SIZE) * BYTE_GROUP_SIZE
	local control_size = version == 0 and 0 or vertex_size / 4
	local control = pos
	pos = pos + control_size

	for k = 0, vertex_size - 1, 4 do
		local ctrl_byte = version == 0 and 0 or data[control + k / 4]

		for j = 0, 3 do
			local ctrl = band(rshift(ctrl_byte, j * 2), 3)

			if ctrl == 3 then
				ffi.copy(buffer + j * vertex_count, data + pos, vertex_count)
				pos = pos + vertex_count
			elseif ctrl == 2 then
				ffi.fill(buffer + j * vertex_count, vertex_count)
			elseif version == 0 then
				pos = meshopt.DecodeBytes(data, pos, buffer, j * vertex_count, aligned, BITS_V0, 0)
			else
				pos = meshopt.DecodeBytes(data, pos, buffer, j * vertex_count, aligned, BITS_V1, ctrl)
			end
		end

		local channel = version == 0 and 0 or channels[k / 4]
		local kind = band(channel, 3)
		local size = kind == 0 and 1 or kind == 1 and 2 or 4
		local rot = band(32 - rshift(channel, 4), 31)
		local buffer_pos = 0
		local last_pos = k

		for sub = 0, 3, size do
			local vertex_offset = k + sub
			local p = last_vertex[last_pos]

			for j = 1, size - 1 do
				p = bor(p, lshift(last_vertex[last_pos + j], 8 * j))
			end

			for i = 0, vertex_count - 1 do
				local v = buffer[buffer_pos + i]

				for j = 1, size - 1 do
					v = bor(v, lshift(buffer[buffer_pos + i + vertex_count * j], 8 * j))
				end

				if size == 1 then
					v = band(bxor(-band(v, 1), rshift(v, 1)) + p, 0xff)
				elseif size == 2 then
					v = band(bxor(-band(v, 1), rshift(v, 1)) + p, 0xffff)
				else
					v = bxor(rol(v, rot), p)
				end

				for j = 0, size - 1 do
					transposed[vertex_offset + j] = band(rshift(v, j * 8), 0xff)
				end

				p = v
				vertex_offset = vertex_offset + vertex_size
			end

			buffer_pos = buffer_pos + vertex_count * size
			last_pos = last_pos + size
		end
	end

	ffi.copy(out + out_pos, transposed, vertex_count * vertex_size)
	ffi.copy(last_vertex, transposed + vertex_size * (vertex_count - 1), vertex_size)
	return pos
end

-- data is a uint8_t pointer, returns a uint8_t array of vertex_count * vertex_size bytes
function meshopt.DecodeVertexBuffer(vertex_count, vertex_size, data, length)
	assert(band(data[0], 0xf0) == 0xa0, "invalid vertex buffer header")
	local version = band(data[0], 0x0f)
	assert(version <= 1, "unsupported vertex buffer version")
	local tail_size = vertex_size + (version == 0 and 0 or vertex_size / 4)
	local tail_pad = math.max(tail_size, version == 0 and TAIL_MIN_V0 or TAIL_MIN_V1)
	local pos = 1
	local result = byte_array_t(vertex_count * vertex_size)
	local last_vertex = byte_array_t(vertex_size)
	ffi.copy(last_vertex, data + length - tail_size, vertex_size)
	local channels = version == 0 and nil or data + length - tail_size + vertex_size
	local block_size = math.min(
		band(math.floor(VERTEX_BLOCK_SIZE_BYTES / vertex_size), -BYTE_GROUP_SIZE),
		VERTEX_BLOCK_MAX_SIZE
	)
	local buffer = byte_array_t(VERTEX_BLOCK_MAX_SIZE * 4)
	local transposed = byte_array_t(VERTEX_BLOCK_SIZE_BYTES)
	local vertex_offset = 0

	while vertex_offset < vertex_count do
		local count = math.min(block_size, vertex_count - vertex_offset)
		pos = decode_vertex_block(
			data,
			pos,
			result,
			vertex_offset * vertex_size,
			count,
			vertex_size,
			last_vertex,
			channels,
			version,
			buffer,
			transposed
		)
		vertex_offset = vertex_offset + count
	end

	assert(length - pos == tail_pad, "vertex buffer tail size incorrect")
	return result
end

function meshopt.DecodeIndexBuffer(index_count, index_size, data, length)
	assert(index_count % 3 == 0)
	assert(band(data[0], 0xf0) == 0xe0, "invalid index buffer header")
	local version = band(data[0], 0x0f)
	assert(version <= 1, "unsupported index buffer version")
	local edge_a, edge_b, vertex_fifo = {}, {}, {}

	for i = 0, 15 do
		edge_a[i], edge_b[i], vertex_fifo[i] = 0, 0, 0
	end

	local edge_offset, vertex_offset = 0, 0
	local next_index, last = 0, 0
	local fecmax = version >= 1 and 13 or 15
	local code_pos = 1
	local data_start = 1 + index_count / 3
	local position = data_start
	local data_safe_end = length - 16
	local codeaux = data_safe_end
	local out = byte_array_t(index_count * index_size)
	local out32 = ffi.cast(u32_ptr_t, out)
	local out16 = ffi.cast(u16_ptr_t, out)
	local o = 0

	local function decode_index()
		local lead = data[position]
		position = position + 1
		local v = lead

		if lead >= 128 then
			v = band(lead, 127)
			local shift = 7

			for _ = 1, 4 do
				local group = data[position]
				position = position + 1
				v = bor(v, lshift(band(group, 127), shift))
				shift = shift + 7

				if group < 128 then break end
			end
		end

		local d = bxor(rshift(v, 1), -band(v, 1))
		last = (last + d) % 4294967296
		return last
	end

	local function emit(a, b, c)
		if index_size == 2 then
			out16[o], out16[o + 1], out16[o + 2] = a, b, c
		else
			out32[o], out32[o + 1], out32[o + 2] = a, b, c
		end

		o = o + 3
	end

	local function push_edge(a, b)
		edge_a[edge_offset], edge_b[edge_offset] = a, b
		edge_offset = band(edge_offset + 1, 15)
	end

	local function push_vertex(v, cond)
		vertex_fifo[vertex_offset] = v

		if cond then vertex_offset = band(vertex_offset + 1, 15) end
	end

	for i = 0, index_count / 3 - 1 do
		local codetri = data[code_pos + i]

		if codetri < 0xf0 then
			local fe = rshift(codetri, 4)
			local slot = band(edge_offset - 1 - fe, 15)
			local a, b = edge_a[slot], edge_b[slot]
			local c
			local fec = band(codetri, 15)

			if fec < fecmax then
				local cf = vertex_fifo[band(vertex_offset - 1 - fec, 15)]
				local fec0 = fec == 0
				c = fec0 and next_index or cf

				if fec0 then next_index = next_index + 1 end

				push_vertex(c, fec0)
			else
				if fec ~= 15 then
					last = last + (fec * 2 - 27)
					c = last
				else
					c = decode_index()
				end

				push_vertex(c, true)
			end

			push_edge(c, b)
			push_edge(a, c)
			emit(a, b, c)
		elseif codetri < 0xfe then
			local aux = data[codeaux + band(codetri, 15)]
			local feb = rshift(aux, 4)
			local fec = band(aux, 15)
			local a = next_index
			next_index = next_index + 1
			local feb0 = feb == 0
			local b = feb0 and next_index or vertex_fifo[band(vertex_offset - feb, 15)]

			if feb0 then next_index = next_index + 1 end

			local fec0 = fec == 0
			local c = fec0 and next_index or vertex_fifo[band(vertex_offset - fec, 15)]

			if fec0 then next_index = next_index + 1 end

			emit(a, b, c)
			push_vertex(a, true)
			push_vertex(b, feb0)
			push_vertex(c, fec0)
			push_edge(b, a)
			push_edge(c, b)
			push_edge(a, c)
		else
			local aux = data[position]
			position = position + 1
			local fea = codetri == 0xfe and 0 or 15
			local feb = rshift(aux, 4)
			local fec = band(aux, 15)

			if aux == 0 then next_index = 0 end

			local a, b, c = 0, 0, 0

			if fea == 0 then
				a = next_index
				next_index = next_index + 1
			end

			if feb == 0 then
				b = next_index
				next_index = next_index + 1
			else
				b = vertex_fifo[band(vertex_offset - feb, 15)]
			end

			if fec == 0 then
				c = next_index
				next_index = next_index + 1
			else
				c = vertex_fifo[band(vertex_offset - fec, 15)]
			end

			if fea == 15 then a = decode_index() end

			if feb == 15 then b = decode_index() end

			if fec == 15 then c = decode_index() end

			emit(a, b, c)
			push_vertex(a, true)
			push_vertex(b, feb == 0 or feb == 15)
			push_vertex(c, fec == 0 or fec == 15)
			push_edge(b, a)
			push_edge(c, b)
			push_edge(a, c)
		end
	end

	assert(position == data_safe_end, "index buffer data is malformed")
	return out
end

return meshopt
