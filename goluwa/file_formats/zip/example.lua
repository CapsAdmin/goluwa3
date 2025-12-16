-- ZIP Decoder Example Usage
-- This demonstrates how to use the ZIP decoder similar to the PNG decoder
local Buffer = require("structs.buffer")
local zip_decode = require("file_formats.zip.decode")
local file_formats = require("file_formats")

-- Example 1: Decode a ZIP file from a file path using file_formats helper
local function example_load_zip_from_path()
	local archive = file_formats.LoadZIP("path/to/your/file.zip")
	print("ZIP archive contains", archive.fileCount, "files")

	-- Iterate through all files in the archive
	for i, file in ipairs(archive.files) do
		print(
			string.format(
				"[%d] %s (%s, %d bytes)",
				i,
				file.name,
				file.isDirectory and "directory" or "file",
				file.uncompressedSize
			)
		)

		-- Access file data (for non-directories)
		if not file.isDirectory then
			-- file.data contains the decompressed file content as a string
			print("  First 100 bytes:", file.data:sub(1, 100))
		end
	end
end

-- Example 2: Decode a ZIP file from raw data
local function example_load_zip_from_data(zip_data)
	-- Create a buffer from the raw ZIP data
	local buffer = Buffer.New(zip_data, #zip_data)
	-- Decode the ZIP archive
	local archive = zip_decode(buffer)
	return archive
end

-- Example 3: Extract a specific file from the archive
local function example_extract_file(zip_path, target_filename)
	local archive = file_formats.LoadZIP(zip_path)

	for _, file in ipairs(archive.files) do
		if file.name == target_filename then return file.data end
	end

	error("File not found in archive: " .. target_filename)
end

-- Example 4: List all files in a ZIP archive
local function example_list_files(zip_path)
	local archive = file_formats.LoadZIP(zip_path)
	local files = {}

	for _, file in ipairs(archive.files) do
		if not file.isDirectory then
			table.insert(
				files,
				{
					name = file.name,
					size = file.uncompressedSize,
					compressed_size = file.compressedSize,
					compression = file.compressionMethod == 0 and "none" or "deflate",
				}
			)
		end
	end

	return files
end

-- The ZIP decoder returns a table with the following structure:
--[[
{
	fileCount = <number of files>,
	files = {
		{
			name = <string>,                 -- filename/path within archive
			isDirectory = <boolean>,         -- true if this is a directory entry
			data = <string>,                 -- decompressed file content
			compressionMethod = <number>,    -- 0=none, 8=deflate
			compressedSize = <number>,       -- size of compressed data
			uncompressedSize = <number>,     -- size of decompressed data
			crc32 = <number>,                -- CRC32 checksum
			lastModTime = <number>,          -- DOS time format
			lastModDate = <number>,          -- DOS date format
			flags = <number>,                -- general purpose bit flags
		},
		...
	}
}
]]
--
return {
	example_load_zip_from_path = example_load_zip_from_path,
	example_load_zip_from_data = example_load_zip_from_data,
	example_extract_file = example_extract_file,
	example_list_files = example_list_files,
}
