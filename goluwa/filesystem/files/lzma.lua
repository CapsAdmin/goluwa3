return function(vfs)
	local lzma = require("codecs.lzma")
	local crypto = require("crypto")
	local CONTEXT = {}
	CONTEXT.Name = "lzma archive"
	CONTEXT.Extension = "bin"
	CONTEXT.Base = "generic_archive"
	CONTEXT.Position = 4

	function CONTEXT:OnParseArchive(file, archive_path)
		do
			return false, "wip"
		end

		print("lzma: OnParseArchive", archive_path)
		local saved_pos = file:GetPosition()
		local props = file:ReadByte()
		file:SetPosition(saved_pos)

		if props >= 9 * 5 * 5 then return false, "not a valid lzma file" end

		local ok, decompressed = pcall(lzma.DecodeBuffer, file)

		if not ok then
			print("lzma decompression failed: " .. tostring(decompressed))
			return false, "lzma decompression failed: " .. tostring(decompressed)
		end

		print("lzma: decompressed size", decompressed:GetSize())
		-- Cache the decompressed data to disk so generic_archive can open it
		local cache_key = archive_path .. (vfs.GetLastModified(archive_path) or "")
		local cache_path = "os:cache/lzma/" .. crypto.CRC32(cache_key) .. ".dat"

		if not vfs.IsFile(cache_path) then vfs.Write(cache_path, decompressed) end

		-- Stacking: try other archive handlers
		local found_handler = false

		for _, fs in ipairs(vfs.GetFileSystems()) do
			if fs.Name ~= self.Name and fs.OnParseArchive then
				local fake_path = archive_path

				if fs.Extension then fake_path = "fake." .. fs.Extension end

				decompressed:SetPosition(0)
				-- Override AddEntry to use the cached decompressed file
				local old_AddEntry = self.AddEntry
				self.AddEntry = function(self, entry)
					entry.archive_path = cache_path
					return old_AddEntry(self, entry)
				end
				print("lzma: trying handler", fs.Name, "with", fake_path)
				local ok, err = fs.OnParseArchive(self, decompressed, fake_path)
				self.AddEntry = old_AddEntry

				if ok then
					print("lzma: handler", fs.Name, "succeeded")
					found_handler = true

					break
				else
					print("lzma stacking: " .. fs.Name .. " failed: " .. tostring(err))
				end
			end
		end

		if not found_handler then
			-- If no other handler matched, expose the decompressed file
			local name = archive_path:match("([^/]+)$") or "decompressed"

			if name:ends_with(".bin") then name = name:sub(1, -5) end

			if name:ends_with(".lzma") then name = name:sub(1, -6) end

			self:AddEntry(
				{
					full_path = name,
					archive_path = cache_path,
					size = decompressed:GetSize(),
					offset = 0,
				}
			)
		end

		return true
	end

	function CONTEXT:IsArchive(path_info)
		return true
	end

	vfs.RegisterFileSystem(CONTEXT)
	-- Also register for .lzma extension
	local CONTEXT_LZMA = {}

	for k, v in pairs(CONTEXT) do
		CONTEXT_LZMA[k] = v
	end

	CONTEXT_LZMA.Name = "lzma_archive_lzma"
	CONTEXT_LZMA.Extension = "lzma"
	CONTEXT_LZMA.ClassName = nil
	CONTEXT_LZMA.Type = nil
	vfs.RegisterFileSystem(CONTEXT_LZMA)
end
