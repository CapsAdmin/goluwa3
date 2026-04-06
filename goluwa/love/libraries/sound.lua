local audio = import("goluwa/audio.lua")
local line = import("goluwa/love/line.lua")
local resource = import("goluwa/resource.lua")
local vfs = import("goluwa/vfs.lua")
local love = ... or _G.love
local ENV = love._line_env
local ffi = require("ffi")
love.sound = love.sound or {}
ENV.transport_deserializers = ENV.transport_deserializers or {}

local function create_buffer_stub(data, size, bits, channels, sample_rate, sample_count)
	local buffer = {
		_data = data,
		_size = size,
		_bits = bits,
		_channels = channels,
		_sample_rate = sample_rate,
		_sample_count = sample_count,
	}

	function buffer:GetData()
		return self._data
	end

	function buffer:GetSize()
		return self._size
	end

	function buffer:GetBits()
		return self._bits
	end

	function buffer:GetChannels()
		return self._channels
	end

	function buffer:GetDuration()
		if self._sample_rate <= 0 or self._channels <= 0 then return 0 end

		return self._sample_count / self._sample_rate
	end

	function buffer:GetLength()
		return self._sample_count
	end

	function buffer:GetSampleRate()
		return self._sample_rate
	end

	function buffer:SetData(new_data, new_size)
		self._data = new_data
		self._size = new_size or self._size
		return self
	end

	return buffer
end

local SoundData = line.TypeTemplate("SoundData", love)

function SoundData:getPointer()
	return self.samples
end

function SoundData:getSize()
	return self.buffer:GetSize()
end

function SoundData:getString()
	return ffi.string(self.buffer:GetData())
end

function SoundData:getBitDepth()
	return self.buffer:GetBits()
end

function SoundData:getBits()
	return self.buffer:GetBits()
end

function SoundData:getChannels()
	return self.buffer:GetChannels()
end

function SoundData:getDuration()
	return self.buffer:GetDuration()
end

function SoundData:getSample(i)
	return self.samples and self.samples[i] or 0
end

function SoundData:getSampleCount()
	return self.buffer:GetLength()
end

function SoundData:getSampleRate()
	return self.buffer:GetSampleRate()
end

function SoundData:Serialize()
	return {
		bits = self:getBits(),
		channels = self:getChannels(),
		data = self:getString(),
		rate = self:getSampleRate(),
		sample_count = self:getSampleCount(),
	}
end

function SoundData.Deserialize(payload, current_love)
	local sample_count = tonumber(payload.sample_count) or 0
	local sound = current_love.sound.newSoundData(
		sample_count,
		tonumber(payload.rate) or 44100,
		tonumber(payload.bits) or 16,
		tonumber(payload.channels) or 1
	)
	local raw = payload.data or ""
	local target = sound.buffer and sound.buffer.GetData and sound.buffer:GetData() or sound.samples

	if target and #raw > 0 then
		ffi.copy(target, raw, math.min(#raw, sound:getSize()))
	end

	return sound
end

ENV.transport_deserializers.SoundData = SoundData.Deserialize

function SoundData:setSample(i, sample)
	if not self.samples then return end

	self.samples[i] = sample * 127
	self.buffer:SetData(self.buffer:GetData()) -- slow!!!
end

local al = desire("al")

local function get_format(channels, bits)
	if al then
		if channels == 1 and bits == 8 then
			return al.e.FORMAT_MONO8
		elseif channels == 1 and bits == 16 then
			return al.e.FORMAT_MONO16
		elseif channels == 2 and bits == 8 then
			return al.e.FORMAT_STEREO8
		elseif channels == 2 and bits == 16 then
			return al.e.FORMAT_STEREO16
		end
	end

	return 0
end

function love.sound.newSoundData(samples, rate, bits, channels)
	local self = line.CreateObject("SoundData", love)
	rate = rate or 44100
	bits = bits or 16
	channels = channels or 1
	self.buffer = create_buffer_stub(nil, 0, bits, channels, rate, 0)

	if type(samples) == "string" then
		self.path = samples

		if resource.Download and audio.Decode then
			resource.Download(samples):Then(function(path)
				local file = vfs.Open(path)
				local data, length, info = audio.Decode(file)
				file:Close()

				if data then
					self.buffer = create_buffer_stub(
						data,
						length,
						bits,
						info.channels or channels,
						info.samplerate or rate,
						length
					)
					self.samples = data
				end
			end)
		end

		return self
	end

	local bytes_per_sample = math.max(1, math.floor(bits / 8))
	local size = math.max(1, samples * channels * bytes_per_sample)
	local data = ffi.new("int8_t[?]", size)
	self.buffer = create_buffer_stub(data, size, bits, channels, rate, samples)
	self.samples = ffi.cast("int8_t*", data)
	return self
end

line.RegisterType(SoundData, love)
local Decoder = line.TypeTemplate("Decoder", love)

function Decoder:getDepth()
	return 8
end

function Decoder:getBits()
	return 8
end

function Decoder:getChannels()
	return self.info.channels
end

function Decoder:getDuration()
	return self.length
end

function Decoder:getSampleRate()
	return self.info.samplerate
end

function love.sound.newDecoder(file, buffer_size)
	local self = line.CreateObject("Decoder", love)
	self.info = {channels = 2, samplerate = 44100}
	self.length = 0
	local source = file

	if line.Type(source) == "File" then
		source = source.file
	elseif line.Type(source) == "string" then
		self.path = source
	end

	if audio.Decode and source and type(source) ~= "string" then
		local decoded_data, length, info = audio.Decode(source)
		self.decoded_data = decoded_data
		self.length = length or 0
		self.info = info or self.info
	end

	return self
end

line.RegisterType(Decoder, love)
