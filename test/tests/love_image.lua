local T = import("test/environment.lua")
local vfs = import("goluwa/vfs.lua")

local function new_love_image_env(with_graphics)
	local love = {_line_env = {}}
	assert(loadfile("goluwa/love/libraries/image.lua"))(love)

	if with_graphics then assert(loadfile("goluwa/love/libraries/graphics.lua"))(love) end

	return love
end

local function write_fixture_png(love)
	local fixture = love.image.newImageData(2, 2)
	fixture:setPixel(0, 0, 11, 22, 33, 44)
	fixture:setPixel(1, 1, 101, 111, 121, 131)
	local path = "os:cache/love_image_compat.png"
	assert(fixture:encode(path))
	return path
end

T.Test("love image data compatibility", function()
	local love = new_love_image_env(false)
	local data = love.image.newImageData(2, 2)
	T(data.__line_type)["=="]("ImageData")
	T(data:getWidth())["=="](2)
	T(data:getHeight())["=="](2)
	T(data:getSize())["=="](16)
	data:setPixel(0, 0, 10, 20, 30, 40)
	data:setPixel(1, 0, 50, 60, 70, 80)
	data:mapPixel(function(_, _, r, g, b, a)
		return r + 1, g + 2, b + 3, a + 4
	end)
	local r, g, b, a = data:getPixel(0, 0)
	T(r)["=="](11)
	T(g)["=="](22)
	T(b)["=="](33)
	T(a)["=="](44)
	local patch = love.image.newImageData(1, 1)
	patch:setPixel(0, 0, 101, 111, 121, 131)
	data:paste(patch, 1, 1, 0, 0, 1, 1)
	r, g, b, a = data:getPixel(1, 1)
	T(r)["=="](101)
	T(g)["=="](111)
	T(b)["=="](121)
	T(a)["=="](131)
	local path = write_fixture_png(love)
	local file = assert(vfs.Open(path))
	local bytes = assert(file:ReadAll())
	file:Close()
	T(#bytes)[">"](0)
	vfs.Delete(path)
end)

T.Test2D("love graphics image from image data", function()
	local love = new_love_image_env(true)
	local data = love.image.newImageData(2, 1)
	data:setPixel(0, 0, 12, 34, 56, 78)
	data:setPixel(1, 0, 90, 87, 65, 43)
	local image = love.graphics.newImage(data)
	T(image.__line_type)["=="]("Image")
	T(image:getWidth())["=="](2)
	T(image:getHeight())["=="](1)
	local readback = image:getData()
	local r, g, b, a = readback:getPixel(1, 0)
	T(r)["=="](90)
	T(g)["=="](87)
	T(b)["=="](65)
	T(a)["=="](43)
	local from_graphics = love.graphics.newImageData(3, 4)
	T(from_graphics.__line_type)["=="]("ImageData")
	T(from_graphics:getWidth())["=="](3)
	T(from_graphics:getHeight())["=="](4)
end)