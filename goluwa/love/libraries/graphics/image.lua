local line = import("goluwa/love/line.lua")
local shared = import("goluwa/love/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love
local ctx = shared.Get(love)
local ENV = ctx.ENV
local ADD_FILTER = ctx.ADD_FILTER
local translate_wrap_mode = ctx.translate_wrap_mode
local Image = line.TypeTemplate("Image", love)

function Image:getWidth()
	return ENV.textures[self]:GetSize().x
end

function Image:getHeight()
	return ENV.textures[self]:GetSize().y
end

function Image:getDimensions()
	return ENV.textures[self]:GetSize():Unpack()
end

function Image:getData()
	local tex = ENV.textures[self]
	return love.image._newImageDataFromTexture(tex)
end

ADD_FILTER(Image)

function Image:setWrap(wrap_s, wrap_t)
	self.wrap_s = wrap_s or self.wrap_s
	self.wrap_t = wrap_t or wrap_s or self.wrap_t
	local tex = ENV.textures[self]

	if not tex then return end

	local translated_wrap_s, border_color_s = translate_wrap_mode(self.wrap_s)
	local translated_wrap_t, border_color_t = translate_wrap_mode(self.wrap_t)
	local translated_wrap_r, border_color_r = translate_wrap_mode(self.wrap_t)
	local border_color = border_color_s or border_color_t or border_color_r
	tex:SetWrapS(translated_wrap_s)
	tex:SetWrapT(translated_wrap_t)
	tex:SetWrapR(translated_wrap_r)

	if border_color ~= nil then tex:SetBorderColor(border_color) end
end

function Image:getWrap()
	return self.wrap_s, self.wrap_t
end

function love.graphics.newImage(path)
	if line.Type(path) == "Image" then return path end

	local self = line.CreateObject("Image", love)
	local tex
	local path_type = line.Type(path)
	self.filter_min = ENV.graphics_filter_min
	self.filter_mag = ENV.graphics_filter_mag
	self.filter_anistropy = ENV.graphics_filter_anisotropy
	self.wrap_s = "clamp"
	self.wrap_t = "clamp"

	if path_type == "ImageData" then
		self.wrap_s = path.wrap_s or self.wrap_s
		self.wrap_t = path.wrap_t or self.wrap_t
	end

	if path_type == "ImageData" then
		tex = love.image._createTextureFromImageData(
			path,
			{
				min_filter = self.filter_min,
				mag_filter = self.filter_mag,
				anisotropy = self.filter_anistropy,
			}
		)
	elseif path_type == "CompressedData" then
		tex = love.image._createTextureFromCompressedData(
			path,
			{
				min_filter = self.filter_min,
				mag_filter = self.filter_mag,
				anisotropy = self.filter_anistropy,
			}
		)
	else
		local ok, compressed = pcall(love.image.newCompressedData, path)

		if ok then
			tex = love.image._createTextureFromCompressedData(
				compressed,
				{
					min_filter = self.filter_min,
					mag_filter = self.filter_mag,
					anisotropy = self.filter_anistropy,
				}
			)
		else
			tex = love.image._createTextureFromImageData(
				love.image.newImageData(path),
				{
					min_filter = self.filter_min,
					mag_filter = self.filter_mag,
					anisotropy = self.filter_anistropy,
				}
			)
		end
	end

	ENV.textures[self] = tex
	self:setWrap(self.wrap_s, self.wrap_t)
	return self
end

function love.graphics.newImageData(...)
	return love.image.newImageData(...)
end

line.RegisterType(Image, love)
return love.graphics
