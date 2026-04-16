local audio = import("goluwa/audio.lua")
local resource = import("goluwa/resource.lua")

do
	function gine.env.CreateSound(ent, path, filter)
		local resolved_path = gine.ResolvePath(path, "sound")

		if not resolved_path then return end

		resource.skip_providers = true
		local self = audio.CreateSource(resolved_path)
		resource.skip_providers = false
		return gine.WrapObject(self, "CSoundPatch")
	end

	local META = gine.GetMetaTable("CSoundPatch")

	function META:SetSoundLevel(level)
		self.sound_level = level
	end

	function META:GetSoundLevel()
		return self.sound_level
	end

	function META:Stop()
		self.__obj:Stop()
	end

	function META:Play()
		self.__obj:Play()
	end

	function META:PlayEx(volume, pitch)
		self.__obj:Play()
		self.__obj:SetGain(volume)
		self.__obj:SetPitch(pitch / 100)
	end

	function META:ChangeVolume(volume)
		self.__obj:SetGain(volume)
	end

	function META:ChangePitch(pitch)
		self.__obj:SetPitch(pitch / 100)
	end

	function META:IsPlaying()
		return self.__obj:IsPlaying()
	end
end

if CLIENT then
	function gine.env.surface.PlaySound(path)
		if not SOUND then return end

		local resolved_path = gine.ResolvePath(path, "sound")

		if not resolved_path then return end

		resource.skip_providers = true
		audio.CreateSource(resolved_path):Play()
		resource.skip_providers = false
	end
end

function gine.env.sound.GetTable()
	return {}
end