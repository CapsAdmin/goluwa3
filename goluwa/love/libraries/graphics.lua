local render = import("goluwa/render/render.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local vfs = import("goluwa/vfs.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local window = import("goluwa/window.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local IndexBuffer = import("goluwa/render/index_buffer.lua")
local line = import("goluwa/love/line.lua")
local love = ... or _G.love
local ENV = love._line_env
ENV.textures = ENV.textures or table.weak(true)
ENV.graphics_filter_min = ENV.graphics_filter_min or "linear"
ENV.graphics_filter_mag = ENV.graphics_filter_mag or "linear"
ENV.graphics_filter_anisotropy = ENV.graphics_filter_anisotropy or 1
love.graphics = love.graphics or {}

local function love_uses_normalized_color_range()
	return (love._version_major or 0) >= 11
end

local function get_api_default_alpha()
	if love_uses_normalized_color_range() then return 1 end

	return 255
end

local function color_component_to_internal(value)
	value = value or 0

	if love_uses_normalized_color_range() and value >= 0 and value <= 1 then
		return value * 255
	end

	return value
end

local function color_component_from_internal(value)
	value = value or 0

	if love_uses_normalized_color_range() then return value / 255 end

	return value
end

local function parse_color_bytes(r, g, b, a, default_a)
	if type(r) == "table" then
		return parse_color_bytes(r[1], r[2], r[3], r[4], default_a)
	end

	if a == nil then a = default_a or get_api_default_alpha() end

	return color_component_to_internal(r or 0),
	color_component_to_internal(g or 0),
	color_component_to_internal(b or 0),
	color_component_to_internal(a)
end

local function get_internal_color()
	return ENV.graphics_color_r or 255,
	ENV.graphics_color_g or 255,
	ENV.graphics_color_b or 255,
	ENV.graphics_color_a or 255
end

local function get_internal_background_color()
	return ENV.graphics_bg_color_r or 0,
	ENV.graphics_bg_color_g or 0,
	ENV.graphics_bg_color_b or 0,
	ENV.graphics_bg_color_a or 255
end

local function draw_clear_rect(r, g, b, a, w, h)
	local old_r, old_g, old_b, old_a = love.graphics.getColor()
	render2d.PushMatrix(nil, nil, nil, nil, nil, true)
	render2d.PushTexture(render2d.GetTexture())
	render2d.PushUV(render2d.GetUV())
	render2d.PushAlphaMultiplier(render2d.GetAlphaMultiplier())
	render2d.PushSwizzleMode(render2d.GetSwizzleMode())
	render2d.LoadIdentity()
	render2d.PushBlendMode("one", "zero", "add", "one", "zero", "add")
	render2d.SetTexture()
	render2d.SetUV()
	render2d.SetAlphaMultiplier(1)
	render2d.SetSwizzleMode(0)
	render2d.SetColor(r / 255, g / 255, b / 255, a / 255)
	render2d.DrawRectf(0, 0, w, h)
	render2d.PopBlendMode()
	render2d.PopSwizzleMode()
	render2d.PopAlphaMultiplier()
	render2d.PopUV()
	render2d.PopTexture()
	render2d.PopMatrix()
	love.graphics.setColor(old_r, old_g, old_b, old_a)
end

local function get_texture_dimensions(tex)
	if not tex then return 0, 0 end

	if tex.GetSize then
		local size = tex:GetSize()

		if size then return size.x or 0, size.y or 0 end
	end

	if tex.GetWidth and tex.GetHeight then return tex:GetWidth(), tex:GetHeight() end

	return tex.width or 0, tex.height or 0
end

local function apply_filter_to_texture(tex, min, mag, anisotropy)
	if not tex then return end

	tex.config = tex.config or {}
	tex.config.sampler = tex.config.sampler or {}
	local sampler_config = tex.config.sampler
	sampler_config.min_filter = min or sampler_config.min_filter or "linear"
	sampler_config.mag_filter = mag or sampler_config.mag_filter or sampler_config.min_filter or "linear"
	sampler_config.anisotropy = anisotropy or sampler_config.anisotropy

	if sampler_config.anisotropy and sampler_config.anisotropy < 1 then
		sampler_config.anisotropy = nil
	end

	tex.sampler = render.CreateSampler{
		min_filter = sampler_config.min_filter,
		mag_filter = sampler_config.mag_filter,
		mipmap_mode = sampler_config.mipmap_mode or "linear",
		wrap_s = sampler_config.wrap_s or "repeat",
		wrap_t = sampler_config.wrap_t or "repeat",
		wrap_r = sampler_config.wrap_r or "repeat",
		max_lod = sampler_config.max_lod or (tex.GetMipMapLevels and tex:GetMipMapLevels()) or 1,
		min_lod = sampler_config.min_lod,
		mip_lod_bias = sampler_config.mip_lod_bias,
		anisotropy = sampler_config.anisotropy,
		border_color = sampler_config.border_color,
		unnormalized_coordinates = sampler_config.unnormalized_coordinates,
		compare_enable = sampler_config.compare_enable,
		compare_op = sampler_config.compare_op,
		flags = sampler_config.flags,
	}
end

local function ADD_FILTER(obj)
	obj.setFilter = function(s, min, mag, anistropy)
		s.filter_min = min or s.filter_min or ENV.graphics_filter_min
		s.filter_mag = mag or min or s.filter_mag or ENV.graphics_filter_mag
		s.filter_anistropy = anistropy or s.filter_anistropy or ENV.graphics_filter_anisotropy
		apply_filter_to_texture(ENV.textures[s], s.filter_min, s.filter_mag, s.filter_anistropy)
	end
	obj.getFilter = function(s)
		return s.filter_min, s.filter_mag, s.filter_anistropy
	end
end

do -- filter
	function love.graphics.setDefaultImageFilter(min, mag, anisotropy)
		ENV.graphics_filter_min = min or "linear"
		ENV.graphics_filter_mag = mag or min or "linear"
		ENV.graphics_filter_anisotropy = anisotropy or 1
	end

	love.graphics.setDefaultFilter = love.graphics.setDefaultImageFilter
end

do -- quad
	local Quad = line.TypeTemplate("Quad")

	local function refresh(vertices, x, y, w, h, sw, sh)
		vertices[0].x = 0
		vertices[0].y = 0
		vertices[1].x = 0
		vertices[1].y = h
		vertices[2].x = w
		vertices[2].y = h
		vertices[3].x = w
		vertices[3].y = 0
		vertices[0].s = x / sw
		vertices[0].t = y / sh
		vertices[1].s = x / sw
		vertices[1].t = (y + h) / sh
		vertices[2].s = (x + w) / sw
		vertices[2].t = (y + h) / sh
		vertices[3].s = (x + w) / sw
		vertices[3].t = y / sh
	end

	function Quad:flip() end

	function Quad:getViewport()
		return self.x, self.y, self.w, self.h
	end

	function Quad:setViewport(x, y, w, h)
		self.x = x
		self.y = y
		self.w = w
		self.h = h
		refresh(self.vertices, self.x, self.y, self.w, self.h, self.sw, self.sh)
	end

	function love.graphics.newQuad(x, y, w, h, sw, sh)
		local self = line.CreateObject("Quad")
		local vertices = {}

		for i = 0, 3 do
			vertices[i] = {x = 0, y = 0, s = 0, t = 0}
		end

		self.x = x
		self.y = y
		self.w = w
		self.h = h
		self.sw = sw or 1
		self.sh = sh or 1
		self.vertices = vertices
		refresh(self.vertices, x, y, w, h, sw, sh)
		return self
	end

	line.RegisterType(Quad)
end

love.graphics.origin = render2d.LoadIdentity
love.graphics.translate = render2d.Translatef
love.graphics.shear = render2d.Shear
love.graphics.rotate = render2d.Rotate
love.graphics.push = render2d.PushMatrix
love.graphics.pop = render2d.PopMatrix

function love.graphics.scale(x, y)
	y = y or x
	render2d.Scalef(x, y)
end

function love.graphics.setCaption(title)
	window.SetTitle(title)
end

function love.graphics.getWidth()
	return render.GetWidth()
end

function love.graphics.getHeight()
	return render.GetHeight()
end

function love.graphics.setMode(width, height, fullscreen, vsync, fsaa)
	window.SetSize(Vec2(width, height))
	return true
end

function love.graphics.getMode()
	return window.GetSize().x, window.GetSize().y, false, false, false
end

function love.graphics.getDimensions()
	return render.GetWidth(), render.GetHeight()
end

function love.graphics.reset() end

function love.graphics.isSupported(what)
	llog("is supported: %s", what)
	return true
end

do
	ENV.graphics_color_r = 255
	ENV.graphics_color_g = 255
	ENV.graphics_color_b = 255
	ENV.graphics_color_a = 255

	function love.graphics.setColor(r, g, b, a)
		ENV.graphics_color_r, ENV.graphics_color_g, ENV.graphics_color_b, ENV.graphics_color_a = parse_color_bytes(r, g, b, a, get_api_default_alpha())
		render2d.SetColor(
			ENV.graphics_color_r / 255,
			ENV.graphics_color_g / 255,
			ENV.graphics_color_b / 255,
			ENV.graphics_color_a / 255
		)
	end

	function love.graphics.getColor()
		return color_component_from_internal(ENV.graphics_color_r),
		color_component_from_internal(ENV.graphics_color_g),
		color_component_from_internal(ENV.graphics_color_b),
		color_component_from_internal(ENV.graphics_color_a)
	end
end

do -- background
	ENV.graphics_bg_color_r = 0
	ENV.graphics_bg_color_g = 0
	ENV.graphics_bg_color_b = 0
	ENV.graphics_bg_color_a = 255

	function love.graphics.setBackgroundColor(r, g, b, a)
		ENV.graphics_bg_color_r, ENV.graphics_bg_color_g, ENV.graphics_bg_color_b, ENV.graphics_bg_color_a = parse_color_bytes(r, g, b, a, 255)
	end

	function love.graphics.getBackgroundColor()
		return color_component_from_internal(ENV.graphics_bg_color_r),
		color_component_from_internal(ENV.graphics_bg_color_g),
		color_component_from_internal(ENV.graphics_bg_color_b),
		color_component_from_internal(ENV.graphics_bg_color_a)
	end

	function love.graphics.clear(r, g, b, a)
		local canvas = love.graphics.getCanvas()

		if canvas then
			canvas:clear(r, g, b, a)
		else
			local cr, cg, cb, ca

			if r ~= nil then
				cr, cg, cb, ca = parse_color_bytes(r, g, b, a, 255)
			else
				cr, cg, cb, ca = get_internal_background_color()
			end

			draw_clear_rect(cr, cg, cb, ca, render.GetWidth(), render.GetHeight())
		end
	end
end

do
	local COLOR_MODE = "alpha"
	local ALPHA_MODE = "alphamultiply"

	function love.graphics.setBlendMode(color_mode, alpha_mode)
		alpha_mode = alpha_mode or "alphamultiply"
		local func = "add"
		local srcRGB = "one"
		local srcA = "one"
		local dstRGB = "zero"
		local dstA = "zero"

		if color_mode == "alpha" then
			srcRGB = "one"
			srcA = "one"
			dstRGB = "one_minus_src_alpha"
			dstA = "one_minus_src_alpha"
		elseif color_mode == "multiply" or color_mode == "multiplicative" then
			srcRGB = "dst_color"
			srcA = "dst_alpha"
			dstRGB = "zero"
			dstA = "zero"
		elseif color_mode == "subtract" or color_mode == "subtractive" then
			func = "subtract"
		elseif color_mode == "add" or color_mode == "additive" then
			srcRGB = "one"
			srcA = "zero"
			dstRGB = "one"
			dstA = "one"
		elseif color_mode == "lighten" then
			func = "max"
		elseif color_mode == "darken" then
			func = "min"
		elseif color_mode == "screen" then
			srcRGB = "one"
			srcA = "one"
			dstRGB = "one_minus_src_color"
			dstA = "one_minus_src_color"
		else --if color_mode == "replace" then
			srcRGB = "one"
			srcA = "one"
			dstRGB = "zero"
			dstA = "zero"
		end

		if srcRGB == "one" and alpha_mode == "alphamultiply" then
			srcRGB = "src_alpha"
		end

		render2d.SetBlendMode(srcRGB, dstRGB, func, srcA, dstA, func)
		COLOR_MODE = color_mode
		ALPHA_MODE = alpha_mode
	end

	function love.graphics.getBlendMode()
		return COLOR_MODE, ALPHA_MODE
	end
end

do
	function love.graphics.setColorMode(mode)
		if mode == "replace" then mode = "none" end
	--render2d.SetColorMode(mode)
	end

	function love.graphics.getColorMode()
		--return render2d.GetBlendMode()
		return "modulate"
	end
end

do -- points
	local SIZE = 1
	local STYLE = "rough"

	function love.graphics.setPointStyle(style)
		STYLE = style
	end

	function love.graphics.getPointStyle()
		return STYLE
	end

	function love.graphics.setPointSize(size)
		SIZE = size
	end

	function love.graphics.getPointSize()
		return SIZE
	end

	function love.graphics.setPoint(size, style)
		love.graphics.setPointSize(size)
		love.graphics.setPointStyle(style)
	end

	function love.graphics.point(x, y)
		if STYLE == "rough" then
			render2d.PushTexture()
			render2d.DrawRect(x, y, SIZE, SIZE, nil, SIZE / 2, SIZE / 2)
			render2d.PopTexture()
		else
			gfx.DrawFilledCircle(x, y, SIZE)
		end
	end

	function love.graphics.points(...)
		local points = ...

		if type(points) == "number" then points = {...} end

		if type(points[1]) == "number" then
			for i = 1, #points, 2 do
				love.graphics.point(points[i + 0], points[i + 1])
			end
		else
			for i, point in ipairs(points) do
				if point[3] then
					render2d.SetColor(
						(point[3] or 255) / 255,
						(point[4] or 255) / 255,
						(point[5] or 255) / 255,
						(point[6] or 255) / 255
					)
				end

				love.graphics.point(point[1], point[2])
			end
		end
	end
end

do -- font
	local Font = line.TypeTemplate("Font")

	function Font:getWidth(str)
		str = str or "W"
		return (self.font:GetTextSize(str)) + 2
	end

	function Font:getHeight(str)
		str = str or "W"
		return select(2, self.font:GetTextSize(str)) + 2
	end

	function Font:setLineHeight(num)
		self.line_height = num
	end

	function Font:getLineHeight(num)
		self.line_height = num
	end

	function Font:getBaseline()
		return 0
	end

	function Font:getWrap(str, width)
		str = tostring(str)
		local old = fonts.GetFont()
		fonts.SetFont(self.font)
		local res = self.font:WrapString(str, width)
		local w = self.font:GetTextSize(str) + 2
		fonts.SetFont(old)

		if love._version_minor < 10 and love._version_revision == 0 then
			return w, res:split("\n")
		end

		if love._version_minor >= 10 then return w, res end

		return w, math.max(res:count("\n"), 1)
	end

	function Font:setFilter(filter)
		self.filter = filter
	end

	function Font:getFilter()
		return self.filter
	end

	function Font:setFallbacks(...) end

	local function create_font(path, size, glyphs, texture)
		local self = line.CreateObject("Font")
		self:setLineHeight(1)
		path = line.FixPath(path)

		if not vfs.IsFile(path) then path = fonts.GetDefaultSystemFontPath() end

		self.font = fonts.New{
			Size = size and (size * 1.25),
			Path = path ~= "memory" and path or fonts.GetDefaultSystemFontPath(),
		}
		self.Name = self.font:GetName()
		local w, h = self.font:GetTextSize("W")
		self.Size = size or w
		return self
	end

	function love.graphics.newFont(a, b)
		local font = a
		local size = b

		if type(a) == "number" then
			font = "fonts/vera.ttf"
			size = a
		end

		if not a then
			font = "fonts/vera.ttf"
			size = b or 11
		end

		size = size or 12
		return create_font(font, size)
	end

	function love.graphics.newImageFont(path, glyphs)
		local tex

		if line.Type(path) == "Image" then
			tex = ENV.textures[path]
			path = "memory"
		end

		return create_font(path, nil, glyphs, tex)
	end

	function love.graphics.setFont(font)
		font = font or love.graphics.getFont()
		ENV.current_font = font
		fonts.SetFont(font.font)
	end

	function love.graphics.getFont()
		if not ENV.default_font then ENV.default_font = love.graphics.newFont() end

		return ENV.current_font or ENV.default_font
	end

	function love.graphics.setNewFont(...)
		love.graphics.setFont(love.graphics.newFont(...))
	end

	local function draw_text(text, x, y, r, sx, sy, ox, oy, kx, ky, align, limit)
		local font = love.graphics.getFont()
		love.graphics.setFont(font)
		text = tostring(text)
		x = x or 0
		y = y or 0
		sx = sx or 1
		sy = sy or sx
		r = r or 0
		ox = ox or 0
		oy = oy or 0
		kx = kx or 0
		ky = ky or 0
		local cr, cg, cb, ca = get_internal_color()
		ca = ca or 255
		render2d.PushColor(cr / 255, cg / 255, cb / 255, ca / 255)
		render2d.PushMatrix(x, y, sx, sy, r)
		render2d.Translate(ox, oy)

		if align then
			local max_width = 0
			local t = font.font:WrapString(text, limit):split("\n")

			for i, line in ipairs(t) do
				local w, h = font.font:GetTextSize(line)

				if w > max_width then max_width = w end
			end

			for i, line in ipairs(t) do
				local w, h = font.font:GetTextSize(line)
				local align_x = 0

				if align == "right" then
					align_x = max_width - w
				elseif align == "center" then
					align_x = (max_width - w) / 2
				end

				font.font:DrawText(line, align_x, (i - 1) * h * font.line_height)
			end
		else
			font.font:DrawText(text, 0, 0)
		end

		render2d.PopMatrix()
		render2d.PopColor()
	end

	function love.graphics.print(text, x, y, r, sx, sy, ox, oy, kx, ky)
		return draw_text(text, x, y, r, sx, sy, ox, oy, kx, ky)
	end

	function love.graphics.printf(text, x, y, limit, align, r, sx, sy, ox, oy, kx, ky)
		return draw_text(text, x, y, r, sx, sy, ox, oy, kx, ky, align or "left", limit or 0)
	end

	line.RegisterType(Font)
end

do -- line
	ENV.graphics_line_width = 1
	ENV.graphics_line_style = "rough"
	ENV.graphics_line_join = "miter"

	function love.graphics.setLineStyle(s)
		ENV.graphics_line_style = s
	end

	function love.graphics.getLineStyle()
		return ENV.graphics_line_style
	end

	function love.graphics.setLineJoin(s)
		ENV.graphics_line_join = s
	end

	function love.graphics.getLineJoin(s)
		return ENV.graphics_line_join
	end

	function love.graphics.setLineWidth(w)
		ENV.graphics_line_width = w
	end

	function love.graphics.getLineWidth()
		return ENV.graphics_line_width
	end

	function love.graphics.setLine(w, s)
		love.graphics.setLineWidth(w)
		love.graphics.setLineStyle(s)
	end
end

do -- canvas
	local Canvas = line.TypeTemplate("Canvas")
	ADD_FILTER(Canvas)

	local function update_render_size_for_canvas(canvas)
		if canvas then
			render2d.UpdateScreenSize{w = canvas.w, h = canvas.h}
		else
			local width = render.GetWidth and render.GetWidth() or nil
			local height = render.GetHeight and render.GetHeight() or nil

			if width and height and width > 0 and height > 0 then
				render2d.UpdateScreenSize{w = width, h = height}
			else
				local size = render.GetRenderImageSize()
				render2d.UpdateScreenSize{w = size.x, h = size.y}
			end
		end
	end

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

	function Canvas:getImageData() end

	function Canvas:clear(...)
		local r, g, b, a

		if select("#", ...) > 0 then
			local cr, cg, cb, ca = ...
			r, g, b, a = parse_color_bytes(cr, cg, cb, ca, 255)
		else
			r, g, b, a = 0, 0, 0, 0
		end

		if self._canvas_cmd and render2d.cmd == self._canvas_cmd then
			draw_clear_rect(r, g, b, a, self.w, self.h)
		else
			local old_clear_color = self.fb.clear_colors[1]
			self.fb.clear_colors[1] = {r / 255, g / 255, b / 255, a / 255}
			self.fb.clear_color = self.fb.clear_colors[1]
			self.fb:Begin(nil, "clear")
			self.fb:End()
			self.fb.clear_colors[1] = old_clear_color
			self.fb.clear_color = old_clear_color
		end
	end

	function Canvas:setWrap() end

	function Canvas:getWrap() end

	function love.graphics.newCanvas(w, h)
		w = w or render.GetWidth()
		h = h or render.GetHeight()
		local screen_texture = render.GetScreenTexture and render.GetScreenTexture()
		local self = line.CreateObject("Canvas")
		self.w = w
		self.h = h
		self.fb = Framebuffer.New{
			width = w,
			height = h,
			format = screen_texture and screen_texture.format or "r8g8b8a8_unorm",
			clear_color = {0, 0, 0, 0},
			min_filter = ENV.graphics_filter_min,
			mag_filter = ENV.graphics_filter_mag,
		}
		self.filter_min = ENV.graphics_filter_min
		self.filter_mag = ENV.graphics_filter_mag
		self.filter_anistropy = ENV.graphics_filter_anisotropy
		ENV.textures[self] = self.fb:GetColorTexture()
		return self
	end

	function love.graphics.setCanvas(canvas)
		if ENV.graphics_current_canvas == canvas then return end

		local current = ENV.graphics_current_canvas

		if current and current._canvas_cmd then
			current.fb:End(current._canvas_cmd)
			current._canvas_cmd = nil
			render2d.cmd = ENV.graphics_previous_canvas_cmd
			ENV.graphics_previous_canvas_cmd = nil
		end

		ENV.graphics_current_canvas = canvas

		if canvas then
			ENV.graphics_previous_canvas_cmd = render2d.cmd
			canvas._canvas_cmd = canvas.fb:Begin()
			render2d.BindPipeline(canvas._canvas_cmd)
			update_render_size_for_canvas(canvas)
		else
			if render2d.cmd then render2d.BindPipeline(render2d.cmd) end

			update_render_size_for_canvas()
		end
	end

	function love.graphics.getCanvas()
		return ENV.graphics_current_canvas
	end

	line.RegisterType(Canvas)
end

do -- image
	local Image = line.TypeTemplate("Image")

	function Image:getWidth()
		local w = get_texture_dimensions(ENV.textures[self])
		return w
	end

	function Image:getHeight()
		local _, h = get_texture_dimensions(ENV.textures[self])
		return h
	end

	function Image:getDimensions()
		return get_texture_dimensions(ENV.textures[self])
	end

	function Image:getHeight()
		local _, h = get_texture_dimensions(ENV.textures[self])
		return h
	end

	function Image:getData()
		local tex = ENV.textures[self]
		return love.image._newImageDataFromTexture(tex)
	end

	ADD_FILTER(Image)

	function Image:setWrap() end

	function Image:getWrap() end

	function love.graphics.newImage(path)
		if line.Type(path) == "Image" then return path end

		local self = line.CreateObject("Image")
		local tex
		self.filter_min = ENV.graphics_filter_min
		self.filter_mag = ENV.graphics_filter_mag
		self.filter_anistropy = ENV.graphics_filter_anisotropy

		if line.Type(path) == "ImageData" then
			tex = love.image._createTextureFromImageData(
				path,
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

		ENV.textures[self] = tex
		return self
	end

	function love.graphics.newImageData(...)
		return love.image.newImageData(...)
	end

	line.RegisterType(Image)
end

do -- stencil
	function love.graphics.newStencil(func) end

	function love.graphics.setStencil(func) end

	function love.graphics.setStencilTest(mode, val)
		if mode then
			render.SetStencil(true)
			ENV.graphics_stencil_mode = mode
			ENV.graphics_stencil_val = val
			render.StencilFunction(mode, val)
		else
			render.SetStencil(false)
			ENV.graphics_stencil_mode = "always"
			ENV.graphics_stencil_val = 0
		end
	end

	function love.graphics.getStencilTest()
		return ENV.graphics_stencil_mode or "always", ENV.graphics_stencil_val or 0
	end

	function love.graphics.stencil(func, action, num, keep)
		render.SetStencil(true)

		if not keep then render.GetFrameBuffer():ClearStencil(0) end

		local old_mode, old_val = love.graphics.getStencilTest()
		render.StencilFunction("always", num, 0xFFFFFFFF)
		render.StencilOperation("keep", "keep", action)
		render.SetColorMask(0, 0, 0, 0)
		func()
		render.SetColorMask(1, 1, 1, 1)
		render.StencilFunction(old_mode, old_val)
	end
end

function love.graphics.rectangle(mode, x, y, w, h)
	if mode == "fill" then
		render2d.SetTexture()
		render2d.DrawRect(x, y, w, h)
	else
		gfx.DrawLine(x, y, x + w, y)
		gfx.DrawLine(x, y, x, y + h)
		gfx.DrawLine(x + w, y, x + w, y + h)
		gfx.DrawLine(x, y + h, x + w, y + h)
	end
end

function love.graphics.roundrect(mode, x, y, w, h)
	return love.graphics.rectangle(mode, x, y, w, h)
end

function love.graphics.drawq(drawable, quad, x, y, r, sx, sy, ox, oy, kx, ky)
	x = x or 0
	y = y or 0
	sx = sx or 1
	sy = sy or sx
	ox = ox or 0
	oy = oy or 0
	r = r or 0
	kx = kx or 0
	ky = ky or 0
	local cr, cg, cb, ca = get_internal_color()
	ca = ca or 255
	render2d.SetColor(cr / 255, cg / 255, cb / 255, ca / 255)
	render2d.PushSwizzleMode(render2d.GetSwizzleMode())
	render2d.SetSwizzleMode(0)
	render2d.PushTexture(ENV.textures[drawable])
	render2d.SetUV(quad.x, -quad.y, quad.w, -quad.h, quad.sw, quad.sh)
	render2d.DrawRectf(x, y, quad.w * sx, quad.h * sy, r, ox * sx, oy * sy)
	render2d.SetUV()
	render2d.PopTexture()
	render2d.PopSwizzleMode()
end

function love.graphics.draw(drawable, x, y, r, sx, sy, ox, oy, kx, ky, quad_arg)
	local drawable_texture = ENV.textures[drawable]

	if
		not drawable_texture and
		(
			line.Type(drawable) == "Image" or
			line.Type(drawable) == "Canvas"
		)
	then
		if drawable.fb and drawable.fb.GetColorTexture then
			drawable_texture = drawable.fb:GetColorTexture()
			ENV.textures[drawable] = drawable_texture
		end
	end

	if drawable_texture then
		if line.Type(x) == "Quad" then
			love.graphics.drawq(drawable, x, y, r, sx, sy, ox, oy, kx, ky, quad_arg)
		else
			x = x or 0
			y = y or 0
			sx = sx or 1
			sy = sy or sx
			ox = ox or 0
			oy = oy or 0
			r = r or 0
			kx = kx or 0
			ky = ky or 0
			local tex = drawable_texture
			local tex_w, tex_h = get_texture_dimensions(tex)
			local cr, cg, cb, ca = get_internal_color()
			ca = ca or 255
			render2d.SetColor(cr / 255, cg / 255, cb / 255, ca / 255)
			render2d.PushSwizzleMode(render2d.GetSwizzleMode())
			render2d.SetSwizzleMode(0)
			render2d.PushTexture(tex)
			render2d.PushUV()
			render2d.SetUV(0, 0, tex_w, -tex_h, tex_w, tex_h)
			render2d.DrawRectf(x, y, tex_w * sx, tex_h * sy, r, ox * sx, oy * sy)
			render2d.PopUV()
			render2d.PopTexture()
			render2d.PopSwizzleMode()
		end
	else
		x = x or 0
		y = y or 0
		sx = sx or 1
		sy = sy or sx
		ox = ox or 0
		oy = oy or 0
		r = r or 0
		kx = kx or 0
		ky = ky or 0

		if line.Type(drawable) == "SpriteBatch" then
			drawable:Draw(x, y, r, sx, sy, ox, oy, kx, ky)
		elseif line.Type(drawable) == "Mesh" then
			render2d.PushColor(1, 1, 1, 1)
			render2d.PushTexture(ENV.textures[drawable.img])
			render2d.PushMatrix(nil, nil, nil, nil, nil, true)
			render2d.Translatef(x, y)
			render2d.Rotate(r)

			if ox ~= 0 or oy ~= 0 then render2d.Translatef(-ox * sx, -oy * sy) end

			if kx ~= 0 or ky ~= 0 then render2d.Shear(kx, ky) end

			render2d.Scalef(sx, sy)
			render2d.UploadConstants(render2d.cmd)
			drawable:Draw()
			render2d.PopMatrix()
			render2d.PopTexture()
			render2d.PopColor()
		elseif line.Type(drawable) == "ParticleSystem" then

		else
			table.print(drawable)
			debug.trace()
		end
	end
end

function love.graphics.present() end

function love.graphics.setIcon() end

do
	do
		local Shader = line.TypeTemplate("Shader")

		function Shader:getWarnings()
			return ""
		end

		function Shader:sendColor(name, tbl, ...)
			if ... then warning("uh oh") end

			local loc = self.shader.program:GetUniformLocation(name)
			self.shader.program:UploadColor(loc, ColorBytes(unpack(tbl)))
		end

		function Shader:send(name, var, ...)
			if ... then warning("uh oh") end

			local loc = self.shader.program:GetUniformLocation(name)
			local t = type(var)

			if t == "number" then
				self.shader.program:UploadNumber(loc, var)
			elseif t == "boolean" then
				self.shader.program:UploadBoolean(loc, var)
			elseif ENV.textures[var] then
				self.shader.program:UploadTexture(loc, ENV.textures[var], 0, 0)
			elseif t == "table" then
				if type(var[1]) == "number" then
					if #var == 2 then
						self.shader.program:UploadVec2(loc, Vec2(unpack(var)))
					elseif #var == 3 then
						self.shader.program:UploadVec3(loc, Vec3(unpack(var)))
					elseif #var == 16 then
						self.shader.program:UploadMatrix44(loc, Vec2(unpack(var)))
					end
				else
					if #var == 4 then
						self.shader.program:UploadMatrix44(
							loc,
							Matrix44(
								var[1][1],
								var[1][2],
								var[1][3],
								var[1][4],
								var[2][1],
								var[2][2],
								var[2][3],
								var[2][4],
								var[3][1],
								var[3][2],
								var[3][3],
								var[3][4],
								var[4][1],
								var[4][2],
								var[4][3],
								var[4][4]
							)
						)
					elseif #var == 3 then
						warning("uh oh")
					end
				end
			end
		end

		function love.graphics.newShader(frag, vert)
			if type(frag) == "string" and frag:ends_with(".glsl") then
				frag = love.filesystem.read(frag)
			end

			if type(vert) == "string" and vert:ends_with(".glsl") then
				vert = love.filesystem.read(vert)
			end

			local obj = line.CreateObject("Shader")
			local shader = render.CreateShader{
				fragment = {
					mesh_layout = {
						{uv = "vec2"},
					},
					variables = {
						love_ScreenSize = {
							vec2 = function()
								if ENV.graphics_current_canvas then
									local tex_w, tex_h = get_texture_dimensions(ENV.graphics_current_canvas.fb:GetColorTexture())
									return Vec2(tex_w, tex_h)
								end

								return window.GetSize()
							end,
						},
						current_texture = {
							texture = function()
								return render2d.shader.tex
							end,
						},
						current_color = {
							color = function()
								return render2d.shader.global_color
							end,
						},
					},
					include_directories = {
						"shaders/include/",
					},
					source = [[
						#version 430 core

						#define number float
						#define Image sampler2D
						#define Texel texture2D
						#define extern uniform
						#define PIXEL 1

						]] .. frag .. [[

						out vec4 out_color;

						void main()
						{
							out_color = effect(current_color, current_texture, uv, gl_FragCoord.xy);
						}
					]],
				},
			}
			obj.shader = shader
			return obj
		end

		line.RegisterType(Shader)
	end

	love.graphics.newPixelEffect = love.graphics.newShader

	function love.graphics.setShader(obj)
		ENV.current_shader = obj
		render2d.shader_override = obj and obj.shader or nil
	end

	function love.graphics.getShader()
		return ENV.current_shader
	end

	love.graphics.setPixelEffect = love.graphics.setShader
end

function love.graphics.isCreated()
	return true
end

function love.graphics.getModes()
	return {
		{width = 720, height = 480},
		{width = 800, height = 480},
		{width = 800, height = 600},
		{width = 852, height = 480},
		{width = 1024, height = 768},
		{width = 1152, height = 768},
		{width = 1152, height = 864},
		{width = 1280, height = 720},
		{width = 1280, height = 768},
		{width = 1280, height = 800},
		{width = 1280, height = 854},
		{width = 1280, height = 960},
		{width = 1280, height = 1024},
		{width = 1365, height = 768},
		{width = 1366, height = 768},
		{width = 1400, height = 1050},
		{width = 1440, height = 900},
		{width = 1440, height = 960},
		{width = 1600, height = 900},
		{width = 1600, height = 1200},
		{width = 1680, height = 1050},
		{width = 1920, height = 1080},
		{width = 1920, height = 1200},
		{width = 2048, height = 1536},
		{width = 2560, height = 1600},
		{width = 2560, height = 2048},
	}
end

function love.graphics.getStats()
	return {
		fonts = 1,
		images = 1,
		canvases = 1,
		images = 1,
		texturememory = 1,
		canvasswitches = 1,
		drawcalls = 1,
	}
end

function love.graphics.getRendererInfo()
	local screen_texture = render.GetScreenTexture and render.GetScreenTexture()
	local version = screen_texture and screen_texture.format or "unknown"
	return "Vulkan", version, "Goluwa", "Goluwa Vulkan Renderer"
end

do
	function love.graphics.setScissor(x, y, w, h)
		if x == nil then
			ENV.scissor = nil
			local sw, sh = render2d.GetSize()
			render2d.SetScissor(0, 0, sw or 0, sh or 0)
			return
		end

		ENV.scissor = {x = x or 0, y = y or 0, w = w or 0, h = h or 0}
		render2d.SetScissor(ENV.scissor.x, ENV.scissor.y, ENV.scissor.w, ENV.scissor.h)
	end

	function love.graphics.getScissor()
		if not ENV.scissor then return end

		return ENV.scissor.x, ENV.scissor.y, ENV.scissor.w, ENV.scissor.h
	end
end

do -- shapes
	local mesh = render2d.CreateMesh(2048)

	for i = 1, 2048 do
		mesh:SetVertex(i, "color", 1, 1, 1, 1)
	end

	local mesh_idx = IndexBuffer.New()
	mesh_idx:LoadIndices(2048)

	local function triangle_list_indices(mode, source_indices)
		mode = mode or "triangles"

		if mode == "triangles" or mode == "triangle_list" then
			return source_indices
		elseif mode == "triangle_strip" or mode == "strip" then
			local out = {}

			for i = 1, #source_indices - 2 do
				local a = source_indices[i]
				local b = source_indices[i + 1]
				local c = source_indices[i + 2]

				if i % 2 == 0 then a, b = b, a end

				list.insert(out, a)
				list.insert(out, b)
				list.insert(out, c)
			end

			return out
		elseif mode == "triangle_fan" or mode == "fan" then
			local out = {}
			local first = source_indices[1]

			for i = 2, #source_indices - 1 do
				list.insert(out, first)
				list.insert(out, source_indices[i])
				list.insert(out, source_indices[i + 1])
			end

			return out
		end

		return source_indices
	end

	local function polygon(mode, points, join)
		render2d.PushTexture()
		local idx = 1

		if mode == "line" then
			local draw_mode, vertices, indices = math2d.CoordinatesToLines(points, love.graphics.getLineWidth(), join, love.graphics.getLineJoin(), 1, false) --love.graphics.getLineStyle() == "smooth", true)
			local draw_indices

			if indices then
				draw_indices = indices
			else
				draw_indices = {}

				for i = 1, #vertices do
					draw_indices[i] = i - 1
				end
			end

			draw_indices = triangle_list_indices(draw_mode, draw_indices)

			for i, v in ipairs(draw_indices) do
				mesh_idx:SetIndex(i, v)
			end

			idx = #draw_indices

			for i, v in ipairs(vertices) do
				mesh:SetVertex(i, "pos", v.x, v.y)
			end
		else
			local draw_indices = {}
			local vertex_count = 0

			for i = 1, #points, 2 do
				mesh:SetVertex(idx, "pos", points[i + 0], points[i + 1])
				draw_indices[#draw_indices + 1] = vertex_count
				vertex_count = vertex_count + 1
				idx = idx + 1
			end

			draw_indices = triangle_list_indices("triangle_fan", draw_indices)

			for i, v in ipairs(draw_indices) do
				mesh_idx:SetIndex(i, v)
			end

			idx = #draw_indices
		end

		mesh:UpdateBuffer()
		mesh_idx:UpdateBuffer()
		render2d.BindMesh(mesh)
		render2d.UploadConstants(render2d.cmd)
		mesh:Draw(mesh_idx, idx)
		render2d.PopTexture()
	end

	function love.graphics.polygon(mode, ...)
		local points = type(...) == "table" and ... or {...}
		polygon(mode, points, true)
	end

	function love.graphics.arc(...)
		local draw_mode, arc_mode, x, y, radius, angle1, angle2, points

		if type(select(2, ...)) == "number" then
			draw_mode, x, y, radius, angle1, angle2, points = ...
			arc_mode = "pie"
		else
			draw_mode, arc_mode, x, y, radius, angle1, angle2, points = ...
		end

		if
			draw_mode == "line" and
			arc_mode == "closed" and
			math.abs(angle1 - angle2) < math.rad(4)
		then
			arc_mode = "open"
		end

		if draw_mode == "fill" and arc_mode == "open" then arc_mode = "closed" end

		local coords = math2d.ArcToCoordinates(arc_mode, x, y, radius, angle1, angle2, points)

		if coords then polygon(draw_mode, coords) end
	end

	function love.graphics.ellipse(mode, x, y, radiusx, radiusy, points)
		local coords = math2d.EllipseToCoordinates(x, y, radiusx, radiusy, points)
		polygon(mode, coords)
	end

	function love.graphics.circle(mode, x, y, radius, points)
		if not points then
			if radius and radius > 10 then
				points = math.ceil(radius)
			else
				points = 10
			end
		end

		love.graphics.ellipse(mode, x, y, radius, radius, points)
	end

	function love.graphics.line(...)
		local tbl = ...

		if type(tbl) == "number" then tbl = {...} end

		polygon("line", tbl)
	end

	function love.graphics.triangle(mode, x1, y1, x2, y2, x3, y3)
		polygon(mode, {x1, y1, x2, y2, x3, y3, x1, y1})
	end

	function love.graphics.rectangle(mode, x, y, w, h, rx, ry, points)
		rx = rx or 0
		ry = ry or rx

		if mode == "fill" then
			render2d.PushSwizzleMode(render2d.GetSwizzleMode())
			render2d.SetSwizzleMode(0)
			render2d.SetTexture()
			render2d.DrawRect(x, y, w, h)
			render2d.PopSwizzleMode()
		else
			local coords = math2d.RoundedRectangleToCoordinates(x, y, w, h, rx, ry, points)
			polygon("line", coords, true)
		end
	end
end

do
	local Mesh = line.TypeTemplate("Mesh")

	local function triangle_list_indices(mode, source_indices)
		mode = mode or "triangles"

		if mode == "triangles" or mode == "triangle_list" then
			return source_indices
		elseif mode == "triangle_strip" or mode == "strip" then
			local out = {}

			for i = 1, #source_indices - 2 do
				local a = source_indices[i]
				local b = source_indices[i + 1]
				local c = source_indices[i + 2]

				if i % 2 == 0 then a, b = b, a end

				list.insert(out, a)
				list.insert(out, b)
				list.insert(out, c)
			end

			return out
		elseif mode == "triangle_fan" or mode == "fan" then
			local out = {}
			local first = source_indices[1]

			for i = 2, #source_indices - 1 do
				list.insert(out, first)
				list.insert(out, source_indices[i])
				list.insert(out, source_indices[i + 1])
			end

			return out
		end

		return source_indices
	end

	local function rebuild_index_buffer(self)
		local source_indices = self.vertex_map or {}
		local draw_indices = triangle_list_indices(self.draw_mode, source_indices)
		self.index_buffer.indices = draw_indices
		self.index_buffer.index_count = #draw_indices
		self.index_buffer:UpdateBuffer()
	end

	function love.graphics.newMesh(...)
		local vertices
		local vertex_count
		local vertex_format
		local mode
		local usage
		local texture

		if
			type(select(1, ...)) == "table" and
			(
				line.Type(select(2, ...)) == "Image" or
				line.Type(select(2, ...)) == "Canvas"
			)
		then --(mesh_vertices, texture, 'triangles')
			vertices, texture, mode = ...
			vertex_count = #vertices
		elseif type(select(1, ...)) == "table" and type(select(2, ...)) == "table" then
			vertex_format, vertices, mode, usage = ...
			vertex_count = #vertices
		elseif type(...) == "number" then
			vertex_count, mode, usage = ...
		elseif type(...) == "table" then
			vertices, mode, usage = ...
			vertex_count = #vertices
		end

		local self = line.CreateObject("Mesh")
		self.vertex_buffer = render2d.CreateMesh(vertex_count)
		local mesh_idx = IndexBuffer.New()
		mesh_idx:LoadIndices(vertex_count)
		self.index_buffer = mesh_idx
		self.draw_mode = "triangles"
		self.vertex_map = {}

		for i = 1, vertex_count do
			self.vertex_map[i] = i - 1
		end

		self.vertex_format = vertex_format or
			{
				{"VertexPosition", "float", 2},
				{"VertexTexCoord", "float", 2},
				{"VertexColor", "float", 4},
			}
		self.vertex_buffer:SetDrawHint(usage)
		self:setDrawMode(mode)

		if vertices then self:setVertices(vertices) end

		if texture then self:setTexture(texture) end

		return self
	end

	function Mesh:setTexture(tex)
		self.img = tex
	end

	function Mesh:getTexture()
		return self.img
	end

	Mesh.setImage = Mesh.setTexture
	Mesh.getImage = Mesh.getTexture

	function Mesh:setVertices(vertices)
		for i, v in ipairs(vertices) do
			self:setVertex(i, v)
		end

		self.vertex_buffer:UpdateBuffer()
	end

	function Mesh:getVertices()
		local out = {}

		for i = 1, self.vertex_buffer:GetVertexCount() do
			out[i] = {self:getVertex(i)}
		end

		return out
	end

	function Mesh:setVertex(index, vertex, ...)
		if type(vertex) == "number" then vertex = {vertex, ...} end

		if vertex[1] then
			self.vertex_buffer:SetVertex(index, "pos", vertex[1], vertex[2])
		end

		if vertex[3] then
			self.vertex_buffer:SetVertex(index, "uv", vertex[3], vertex[4])
		end

		if vertex[5] then
			local r = (vertex[5] or 255) / 255
			local g = (vertex[6] or 255) / 255
			local b = (vertex[7] or 255) / 255
			local a = (vertex[8] or 255) / 255
			self.vertex_buffer:SetVertex(index, "color", r, g, b, a)
		end
	end

	function Mesh:getVertex(index)
		local x, y = self.vertex_buffer:GetVertex(index, "pos")
		local u, v = self.vertex_buffer:GetVertex(index, "uv")
		local r, g, b, a = self.vertex_buffer:GetVertex(index, "color")
		return x, y, u, v, r, g, b, a
	end

	function Mesh:setDrawRange(min, max)
		self.draw_range_min = min
		self.draw_range_max = max
	end

	function Mesh:getDrawRange()
		return self.draw_range_min, self.draw_range_max
	end

	function Mesh:Draw()
		local count = self.draw_range_max or self.index_buffer:GetIndexCount()
		self.vertex_buffer:Draw(self.index_buffer, count)
	end

	function Mesh:setVertexColors() end

	function Mesh:hasVertexColors()
		return true
	end

	function Mesh:setVertexMap(...)
		local indices = type(...) == "table" and ... or {...}
		self.vertex_map = {}

		for i, i2 in ipairs(indices) do
			self.vertex_map[i] = i2 - 1
		end

		rebuild_index_buffer(self)
	end

	function Mesh:getVertexMap()
		local out = {}
		local data = self.vertex_map

		for i = 1, #data do
			out[i] = data[i] + 1
		end

		return out
	end

	function Mesh:getVertexCount()
		return self.vertex_buffer:GetVertexCount()
	end

	do
		local attribute_translation = {
			VertexPosition = "pos",
			VertexTexCoord = "uv",
			VertexColor = "color",
		}

		local function get_attribute_name(self, pos)
			local info = self.vertex_format[pos]

			if not info then
				error("unknown vertex attribute index: " .. tostring(pos), 2)
			end

			return attribute_translation[info[1]] or info[1]
		end

		function Mesh:setVertexAttribute(index, pos, ...)
			self.vertex_buffer:SetVertex(index, get_attribute_name(self, pos), ...)
		end

		function Mesh:getVertexAttribute(index, pos)
			return self.vertex_buffer:GetVertex(index, get_attribute_name(self, pos))
		end
	end

	function Mesh:setAttributeEnabled(name, enable) end

	function Mesh:isAttributeEnabled() end

	function Mesh:attachAttribute() end

	do
		local tr = {
			pos = "VertexPosition",
			uv = "VertexTexCoord",
			color = "VertexColor",
		}

		function Mesh:getVertexFormat()
			local out = {}

			for i, info in ipairs(self.vertex_format) do
				list.insert(out, {tr[info[1]] or info[1], info[2], info[3]})
			end

			return out
		end
	end

	function Mesh:UpdateBuffers()
		self.vertex_buffer:UpdateBuffer()
		rebuild_index_buffer(self)
	end

	function Mesh:flush()
		self:UpdateBuffers()
	end

	do
		local tr = {
			triangles = "triangle_list",
			fan = "triangle_fan",
			strip = "triangle_strip",
			points = "point_list",
			lines = "line_list",
		}

		function Mesh:setDrawMode(mode)
			self.draw_mode = tr[mode] or mode or "triangles"
			self.vertex_buffer:SetMode(self.draw_mode)
			rebuild_index_buffer(self)
		end

		local tr2 = {}

		for k, v in pairs(tr) do
			tr2[v] = k
		end

		function Mesh:getDrawMode()
			local mode = self.draw_mode or self.vertex_buffer:GetMode()
			return tr2[mode] or mode
		end
	end

	line.RegisterType(Mesh)
end

do -- sprite batch
	local SpriteBatch = line.TypeTemplate("SpriteBatch")

	local function store_entry(self, id, entry)
		self.entries[id] = entry
	end

	function SpriteBatch:set(id, q, ...)
		id = id or 1
		local is_quad = line.Type(q) == "Quad" or
			(
				type(q) == "table" and
				type(q.x) == "number" and
				type(q.y) == "number" and
				type(q.w) == "number" and
				type(q.h) == "number" and
				type(q.sw) == "number" and
				type(q.sh) == "number"
			)

		if is_quad then
			local x, y, r, sx, sy, ox, oy, kx, ky = ...
			store_entry(
				self,
				id,
				{
					quad = q,
					x = x or 0,
					y = y or 0,
					r = r or 0,
					sx = sx or 1,
					sy = sy or sx or 1,
					ox = ox or 0,
					oy = oy or 0,
					kx = kx or 0,
					ky = ky or 0,
				}
			)
		else
			local x, y, r, sx, sy, ox, oy, kx, ky = q, ...
			store_entry(
				self,
				id,
				{
					x = x or 0,
					y = y or 0,
					r = r or 0,
					sx = sx or 1,
					sy = sy or sx or 1,
					ox = ox or 0,
					oy = oy or 0,
					kx = kx or 0,
					ky = ky or 0,
				}
			)
		end
	end

	SpriteBatch.setq = SpriteBatch.set

	function SpriteBatch:add(...)
		if self.i <= self.size then self:set(self.i, ...) end

		self.i = self.i + 1
		return self.i
	end

	SpriteBatch.addq = SpriteBatch.add

	function SpriteBatch:setColor(r, g, b, a)
		r, g, b, a = parse_color_bytes(r, g, b, a, get_api_default_alpha())
		self.r = r / 255
		self.g = g / 255
		self.b = b / 255
		self.a = a / 255
	end

	function SpriteBatch:clear()
		self.i = 1
		self.entries = {}
	end

	function SpriteBatch:getImage()
		return self.image
	end

	function SpriteBatch:bind() end

	function SpriteBatch:unbind() end

	function SpriteBatch:setImage(image)
		self.img = image
		self.w = image:getWidth()
		self.h = image:getHeight()
	end

	function SpriteBatch:getImage()
		return self.img
	end

	function SpriteBatch:Draw(...)
		local x, y, r, sx, sy, ox, oy, kx, ky = ...
		x = x or 0
		y = y or 0
		r = r or 0
		sx = sx or 1
		sy = sy or sx
		ox = ox or 0
		oy = oy or 0
		kx = kx or 0
		ky = ky or 0
		local cr, cg, cb, ca = get_internal_color()
		local restore = {cr, cg, cb, ca}
		love.graphics.setColor(cr * (self.r or 1), cg * (self.g or 1), cb * (self.b or 1), ca * (self.a or 1))
		render2d.PushMatrix()
		render2d.Translatef(x, y)
		render2d.Rotate(r)

		if ox ~= 0 or oy ~= 0 then render2d.Translatef(-ox * sx, -oy * sy) end

		if kx ~= 0 or ky ~= 0 then render2d.Shear(kx, ky) end

		render2d.Scalef(sx, sy)

		for i = 1, self.i - 1 do
			local entry = self.entries[i]

			if entry then
				if entry.quad then
					love.graphics.drawq(
						self.img,
						entry.quad,
						entry.x,
						entry.y,
						entry.r,
						entry.sx,
						entry.sy,
						entry.ox,
						entry.oy,
						entry.kx,
						entry.ky
					)
				else
					love.graphics.draw(
						self.img,
						entry.x,
						entry.y,
						entry.r,
						entry.sx,
						entry.sy,
						entry.ox,
						entry.oy,
						entry.kx,
						entry.ky
					)
				end
			end
		end

		render2d.PopMatrix()
		love.graphics.setColor(unpack(restore))
	end

	function love.graphics.newSpriteBatch(image, size, usagehint)
		local self = line.CreateObject("SpriteBatch")
		local poly = gfx.CreatePolygon2D(size * 6)
		self.size = size
		self.poly = poly
		self.img = image
		self.w = image:getWidth()
		self.h = image:getHeight()
		self.entries = {}
		self.r = 1
		self.g = 1
		self.b = 1
		self.a = 1
		self.i = 1
		return self
	end

	line.RegisterType(SpriteBatch)
end

function love.graphics.reset()
	love.graphics.setColor(255, 255, 255, 255)
	love.graphics.setBackgroundColor(0, 0, 0, 255)
	love.graphics.setCanvas()
	love.graphics.setShader()
	love.graphics.origin()
	love.graphics.setBlendMode("alpha")
	love.graphics.setLine(1, "smooth")
	love.graphics.setPoint(1, "smooth")
end
