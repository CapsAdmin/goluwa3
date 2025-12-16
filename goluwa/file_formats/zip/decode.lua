-- ZIP file decoder
-- Based on PKZIP .ZIP File Format Specification
local ffi = require("ffi")
local bit = require("bit")
local Buffer = require("structs.buffer")
local deflate = require("helpers.deflate")
local bit_band = bit.band
local bit_bor = bit.bor
local bit_lshift = bit.lshift
-- ZIP file signatures
local LOCAL_FILE_HEADER_SIG = 0x04034b50
local CENTRAL_DIR_HEADER_SIG = 0x02014b50
local END_CENTRAL_DIR_SIG = 0x06054b50
local DATA_DESCRIPTOR_SIG = 0x08074b50
-- Compression methods
local COMPRESSION_NONE = 0
local COMPRESSION_DEFLATE = 8
-- General purpose bit flags
local FLAG_ENCRYPTED = 0x0001
local FLAG_DATA_DESCRIPTOR = 0x0008
local FLAG_UTF8 = 0x0800

local function readLocalFileHeader(buffer)
	local signature = buffer:ReadU32LE()

	if signature ~= LOCAL_FILE_HEADER_SIG then return nil end

	local header = {
		signature = signature,
		versionNeeded = buffer:ReadU16LE(),
		flags = buffer:ReadU16LE(),
		compressionMethod = buffer:ReadU16LE(),
		lastModTime = buffer:ReadU16LE(),
		lastModDate = buffer:ReadU16LE(),
		crc32 = buffer:ReadU32LE(),
		compressedSize = buffer:ReadU32LE(),
		uncompressedSize = buffer:ReadU32LE(),
		fileNameLength = buffer:ReadU16LE(),
		extraFieldLength = buffer:ReadU16LE(),
	}
	header.fileName = buffer:ReadBytes(header.fileNameLength)
	header.extraField = buffer:ReadBytes(header.extraFieldLength)
	return header
end

local function readCentralDirectoryHeader(buffer)
	local signature = buffer:ReadU32LE()

	if signature ~= CENTRAL_DIR_HEADER_SIG then return nil end

	local header = {
		signature = signature,
		versionMadeBy = buffer:ReadU16LE(),
		versionNeeded = buffer:ReadU16LE(),
		flags = buffer:ReadU16LE(),
		compressionMethod = buffer:ReadU16LE(),
		lastModTime = buffer:ReadU16LE(),
		lastModDate = buffer:ReadU16LE(),
		crc32 = buffer:ReadU32LE(),
		compressedSize = buffer:ReadU32LE(),
		uncompressedSize = buffer:ReadU32LE(),
		fileNameLength = buffer:ReadU16LE(),
		extraFieldLength = buffer:ReadU16LE(),
		fileCommentLength = buffer:ReadU16LE(),
		diskNumberStart = buffer:ReadU16LE(),
		internalFileAttributes = buffer:ReadU16LE(),
		externalFileAttributes = buffer:ReadU32LE(),
		localHeaderOffset = buffer:ReadU32LE(),
	}
	header.fileName = buffer:ReadBytes(header.fileNameLength)
	header.extraField = buffer:ReadBytes(header.extraFieldLength)
	header.fileComment = buffer:ReadBytes(header.fileCommentLength)
	return header
end

local function readEndOfCentralDirectory(buffer)
	-- Search for End of Central Directory signature from the end
	-- This is more robust than assuming it's at a fixed position
	local size = buffer:GetSize()
	-- Search backwards from end (up to 64KB + 22 bytes for comment)
	local searchStart = math.max(0, size - 65557)
	local found = false
	local offset = size - 22 -- Minimum EOCD size
	while offset >= searchStart do
		-- Save current position and peek at signature
		local savedPos = buffer:GetPosition()
		buffer:SetPosition(offset)
		local sig = buffer:ReadU32LE()
		buffer:SetPosition(savedPos)

		if sig == END_CENTRAL_DIR_SIG then
			found = true

			break
		end

		offset = offset - 1
	end

	if not found then error("End of Central Directory signature not found") end

	-- Set buffer position to EOCD
	buffer:SetPosition(offset)
	local eocd = {
		signature = buffer:ReadU32LE(),
		diskNumber = buffer:ReadU16LE(),
		diskWithCentralDir = buffer:ReadU16LE(),
		numEntriesThisDisk = buffer:ReadU16LE(),
		numEntriesTotal = buffer:ReadU16LE(),
		centralDirSize = buffer:ReadU32LE(),
		centralDirOffset = buffer:ReadU32LE(),
		commentLength = buffer:ReadU16LE(),
	}

	if eocd.commentLength > 0 then
		eocd.comment = buffer:ReadBytes(eocd.commentLength)
	end

	return eocd
end

local function decompressFile(compressedData, compressionMethod, uncompressedSize)
	if compressionMethod == COMPRESSION_NONE then
		return compressedData
	elseif compressionMethod == COMPRESSION_DEFLATE then
		local decompressed = deflate.inflate_raw({
			input = compressedData,
			disable_crc = true,
		})
		return decompressed:ReadBytes(uncompressedSize)
	else
		error("Unsupported compression method: " .. compressionMethod)
	end
end

local function extractFiles(buffer)
	local files = {}
	-- Read End of Central Directory to find where central directory starts
	local eocd = readEndOfCentralDirectory(buffer)
	-- Read Central Directory entries
	buffer:SetPosition(eocd.centralDirOffset)
	local centralDirEntries = {}

	for i = 1, eocd.numEntriesTotal do
		local entry = readCentralDirectoryHeader(buffer)

		if not entry then break end

		table.insert(centralDirEntries, entry)
	end

	-- Extract file data using information from central directory
	for _, entry in ipairs(centralDirEntries) do
		-- Seek to local file header
		buffer:SetPosition(entry.localHeaderOffset)
		local localHeader = readLocalFileHeader(buffer)

		if not localHeader then
			error("Invalid local file header at offset " .. entry.localHeaderOffset)
		end

		-- Check if this is a directory (ends with /)
		local isDirectory = entry.fileName:sub(-1) == "/"
		local fileData = {
			name = entry.fileName,
			isDirectory = isDirectory,
			compressionMethod = entry.compressionMethod,
			compressedSize = entry.compressedSize,
			uncompressedSize = entry.uncompressedSize,
			crc32 = entry.crc32,
			lastModTime = entry.lastModTime,
			lastModDate = entry.lastModDate,
			flags = entry.flags,
		}

		-- Read and decompress file data (if not a directory)
		if not isDirectory and entry.compressedSize > 0 then
			local compressedData = buffer:ReadBytes(entry.compressedSize)
			fileData.data = decompressFile(compressedData, entry.compressionMethod, entry.uncompressedSize)
		else
			fileData.data = ""
		end

		table.insert(files, fileData)
	end

	return files
end

local function zipArchive(inputBuffer)
	-- Check for PK signature at the beginning (optional check)
	local savedPos = inputBuffer:GetPosition()
	inputBuffer:SetPosition(0)
	local firstBytes = inputBuffer:ReadBytes(2)
	inputBuffer:SetPosition(savedPos)

	if firstBytes ~= "PK" then
		error("Not a valid ZIP file (missing PK signature)")
	end

	local files = extractFiles(inputBuffer)
	return {
		files = files,
		fileCount = #files,
	}
end

return zipArchive
