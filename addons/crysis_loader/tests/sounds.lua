local T = import("test/environment.lua")
local vfs = import("goluwa/vfs.lua")
local codec = import("goluwa/codec.lua")
local fmod_events = import("lua/crysis_loader/fmod_events.lua")
local cry_game = import("lua/crysis_loader/game.lua")
local CRYSIS_WARS_APPID = 17340
local CHICKEN_CLUCK = "Sounds/environment:random_oneshots_natural:chicken_cluck"

T.Test("FMOD projects map nested event groups to the waveforms of their sound definitions", function()
	local project = fmod_events.ParseProject([[
<project>
<name>animals</name>
<sounddeffolder>
<name>master</name>
<sounddef>
<name>cluck</name>
<volume_db>-3</volume_db>
<waveform>
<filename>random/cluck_01.wav</filename>
<soundbankname>animals_bank</soundbankname>
</waveform>
<waveform>
<filename>random\cluck_02.wav</filename>
<soundbankname>animals_bank</soundbankname>
</waveform>
</sounddef>
</sounddeffolder>
<eventgroup>
<name>farm</name>
<eventgroup>
<name>birds</name>
<event>
<name>Chicken</name>
<layer>
<name>layer00</name>
<sound>
<name>cluck</name>
</sound>
</layer>
<parameter>
<name>distance</name>
</parameter>
<volume_db>-10</volume_db>
<pitch>-0.25</pitch>
<pitch_randomization>0.2</pitch_randomization>
</event>
</eventgroup>
</eventgroup>
</project>
]])
	local event = project.events["farm:birds:chicken"]
	T(event ~= nil)["=="](true)
	T(event.name)["=="]("Chicken")
	T(#event.sounds)["=="](1)
	T(event.sounds[1])["=="]("cluck")
	T(event.volume_db)["=="](-10)
	T(event.pitch)["=="](-0.25)
	local sounddef = project.sounddefs.cluck
	T(#sounddef.waveforms)["=="](2)
	T(sounddef.waveforms[2].filename)["=="]("random\\cluck_02.wav")
	T(sounddef.waveforms[1].soundbankname)["=="]("animals_bank")
end)

T.Test("Crysis FSB3 sound banks list their samples and decode MPEG layer II", function()
	if not cry_game.GetGame(cry_game.CRYSIS_APPID) then
		return T.Unavailable("Crysis is not installed")
	end

	cry_game.MountContent(cry_game.CRYSIS_APPID)
	local event = fmod_events.Get(CHICKEN_CLUCK)
	T(#event.Paths)["=="](11)
	T(math.abs(event.Volume - 10 ^ (-10 / 20)))["<"](0.0001)
	T(event.Pitch)["=="](-0.25)
	local path = event.Paths[1]
	T(path:ends_with("environment_random_oneshots_natural.fsb/chicken_cluck_01.wav"))["=="](true)
	local decoded = assert(codec.DecodeFile(path))
	T(decoded.samples)["=="](48384)
	T(decoded.channels)["=="](1)
	T(decoded.sample_rate)["=="](44100)
	local peak, sum = 0, 0

	for i = 0, decoded.samples - 1 do
		local value = decoded.data[i]
		peak = math.max(peak, math.abs(value))
		sum = sum + value * value
	end

	-- measured against ffmpeg's mp2 decoder
	T(math.abs(peak - 0.630))["<"](0.005)
	T(math.abs(math.sqrt(sum / decoded.samples) - 0.0739))["<"](0.001)
end)

T.Test("Crysis Wars FSB4 sound banks decode", function()
	if not cry_game.GetGame(CRYSIS_WARS_APPID) then
		return T.Unavailable("Crysis Wars is not installed")
	end

	cry_game.MountContent(CRYSIS_WARS_APPID)
	local event = fmod_events.Get(CHICKEN_CLUCK)
	T(event ~= nil)["=="](true)
	local bank = event.Paths[1]:match("^(.+%.fsb)/")
	local file = assert(vfs.Open(vfs.GetAbsolutePath(bank, false)))
	T(file:ReadBytes(4))["=="]("FSB4")
	file:Close()
	local decoded = assert(codec.DecodeFile(event.Paths[1]))
	T(decoded.samples)[">"](0)
	cry_game.UnmountContent(CRYSIS_WARS_APPID)
end)
