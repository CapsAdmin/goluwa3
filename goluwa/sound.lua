local prototype = require("prototype")
local ffi = require("ffi")
local META = prototype.CreateTemplate("Sound")
prototype.StartStorable(META)
prototype.GetSet(META, "Name", "")
prototype.GetSet(META, "Volume", 1)
prototype.GetSet(META, "Pitch", 1)
prototype.IsSet(META, "Looping", false)
prototype.EndStorable()
prototype.GetSet(META, "Buffer", nil)
prototype.GetSet(META, "BufferLength", 0)
prototype.GetSet(META, "Channels", 2)
prototype.GetSet(META, "SampleRate", 44100)
prototype.GetSet(META, "PlaybackPosition", 0)
prototype.IsSet(META, "Playing", false)
prototype.IsSet(META, "Paused", false)

function META:Start()
	self:SetPlaying(true)
	self:SetPaused(false)
	self:SetPlaybackPosition(0)
end

function META:Stop()
	self:SetPlaying(false)
	self:SetPaused(false)
	self:SetPlaybackPosition(0)
end

function META:Pause()
	if self:IsPlaying() then self:SetPaused(true) end
end

function META:Resume()
	if self:IsPaused() then self:SetPaused(false) end
end

function META:__tostring2()
	return (
		" %s | %.2f%%"
	):format(self:GetName(), (self:GetPlaybackPosition() / self:GetBufferLength()) * 100)
end

return prototype.Register(META)