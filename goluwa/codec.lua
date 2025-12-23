local vfs = require("vfs")
local fs = require("fs")
local Buffer = require("structs.buffer")
local codec = {}

function codec.GetLibrary(name)
	return codec.libraries[name] and codec.libraries[name].lib
end

function codec.Encode(lib, ...)
	local data = require("codecs." .. lib)
	local encode = data.encode or data.Encode
	return encode(...)
end

function codec.Decode(lib, ...)
	local data = require("codecs." .. lib)
	local decode = data.decode or data.Decode
	return decode(...)
end

function codec.GuessFormatFromPath(path)
	for _, name in ipairs(fs.get_files("goluwa/codecs")) do
		local mod = require("codecs." .. name:sub(1, -5))

		if mod.file_extensions then
			for _, ext in ipairs(mod.file_extensions) do
				if path:ends_with("." .. ext) then return mod end
			end
		end
	end
end

function codec.DecodeFile(path, lib)
	local mod = lib and require("codecs." .. lib) or codec.GuessFormatFromPath(path)
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
