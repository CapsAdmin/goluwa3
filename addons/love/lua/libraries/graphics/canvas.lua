local line = import("lua/line.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local shared = import("addons/love/lua/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love
local ctx = shared.Get(love)
local ENV = ctx.ENV
local ADD_FILTER = ctx.ADD_FILTER
local Canvas = line.TypeTemplate("Canvas", love)
ADD_FILTER(Canvas)

local function get_canvas_depth_format()
	return "d32_sfloat"
end

local function create_canvas_framebuffer(canvas, with_depth) end

local function update_render_size_for_canvas(canvas) end

function Canvas:renderTo(cb)
	local old = love.graphics.getCanvas()
	love.graphics.setCanvas(self)
	local ok, err = pcall(cb)

	if not ok then wlog(err) end

	love.graphics.setCanvas(old)
end

function Canvas:getWidth()
	return self.w
end

function Canvas:getHeight()
	return self.h
end

function Canvas:getDimensions()
	return self.w, self.h
end

function Canvas:getPixelWidth()
	return self.w
end

function Canvas:getPixelHeight()
	return self.h
end

function Canvas:getPixelDimensions()
	return self:getPixelWidth(), self:getPixelHeight()
end

function Canvas:getImageData(x, y, w, h)
	local was_current = ENV.graphics_current_canvas == self

	if was_current then love.graphics.setCanvas() end

	local image_data = love.image._newImageDataFromTexture(self.fb:GetColorTexture())

	if was_current then love.graphics.setCanvas(self) end

	x = math.floor(tonumber(x) or 0)
	y = math.floor(tonumber(y) or 0)
	w = math.floor(tonumber(w) or image_data:getWidth())
	h = math.floor(tonumber(h) or image_data:getHeight())

	if x == 0 and y == 0 and w == image_data:getWidth() and h == image_data:getHeight() then
		return image_data
	end

	local cropped = love.image.newImageData(w, h)
	cropped:paste(image_data, 0, 0, x, y, w, h)
	return cropped
end

function Canvas:newImageData(...)
	return self:getImageData(...)
end

function Canvas:clear(...)
	local count = select("#", ...)
	local depth
	local stencil

	-- Extract depth/stencil when present (count > 4 means r,g,b,a + optional stencil/depth)
	if count > 4 then
		if count == 6 then
			depth = select(-1, ...)
			stencil = select(count - 1, ...)
		else -- count == 5
			depth = nil
			stencil = select(-1, ...)
		end

		if depth == true then depth = 0 elseif not tonumber(depth) then depth = nil end

		if stencil == true then
			stencil = 0
		elseif not tonumber(stencil) then
			stencil = nil
		end
	end

	local colors = {select(1, ...)}

	if type(colors[1]) == "number" then
		colors[1] = {select(1, ...), select(2, ...), select(3, ...), (select(4, ...))}
	end

	if count > 4 then
		for i = #colors, 2, -1 do
			table.remove(colors, i)
		end
	end

	for i, color in ipairs(colors) do
		self.fb:Clear(i, color[1], color[2], color[3], color[4], depth, stencil)
	end
end

function Canvas:setWrap() end

function Canvas:getWrap() end

function love.graphics.newCanvas(w, h)
	if not w or not h then
		local default_w, default_h = ctx.get_main_surface_dimensions()
		w = w or default_w
		h = h or default_h
	end

	local screen_texture = render.GetScreenTexture()
	local self = line.CreateObject("Canvas", love)
	self.w = w
	self.h = h
	self.format = screen_texture.format or "r8g8b8a8_unorm"
	self.filter_min = ENV.graphics_filter_min
	self.filter_mag = ENV.graphics_filter_mag
	self.filter_anistropy = ENV.graphics_filter_anisotropy
	self.fb = Framebuffer.New{
		width = self.w,
		height = self.h,
		format = self.format,
		clear_color = {0, 0, 0, 0},
		min_filter = self.filter_min,
		mag_filter = self.filter_mag,
	}
	ENV.textures[self] = self.fb:GetColorTexture()
	return self
end

function love.graphics.setCanvas(canvas, ...)
	if canvas and canvas[1] then
		canvas = canvas[1]
		print("multiple canvases are not supported")
	elseif ... then
		print("multiple arguments are not supported")
	end

	if canvas then
		ENV.graphics_current_canvas = canvas
		ENV.old_command_buffer = render.SetCommandBuffer(assert(canvas.fb:Begin()))
		render2d.UpdateScreenSize(canvas.w, canvas.h)
		render2d.BindPipeline()
	else
		local canvas = ENV.graphics_current_canvas

		if canvas then
			canvas.fb:End()

			if ENV.old_command_buffer then
				render.SetCommandBuffer(ENV.old_command_buffer)
			end
		end

		ENV.graphics_current_canvas = nil
		local width, height = ctx.get_main_surface_dimensions()
		render2d.UpdateScreenSize(width, height)
	end
end

function love.graphics.getCanvas()
	return ENV.graphics_current_canvas
end

line.RegisterType(Canvas, love)
return love.graphics
