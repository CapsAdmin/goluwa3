local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/fs.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local codec = library()
local codec_modules

local function get_codec_modules()
	if codec_modules then return codec_modules end

	codec_modules = {}

	for _, name in ipairs(fs.get_files("goluwa/codecs")) do
		if not name:ends_with(".lua") then goto continue end

		local module_name = name:sub(1, -5)
		codec_modules[#codec_modules + 1] = {
			name = module_name,
			mod = import("goluwa/codecs/" .. module_name .. ".lua"),
		}

		::continue::
	end

	return codec_modules
end

local function path_matches_extension(path, mod)
	if type(path) ~= "string" or not mod.file_extensions then return false end

	local lower_path = path:lower()

	for _, ext in ipairs(mod.file_extensions) do
		if lower_path:ends_with("." .. ext:lower()) then return true end
	end

	return false
end

local function data_matches_magic(path, file_content, mod)
	local can_decode = mod.CanDecodeData or mod.can_decode_data

	if can_decode then
		local ok, matches = pcall(can_decode, file_content, path)

		if ok and matches then return true end
	end

	if mod.magic_headers then
		for _, header in ipairs(mod.magic_headers) do
			if file_content:sub(1, #header) == header then return true end
		end
	end

	return false
end

local function collect_decoder_candidates(path, file_content)
	local candidates = {}
	local seen = {}

	local function add(name, mod)
		if not mod or seen[name] then return end

		seen[name] = true
		candidates[#candidates + 1] = {
			name = name,
			mod = mod,
		}
	end

	for _, info in ipairs(get_codec_modules()) do
		if path_matches_extension(path, info.mod) then add(info.name, info.mod) end
	end

	for _, info in ipairs(get_codec_modules()) do
		if data_matches_magic(path, file_content, info.mod) then
			add(info.name, info.mod)
		end
	end

	return candidates
end

local function decode_with_module(path, file_content, mod)
	local decode = mod.decode_buffer or mod.DecodeBuffer

	if decode then return decode(Buffer.New(file_content, #file_content), path) end

	decode = mod.decode or mod.Decode

	if not decode then
		return nil, "decoder has no Decode or DecodeBuffer for " .. tostring(path)
	end

	return decode(file_content, path)
end

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
	for _, info in ipairs(get_codec_modules()) do
		if path_matches_extension(path, info.mod) then return info.mod end
	end
end

function codec.GuessFormat(path, file_content)
	local candidate = collect_decoder_candidates(path, file_content)[1]
	return candidate and candidate.mod or nil
end

function codec.DecodeFile(path, lib)
	local file = assert(vfs.Open(path))
	local file_content = file:ReadAll()

	if not file_content then
		file:Close()
		error("File is empty")
	end

	file:Close()

	if lib then
		return decode_with_module(path, file_content, import("goluwa/codecs/" .. lib .. ".lua"))
	end

	local candidates = collect_decoder_candidates(path, file_content)

	if #candidates == 0 then
		return nil, "no decoder found for " .. tostring(path)
	end

	local last_err

	for _, candidate in ipairs(candidates) do
		local ok, decoded, err = pcall(decode_with_module, path, file_content, candidate.mod)

		if ok then
			if decoded ~= nil then return decoded, err end

			last_err = err or ("decoder rejected " .. tostring(path) .. ": " .. candidate.name)
		else
			last_err = decoded
		end
	end

	return nil, last_err or ("no decoder accepted " .. tostring(path))
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
