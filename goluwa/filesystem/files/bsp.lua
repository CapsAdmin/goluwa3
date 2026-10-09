local vfs = import("goluwa/filesystem/vfs.lua")
local objects = import("goluwa/objects/objects.lua")
local CONTEXT = objects.CreateTemplate("file_system_bsp_pakfile")
CONTEXT.Base = import("goluwa/filesystem/files/zip.lua")
CONTEXT.Name = "bsp pakfile"
CONTEXT.Extension = "bsp"
CONTEXT.Position = 6
CONTEXT.ArchiveReadPrefix = ""
CONTEXT.NestedArchives = true
local LUMP_TABLE_OFFSET = 8
local LUMP_SIZE = 16
local LUMP_PAKFILE = 40

function CONTEXT:OpenArchive(archive_path)
	return vfs.Open(archive_path)
end

local function read_pak_lump(file)
	file:SetPosition(0)

	if file:ReadBytes(4) ~= "VBSP" then return nil, "not a source bsp" end

	file:SetPosition(LUMP_TABLE_OFFSET + LUMP_PAKFILE * LUMP_SIZE)
	return file:ReadI32(), file:ReadI32()
end

function CONTEXT:GetArchiveVersion(archive_path)
	local file = self:OpenArchive(archive_path)

	if not file then return "" end

	local offset, length = read_pak_lump(file)
	file:Close()
	return tostring(offset) .. ":" .. tostring(length)
end

function CONTEXT:OnParseArchive(file, archive_path)
	local offset, length = read_pak_lump(file)

	if not offset then return false, length end

	if length <= 0 then return false, "bsp has no pakfile" end

	file:SetPosition(offset)
	return self:ParseZipData(file:ReadBytes(length), archive_path, offset)
end

return CONTEXT:Register()
