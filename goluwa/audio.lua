local codec = import("goluwa/codec.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local audio = import("goluwa/audio/state.lua")
local spatial = import("goluwa/audio/spatial.lua")
local sound = import("goluwa/audio/sound.lua")
local runtime = import("goluwa/audio/runtime.lua")
local backend = import("goluwa/audio/backend.lua")

local function pack_decoded_audio(decoded)
	if not decoded then return nil, 0, nil end

	return decoded.data,
	decoded.samples or 0,
	{
		channels = decoded.channels,
		samplerate = decoded.sample_rate,
		sample_rate = decoded.sample_rate,
	}
end

function audio.Decode(source, lib)
	if type(source) == "string" then
		return pack_decoded_audio(codec.DecodeFile(source, lib))
	end

	local path
	local file = source

	if type(source) == "table" and source.file then
		file = source.file
		path = source.path
	end

	if not path and type(source) == "table" then
		path = source.path or source.path_used
	end

	if not file or not file.ReadAll then
		return nil, 0, nil, "unsupported audio source"
	end

	local contents = file:ReadAll()

	if not contents then return nil, 0, nil, "file is empty" end

	local decoder = lib and
		import("goluwa/codecs/" .. lib .. ".lua") or
		(
			path and
			codec.GuessFormat(path, contents)
		)

	if not decoder then return nil, 0, nil, "no decoder found" end

	local decode = decoder.decode_buffer or decoder.DecodeBuffer
	local decoded, err

	if decode then
		decoded, err = decode(Buffer.New(contents, #contents))

		if not decoded then return nil, 0, nil, err end

		return pack_decoded_audio(decoded)
	end

	decode = decoder.decode or decoder.Decode

	if not decode then
		return nil, 0, nil, "decoder has no Decode or DecodeBuffer"
	end

	decoded, err = decode(contents)

	if not decoded then return nil, 0, nil, err end

	return pack_decoded_audio(decoded)
end

spatial.Attach(audio)
sound.Attach(audio)
runtime.Attach(audio)
backend.Attach(audio)
return audio
