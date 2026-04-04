local audio = import("goluwa/audio.lua")
local line = import("goluwa/love/line.lua")
local pvars = import("goluwa/pvars.lua")
local vfs = import("goluwa/vfs.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local love = ... or _G.love
local ENV = love._line_env
love.audio = love.audio or {}

if audio.Initialize and not audio.initialized then audio.Initialize() end

local function get_source_count()
	local count = 0

	for _ in pairs(line.GetCreatedObjects("Source")) do
		count = count + 1
	end

	return count
end

local function resolve_source_path(path)
	return vfs.GetAbsolutePath(path, false) or vfs.GetAbsolutePath(path) or path
end

function love.audio.getNumSources()
	return get_source_count()
end

love.audio.getSourceCount = love.audio.getNumSources

function love.audio.getOrientation()
	return audio.GetListenerOrientation()
end

function love.audio.getPosition()
	return audio.GetListenerPosition()
end

function love.audio.getVelocity()
	return audio.GetListenerVelocity()
end

function love.audio.getVolume()
	return audio.GetListenerGain()
end

function love.audio.pause()
	for k, v in pairs(line.GetCreatedObjects("Source")) do
		v:pause()
	end
end

function love.audio.play()
	for k, v in pairs(line.GetCreatedObjects("Source")) do
		v:play()
	end
end

function love.audio.resume()
	for k, v in pairs(line.GetCreatedObjects("Source")) do
		v:resume()
	end
end

function love.audio.rewind()
	for k, v in pairs(line.GetCreatedObjects("Source")) do
		v:rewind()
	end
end

function love.audio.setDistanceModel(name)
	audio.SetDistanceModel(name)
end

function love.audio.getDistanceModel()
	return audio.GetDistanceModel()
end

function love.audio.setOrientation(x, y, z, x2, y2, z2)
	audio.SetListenerOrientation(x, y, z, x2, y2, z2)
end

function love.audio.setPosition(x, y, z)
	audio.SetListenerPosition(x, y, z)
end

function love.audio.setVelocity(x, y, z)
	audio.SetListenerVelocity(x, y, z)
end

function love.audio.setVolume(vol)
	audio.SetListenerGain(vol or 1)
end

function love.audio.newEffect(...) --line only
	return audio.CreateEffect(...)
end

function love.audio.newFilter(...) --line only
	return audio.CreateFilter(...)
end

function love.audio.stop()
	for k, v in pairs(line.GetCreatedObjects("Source")) do
		v:stop()
	end
end

do -- Source
	local Source = line.TypeTemplate("Source")

	function Source:getChannels()
		if self.source and self.source.GetChannels then
			return self.source:GetChannels()
		end

		return 2 --stereo
	end

	function Source:getDirection()
		if self.source then return self.source:GetDirection():Unpack() end

		return 0, 0, 0
	end

	function Source:getDistance()
		if self.source then
			return self.source:GetReferenceDistance(), self.source:GetMaxDistance()
		end

		return 0, 0
	end

	function Source:getPitch()
		if self.source then return self.source:GetPitch() end

		return 1
	end

	function Source:getPosition()
		if self.source then return self.source:GetPosition():Unpack() end

		return 0, 0, 0
	end

	function Source:getRolloff()
		if self.source then return self.source:GetRolloffFactor() end

		return 1
	end

	function Source:getVelocity()
		if self.source then return self.source:GetVelocity():Unpack() end

		return 0, 0, 0
	end

	function Source:getVolume()
		if self.source then return self.source:GetGain() end

		return 1
	end

	function Source:getVolumeLimits()
		return 0, 1
	end

	function Source:isLooping()
		if self.source then return self.source:GetLooping() end

		return false
	end

	function Source:isRelative()
		return not not self.relative
	end

	function Source:isPaused()
		if self.source and self.source.IsPaused then return self.source:IsPaused() end

		if self.source then return not self.playing end

		return false
	end

	function Source:isStatic()
		return false
	end

	function Source:isStopped()
		if self.source and self.source.IsStopped then return self.source:IsStopped() end

		if self.source then return not self.playing end

		return true
	end

	function Source:isPlaying()
		if self.source and self.source.IsPlaying then return self.source:IsPlaying() end

		return self.source ~= nil and not self:isStopped()
	end

	function Source:pause()
		if self.source then
			self.source:Pause()
			self.playing = false
		end
	end

	function Source:play()
		if self.source then
			if pvars.Get("line_enable_audio") then
				self.source:Play()
				self.playing = self.source.IsPlaying and self.source:IsPlaying() or true
			else
				self.playing = false
			end
		end
	end

	function Source:resume()
		if self.source then
			if pvars.Get("line_enable_audio") then
				self.source:Resume()
				self.playing = self.source.IsPlaying and self.source:IsPlaying() or true
			else
				self.playing = false
			end
		end
	end

	function Source:rewind()
		if self.source then self.source:Rewind() end
	end

	function Source:seek(offset, type)
		if self.source then self.source:Seek(offset, type) end
	end

	function Source:stop()
		if self.source then
			self.source:Stop()
			self.playing = false
		end
	end

	function Source:setDirection(x, y, z)
		if self.source then self.source:SetDirection(Vec3(x, y, z)) end
	end

	function Source:setDistance(ref, max)
		if self.source then
			self.source:SetReferenceDistance(ref)
			self.source:SetMaxDistance(max)
		end
	end

	function Source:setAttenuationDistances(ref, max)
		if self.source then
			self.source:SetReferenceDistance(ref)
			self.source:SetMaxDistance(max)
		end
	end

	function Source:setLooping(bool)
		if self.source then self.source:SetLooping(not not bool) end
	end

	function Source:setPitch(pitch)
		if self.source then self.source:SetPitch(pitch) end
	end

	function Source:setRelative(relative)
		self.relative = not not relative
	end

	function Source:setPosition(x, y, z)
		if self.source then self.source:SetPosition(Vec3(x, y, z)) end
	end

	function Source:setRolloff(x)
		if self.source then self.source:SetRolloffFactor(x) end
	end

	function Source:setVelocity(x, y, z)
		if self.source then self.source:SetVelocity(Vec3(x, y, z)) end
	end

	function Source:setVolume(vol)
		if self.source then self.source:SetGain(vol) end
	end

	function Source:setVolumeLimits() end

	function Source:tell(type)
		if self.source then return self.source:Tell(type) end

		return 1
	end

	function Source:addEffect(...) --line only
		if self.source then return self.source:AddEffect(...) end
	end

	function Source:setFilter(...) --line only
		if self.source then return self.source:SetFilter(...) end
	end

	function Source:clone()
		return love.audio.newSource(self.path)
	end

	function love.audio.newSource(var, type)
		local self = line.CreateObject("Source")

		if audio.Initialize and not audio.initialized then audio.Initialize() end

		if line.Type(var) == "string" then
			self.path = resolve_source_path(var)

			if audio.CreateSource then
				local ext = self.path:match(".+%.(.+)")

				if ext == "flac" or ext == "wav" or ext == "ogg" then
					self.source = audio.CreateSource(self.path)
					self.source:SetChannel(1)
				end
			end
		elseif line.Type(var) == "File" then
			if audio.CreateSource then self.source = audio.CreateSource(var) end
		elseif line.Type(var) == "Decoder" then
			if audio.CreateSource then self.source = audio.CreateSource(var) end
		elseif line.Type(var) == "SoundData" then
			if audio.CreateSource then
				if var.getPointer and var:getPointer() then
					self.source = audio.CreateSource(var)

					if self.source.SetBuffer then self.source:SetBuffer(var.buffer) end
				elseif var.path then
					self.path = var.path
					self.source = audio.CreateSource(var.path)
				else
					self.source = audio.CreateSource(var)

					if self.source.SetBuffer then self.source:SetBuffer(var.buffer) end
				end
			end
		else
			wlog("tried to create unknown source type: %s %s", line.Type(var), type, 2)
		end

		self.relative = false
		return self
	end

	line.RegisterType(Source)
end
