local line = import("goluwa/love/line.lua")
local codec = import("goluwa/codec.lua")
local Texture = import("goluwa/render/texture.lua")
local vfs = import("goluwa/vfs.lua")
local love = ... or _G.love
local ENV = love._line_env
local ffi = require("ffi")
love.image = love.image or {}
local DEFAULT_FORMAT = "r8g8b8a8_unorm"

local function clamp_byte(value)
	value = tonumber(value) or 0

	if value < 0 then return 0 end

	if value > 255 then return 255 end

	return math.floor(value)
end

local function image_uses_normalized_color_range()
	return (love._version_major or 0) >= 11
end

local function color_component_to_public(value)
	value = tonumber(value) or 0

	if image_uses_normalized_color_range() then return value / 255 end

	return value
end

local function color_component_from_public(value)
	value = tonumber(value) or 0

	if image_uses_normalized_color_range() and value >= 0 and value <= 1 then
		return clamp_byte(value * 255)
	end

	return clamp_byte(value)
end

local function create_pixel_buffer(size)
	local pixels = ffi.new("uint8_t[?]", size)
	ffi.fill(pixels, size, 0)
	return pixels
end

local function copy_pixels(source, size)
	local pixels = create_pixel_buffer(size)

	if source then ffi.copy(pixels, source, size) end

	return pixels
end

local function create_image_data(width, height, pixels)
	local self = line.CreateObject("ImageData")
	self.width = width
	self.height = height
	self.size = width * height * 4
	self.format = DEFAULT_FORMAT
	self.buffer = pixels or create_pixel_buffer(self.size)
	self.wrap_s = "clamp"
	self.wrap_t = "clamp"
	return self
end

local function get_source_pointer(source)
	if source == nil then return nil end

	if source.pixels then return source.pixels end

	if source.data then return source.data end

	if source.buffer and source.buffer.GetBuffer then
		return source.buffer:GetBuffer()
	end
end

local function get_source_size(source)
	if source == nil then return nil end

	if source.size then return tonumber(source.size) end

	if source.data_size then return tonumber(source.data_size) end

	if source.buffer and source.buffer.GetSize then
		return tonumber(source.buffer:GetSize())
	end
end

local function create_compressed_data(decoded)
	local self = line.CreateObject("CompressedData")
	self.width = decoded.width
	self.height = decoded.height
	self.depth = decoded.depth or 1
	self.size = get_source_size(decoded) or 0
	self.data_size = self.size
	self.format = decoded.format
	self.vulkan_format = decoded.vulkan_format
	self.mip_count = decoded.mip_count or 1
	self.mip_info = decoded.mip_info
	self.is_compressed = true
	self.data = get_source_pointer(decoded)
	self.buffer = decoded.buffer
	self.reflectivity = decoded.reflectivity
	return self
end

