local codec = import("goluwa/codec.lua")
local pvars = import("goluwa/cli/pvars.lua")
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

	local decoded, err = codec.DecodeWithModule(path, contents, decoder)

	if not decoded then return nil, 0, nil, err end

	return pack_decoded_audio(decoded)
end

function audio.SetAcousticsTracer(tracer)
	if audio.acoustics and audio.acoustics.tracer.Remove then
		audio.acoustics.tracer:Remove()
	end

	if tracer then
		audio.acoustics = import("goluwa/audio/acoustics.lua").New(audio, tracer)
	else
		audio.acoustics = nil
	end

	for _, sound in pairs(audio.active_sounds) do
		sound.audio_environment = nil
		sound.audio_occlusion = nil
	end
end

pvars.StartGroup("Engine", "Audio", {prefix = "audio_"})
local acoustics_mode = pvars.Setup2{
	key = "audio_acoustics",
	default = "auto",
	enums = {"auto", "gpu", "cpu", "off"},
	friendly = "acoustics",
	help = "how the environment is traced for reverb, occlusion and reflections: gpu ray queries, cpu physics raycasts, or off for free field",
	callback = function()
		if audio.initialized then audio.SetupAcoustics() end
	end,
}
audio.pinna_cues = pvars.Setup2{
	key = "audio_pinna",
	default = 1,
	min = 0,
	max = 3,
	friendly = "pinna cues",
	help = "strength of the direction dependent ear filters on the direct sound (outer ear notch, overhead and front cues) that let headphones tell up from down and front from back: 0 is off, 1 is about a measured ear, more exaggerates",
}
pvars.EndGroup()

function audio.SetupAcoustics(mode)
	mode = mode or acoustics_mode:Get()

	if mode == "off" then return audio.SetAcousticsTracer(nil) end

	if
		mode ~= "cpu" and
		RENDER_3D and
		import("goluwa/render/render.lua").GetDevice().ray_query_supported
	then
		return audio.SetAcousticsTracer(import("goluwa/audio/acoustics_gpu.lua").New())
	end

	if mode ~= "gpu" and PHYSICS then
		return audio.SetAcousticsTracer(import("goluwa/audio/acoustics_cpu.lua").New())
	end

	audio.SetAcousticsTracer(nil)
end

spatial.Attach(audio)
sound.Attach(audio)
runtime.Attach(audio)
backend.Attach(audio)
return audio
