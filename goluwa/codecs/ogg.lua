local Buffer = import("goluwa/structs/buffer.lua")
local bit = require("bit")
local ffi = require("ffi")
local vorbis_codec = import("goluwa/codecs/internal/vorbis.lua")
local ogg = library()
local ffi_copy = ffi.copy
local float_size = ffi.sizeof("float")
ogg.file_extensions = {"ogg"}
ogg.magic_headers = {"OggS"}
ogg.returns_blob = true
ogg.thread_job = [[
	local input = ...
	local ogg = import("goluwa/codecs/ogg.lua")
	local meta, pcm = ogg.Decode(input)

	if not meta then error(pcm, 0) end

	return meta, pcm
]]

function ogg.Decode(data)
	local buffer

	if type(data) == "string" then
		buffer = Buffer.New(data)
	else
		buffer = data
	end

	if buffer:TheEnd() then return nil, "Empty buffer" end

	local pages = {}
	local start_pos = buffer:GetPosition()

	while not buffer:TheEnd() do
		local magic = buffer:ReadBytes(4)

		if magic ~= "OggS" then
			if #pages == 0 then
				error(
					"Not an Ogg file (magic 'OggS' not found at pos " .. buffer:GetPosition() - 4 .. ")"
				)
			else
				break
			end
		end

		local page = {}
		page.version = buffer:ReadByte()
		page.header_type = buffer:ReadByte()
		page.granule_position = buffer:ReadI64LE()
		page.serial_number = buffer:ReadU32LE()
		page.sequence_number = buffer:ReadU32LE()
		page.checksum = buffer:ReadU32LE()
		page.num_segments = buffer:ReadByte()
		local segments = {}
		local page_data_size = 0

		for i = 1, page.num_segments do
			local len = buffer:ReadByte()
			segments[i] = len
			page_data_size = page_data_size + len
		end

		page.segment_table = segments
		local page_data = buffer:ReadBytes(page_data_size)
		page.data = page_data
		table.insert(pages, page)
	end

	local packets = {}
	local current_packet = {}

	for _, page in ipairs(pages) do
		local segments = page.segment_table
		local offset = 1

		for i = 1, #segments do
			local segment_len = segments[i]
			local segment_data = page.data:sub(offset, offset + segment_len - 1)
			offset = offset + segment_len
			table.insert(current_packet, segment_data)

			if segment_len < 255 then
				table.insert(packets, table.concat(current_packet))
				current_packet = {}
			end
		end
	end

	local result = {
		pages = pages,
		packets = packets,
	}

	if #packets < 3 then
		return nil,
		"Not enough packets for Vorbis stream (expected at least 3 headers, got " .. #packets .. ")"
	end

	local id_header = packets[1]
	local comment_header = packets[2]
	local setup_header = packets[3]

	if id_header:sub(2, 7) ~= "vorbis" then
		return nil, "First packet is not a Vorbis identification header"
	end

	local info, err = vorbis_codec.DecodeIdentification(id_header)

	if not info then
		return nil, "Failed to decode Vorbis identification header: " .. tostring(err)
	end

	for k, v in pairs(info) do
		result[k] = v
	end

	local comments, err = vorbis_codec.DecodeComment(comment_header)

	if not comments then
		return nil, "Failed to decode Vorbis comment header: " .. tostring(err)
	end

	result.comments = comments
	local setup, err = vorbis_codec.DecodeSetup(setup_header, info)

	if not setup then
		return nil, "Failed to decode Vorbis setup header: " .. tostring(err)
	end

	result.setup = setup
	local channels = result.channels or 2
	local sample_rate = result.sample_rate or 44100
	local total_samples = pages[#pages].granule_position
	total_samples = tonumber(total_samples) or 0

	if total_samples <= 0 then total_samples = (#packets - 3) * 1024 end

	local buffer_size = total_samples * channels
	local pcm = ffi.new("float[?]", buffer_size)
	local state = {
		prev_pcm = nil,
		imdct = {},
		window = {},
	}
	local pcm_offset = 0
	local packets_decoded = 0

	for i = 4, #packets do
		local packet = packets[i]
		local decoded_pcm, n = vorbis_codec.DecodePacket(packet, result, setup, state)

		if decoded_pcm and n then
			local copy_count = n * channels

			if pcm_offset + copy_count > buffer_size then
				copy_count = buffer_size - pcm_offset
			end

			if copy_count > 0 then
				ffi_copy(pcm + pcm_offset, decoded_pcm, copy_count * float_size)
			end

			pcm_offset = pcm_offset + n * channels
			packets_decoded = packets_decoded + 1
		end
	end

	result.page_count = #pages
	result.packet_count = #packets
	result.pages = nil
	result.packets = nil
	result.setup = nil
	result.samples = total_samples
	result.channels = channels
	result.sample_rate = sample_rate
	result.packets_decoded = packets_decoded
	return result, pcm
end

return ogg
