local ffi = require("ffi")
local Buffer = import("goluwa/structs/buffer.lua")
local bit = require("bit")
local deflate = import("goluwa/codecs/deflate.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local vfs = import("goluwa/filesystem/vfs.lua")
local objects = import("goluwa/objects/objects.lua")
local CONTEXT = objects.CreateTemplate("file_system_zip")
CONTEXT.Base = import("goluwa/filesystem/files/generic_archive.lua")
CONTEXT.Name = "zip archive"
CONTEXT.Extension = {"zip", "love", "cry"}

function CONTEXT:OnParseArchive(file, archive_path)
	if VERBOSE then print("ZIP: Parsing archive:", archive_path) end

	local LOCAL_FILE_HEADER_SIG = 0x04034b50
	local CENTRAL_DIR_HEADER_SIG = 0x02014b50
	local END_CENTRAL_DIR_SIG = 0x06054b50
	file:SetPosition(0)
	local file_data = file:ReadBytes(file:GetSize())
	local buffer = Buffer.New(file_data, #file_data)
	local size = buffer:GetSize()
	local searchStart = math.max(0, size - 65557)
	local found = false
	local offset = size - 22

	while offset >= searchStart do
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

	if not found then
		return false, "End of Central Directory signature not found"
	end

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
	buffer:SetPosition(eocd.centralDirOffset)

	if VERBOSE then
		print("ZIP: Found", eocd.numEntriesTotal, "entries in central directory")
	end

	for i = 1, eocd.numEntriesTotal do
		local signature = buffer:ReadU32LE()

		if signature ~= CENTRAL_DIR_HEADER_SIG then break end

		local entry = {
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
		entry.fileName = buffer:ReadBytes(entry.fileNameLength)
		buffer:ReadBytes(entry.extraFieldLength)
		buffer:ReadBytes(entry.fileCommentLength)
		local isDirectory = entry.fileName:sub(-1) == "/"

		if not isDirectory then
			local savedPos = buffer:GetPosition()
			buffer:SetPosition(entry.localHeaderOffset)
			local localSig = buffer:ReadU32LE()

			if localSig == LOCAL_FILE_HEADER_SIG then
				buffer:ReadU16LE()
				buffer:ReadU16LE()
				buffer:ReadU16LE()
				buffer:ReadU16LE()
				buffer:ReadU16LE()
				buffer:ReadU32LE()
				buffer:ReadU32LE()
				buffer:ReadU32LE()
				local localFileNameLength = buffer:ReadU16LE()
				local localExtraFieldLength = buffer:ReadU16LE()
				buffer:ReadBytes(localFileNameLength)
				buffer:ReadBytes(localExtraFieldLength)
				entry.offset = buffer:GetPosition()
			else
				entry.offset = entry.localHeaderOffset + 30 + entry.fileNameLength
			end

			buffer:SetPosition(savedPos)
			entry.full_path = entry.fileName
			entry.size = entry.compressionMethod == 0 and entry.compressedSize or entry.uncompressedSize
			entry.archive_path = "os:" .. archive_path

			if VERBOSE and i <= 3 then
				print("ZIP: Adding entry:", entry.full_path, "size:", entry.size)
			end

			self:AddEntry(entry)
		end
	end

	if VERBOSE then print("ZIP: Parse complete") end

	return true
end

function CONTEXT:TranslateArchivePath(file_info, archive_path)
	return file_info.archive_path or ("os:" .. archive_path)
end

function CONTEXT:Open(path_info, mode, ...)
	if self:GetMode() == "read" then
		local tree, relative, archive_path = self:GetFileTree(path_info)

		if not tree then return false, relative end

		local file_info = tree:GetEntry(relative)

		if not file_info then return false, "file not found in archive" end

		if file_info.is_dir then return false, "file is a directory" end

		local archive_path = self:TranslateArchivePath(file_info, archive_path)
		local file, err = vfs.Open(archive_path)

		if not file then return false, err end

		file:SetPosition(file_info.offset)
		self.position = 0
		self.file_info = file_info
		local compressed_data = file:ReadBytes(file_info.compressedSize)
		file:Close()

		if file_info.compressionMethod == 8 then
			local decompressed = deflate.Decode(
				compressed_data,
				"raw",
				Buffer.New(ffi.new("uint8_t[?]", file_info.size), file_info.size):MakeWritable()
			)
			self.data = decompressed:ReadBytes(file_info.size)
		elseif file_info.compressionMethod == 0 then
			self.data = compressed_data
		else
			return false, "Unsupported compression method: " .. file_info.compressionMethod
		end

		return true
	end

	return false, "mode " .. self:GetMode() .. " not supported"
end

function CONTEXT:ReadByte()
	if self.data then
		local char = self.data:sub(self.position + 1, self.position + 1)
		self.position = math.clamp(self.position + 1, 0, self.file_info.size)

		if char == "" then return nil end

		return char:byte()
	end
end

function CONTEXT:ReadBytes(bytes)
	if bytes == math.huge then bytes = self:GetSize() end

	if self.data then
		local remaining = self.file_info.size - self.position
		bytes = math.min(bytes, remaining)

		if bytes <= 0 then return nil end

		local str = self.data:sub(self.position + 1, self.position + bytes)
		self.position = self.position + #str

		if str == "" then return nil end

		return str
	end
end

function CONTEXT:SetPosition(pos)
	self.position = math.clamp(pos, 0, self.file_info.size)
end

function CONTEXT:GetPosition()
	return self.position
end

function CONTEXT:OnRemove()
	self.data = nil
end

function CONTEXT:GetSize()
	return self.file_info.size
end

return CONTEXT:Register()
