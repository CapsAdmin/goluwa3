local line = import("goluwa/love/line.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
return function(ctx)
	local love = ctx.love
	local ENV = ctx.ENV
	local ADD_FILTER = ctx.ADD_FILTER
	local get_main_surface_dimensions = ctx.get_main_surface_dimensions
	local parse_color_bytes = ctx.parse_color_bytes
	local clear_active_target = ctx.clear_active_target
	local draw_clear_rect = ctx.draw_clear_rect
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

				if frame ~= nil then self._love_depth_initialized_frame = frame end
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
