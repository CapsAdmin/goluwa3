local render = import("goluwa/render/render.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local ffi = require("ffi")
local math2d = import("goluwa/render2d/math2d.lua")
local vfs = import("goluwa/vfs.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local window = import("goluwa/window.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local RenderMesh = import("goluwa/render/mesh.lua")
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

function love.graphics.getTextureTypes()
	return {
		["2d"] = true,
		array = false,
		cube = false,
		volume = true,
	}
end

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

local get_main_surface_dimensions

local function begin_temporary_frame()
	if ENV.graphics_manual_frame_active then
		return render.GetCommandBuffer() ~= nil
	end

	if render.in_frame or not render.target then
		return render.GetCommandBuffer() ~= nil
	end

	render.target:WaitForPreviousFrame()

	if not render.BeginFrame() then return false end

	ENV.graphics_manual_frame_active = true
	render2d.cmd = render.GetCommandBuffer()
	return true
end

render2d.on_missing_command = begin_temporary_frame

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

local function clear_active_target(r, g, b, a, depth, stencil)
	local cmd = render2d.cmd

	if not (cmd and cmd.ClearAttachments) then return false end

	local w, h

	if ENV.graphics_current_canvas then
		w, h = ENV.graphics_current_canvas:getDimensions()
	else
		w, h = get_main_surface_dimensions()
	end

	cmd:ClearAttachments{
		color = {r / 255, g / 255, b / 255, a / 255},
		depth = depth,
		stencil = stencil,
		w = w,
		h = h,
	}
	return true
end

local function get_current_depth_target_size()
	if ENV.graphics_current_canvas then
		return ENV.graphics_current_canvas:getDimensions()
	end

	return get_main_surface_dimensions()
end

local function get_depth_target_frame_marker()
	local canvas = ENV.graphics_current_canvas

	if canvas then return canvas, "_love_depth_initialized_frame" end

	return ENV, "graphics_screen_depth_initialized_frame"
end

local function mark_depth_target_initialized(frame)
	local holder, key = get_depth_target_frame_marker()
	holder[key] = frame
end

local function get_love_depth_clear_value(compare_mode)
	if compare_mode == "greater" or compare_mode == "gequal" then return 0 end

	return 1
end

local function ensure_love_depth_target_initialized(compare_mode)
	local cmd = render2d.cmd

	if not (cmd and cmd.ClearAttachments) then return end

	local frame = render.GetCurrentFrame and render.GetCurrentFrame() or nil
	local holder, key = get_depth_target_frame_marker()

	if frame ~= nil and holder[key] == frame then return end

	local w, h = get_current_depth_target_size()
	cmd:ClearAttachments{
		depth = get_love_depth_clear_value(compare_mode),
		w = w,
		h = h,
	}

	if frame ~= nil then mark_depth_target_initialized(frame) end
end

local function clear_love_stencil_target(value)
	local cmd = render2d.cmd

	if not (cmd and cmd.ClearAttachments) then return end

	local w, h = get_current_depth_target_size()
	cmd:ClearAttachments{
		stencil = value or 0,
		w = w,
		h = h,
	}
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

function get_main_surface_dimensions()
	if ENV.graphics_current_canvas then
		return get_texture_dimensions(ENV.graphics_current_canvas.fb:GetColorTexture())
	end

	local size = window.GetSize and window.GetSize() or nil

	if size and size.x and size.y and size.x > 0 and size.y > 0 then
		return size.x, size.y
	end

	if render.GetRenderImageSize then
		local render_size = render.GetRenderImageSize()

		if render_size and render_size.x and render_size.y then
			return render_size.x, render_size.y
		end
	end

	local width = render.GetWidth and render.GetWidth() or 0
	local height = render.GetHeight and render.GetHeight() or 0
	return width, height
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

local function translate_wrap_mode(mode)
	if mode == "clamp" then return "clamp_to_edge" end

	if mode == "clampzero" then
		return "clamp_to_border", "float_transparent_black"
	end

	return mode
end

local function apply_wrap_to_texture(tex, wrap_s, wrap_t, wrap_r)
	if not tex then return end

	local translated_wrap_s, border_color_s = translate_wrap_mode(wrap_s)
	local translated_wrap_t, border_color_t = translate_wrap_mode(wrap_t or wrap_s)
	local translated_wrap_r, border_color_r = translate_wrap_mode(wrap_r or wrap_t or wrap_s)
	tex.config = tex.config or {}
	tex.config.sampler = tex.config.sampler or {}
	tex.config.sampler.wrap_s = translated_wrap_s or tex.config.sampler.wrap_s
	tex.config.sampler.wrap_t = translated_wrap_t or tex.config.sampler.wrap_t
	tex.config.sampler.wrap_r = translated_wrap_r or tex.config.sampler.wrap_r
	tex.config.sampler.border_color = border_color_s or border_color_t or border_color_r
	apply_filter_to_texture(tex)
end

local function drawable_uses_linear_filter(drawable)
	local min = drawable and drawable.filter_min or ENV.graphics_filter_min
	local mag = drawable and drawable.filter_mag or min or ENV.graphics_filter_mag
	return min == "linear" or mag == "linear"
end

local function get_quad_uv_rect(drawable, quad)
	local sample_x = quad.x
	local sample_y = quad.y
	local sample_w = quad.w
	local sample_h = quad.h

	if drawable_uses_linear_filter(drawable) then
		local inset_x = math.min(0.5, quad.w / 2)
		local inset_y = math.min(0.5, quad.h / 2)
		sample_x = sample_x + inset_x
		sample_y = sample_y + inset_y
		sample_w = math.max(quad.w - (inset_x * 2), 0)
		sample_h = math.max(quad.h - (inset_y * 2), 0)
	end

	return sample_x, sample_y, sample_w, sample_h
end

local function get_quad_draw_rect(drawable, quad, x, y, sx, sy, ox, oy, r, kx, ky)
	local draw_x = x
	local draw_y = y
	local draw_w = quad.w * sx
	local draw_h = quad.h * sy

	if
		drawable_uses_linear_filter(drawable) and
		r == 0 and
		kx == 0 and
		ky == 0 and
		ox == 0 and
		oy == 0 and
		sx >= 0 and
		sy >= 0
	then
		-- Separate axis-aligned quad draws can leave a 1px crack at shared edges.
		-- Expanding the destination rect by half a pixel on each side matches Love's
		-- visually continuous nine-slice output more closely for linear-filtered atlases.
		draw_x = draw_x - 0.5
		draw_y = draw_y - 0.5
		draw_w = draw_w + 1
		draw_h = draw_h + 1
	end

	return draw_x, draw_y, draw_w, draw_h
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

		if type(sw) == "table" and sh == nil then
			sw, sh = get_texture_dimensions(sw)
		end

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
		refresh(self.vertices, x, y, w, h, self.sw, self.sh)
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
	local width = get_main_surface_dimensions()
	return width
end

function love.graphics.getHeight()
	local _, height = get_main_surface_dimensions()
	return height
end

function love.graphics.setMode(width, height, fullscreen, vsync, fsaa)
	window.SetSize(Vec2(width, height))
	return true
end

function love.graphics.getMode()
	return window.GetSize().x, window.GetSize().y, false, false, false
end

function love.graphics.getDimensions()
	return get_main_surface_dimensions()
end

function love.graphics.getDPIScale()
	if love.window and love.window.getDPIScale then
		return love.window.getDPIScale()
	end

	if love.window and love.window.getPixelScale then
		return love.window.getPixelScale()
	end

	return 1
end

function love.graphics.reset() end

function love.graphics.setDepthMode(compare_mode, write)
	if not compare_mode then
		render2d.SetDepthMode("none", false)
		return
	end

	render2d.SetDepthMode(compare_mode, write)
	ensure_love_depth_target_initialized(compare_mode)
end

function love.graphics.getDepthMode()
	local compare_mode, write = render2d.GetDepthMode()

	if compare_mode == "none" then return nil, false end

	return compare_mode, write
end

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

	function love.graphics.clear(r, g, b, a, ...)
		local canvas = love.graphics.getCanvas()
		local stencil
		local depth

		if select("#", ...) >= 1 then stencil = select(1, ...) end

		if select("#", ...) >= 2 then depth = select(2, ...) end

		if canvas then
			canvas:clear(r, g, b, a, stencil, depth)
		else
			local cr, cg, cb, ca

			if r ~= nil then
				cr, cg, cb, ca = parse_color_bytes(r, g, b, a, 255)
			else
				cr, cg, cb, ca = get_internal_background_color()
			end

			if not clear_active_target(cr, cg, cb, ca, depth, stencil) then
				draw_clear_rect(cr, cg, cb, ca, render.GetWidth(), render.GetHeight())
			end

			if depth ~= nil then
				local frame = render.GetCurrentFrame and render.GetCurrentFrame() or nil

				if frame ~= nil then mark_depth_target_initialized(frame) end
			end
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
	local LOVE_TTF_FONT_COMPAT_SCALE = 0.78

	local function get_font_text_size(font, str)
		return font:GetTextSize(tostring(str or ""))
	end

	local function get_font_line_height(font)
		local height = 0

		if font.GetLineHeight then
			local line_height = font:GetLineHeight()

			if line_height and line_height > 0 then height = line_height end
		end

		if height <= 0 then
			local ascent = font.GetAscent and font:GetAscent() or 0
			local descent = font.GetDescent and font:GetDescent() or 0
			height = ascent + descent
		end

		if height <= 0 then
			local _, text_height = get_font_text_size(font, "W")
			height = text_height or 0
		end

		return math.ceil(height)
	end

	local function split_wrapped_lines(text)
		local lines = {}
		text = tostring(text or "")

		if text == "" then
			lines[1] = ""
			return lines
		end

		for line in (text .. "\n"):gmatch("(.-)\n") do
			lines[#lines + 1] = line
		end

		if #lines == 0 then lines[1] = text end

		return lines
	end

	local function get_wrapped_lines(font, str, width)
		str = tostring(str or "")
		local wrapped = font:WrapString(str, width or 0)
		return wrapped, split_wrapped_lines(wrapped)
	end

	function Font:getWidth(str)
		local width = get_font_text_size(self.font, str or "")
		return math.ceil(width or 0)
	end

	function Font:getHeight()
		return get_font_line_height(self.font)
	end

	function Font:setLineHeight(num)
		self.line_height = num
	end

	function Font:getLineHeight()
		return self.line_height or 1
	end

	function Font:getBaseline()
		if self.font.GetAscent then return math.ceil(self.font:GetAscent()) end

		return self:getHeight()
	end

	function Font:getWrap(str, width)
		local old = fonts.GetFont()
		fonts.SetFont(self.font)
		local res, lines = get_wrapped_lines(self.font, str, width)
		local wrapped_width = 0

		for _, line in ipairs(lines) do
			local line_width = self:getWidth(line)

			if line_width > wrapped_width then wrapped_width = line_width end
		end

		fonts.SetFont(old)

		if love._version_minor < 10 and love._version_revision == 0 then
			return wrapped_width, lines
		end

		if love._version_minor >= 10 then return wrapped_width, res end

		return wrapped_width, math.max(#lines, 1)
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

		local resolved_path = path ~= "memory" and path or fonts.GetDefaultSystemFontPath()
		self.font = fonts.New{
			Size = size,
			Path = resolved_path,
		}
		local ext = resolved_path:match("%.([^%.]+)$")

		if not texture and ext then
			ext = ext:lower()

			if (ext == "ttf" or ext == "otf") and self.font.SetScale then
				self.compat_scale = LOVE_TTF_FONT_COMPAT_SCALE
				self.font:SetScale(Vec2(self.compat_scale, self.compat_scale))
			end
		end

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
			local _, t = get_wrapped_lines(font.font, text, limit)
			local line_height = font:getHeight() * font:getLineHeight()

			for i, line in ipairs(t) do
				local w = font:getWidth(line)

				if w > max_width then max_width = w end
			end

			for i, line in ipairs(t) do
				local w = font:getWidth(line)
				local align_x = 0

				if align == "right" then
					align_x = max_width - w
				elseif align == "center" then
					align_x = (max_width - w) / 2
				end

				font.font:DrawText(line, align_x, (i - 1) * line_height)
			end
		else
			font.font:DrawText(text, 0, 0)
		end

		render2d.PopMatrix()
		render2d.PopColor()
	end

	function love.graphics.print(text, ...)
		local args = {...}
		local font_override

		if type(args[1]) == "table" and line.Type(args[1]) == "Font" then
			font_override = table.remove(args, 1)
		end

		local old_font

		if font_override then
			old_font = love.graphics.getFont()
			love.graphics.setFont(font_override)
		end

		local result = {draw_text(text, unpack(args, 1, 9))}

		if old_font then love.graphics.setFont(old_font) end

		return unpack(result)
	end

	function love.graphics.printf(text, ...)
		local args = {...}
		local font_override

		if type(args[1]) == "table" and line.Type(args[1]) == "Font" then
			font_override = table.remove(args, 1)
		end

		local x = args[1]
		local y = args[2]
		local limit = args[3]
		local align = args[4]
		local r = args[5]
		local sx = args[6]
		local sy = args[7]
		local ox = args[8]
		local oy = args[9]
		local kx = args[10]
		local ky = args[11]
		local old_font

		if font_override then
			old_font = love.graphics.getFont()
			love.graphics.setFont(font_override)
		end

		local result = {draw_text(text, x, y, r, sx, sy, ox, oy, kx, ky, align or "left", limit or 0)}

		if old_font then love.graphics.setFont(old_font) end

		return unpack(result)
	end

	do
		local Text = line.TypeTemplate("Text")

		local function text_get_font(self)
			return self.font or love.graphics.getFont()
		end

		local function text_get_string(self)
			return tostring(self.text or "")
		end

		local function update_text_metrics(self)
			local font = text_get_font(self)
			local text = text_get_string(self)
			self.width = font:getWidth(text)
			self.height = font:getHeight(text)
		end

		function Text:set(text)
			self.text = tostring(text or "")
			update_text_metrics(self)
			return self
		end

		function Text:add(text)
			self.text = text_get_string(self) .. tostring(text or "")
			update_text_metrics(self)
			return self
		end

		function Text:getString()
			return text_get_string(self)
		end

		function Text:getFont()
			return text_get_font(self)
		end

		function Text:getWidth()
			return self.width or 0
		end

		function Text:getHeight()
			return self.height or 0
		end

		function Text:getDimensions()
			return self:getWidth(), self:getHeight()
		end

		function Text:Draw(x, y, r, sx, sy, ox, oy, kx, ky)
			local old_font = love.graphics.getFont()
			love.graphics.setFont(text_get_font(self))
			love.graphics.print(text_get_string(self), x, y, r, sx, sy, ox, oy, kx, ky)
			love.graphics.setFont(old_font)
		end

		function love.graphics.newText(font, text)
			if type(font) ~= "table" or line.Type(font) ~= "Font" then
				text = font
				font = love.graphics.getFont()
			end

			local self = line.CreateObject("Text")
			self.font = font
			self:set(text or "")
			return self
		end

		line.RegisterType(Text)
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

	local function get_canvas_depth_format()
		return "d32_sfloat"
	end

	local function create_canvas_framebuffer(canvas, with_depth)
		canvas.fb = Framebuffer.New{
			width = canvas.w,
			height = canvas.h,
			format = canvas.format,
			clear_color = {0, 0, 0, 0},
			min_filter = canvas.filter_min,
			mag_filter = canvas.filter_mag,
			depth = with_depth,
			depth_format = with_depth and get_canvas_depth_format() or nil,
		}
		ENV.textures[canvas] = canvas.fb:GetColorTexture()
	end

	local function update_render_size_for_canvas(canvas)
		if canvas then
			render2d.UpdateScreenSize(canvas.w, canvas.h)
		else
			local width, height = get_main_surface_dimensions()
			render2d.UpdateScreenSize(width, height)
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
		local r, g, b, a
		local stencil
		local depth

		if select("#", ...) > 0 then
			local cr, cg, cb, ca = ...
			r, g, b, a = parse_color_bytes(cr, cg, cb, ca, 255)

			if select("#", ...) >= 5 then stencil = select(5, ...) end

			if select("#", ...) >= 6 then depth = select(6, ...) end
		else
			r, g, b, a = 0, 0, 0, 0
		end

		if self._canvas_cmd and render2d.cmd == self._canvas_cmd then
			if not clear_active_target(r, g, b, a, depth, stencil) then
				draw_clear_rect(r, g, b, a, self.w, self.h)
			end

			if depth ~= nil then
				local frame = render.GetCurrentFrame and render.GetCurrentFrame() or nil

				if frame ~= nil then mark_depth_target_initialized(frame) end
			end
		else
			local old_clear_color = self.fb.clear_colors[1]
			self.fb.clear_colors[1] = {r / 255, g / 255, b / 255, a / 255}
			self.fb.clear_color = self.fb.clear_colors[1]
			self.fb:Begin(nil, "clear")

			if depth ~= nil or stencil ~= nil then
				clear_active_target(r, g, b, a, depth, stencil)
			end

			if depth ~= nil then
				local frame = render.GetCurrentFrame and render.GetCurrentFrame() or nil

				if frame ~= nil then self._love_depth_initialized_frame = frame end
			end

			self.fb:End()
			self.fb.clear_colors[1] = old_clear_color
			self.fb.clear_color = old_clear_color
		end
	end

	function Canvas:setWrap() end

	function Canvas:getWrap() end

	function love.graphics.newCanvas(w, h)
		if not w or not h then
			local default_w, default_h = get_main_surface_dimensions()
			w = w or default_w
			h = h or default_h
		end

		local screen_texture = render.GetScreenTexture and render.GetScreenTexture()
		local self = line.CreateObject("Canvas")
		self.w = w
		self.h = h
		self.format = screen_texture and screen_texture.format or "r8g8b8a8_unorm"
		self.filter_min = ENV.graphics_filter_min
		self.filter_mag = ENV.graphics_filter_mag
		self.filter_anistropy = ENV.graphics_filter_anisotropy
		create_canvas_framebuffer(self, false)
		return self
	end

	local function resolve_canvas_target(canvas)
		if type(canvas) == "table" and not canvas.fb then
			return canvas[1], canvas.depth == true
		end

		return canvas, false
	end

	function love.graphics.setCanvas(canvas)
		local resolved_canvas, require_depth = resolve_canvas_target(canvas)

		if ENV.graphics_current_canvas == resolved_canvas then return end

		local current = ENV.graphics_current_canvas

		if current and current._canvas_cmd then
			current.fb:End(current._canvas_cmd)
			current._canvas_cmd = nil
			render2d.cmd = ENV.graphics_previous_canvas_cmd
			ENV.graphics_previous_canvas_cmd = nil
		end

		ENV.graphics_current_canvas = resolved_canvas

		if resolved_canvas then
			if require_depth and not resolved_canvas.fb:GetDepthTexture() then
				create_canvas_framebuffer(resolved_canvas, true)
			end

			ENV.graphics_previous_canvas_cmd = render2d.cmd
			resolved_canvas._canvas_cmd = resolved_canvas.fb:Begin()
			update_render_size_for_canvas(resolved_canvas)
			render2d.BindPipeline(resolved_canvas._canvas_cmd)
		else
			update_render_size_for_canvas()

			if render2d.cmd then render2d.BindPipeline(render2d.cmd) end
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

	function Image:setWrap(wrap_s, wrap_t)
		self.wrap_s = wrap_s or self.wrap_s
		self.wrap_t = wrap_t or wrap_s or self.wrap_t
		apply_wrap_to_texture(ENV.textures[self], self.wrap_s, self.wrap_t)
	end

	function Image:getWrap()
		return self.wrap_s, self.wrap_t
	end

	function love.graphics.newImage(path)
		if line.Type(path) == "Image" then return path end

		local self = line.CreateObject("Image")
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

	line.RegisterType(Image)
end

do -- volume image
	local VolumeImage = line.TypeTemplate("VolumeImage")
	ADD_FILTER(VolumeImage)

	function VolumeImage:getWidth()
		return self.layer_width or 0
	end

	function VolumeImage:getHeight()
		return self.layer_height or 0
	end

	function VolumeImage:getDepth()
		return self.depth or 0
	end

	function VolumeImage:getDimensions()
		return self:getWidth(), self:getHeight(), self:getDepth()
	end

	function VolumeImage:getData()
		return self.atlas_image_data
	end

	function VolumeImage:setWrap(wrap_s, wrap_t)
		self.wrap_s = wrap_s or self.wrap_s
		self.wrap_t = wrap_t or wrap_s or self.wrap_t
		apply_wrap_to_texture(ENV.textures[self], self.wrap_s, self.wrap_t)
	end

	function VolumeImage:getWrap()
		return self.wrap_s, self.wrap_t
	end

	local function normalize_volume_layer(layer, index)
		local layer_type = line.Type(layer)

		if layer_type == "ImageData" then return layer end

		if layer_type == "Image" then return layer:getData() end

		if type(layer) == "string" then return love.image.newImageData(layer) end

		error("newVolumeImage layer #" .. index .. " must be ImageData, Image, or a path", 3)
	end

	function love.graphics.newVolumeImage(layers)
		assert(type(layers) == "table", "newVolumeImage requires a table of layers")
		assert(#layers > 0, "newVolumeImage requires at least one layer")
		local normalized_layers = {}
		local layer_width
		local layer_height

		for i = 1, #layers do
			local layer = normalize_volume_layer(layers[i], i)
			local width, height = layer:getDimensions()

			if not layer_width then
				layer_width = width
				layer_height = height
			elseif layer_width ~= width or layer_height ~= height then
				error("newVolumeImage requires all layers to have matching dimensions", 2)
			end

			normalized_layers[i] = layer
		end

		local atlas_image_data = love.image.newImageData(layer_width, layer_height * #normalized_layers)

		for i, layer in ipairs(normalized_layers) do
			atlas_image_data:paste(layer, 0, (i - 1) * layer_height)
		end

		local self = line.CreateObject("VolumeImage")
		self.layer_width = layer_width
		self.layer_height = layer_height
		self.depth = #normalized_layers
		self.atlas_image_data = atlas_image_data
		self.filter_min = "nearest"
		self.filter_mag = "nearest"
		self.filter_anistropy = 1
		self.wrap_s = "clamp"
		self.wrap_t = "clamp"
		ENV.textures[self] = love.image._createTextureFromImageData(
			atlas_image_data,
			{
				min_filter = self.filter_min,
				mag_filter = self.filter_mag,
				anisotropy = self.filter_anistropy,
			}
		)
		self:setWrap(self.wrap_s, self.wrap_t)
		return self
	end

	line.RegisterType(VolumeImage)
end

do -- stencil
	function love.graphics.newStencil(func) end

	function love.graphics.setStencil(func) end

	function love.graphics.setStencilTest(mode, val)
		if mode then
			ENV.graphics_stencil_mode = mode
			ENV.graphics_stencil_val = val

			if mode == "always" then
				render2d.SetStencilMode("none", 0)
			elseif mode == "equal" then
				render2d.SetStencilMode("test", val)
			elseif mode == "greater" and val == 0 then
				render2d.SetStencilMode("test_inverse", val)
			else
				error("unsupported stencil test mode: " .. tostring(mode), 2)
			end
		else
			ENV.graphics_stencil_mode = "always"
			ENV.graphics_stencil_val = 0
			render2d.SetStencilMode("none", 0)
		end
	end

	function love.graphics.getStencilTest()
		return ENV.graphics_stencil_mode or "always", ENV.graphics_stencil_val or 0
	end

	function love.graphics.stencil(func, action, num, keep)
		action = action or "replace"
		num = num or 1

		if action ~= "replace" then
			error("unsupported stencil action: " .. tostring(action), 2)
		end

		if not keep then clear_love_stencil_target(0) end

		local old_mode, old_val = love.graphics.getStencilTest()
		local old_r, old_g, old_b, old_a = love.graphics.getColor()
		render2d.SetStencilMode("write", num)
		love.graphics.setColor(old_r, old_g, old_b, 0)
		render2d.PushBlendMode("zero", "one", "add", "zero", "one", "add")
		func()
		render2d.PopBlendMode()
		love.graphics.setColor(old_r, old_g, old_b, old_a)
		love.graphics.setStencilTest(old_mode, old_val)
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
	local uv_x, uv_y, uv_w, uv_h = get_quad_uv_rect(drawable, quad)
	local draw_x, draw_y, draw_w, draw_h = get_quad_draw_rect(drawable, quad, x, y, sx, sy, ox, oy, r, kx, ky)
	render2d.SetColor(cr / 255, cg / 255, cb / 255, ca / 255)
	render2d.PushSwizzleMode(render2d.GetSwizzleMode())
	render2d.SetSwizzleMode(0)
	render2d.PushTexture(ENV.textures[drawable])
	render2d.SetUV(uv_x, -uv_y, uv_w, -uv_h, quad.sw, quad.sh)
	render2d.DrawRectf(draw_x, draw_y, draw_w, draw_h, r, ox * sx, oy * sy)
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
		elseif line.Type(drawable) == "Text" then
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

local function get_attached_mesh_attribute(drawable, attribute_name, index, default_a, default_b)
	local attachment = drawable.attached_attributes and drawable.attached_attributes[attribute_name]

	if not attachment or not attachment.mesh then return default_a, default_b end

	local a, b = attachment.mesh:getVertexAttributeByName(index, attribute_name)

	if a == nil then a = default_a end

	if b == nil then b = default_b end

	return a, b
end

local function get_shared_instance_mesh(drawable)
	local shared_mesh

	for _, attachment in pairs(drawable.attached_attributes or {}) do
		if attachment and attachment.mesh then
			if shared_mesh and shared_mesh ~= attachment.mesh then return nil end

			shared_mesh = attachment.mesh
		end
	end

	return shared_mesh
end

local function draw_instanced_mesh_gpu(drawable, instance_count, x, y, r, sx, sy, ox, oy, kx, ky)
	local shader = ENV.current_shader

	if not shader or not shader.pipeline or not shader.instance_binding then
		return false
	end

	local instance_mesh = get_shared_instance_mesh(drawable)

	if not instance_mesh or not instance_mesh.vertex_buffer then return false end

	local texture = drawable:getTexture()

	if not texture then return false end

	if drawable._line_dirty_buffers then drawable:UpdateBuffers() end

	if instance_mesh._line_dirty_buffers then instance_mesh:UpdateBuffers() end

	instance_count = math.min(
		instance_count or instance_mesh.vertex_buffer:GetVertexCount(),
		instance_mesh.vertex_buffer:GetVertexCount()
	)
	x = x or 0
	y = y or 0
	r = r or 0
	sx = sx or 1
	sy = sy or sx
	ox = ox or 0
	oy = oy or 0
	kx = kx or 0
	ky = ky or 0
	render2d.PushColor(1, 1, 1, 1)
	render2d.PushTexture(ENV.textures[texture] or texture)
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	render2d.Rotate(r)

	if ox ~= 0 or oy ~= 0 then render2d.Translatef(-ox * sx, -oy * sy) end

	if kx ~= 0 or ky ~= 0 then render2d.Shear(kx, ky) end

	render2d.Scalef(sx, sy)
	render2d.UploadConstants(render2d.cmd)
	drawable:DrawInstanced(instance_count, {instance_mesh.vertex_buffer})
	render2d.PopMatrix()
	render2d.PopTexture()
	render2d.PopColor()
	return true
end

local function draw_instanced_mesh(drawable, instance_count, x, y, r, sx, sy, ox, oy, kx, ky)
	if
		draw_instanced_mesh_gpu(drawable, instance_count, x, y, r, sx, sy, ox, oy, kx, ky)
	then
		return true
	end

	if not drawable.attached_attributes then return false end

	local texture = drawable:getTexture()

	if not texture then return false end

	local position_attachment = drawable.attached_attributes.InstancePosition

	if not position_attachment or not position_attachment.mesh then return false end

	instance_count = math.min(
		instance_count or position_attachment.mesh:getVertexCount(),
		position_attachment.mesh:getVertexCount()
	)
	x = x or 0
	y = y or 0
	r = r or 0
	sx = sx or 1
	sy = sy or sx
	ox = ox or 0
	oy = oy or 0
	kx = kx or 0
	ky = ky or 0
	ENV.graphics_instanced_quad = ENV.graphics_instanced_quad or love.graphics.newQuad(0, 0, 1, 1, texture)
	local quad = ENV.graphics_instanced_quad
	local base_r, base_g, base_b, base_a = get_internal_color()
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	render2d.Rotate(r)

	if ox ~= 0 or oy ~= 0 then render2d.Translatef(-ox * sx, -oy * sy) end

	if kx ~= 0 or ky ~= 0 then render2d.Shear(kx, ky) end

	render2d.Scalef(sx, sy)

	for index = 1, instance_count do
		local inst_x, inst_y = get_attached_mesh_attribute(drawable, "InstancePosition", index, 0, 0)
		local uv_x, uv_y = get_attached_mesh_attribute(drawable, "UVOffset", index, 0, 0)
		local img_w, img_h = get_attached_mesh_attribute(drawable, "ImageDim", index, 0, 0)
		local shade = select(1, get_attached_mesh_attribute(drawable, "ImageShade", index, 1)) or 1
		local scale_x, scale_y = get_attached_mesh_attribute(drawable, "Scale", index, 1, 1)

		if img_w ~= 0 and img_h ~= 0 then
			quad:setViewport(uv_x, uv_y, img_w, img_h)
			ENV.graphics_color_r = base_r * shade
			ENV.graphics_color_g = base_g * shade
			ENV.graphics_color_b = base_b * shade
			ENV.graphics_color_a = base_a
			render2d.SetColor(
				ENV.graphics_color_r / 255,
				ENV.graphics_color_g / 255,
				ENV.graphics_color_b / 255,
				ENV.graphics_color_a / 255
			)
			love.graphics.drawq(texture, quad, inst_x, inst_y, 0, scale_x, scale_y)
		end
	end

	render2d.PopMatrix()
	ENV.graphics_color_r = base_r
	ENV.graphics_color_g = base_g
	ENV.graphics_color_b = base_b
	ENV.graphics_color_a = base_a
	render2d.SetColor(base_r / 255, base_g / 255, base_b / 255, base_a / 255)
	return true
end

function love.graphics.drawInstanced(drawable, instancecount, x, y, r, sx, sy, ox, oy, kx, ky)
	if
		line.Type(drawable) == "Mesh" and
		draw_instanced_mesh(drawable, instancecount, x, y, r, sx, sy, ox, oy, kx, ky)
	then
		return
	end

	if drawable.drawInstanced then
		return drawable:drawInstanced(instancecount, x, y, r, sx, sy, ox, oy, kx, ky)
	end

	if drawable.DrawInstanced then
		return drawable:DrawInstanced(instancecount, x, y, r, sx, sy, ox, oy, kx, ky)
	end

	return love.graphics.draw(drawable, x, y, r, sx, sy, ox, oy, kx, ky)
end

function love.graphics.present()
	if not ENV.graphics_manual_frame_active then return end

	render.EndFrame()
	render2d.cmd = nil
	ENV.graphics_manual_frame_active = false
end

function love.graphics.setIcon() end

do
	local Shader = line.TypeTemplate("Shader")
	local warned_missing_custom_shader_backend = false
	local warned_unsupported_love_vertex_shader = false
	local shader_pipeline_cache = setmetatable({}, {__mode = "k"})

	local function warn_unsupported_love_vertex_shader()
		if warned_unsupported_love_vertex_shader then return end

		warned_unsupported_love_vertex_shader = true
		wlog(
			"love.graphics.newShader: vertex/pixel shader pairs are not supported by the minimal Love shader backend yet"
		)
	end

	local function warn_missing_custom_shader_backend()
		if warned_missing_custom_shader_backend then return end

		warned_missing_custom_shader_backend = true
		wlog(
			"love.graphics.newShader: custom shader backend unavailable, using compatibility fallback"
		)
	end

	local function store_shader_uniform(self, name, value)
		self.uniforms = self.uniforms or {}
		self.uniforms[name] = value
	end

	local function register_shader_uniform(self, name)
		self.uniform_names = self.uniform_names or {}
		self.uniform_names[name] = true
	end

	local function clone_uniform_value(value)
		if type(value) ~= "table" then return value end

		local out = {}

		for i = 1, #value do
			out[i] = value[i]
		end

		return out
	end

	local function parse_default_uniform_value(kind, source)
		if not source or source == "" then return nil end

		source = source:match("^%s*(.-)%s*$")

		if kind == "number" or kind == "float" then return tonumber(source) end

		if kind == "boolean" or kind == "bool" then
			if source == "true" then return true end

			if source == "false" then return false end

			return nil
		end

		if kind == "vec2" or kind == "vec3" or kind == "vec4" then
			local out = {}

			for num in source:gmatch("[-+]?%d*%.?%d+[fF]?") do
				out[#out + 1] = tonumber(num)
			end

			return #out > 0 and out or nil
		end

		return nil
	end

	local function extract_fragment_source(source)
		if not source then return nil, false end

		local pixel = source:match("#ifdef%s+PIXEL(.-)#endif")
		local has_vertex = source:find("#ifdef%s+VERTEX") ~= nil

		if pixel then return pixel, has_vertex end

		return source, has_vertex
	end

	local function extract_vertex_source(source)
		if not source then return nil, false end

		local vertex = source:match("#ifdef%s+VERTEX(.-)#endif")
		local has_pixel = source:find("#ifdef%s+PIXEL") ~= nil

		if vertex then return vertex, has_pixel end

		return nil, has_pixel
	end

	local function parse_love_shader_uniforms(source)
		local uniforms = {}
		local stripped = source:gsub("extern%s+([%a_][%w_]*)%s+([%a_][%w_]*)%s*([^;]*);", function(kind, name, suffix)
			local default_expr = suffix:match("=%s*(.+)$")
			uniforms[#uniforms + 1] = {
				kind = kind,
				name = name,
				default = parse_default_uniform_value(kind, default_expr),
			}
			return ""
		end)
		return stripped, uniforms
	end

	local function parse_love_shader_varyings(source)
		local varyings = {}
		local stripped = source:gsub("varying%s+([%a_][%w_]*)%s+([%a_][%w_]*)%s*;", function(kind, name)
			varyings[#varyings + 1] = {kind = kind, name = name}
			return ""
		end)
		return stripped, varyings
	end

	local function parse_love_shader_attributes(source)
		local attributes = {}
		local stripped = source:gsub("attribute%s+([%a_][%w_]*)%s+([%a_][%w_]*)%s*;", function(kind, name)
			attributes[#attributes + 1] = {kind = kind, name = name}
			return ""
		end)
		return stripped, attributes
	end

	local function rewrite_shader_identifier(source, name, replacement)
		return source:gsub("(%f[%a_])" .. name .. "(%f[^%w_])", "%1" .. replacement .. "%2")
	end

	local function rewrite_shader_identifiers(source, items, prefix)
		for _, item in ipairs(items) do
			source = rewrite_shader_identifier(source, item.name, prefix .. item.name)
		end

		return source
	end

	local function glsl_type_to_vertex_format(glsl_type)
		if glsl_type == "vec4" then return "r32g32b32a32_sfloat" end

		if glsl_type == "vec3" then return "r32g32b32_sfloat" end

		if glsl_type == "vec2" then return "r32g32_sfloat" end

		return "r32_sfloat"
	end

	local function build_shader_vertex_bindings(attributes)
		local bindings = {
			{
				binding = 0,
				input_rate = "vertex",
				attributes = {
					{"pos", "vec3", "r32g32b32_sfloat"},
					{"uv", "vec2", "r32g32_sfloat"},
					{"color", "vec4", "r32g32b32a32_sfloat"},
				},
			},
		}

		if #attributes > 0 then
			local instance_attributes = {}

			for _, attribute in ipairs(attributes) do
				instance_attributes[#instance_attributes + 1] = {
					attribute.name,
					attribute.kind,
					glsl_type_to_vertex_format(attribute.kind),
				}
			end

			bindings[#bindings + 1] = {
				binding = 1,
				input_rate = "instance",
				attributes = instance_attributes,
			}
		end

		return bindings
	end

	local function rewrite_love_shader_identifiers(source, uniforms)
		source = source:gsub("(%f[%a_]love_ScreenSize%f[^%w_])", "love_user.love_ScreenSize")

		for _, uniform in ipairs(uniforms) do
			source = source:gsub(
				"(%f[%a_])" .. uniform.name .. "(%f[^%w_])",
				"%1love_user." .. uniform.name .. "%2"
			)
		end

		return source
	end

	local function rewrite_volume_texture_fetches(source, uniforms)
		for _, uniform in ipairs(uniforms) do
			if uniform.kind == "VolumeImage" then
				source = source:gsub(
					"texelFetch%s*%(%s*" .. uniform.name .. "%s*,",
					"love_volume_texelFetch_" .. uniform.name .. "("
				)
			end
		end

		return source
	end

	local function collect_image_identifiers(source, uniforms)
		local names = {}
		local seen = {}

		for _, uniform in ipairs(uniforms) do
			if uniform.kind == "Image" then
				seen[uniform.name] = true
				names[#names + 1] = uniform.name
			end
		end

		for name in source:gmatch("Image%s+([%a_][%w_]*)") do
			if not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end

		return names
	end

	local function rewrite_image_texture_fetches(source, image_names)
		for _, name in ipairs(image_names) do
			source = source:gsub(
				"texelFetch%s*%(%s*" .. name .. "%s*,",
				"love_image_texelFetch(" .. name .. ","
			)
		end

		return source
	end

	local function build_volume_uniform_declarations(uniforms)
		local lines = {}

		for _, uniform in ipairs(uniforms) do
			if uniform.kind == "VolumeImage" then
				if #lines == 0 then
					lines[#lines + 1] = [[
						vec4 love_volume_texel_fetch(int tex, ivec3 coords, int lod, ivec4 info) {
							if (tex < 0) return vec4(0.0);
							if (coords.z < 0 || coords.z >= info.z) return vec4(0.0);
							return texelFetch(TEXTURE(tex), ivec2(coords.x, coords.y + coords.z * info.y), lod);
						}
					]]
				end

				lines[#lines + 1] = string.format(
					"#define love_volume_texelFetch_%s(coords, lod) love_volume_texel_fetch(love_user.%s, (coords), (lod), love_user.%s_volume_info)",
					uniform.name,
					uniform.name,
					uniform.name
				)
			end
		end

		if #lines == 0 then return "" end

		return table.concat(lines, "\n") .. "\n"
	end

	local function get_volume_uniform_info(value)
		if type(value) ~= "table" then return 0, 0, 0 end

		local width = value.layer_width or value.width or 0
		local height = value.layer_height or value.height or 0
		local depth = value.depth or value.layers or 0
		return tonumber(width) or 0, tonumber(height) or 0, tonumber(depth) or 0
	end

	local function get_shader_screen_size()
		if ENV.graphics_current_canvas then
			local tex_w, tex_h = get_texture_dimensions(ENV.graphics_current_canvas.fb:GetColorTexture())
			return tex_w, tex_h
		end

		local size = window.GetSize()
		return size.x or 0, size.y or 0
	end

	local function build_shader_uniform_block(obj, uniforms)
		local block = {
			{
				"love_ScreenSize",
				"vec2",
				function(_, data, key)
					local w, h = get_shader_screen_size()
					data[key][0] = w
					data[key][1] = h
				end,
			},
		}

		for _, uniform in ipairs(uniforms) do
			local uniform_info = uniform
			local glsl_type = uniform_info.kind

			if glsl_type == "number" then glsl_type = "float" end

			if glsl_type == "Image" then glsl_type = "int" end

			if glsl_type == "VolumeImage" then glsl_type = "int" end

			if glsl_type == "boolean" then glsl_type = "int" end

			block[#block + 1] = {
				uniform_info.name,
				glsl_type,
				function(self, data, key)
					local value = obj.uniforms and obj.uniforms[key]

					if value == nil then
						for _, info in ipairs(uniforms) do
							if info.name == key then
								value = clone_uniform_value(info.default)

								break
							end
						end
					end

					if uniform_info.kind == "Image" or uniform_info.kind == "VolumeImage" then
						local texture = value and (ENV.textures[value] or value)
						data[key] = texture and self:GetTextureIndex(texture) or -1
						return
					end

					if uniform_info.kind == "boolean" or uniform_info.kind == "bool" then
						data[key] = value and 1 or 0
						return
					end

					if type(value) == "table" then
						for i = 1, #value do
							data[key][i - 1] = value[i] or 0
						end

						return
					end

					data[key] = value or 0
				end,
			}

			if uniform_info.kind == "VolumeImage" then
				block[#block + 1] = {
					uniform_info.name .. "_volume_info",
					"ivec4",
					function(_, data, key)
						local value = obj.uniforms and obj.uniforms[uniform_info.name]
						local width, height, depth = get_volume_uniform_info(value)
						data[key][0] = width
						data[key][1] = height
						data[key][2] = depth
						data[key][3] = 0
					end,
				}
			end
		end

		return block
	end

	local function copy_love_shader_projection_matrix(ptr)
		render2d.GetMatrix():CopyToFloatPointer(ptr)
	end

	local function build_fragment_pipeline(obj, source)
		local pixel_source, has_vertex_stage = extract_fragment_source(source)

		if has_vertex_stage then
			obj.warning_message = "minimal Love shader backend does not support #ifdef VERTEX shaders yet"
			warn_unsupported_love_vertex_shader()
			return nil
		end

		local stripped_source, uniforms = parse_love_shader_uniforms(pixel_source)
		local image_names = collect_image_identifiers(stripped_source, uniforms)
		stripped_source = rewrite_volume_texture_fetches(stripped_source, uniforms)
		stripped_source = rewrite_image_texture_fetches(stripped_source, image_names)
		stripped_source = rewrite_love_shader_identifiers(stripped_source, uniforms)
		local volume_uniform_declarations = build_volume_uniform_declarations(uniforms)
		register_shader_uniform(obj, "love_ScreenSize")
		local block = build_shader_uniform_block(obj, uniforms)
		local defines = {
			"#define number float",
			"#define Image int",
			"#define extern",
			"#define Texel(tex, coords) love_texel((tex), (coords))",
		}

		for _, uniform in ipairs(uniforms) do
			register_shader_uniform(obj, uniform.name)

			if uniform.default ~= nil then
				obj.uniforms[uniform.name] = clone_uniform_value(uniform.default)
			end
		end

		local config = {
			name = "love_shader_fragment",
			dont_create_framebuffers = true,
			samples = function()
				return render.target:GetSamples()
			end,
			color_format = render.target:GetColorFormat(),
			vertex = {
				uniform_buffers = {
					{
						block = {
							{
								"projection_view_world",
								"mat4",
								function(self, data, key)
									copy_love_shader_projection_matrix(data[key])
								end,
							},
							{
								"apply_love_depth",
								"int",
								function(_, data, key)
									local compare_mode = render2d.GetDepthMode()
									data[key] = compare_mode ~= "none" and 1 or 0
								end,
							},
						},
					},
				},
				attributes = {
					{"pos", "vec3", "r32g32b32_sfloat"},
					{"uv", "vec2", "r32g32_sfloat"},
					{"color", "vec4", "r32g32b32a32_sfloat"},
				},
				shader = [[
					void main() {
						gl_Position = U.projection_view_world * vec4(in_pos, 1.0);
						if (U.apply_love_depth != 0) {
							gl_Position.z = clamp(1.0 - in_pos.z, 0.0, 1.0) * gl_Position.w;
						}
						out_uv = in_uv;
						out_color = in_color;
					}
				]],
			},
			fragment = {
				uniform_buffers = {
					{
						block = {
							{
								"global_color",
								"vec4",
								function(_, data, key)
									local r, g, b, a = render2d.GetColor()
									data[key][0] = r or 1
									data[key][1] = g or 1
									data[key][2] = b or 1
									data[key][3] = a or 1
								end,
							},
							{
								"alpha_multiplier",
								"float",
								function(_, data, key)
									data[key] = render2d.GetAlphaMultiplier()
								end,
							},
							{
								"texture_index",
								"int",
								function(self, data, key)
									local texture = render2d.GetTexture()
									data[key] = texture and self:GetTextureIndex(texture) or -1
								end,
							},
							{
								"discard_zero_alpha",
								"int",
								function(_, data, key)
									local compare_mode = render2d.GetDepthMode()
									data[key] = compare_mode ~= "none" and 1 or 0
								end,
							},
							{
								"uv_offset",
								"vec2",
								function(_, data, key)
									local x, y = render2d.GetUV()
									data[key][0] = x or 0
									data[key][1] = y or 0
								end,
							},
							{
								"uv_scale",
								"vec2",
								function(_, data, key)
									local _, _, w, h = render2d.GetUV()
									data[key][0] = w or 1
									data[key][1] = h or 1
								end,
							},
						},
					},
					{
						name = "love_user",
						block = block,
					},
				},
				custom_declarations = table.concat(defines, "\n") .. [[

					vec4 love_texel(int tex, vec2 coords) {
						if (tex < 0) return vec4(0.0);
						return texture(TEXTURE(tex), coords);
					}

					vec4 love_image_texelFetch(int tex, ivec2 coords, int lod) {
						if (tex < 0) return vec4(0.0);
						return texelFetch(TEXTURE(tex), coords, lod);
					}
				]] .. (
						#volume_uniform_declarations > 0 and
						(
							"\n" .. volume_uniform_declarations
						)
						or
						""
					),
				shader = stripped_source .. [[
					void main() {
						vec4 love_color = in_color * U.global_color;
						vec2 love_texture_coords = in_uv * U.uv_scale + U.uv_offset;
						out_color = effect(love_color, U.texture_index, love_texture_coords, gl_FragCoord.xy);
						out_color.a *= U.alpha_multiplier;
						if (U.discard_zero_alpha != 0 && out_color.a <= 0.0) discard;
					}
				]],
			},
			rasterizer = {
				cull_mode = "none",
			},
			color_blend = {
				attachments = {
					{
						blend = true,
						src_color_blend_factor = "src_alpha",
						dst_color_blend_factor = "one_minus_src_alpha",
						color_blend_op = "add",
						src_alpha_blend_factor = "one",
						dst_alpha_blend_factor = "zero",
						alpha_blend_op = "add",
						color_write_mask = {"r", "g", "b", "a"},
					},
				},
			},
			depth_stencil = {
				depth_test = false,
				depth_write = true,
				stencil_test = false,
				front = {
					fail_op = "keep",
					pass_op = "keep",
					depth_fail_op = "keep",
					compare_op = "always",
				},
				back = {
					fail_op = "keep",
					pass_op = "keep",
					depth_fail_op = "keep",
					compare_op = "always",
				},
			},
		}
		return EasyPipeline.New(config)
	end

	local function build_vertex_fragment_pipeline(obj, source)
		local stripped_source, varyings = parse_love_shader_varyings(source)
		stripped_source, uniforms = parse_love_shader_uniforms(stripped_source)
		local vertex_section = extract_vertex_source(stripped_source)
		local fragment_section = extract_fragment_source(stripped_source)

		if not vertex_section or not fragment_section then
			obj.warning_message = "Love shader is missing a #ifdef VERTEX or #ifdef PIXEL section"
			warn_unsupported_love_vertex_shader()
			return nil
		end

		local cleaned_vertex, attributes = parse_love_shader_attributes(vertex_section)
		local cleaned_fragment = fragment_section
		local image_names = collect_image_identifiers(stripped_source, uniforms)
		cleaned_vertex = rewrite_volume_texture_fetches(cleaned_vertex, uniforms)
		cleaned_fragment = rewrite_volume_texture_fetches(cleaned_fragment, uniforms)
		cleaned_vertex = rewrite_image_texture_fetches(cleaned_vertex, image_names)
		cleaned_fragment = rewrite_image_texture_fetches(cleaned_fragment, image_names)
		cleaned_vertex = rewrite_shader_identifiers(cleaned_vertex, varyings, "out_")
		cleaned_fragment = rewrite_shader_identifiers(cleaned_fragment, varyings, "in_")
		cleaned_vertex = rewrite_shader_identifiers(cleaned_vertex, attributes, "in_")
		cleaned_vertex = rewrite_love_shader_identifiers(cleaned_vertex, uniforms)
		cleaned_fragment = rewrite_love_shader_identifiers(cleaned_fragment, uniforms)
		local volume_uniform_declarations = build_volume_uniform_declarations(uniforms)
		register_shader_uniform(obj, "love_ScreenSize")
		local user_block = build_shader_uniform_block(obj, uniforms)
		local outputs = {
			{"uv", "vec2"},
			{"color", "vec4"},
		}

		for _, varying in ipairs(varyings) do
			outputs[#outputs + 1] = {varying.name, varying.kind}
		end

		for _, uniform in ipairs(uniforms) do
			register_shader_uniform(obj, uniform.name)

			if uniform.default ~= nil then
				obj.uniforms[uniform.name] = clone_uniform_value(uniform.default)
			end
		end

		obj.instance_attributes = attributes
		obj.instance_binding = #attributes > 0 and 1 or nil
		return EasyPipeline.New{
			name = "love_shader_vertex_fragment",
			dont_create_framebuffers = true,
			samples = function()
				return render.target:GetSamples()
			end,
			color_format = render.target:GetColorFormat(),
			vertex = {
				uniform_buffers = {
					{
						block = {
							{
								"projection_view_world",
								"mat4",
								function(self, data, key)
									copy_love_shader_projection_matrix(data[key])
								end,
							},
							{
								"apply_love_depth",
								"int",
								function(_, data, key)
									local compare_mode = render2d.GetDepthMode()
									data[key] = compare_mode ~= "none" and 1 or 0
								end,
							},
						},
					},
					{
						name = "love_user",
						block = user_block,
					},
				},
				bindings = build_shader_vertex_bindings(attributes),
				outputs = outputs,
				shader = cleaned_vertex .. [[
					void main() {
						out_uv = in_uv;
						out_color = in_color;
						vec4 love_vertex_position = vec4(in_pos, 1.0);
						vec4 love_depth_position = position(mat4(1.0), love_vertex_position);
						gl_Position = position(U.projection_view_world, love_vertex_position);
						if (U.apply_love_depth != 0) {
							gl_Position.z = clamp(1.0 - love_depth_position.z, 0.0, 1.0) * gl_Position.w;
						}
					}
				]],
			},
			fragment = {
				uniform_buffers = {
					{
						block = {
							{
								"global_color",
								"vec4",
								function(_, data, key)
									local r, g, b, a = render2d.GetColor()
									data[key][0] = r or 1
									data[key][1] = g or 1
									data[key][2] = b or 1
									data[key][3] = a or 1
								end,
							},
							{
								"alpha_multiplier",
								"float",
								function(_, data, key)
									data[key] = render2d.GetAlphaMultiplier()
								end,
							},
							{
								"texture_index",
								"int",
								function(self, data, key)
									local texture = render2d.GetTexture()
									data[key] = texture and self:GetTextureIndex(texture) or -1
								end,
							},
							{
								"discard_zero_alpha",
								"int",
								function(_, data, key)
									local compare_mode = render2d.GetDepthMode()
									data[key] = compare_mode ~= "none" and 1 or 0
								end,
							},
							{
								"uv_offset",
								"vec2",
								function(_, data, key)
									local x, y = render2d.GetUV()
									data[key][0] = x or 0
									data[key][1] = y or 0
								end,
							},
							{
								"uv_scale",
								"vec2",
								function(_, data, key)
									local _, _, w, h = render2d.GetUV()
									data[key][0] = w or 1
									data[key][1] = h or 1
								end,
							},
						},
					},
					{
						name = "love_user",
						block = user_block,
					},
				},
				custom_declarations = [[
					#define number float
					#define Image int
					#define extern

					vec4 love_texel(int tex, vec2 coords) {
						if (tex < 0) return vec4(0.0);
						return texture(TEXTURE(tex), coords);
					}

					vec4 love_image_texelFetch(int tex, ivec2 coords, int lod) {
						if (tex < 0) return vec4(0.0);
						return texelFetch(TEXTURE(tex), coords, lod);
					}

					#define Texel(tex, coords) love_texel((tex), (coords))
				]] .. (
						#volume_uniform_declarations > 0 and
						(
							"\n" .. volume_uniform_declarations
						)
						or
						""
					),
				shader = cleaned_fragment .. [[
					void main() {
						vec4 love_color = in_color * U.global_color;
						vec2 love_texture_coords = in_uv * U.uv_scale + U.uv_offset;
						out_color = effect(love_color, U.texture_index, love_texture_coords, gl_FragCoord.xy);
						out_color.a *= U.alpha_multiplier;
						if (U.discard_zero_alpha != 0 && out_color.a <= 0.0) discard;
					}
				]],
			},
			rasterizer = {
				cull_mode = "none",
			},
			color_blend = {
				attachments = {
					{
						blend = true,
						src_color_blend_factor = "src_alpha",
						dst_color_blend_factor = "one_minus_src_alpha",
						color_blend_op = "add",
						src_alpha_blend_factor = "one",
						dst_alpha_blend_factor = "zero",
						alpha_blend_op = "add",
						color_write_mask = {"r", "g", "b", "a"},
					},
				},
			},
			depth_stencil = {
				depth_test = false,
				depth_write = true,
				stencil_test = false,
				front = {
					fail_op = "keep",
					pass_op = "keep",
					depth_fail_op = "keep",
					compare_op = "always",
				},
				back = {
					fail_op = "keep",
					pass_op = "keep",
					depth_fail_op = "keep",
					compare_op = "always",
				},
			},
		}
	end

	function Shader:getWarnings()
		return self.warning_message or ""
	end

	function Shader:hasUniform(name)
		if self.uniform_names and self.uniform_names[name] ~= nil then
			return self.uniform_names[name]
		end

		if self.shader and self.shader.program and self.shader.program.GetUniformLocation then
			local ok, loc = pcall(self.shader.program.GetUniformLocation, self.shader.program, name)

			if ok then return loc ~= nil and loc ~= -1 end
		end

		return false
	end

	function Shader:sendColor(name, tbl, ...)
		if ... then warning("uh oh") end

		store_shader_uniform(self, name, {tbl[1], tbl[2], tbl[3], tbl[4]})

		if not (self.shader and self.shader.program) then return end

		local loc = self.shader.program:GetUniformLocation(name)
		self.shader.program:UploadColor(loc, ColorBytes(unpack(tbl)))
	end

	function Shader:send(name, var, ...)
		if ... then warning("uh oh") end

		store_shader_uniform(self, name, var)

		if not (self.shader and self.shader.program) then return end

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
		obj.uniforms = {}
		obj.uniform_names = {}
		obj.source = {fragment = frag, vertex = vert}
		obj.warning_message = nil

		if render.CreateShader then
			obj.shader = render.CreateShader{
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
								return render2d.shader and render2d.shader.tex or nil
							end,
						},
						current_color = {
							color = function()
								return render2d.shader and render2d.shader.global_color or nil
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
		else
			if frag and frag:find("#ifdef%s+VERTEX") then
				obj.shader = build_vertex_fragment_pipeline(obj, frag)
			else
				obj.shader = build_fragment_pipeline(obj, frag)
			end

			if not obj.shader then warn_missing_custom_shader_backend() end
		end

		obj.pipeline = obj.shader
		return obj
	end

	line.RegisterType(Shader)
	love.graphics.newPixelEffect = love.graphics.newShader

	function love.graphics.setShader(obj)
		ENV.current_shader = obj
		render2d.shader_override = obj and obj.pipeline or nil

		if render2d.cmd then render2d.BindPipeline(render2d.cmd) end
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

	function love.graphics.intersectScissor(x, y, w, h)
		if x == nil then
			love.graphics.setScissor()
			return
		end

		local scx, scy, scw, sch = love.graphics.getScissor()

		if scx == nil then
			love.graphics.setScissor(x, y, w, h)
			return
		end

		local left = math.max(scx, x)
		local top = math.max(scy, y)
		local right = math.min(scx + scw, x + w)
		local bottom = math.min(scy + sch, y + h)
		local width = math.max(0, right - left)
		local height = math.max(0, bottom - top)
		love.graphics.setScissor(left, top, width, height)
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
	local attribute_translation = {
		VertexPosition = "pos",
		VertexTexCoord = "uv",
		VertexColor = "color",
	}
	local reverse_attribute_translation = {
		pos = "VertexPosition",
		uv = "VertexTexCoord",
		color = "VertexColor",
	}

	local function get_attribute_name_from_info(info)
		return attribute_translation[info[1]] or info[1]
	end

	local function get_vertex_format_component_count(info)
		return info[3] or 1
	end

	local function get_vertex_attribute_format(component_count)
		if component_count == 4 then return "r32g32b32a32_sfloat" end

		if component_count == 3 then return "r32g32b32_sfloat" end

		if component_count == 2 then return "r32g32_sfloat" end

		return "r32_sfloat"
	end

	local function build_render_vertex_attributes(vertex_format)
		local out = {}
		local offset = 0

		for i, info in ipairs(vertex_format) do
			local component_count = get_vertex_format_component_count(info)
			out[i] = {
				lua_name = get_attribute_name_from_info(info),
				offset = offset,
				format = get_vertex_attribute_format(component_count),
			}
			offset = offset + component_count * 4
		end

		return out
	end

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

	local function is_vertex_format_table(tbl)
		if type(tbl) ~= "table" then return false end

		local first = tbl[1]
		return type(first) == "table" and
			type(first[1]) == "string" and
			type(first[2]) == "string" and
			type(first[3]) == "number"
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
		elseif is_vertex_format_table(select(1, ...)) and type(select(2, ...)) == "table" then
			vertex_format, vertices, mode, usage = ...
			vertex_count = #vertices
		elseif is_vertex_format_table(select(1, ...)) and type(select(2, ...)) == "number" then
			vertex_format, vertex_count, mode, usage = ...
		elseif type(select(1, ...)) == "number" then
			vertex_count, mode, usage = ...
		elseif type(select(1, ...)) == "table" then
			vertices, mode, usage = ...
			vertex_count = #vertices
		end

		local self = line.CreateObject("Mesh")
		local resolved_vertex_format = vertex_format or
			{
				{"VertexPosition", "float", 2},
				{"VertexTexCoord", "float", 2},
				{"VertexColor", "float", 4},
			}

		if vertex_format then
			self.vertex_buffer = RenderMesh.New(build_render_vertex_attributes(resolved_vertex_format), vertex_count)
		else
			self.vertex_buffer = render2d.CreateMesh(vertex_count)
		end

		local mesh_idx = IndexBuffer.New()
		mesh_idx:LoadIndices(vertex_count)
		self.index_buffer = mesh_idx
		self.draw_mode = "triangles"
		self.vertex_map = {}

		for i = 1, vertex_count do
			self.vertex_map[i] = i - 1
		end

		self.vertex_format = resolved_vertex_format
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

		local source_index = 1

		for _, info in ipairs(self.vertex_format) do
			local component_count = get_vertex_format_component_count(info)
			local values = {}

			for component_index = 1, component_count do
				values[component_index] = vertex and vertex[source_index] or nil
				source_index = source_index + 1
			end

			if not vertex then
				for component_index = 1, component_count do
					values[component_index] = 0
				end
			elseif component_count == 2 and values[1] ~= nil and values[2] == nil then
				values[2] = values[1]
			end

			if info[1] == "VertexColor" then
				for component_index = 1, 4 do
					local value = values[component_index]

					if value == nil then
						value = component_index == 4 and get_api_default_alpha() or get_api_default_alpha()
					end

					if value > 1 then
						values[component_index] = value / 255
					else
						values[component_index] = value
					end
				end
			else
				for component_index = 1, component_count do
					values[component_index] = values[component_index] or 0
				end
			end

			self.vertex_buffer:SetVertex(index, get_attribute_name_from_info(info), unpack(values, 1, component_count))
		end

		self._line_dirty_buffers = true
	end

	function Mesh:getVertex(index)
		local out = {}

		for _, info in ipairs(self.vertex_format) do
			local values = {self.vertex_buffer:GetVertex(index, get_attribute_name_from_info(info))}

			for component_index = 1, get_vertex_format_component_count(info) do
				out[#out + 1] = values[component_index]
			end
		end

		return unpack(out)
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

	function Mesh:DrawInstanced(instance_count, extra_vertex_buffers)
		instance_count = instance_count or 1
		local count = self.draw_range_max or
			(
				self.index_buffer and
				self.index_buffer:GetIndexCount()
			)
			or
			self.vertex_buffer:GetVertexCount()

		if self.index_buffer then
			if not render2d.cmd then
				error(
					"Cannot draw without active command buffer. Must be called during Draw2D event.",
					2
				)
			end

			self.vertex_buffer:BindInstanced(render2d.cmd, extra_vertex_buffers, 0)
			render2d.cmd:BindIndexBuffer(self.index_buffer:GetBuffer(), 0, self.index_buffer:GetIndexType())
			render2d.cmd:DrawIndexed(count, instance_count, 0, 0, 0)
			return
		end

		self.vertex_buffer:DrawInstanced(instance_count, extra_vertex_buffers, count)
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
		local function get_attribute_name(self, pos)
			local info = self.vertex_format[pos]

			if not info then
				error("unknown vertex attribute index: " .. tostring(pos), 2)
			end

			return get_attribute_name_from_info(info)
		end

		function Mesh:setVertexAttribute(index, pos, ...)
			self.vertex_buffer:SetVertex(index, get_attribute_name(self, pos), ...)
			self._line_dirty_buffers = true
		end

		function Mesh:getVertexAttribute(index, pos)
			return self.vertex_buffer:GetVertex(index, get_attribute_name(self, pos))
		end
	end

	function Mesh:setAttributeEnabled(name, enable) end

	function Mesh:isAttributeEnabled() end

	function Mesh:attachAttribute(name, mesh, step)
		self.attached_attributes = self.attached_attributes or {}
		self.attached_attributes[name] = {
			mesh = mesh,
			step = step,
		}
	end

	function Mesh:getVertexAttributeByName(index, name)
		return self.vertex_buffer:GetVertex(index, name)
	end

	do
		function Mesh:getVertexFormat()
			local out = {}

			for i, info in ipairs(self.vertex_format) do
				list.insert(out, {reverse_attribute_translation[info[1]] or info[1], info[2], info[3]})
			end

			return out
		end
	end

	function Mesh:UpdateBuffers()
		self.vertex_buffer:UpdateBuffer()
		rebuild_index_buffer(self)
		self._line_dirty_buffers = false
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
		local id = self.i

		if id <= self.size then self:set(id, ...) end

		self.i = id + 1
		return id
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

	function SpriteBatch:flush()
		return self
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
		size = size or 1000
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
