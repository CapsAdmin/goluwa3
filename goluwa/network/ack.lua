local bit = require("bit")
local ack = {}
local ACK_BITMAP_SIZE = 8

function ack.CreateAckHeader(receiver, base_sequence)
	local header = {}
	header.base_sequence = base_sequence
	header.ack_count = 0
	header.bitmap = {}
	local current_seq = base_sequence
	local diff = bit.band(current_seq - receiver.window_start, 0xFFFFFFFF)

	while diff < receiver.window_size do
		local index = bit.band(diff, receiver.window_mask)
		local word_index = math.floor(index / 32)
		local bit_index = bit.band(index % 32, 0xFFFFFFFF)
		local word = receiver.bitmap[word_index] or 0

		if bit.band(word, bit.lshift(1, bit_index)) == 0 then break end

		header.ack_count = header.ack_count + 1
		current_seq = bit.band(current_seq + 1, 0xFFFFFFFF)
		diff = bit.band(current_seq - receiver.window_start, 0xFFFFFFFF)
	end

	local bitmap_bits = {}
	local bitmap_size = 0

	for i = header.ack_count, math.min(header.ack_count + 63, 63) do
		local seq = bit.band(base_sequence + i, 0xFFFFFFFF)
		local diff_inner = bit.band(seq - receiver.window_start, 0xFFFFFFFF)

		if diff_inner < receiver.window_size then
			local index = bit.band(diff_inner, receiver.window_mask)
			local word_index = math.floor(index / 32)
			local bit_index = bit.band(index % 32, 0xFFFFFFFF)
			local word = receiver.bitmap[word_index] or 0

			if bit.band(word, bit.lshift(1, bit_index)) ~= 0 then
				bitmap_bits[i - header.ack_count] = true
				bitmap_size = math.max(bitmap_size, i - header.ack_count + 1)
			end
		end
	end

	if bitmap_size > 0 then
		header.bitmap = {}

		for byte_idx = 0, math.min(math.floor((bitmap_size - 1) / 8), 7) do
			local byte_val = 0

			for bit_idx = 0, 7 do
				local global_bit = byte_idx * 8 + bit_idx

				if bitmap_bits[global_bit] then
					byte_val = bit.bor(byte_val, bit.lshift(1, bit_idx))
				end
			end

			header.bitmap[#header.bitmap + 1] = byte_val
		end
	end

	return header
end

function ack.SerializeAckHeader(header)
	local buffer = {}
	buffer[#buffer + 1] = bit.band(header.base_sequence, 0xFF)
	buffer[#buffer + 1] = bit.band(bit.rshift(header.base_sequence, 8), 0xFF)
	buffer[#buffer + 1] = bit.band(bit.rshift(header.base_sequence, 16), 0xFF)
	buffer[#buffer + 1] = bit.band(bit.rshift(header.base_sequence, 24), 0xFF)
	buffer[#buffer + 1] = bit.band(header.ack_count, 0xFF)
	buffer[#buffer + 1] = bit.band(bit.rshift(header.ack_count, 8), 0xFF)
	local bitmap_size = #header.bitmap

	if bitmap_size > 0 then
		buffer[#buffer + 1] = bit.bor(0x80, bitmap_size)

		for i = 1, bitmap_size do
			buffer[#buffer + 1] = header.bitmap[i]
		end
	else
		buffer[#buffer + 1] = 0
	end

	return buffer
end

function ack.DeserializeAckHeader(buffer)
	if #buffer < 6 then return nil end

	local header = {}
	header.base_sequence = bit.bor(
		buffer[1],
		bit.lshift(buffer[2], 8),
		bit.lshift(buffer[3], 16),
		bit.lshift(buffer[4], 24)
	)
	header.base_sequence = bit.band(header.base_sequence, 0xFFFFFFFF)
	header.ack_count = bit.bor(buffer[5], bit.lshift(buffer[6], 8))
	local flags_byte = buffer[7] or 0

	if bit.band(flags_byte, 0x80) ~= 0 then
		local bitmap_size = bit.band(flags_byte, 0x7F)
		header.bitmap = {}

		for i = 1, bitmap_size do
			header.bitmap[i] = buffer[7 + i]
		end
	else
		header.bitmap = {}
	end

	return header
end

function ack.ApplyAckHeader(receiver, header)
	for i = 0, header.ack_count - 1 do
		local seq = bit.band(header.base_sequence + i, 0xFFFFFFFF)

		if receiver:IsDuplicate(seq) then receiver:Receive(seq) end
	end

	if header.bitmap and #header.bitmap > 0 then
		for byte_idx = 1, #header.bitmap do
			local byte_val = header.bitmap[byte_idx]

			for bit_idx = 0, 7 do
				if bit.band(byte_val, bit.lshift(1, bit_idx)) ~= 0 then
					local global_bit = (byte_idx - 1) * 8 + bit_idx
					local seq = bit.band(header.base_sequence + header.ack_count + global_bit, 0xFFFFFFFF)

					if receiver:IsDuplicate(seq) then receiver:Receive(seq) end
				end
			end
		end
	end
end

return ack
