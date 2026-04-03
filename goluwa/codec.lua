local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/fs.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local codec = library()

function codec.GetLibrary(name)
	return codec.libraries[name] and codec.libraries[name].lib
end

function codec.Encode(lib, ...)
	local data = import("goluwa/codecs/" .. lib .. ".lua")
	local encode = data.encode or data.Encode
	return encode(...)
end

function codec.Decode(lib, ...)
	local data = import("goluwa/codecs/" .. lib .. ".lua")
	local decode = data.decode or data.Decode
	return decode(...)
end

function codec.GuessFormatFromPath(path)
	for _, name in ipairs(fs.get_files("goluwa/codecs")) do
		if not name:ends_with(".lua") then goto continue end

		local mod = import("goluwa/codecs/" .. name:sub(1, -5) .. ".lua")

		if mod.file_extensions then
			for _, ext in ipairs(mod.file_extensions) do
				if path:ends_with("." .. ext) then return mod end
			end
		end

		::continue::
	end
end

function codec.DecodeFile(path, lib)
	local mod = lib and
		import("goluwa/codecs/" .. lib .. ".lua") or
		codec.GuessFormatFromPath(path)

	if not mod then return nil, "no decoder found for " .. tostring(path) end

	local file = assert(vfs.Open(path))
	local file_content = file:ReadAll()

	if not file_content then
		file:Close()
		error("File is empty")
	end

	file:Close()
	local decode = mod.decode_buffer or mod.DecodeBuffer

	if decode then return decode(Buffer.New(file_content, #file_content)) end

	decode = mod.decode or mod.Decode

	if not decode then
		return nil, "decoder has no Decode or DecodeBuffer for " .. tostring(path)
	end

	return decode(file_content)
end

do -- vfs extension
	function codec.WriteFile(lib, path, ...)
		return vfs.Write(path, codec.Encode(lib, ...))
	end

	function codec.ReadFile(lib, path, ...)
		local str, err = vfs.Read(path)

		if str then return codec.Decode(lib, str) end

		return false, err
	end

	function codec.StoreInFile(lib, path, key, value)
		local tbl = codec.ReadFile(lib, path) or {}
		tbl[key] = value
		codec.WriteFile(lib, path, tbl)
	end

	function codec.GetKeyValuesInFile(lib, path)
		local tbl = codec.ReadFile(lib, path) or {}
		return tbl
	end

	function codec.LookupInFile(lib, path, key, def)
		local tbl = codec.ReadFile(lib, path)

		if tbl then
			local val = codec.ReadFile(lib, path)[key]

			if val == nil then return def end

			return val
		end

		return def
	end

	function codec.AppendToFile(lib, path, value)
		local tbl = codec.ReadFile(lib, path) or {}
		list.insert(tbl, value)
		codec.WriteFile(lib, path, tbl)
	end
end

return codec