local function convert_to_rgba8(source)
	local width = assert(tonumber(source.width), "image width missing")
	local height = assert(tonumber(source.height), "image height missing")
	local pixel_count = width * height
	local out = create_pixel_buffer(pixel_count * 4)
	local format = source.format or source.vulkan_format or DEFAULT_FORMAT
	local pixels = assert(get_source_pointer(source), "image data buffer missing")

	if format == "r8g8b8a8_unorm" or format == "r8g8b8a8_srgb" then
		ffi.copy(out, pixels, pixel_count * 4)
	elseif format == "b8g8r8a8_unorm" or format == "b8g8r8a8_srgb" then
		for i = 0, pixel_count - 1 do
			local src = i * 4
			out[src + 0] = pixels[src + 2]
			out[src + 1] = pixels[src + 1]
			out[src + 2] = pixels[src + 0]
			out[src + 3] = pixels[src + 3]
		end
	elseif format == "r8_unorm" then
		for i = 0, pixel_count - 1 do
			local value = pixels[i]
			local dst = i * 4
			out[dst + 0] = value
			out[dst + 1] = value
			out[dst + 2] = value
			out[dst + 3] = 255
		end
	elseif format == "r8g8_unorm" then
		for i = 0, pixel_count - 1 do
			local src = i * 2
			local dst = i * 4
			out[dst + 0] = pixels[src + 0]
			out[dst + 1] = pixels[src + 1]
			out[dst + 2] = 0
			out[dst + 3] = 255
		end
	elseif format == "r32_sfloat" then
		local floats = ffi.cast("float*", pixels)

		for i = 0, pixel_count - 1 do
			local value = clamp_byte(floats[i] * 255)
			local dst = i * 4
			out[dst + 0] = value
			out[dst + 1] = value
			out[dst + 2] = value
			out[dst + 3] = 255
		end
	elseif format == "r32g32_sfloat" then
		local floats = ffi.cast("float*", pixels)

		for i = 0, pixel_count - 1 do
			local src = i * 2
			local dst = i * 4
			out[dst + 0] = clamp_byte(floats[src + 0] * 255)
			out[dst + 1] = clamp_byte(floats[src + 1] * 255)
			out[dst + 2] = 0
			out[dst + 3] = 255
		end
	elseif format == "r32g32b32_sfloat" then
		local floats = ffi.cast("float*", pixels)

		for i = 0, pixel_count - 1 do
			local src = i * 3
			local dst = i * 4
			out[dst + 0] = clamp_byte(floats[src + 0] * 255)
			out[dst + 1] = clamp_byte(floats[src + 1] * 255)
			out[dst + 2] = clamp_byte(floats[src + 2] * 255)
			out[dst + 3] = 255
		end
	elseif format == "r32g32b32a32_sfloat" then
		local floats = ffi.cast("float*", pixels)

		for i = 0, pixel_count - 1 do
			local src = i * 4
			local dst = i * 4
			out[dst + 0] = clamp_byte(floats[src + 0] * 255)
			out[dst + 1] = clamp_byte(floats[src + 1] * 255)
			out[dst + 2] = clamp_byte(floats[src + 2] * 255)
			out[dst + 3] = clamp_byte(floats[src + 3] * 255)
		end
	elseif format == "r16g16b16a16_unorm" or format == "r16g16b16a16_sfloat" then
		local values = ffi.cast("uint16_t*", pixels)

		for i = 0, pixel_count - 1 do
			local src = i * 4
			local dst = i * 4
			out[dst + 0] = clamp_byte((values[src + 0] / 65535) * 255)
			out[dst + 1] = clamp_byte((values[src + 1] / 65535) * 255)
			out[dst + 2] = clamp_byte((values[src + 2] / 65535) * 255)
			out[dst + 3] = clamp_byte((values[src + 3] / 65535) * 255)
		end
	else
		local source_size = get_source_size(source)

		if source_size == pixel_count * 4 then
			ffi.copy(out, pixels, source_size)
		else
			error("unsupported image format for ImageData: " .. tostring(format), 2)
		end
	end

	return create_image_data(width, height, out)
end

local function flip_image_data_vertical(image_data)
	local row_size = image_data.width * 4
	local flipped = create_pixel_buffer(image_data.size)
	local src = ffi.cast("uint8_t*", image_data.buffer)
	local dst = ffi.cast("uint8_t*", flipped)

	for y = 0, image_data.height - 1 do
		ffi.copy(dst + y * row_size, src + (image_data.height - 1 - y) * row_size, row_size)
	end

	image_data.buffer = flipped
	return image_data
end

local function load_image_data(path)
	local decoded = assert(codec.DecodeFile(line.FixPath(path)))

	if decoded.is_compressed then
		error("compressed image data requires love.image.newCompressedData", 2)
	end

	return flip_image_data_vertical(convert_to_rgba8(decoded))
end

local function create_texture_from_compressed_data(compressed_data, sampler)
	sampler = sampler or {}
	return Texture.New{
		decoded = compressed_data,
		sampler = {
			min_filter = sampler.min_filter,
			mag_filter = sampler.mag_filter,
			anisotropy = sampler.anisotropy,
		},
	}
end

function love.image._newImageDataFromTexture(texture)
	return convert_to_rgba8(texture:Download())
end

function love.image._newImageDataFromDecoded(decoded)
	return convert_to_rgba8(decoded)
end

function love.image._newImageDataFromPixels(width, height, pixels)
	return create_image_data(width, height, copy_pixels(pixels, width * height * 4))
end

function love.image._createTextureFromImageData(image_data, sampler)
	sampler = sampler or {}
	return Texture.New{
		buffer = image_data.buffer,
		width = image_data.width,
		height = image_data.height,
		format = DEFAULT_FORMAT,
		sampler = {
			min_filter = sampler.min_filter,
			mag_filter = sampler.mag_filter,
			anisotropy = sampler.anisotropy,
		},
	}
end

function love.image._createTextureFromCompressedData(compressed_data, sampler)
	return create_texture_from_compressed_data(compressed_data, sampler)
end

function love.image.newCompressedData(source)
	if line.Type(source) == "CompressedData" then return source end

	local decoded = source

	if type(source) == "string" then
		decoded = assert(codec.DecodeFile(line.FixPath(source)))
	end

	assert(type(decoded) == "table", "unsupported CompressedData source")
	assert(decoded.is_compressed, "image is not compressed")
	return create_compressed_data(decoded)
end

