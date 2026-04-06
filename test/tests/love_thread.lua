local T = import("test/environment.lua")
local line = import("goluwa/love/line.lua")
local ffi = require("ffi")

T.Test2D("love thread channel transport uses object Serialize/Deserialize", function()
	local love = line.CreateLoveEnv("11.0.0")
	local channel = love.thread.newChannel()
	T(type(channel.Serialize))["=="]("function")
	local file_data = love.filesystem.newFileData("hello", "test.txt")
	T(type(file_data.Serialize))["=="]("function")
	channel:push(file_data)
	local file_copy = channel:pop()
	T(file_copy:typeOf("FileData"))["=="](true)
	T(file_copy:getString())["=="]("hello")
	T(file_copy:getFilename())["=="]("test")
	T(file_copy:getExtension())["=="]("txt")
	local image_data = love.image.newImageData(1, 1)
	image_data:setWrap("repeat", "mirroredrepeat")
	image_data:setPixel(0, 0, 1, 0.5, 0.25, 1)
	T(type(image_data.Serialize))["=="]("function")
	channel:push(image_data)
	local image_copy = channel:pop()
	local r, g, b, a = image_copy:getPixel(0, 0)
	local wrap_s, wrap_t = image_copy:getWrap()
	T(image_copy:typeOf("ImageData"))["=="](true)
	T(math.abs(r - 1))["<="](0.01)
	T(math.abs(g - 0.5))["<="](0.01)
	T(math.abs(b - 0.25))["<="](0.02)
	T(math.abs(a - 1))["<="](0.01)
	T(wrap_s)["=="]("repeat")
	T(wrap_t)["=="]("mirroredrepeat")
	local sound_data = love.sound.newSoundData(4, 22050, 16, 1)
	ffi.copy(sound_data:getPointer(), "\x01\x02\x03\x04", 4)
	T(type(sound_data.Serialize))["=="]("function")
	channel:push(sound_data)
	local sound_copy = channel:pop()
	T(sound_copy:typeOf("SoundData"))["=="](true)
	T(sound_copy:getSampleRate())["=="](22050)
	T(sound_copy:getBits())["=="](16)
	T(sound_copy:getChannels())["=="](1)
	T(sound_copy:getString():sub(1, 4))["=="]("\x01\x02\x03\x04")
	local compressed = love.image.newCompressedData{
		is_compressed = true,
		width = 1,
		height = 1,
		depth = 1,
		format = "mock",
		data = ffi.new("uint8_t[4]", {9, 8, 7, 6}),
		size = 4,
		data_size = 4,
		mip_count = 1,
	}
	T(type(compressed.Serialize))["=="]("function")
	channel:push(compressed)
	local compressed_copy = channel:pop()
	T(compressed_copy:typeOf("CompressedData"))["=="](true)
	T(compressed_copy:getWidth())["=="](1)
	T(compressed_copy:getHeight())["=="](1)
	T(compressed_copy:getSize())["=="](4)
	channel:push(channel)
	local same_channel = channel:pop()
	T(same_channel:typeOf("Channel"))["=="](true)
	T(same_channel.id)["=="](channel.id)
end)
