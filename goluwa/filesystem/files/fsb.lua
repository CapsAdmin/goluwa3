local vfs = import("goluwa/filesystem/vfs.lua")
local objects = import("goluwa/objects/objects.lua")
local CONTEXT = objects.CreateTemplate("file_system_fsb_archive")
CONTEXT.Name = "fmod sound bank"
CONTEXT.Extension = "fsb"
CONTEXT.Base = import("goluwa/filesystem/files/generic_archive.lua")
CONTEXT.Position = 7
CONTEXT.NestedArchives = true
local BANK_BASIC_HEADERS = 0x2
local MODE_8BITS = 0x8
local MODE_MPEG = 0x200
local MODE_IMAADPCM = 0x400000
local MODE_UNSUPPORTED = 0x00800000 + 0x01000000 + 0x02000000 + 0x08000000
local WAVE_FORMAT_PCM = 0x0001
local WAVE_FORMAT_MPEG = 0x0050
local WAVE_FORMAT_XBOX_ADPCM = 0x0069
local XBOX_ADPCM_BLOCK = 36

local function u16(value)
	return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
	return u16(value % 65536) .. u16(math.floor(value / 65536))
end

local function wav_header(format_tag, channels, sample_rate, block_align, bits, samples, data_size)
	return "RIFF" .. u32(4 + 26 + 12 + 8 + data_size) .. "WAVE" .. "fmt " .. u32(18) .. u16(format_tag) .. u16(channels) .. u32(sample_rate) .. u32(sample_rate * block_align) .. u16(block_align) .. u16(bits) .. u16(0) .. "fact" .. u32(4) .. u32(samples) .. "data" .. u32(data_size)
end

function CONTEXT:OpenArchive(archive_path)
	return vfs.Open(archive_path)
end

function CONTEXT:GetArchiveVersion(archive_path)
	local file = vfs.Open(archive_path)

	if not file then return "" end

	local size = file:GetSize()
	file:Close()
	return "3:" .. size
end

function CONTEXT:OnParseArchive(file, archive_path)
	if not archive_path:lower():ends_with(".fsb") then
		return false, "archive path does not end with .fsb"
	end

	file:SetPosition(0)
	local magic = file:ReadBytes(4)

	if magic ~= "FSB3" and magic ~= "FSB4" then
		return false, "not an FSB3 or FSB4 sound bank"
	end

	local count = file:ReadU32LE()
	local header_size = file:ReadU32LE()
	file:ReadU32LE()
	file:ReadU32LE()

	if bit.band(file:ReadU32LE(), BANK_BASIC_HEADERS) ~= 0 then
		return false, "sound banks with basic sample headers are not supported"
	end

	local main_header_size = magic == "FSB4" and 48 or 24
	file:SetPosition(main_header_size)
	local offset = main_header_size + header_size
	local skipped = 0

	for _ = 1, count do
		local start = file:GetPosition()
		local size = file:ReadU16LE()
		local name = file:ReadBytes(30):match("^[^%z]*")

		-- names are cut at 30 bytes, which drops the extension of long ones
		if not name:lower():ends_with(".wav") then name = name .. ".wav" end

		local samples = file:ReadU32LE()
		local bytes = file:ReadU32LE()
		file:ReadU32LE()
		file:ReadU32LE()
		local mode = file:ReadU32LE()
		local sample_rate = file:ReadU32LE()
		file:ReadU16LE()
		file:ReadU16LE()
		file:ReadU16LE()
		local channels = file:ReadU16LE()
		file:SetPosition(start + size)
		local header

		if bit.band(mode, MODE_UNSUPPORTED) ~= 0 or bit.band(mode, MODE_8BITS) ~= 0 then
			skipped = skipped + 1
		elseif bit.band(mode, MODE_MPEG) ~= 0 then
			header = wav_header(WAVE_FORMAT_MPEG, channels, sample_rate, 1, 0, samples, bytes)
		elseif bit.band(mode, MODE_IMAADPCM) ~= 0 then
			header = wav_header(
				WAVE_FORMAT_XBOX_ADPCM,
				channels,
				sample_rate,
				XBOX_ADPCM_BLOCK * channels,
				4,
				samples,
				bytes
			)
		else
			header = wav_header(WAVE_FORMAT_PCM, channels, sample_rate, channels * 2, 16, samples, bytes)
		end

		if header then
			self:AddEntry{
				full_path = name,
				archive_path = archive_path,
				offset = offset,
				size = #header + bytes,
				preload_data = header,
			}
		end

		offset = offset + bytes
	end

	if skipped > 0 then
		wlog("%s: skipped %d samples in codecs that are not supported", archive_path, skipped)
	end

	return true
end

return CONTEXT:Register()