do -- compressed data
	local CompressedData = line.TypeTemplate("CompressedData")

	function CompressedData:getWidth()
		return self.width
	end

	function CompressedData:getHeight()
		return self.height
	end

	function CompressedData:getDimensions()
		return self.width, self.height
	end

	function CompressedData:getSize()
		return self.size
	end

	line.RegisterType(CompressedData)
end

do -- image data
	local ImageData = line.TypeTemplate("ImageData")

	local function get_offset(self, x, y)
		x = math.floor(tonumber(x) or 0)
		y = math.floor(tonumber(y) or 0)

		if x < 0 or x >= self.width or y < 0 or y >= self.height then return nil end

		return (y * self.width + x) * 4
	end

	function ImageData:getSize()
		return self.size
	end

	function ImageData:getWidth()
		return self.width
	end

	function ImageData:getHeight()
		return self.height
	end

	function ImageData:getDimensions()
		return self.width, self.height
	end

	function ImageData:setFilter(min, mag)
		self.filter_min = min or self.filter_min
		self.filter_mag = mag or min or self.filter_mag
	end

	function ImageData:paste(source, dx, dy, sx, sy, sw, sh)
		if line.Type(source) ~= "ImageData" then return end

		dx = math.floor(tonumber(dx) or 0)
		dy = math.floor(tonumber(dy) or 0)
		sx = math.floor(tonumber(sx) or 0)
		sy = math.floor(tonumber(sy) or 0)
		sw = math.floor(tonumber(sw) or source.width)
		sh = math.floor(tonumber(sh) or source.height)

		for y = 0, sh - 1 do
			for x = 0, sw - 1 do
				local r, g, b, a = source:getPixel(sx + x, sy + y)
				self:setPixel(dx + x, dy + y, r, g, b, a)
			end
		end
	end

	function ImageData:encode(outfile)
		local path = outfile

		if line.Type(outfile) == "File" then path = outfile.path end

		assert(type(path) == "string", "ImageData:encode requires a path")
		assert(path:ends_with(".png"), "ImageData:encode currently only supports PNG")
		local png = import("goluwa/codecs/png.lua")
		local png_file = png.Encode(self.width, self.height, "rgba")
		local pixel_table = {}

		for i = 0, self.size - 1 do
			pixel_table[i + 1] = self.buffer[i]
		end

		png_file:write(pixel_table)
		local file = assert(vfs.Open(path, "write"))
		file:Write(png_file:getData())
		file:Close()
		return true
	end

	function ImageData:getString()
		return ffi.string(self.buffer, self.size)
	end

	function ImageData:setWrap(wrap_s, wrap_t)
		self.wrap_s = wrap_s or self.wrap_s
		self.wrap_t = wrap_t or wrap_s or self.wrap_t
	end

	function ImageData:getWrap()
		return self.wrap_s, self.wrap_t
	end

	function ImageData:getPixel(x, y)
		local offset = get_offset(self, x, y)

		if not offset then return 0, 0, 0, 0 end

		return color_component_to_public(self.buffer[offset + 0]),
		color_component_to_public(self.buffer[offset + 1]),
		color_component_to_public(self.buffer[offset + 2]),
		color_component_to_public(self.buffer[offset + 3])
	end

	function ImageData:setPixel(x, y, r, g, b, a)
		local offset = get_offset(self, x, y)

		if not offset then return end

		self.buffer[offset + 0] = color_component_from_public(r)
		self.buffer[offset + 1] = color_component_from_public(g)
		self.buffer[offset + 2] = color_component_from_public(b)
		self.buffer[offset + 3] = color_component_from_public(a == nil and (image_uses_normalized_color_range() and 1 or 255) or a)
		self.dirty = true
	end

	function ImageData:mapPixel(cb)
		for y = 0, self.height - 1 do
			for x = 0, self.width - 1 do
				local r, g, b, a = self:getPixel(x, y)
				local nr, ng, nb, na = cb(x, y, r, g, b, a)

				if nr ~= nil then self:setPixel(x, y, nr, ng, nb, na) end
			end
		end

		return self
	end

	function love.image.newImageData(a, b)
		if line.Type(a) == "ImageData" then return a end

		if type(a) == "number" and type(b) == "number" then
			return create_image_data(math.floor(a), math.floor(b))
		end

		if type(a) == "string" then return load_image_data(a) end

		if type(a) == "table" and a.is_compressed then
			error("compressed image data requires love.image.newCompressedData", 2)
		end

		if type(a) == "table" and a.width and a.height and (a.pixels or a.data or a.buffer) then
			return convert_to_rgba8(a)
		end

		error("unsupported ImageData source: " .. tostring(a), 2)
	end

	line.RegisterType(ImageData)
end
