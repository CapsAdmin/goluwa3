return function(ctx)
	local love = ctx.love
	local ENV = ctx.ENV
	local line = ctx.line
	local fonts = ctx.fonts
	local vfs = ctx.vfs
	local Vec2 = ctx.Vec2
	local render2d = ctx.render2d
	local get_internal_color = ctx.get_internal_color
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

		for line_str in (text .. "\n"):gmatch("(.-)\n") do
			lines[#lines + 1] = line_str
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

		for _, line_str in ipairs(lines) do
			local line_width = self:getWidth(line_str)

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
		local w = self.font:GetTextSize("W")
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
			local _, wrapped_lines = get_wrapped_lines(font.font, text, limit)
			local line_height = font:getHeight() * font:getLineHeight()

			for _, line_str in ipairs(wrapped_lines) do
				local w = font:getWidth(line_str)

				if w > max_width then max_width = w end
			end

			for i, line_str in ipairs(wrapped_lines) do
				local w = font:getWidth(line_str)
				local align_x = 0

				if align == "right" then
					align_x = max_width - w
				elseif align == "center" then
					align_x = (max_width - w) / 2
				end

				font.font:DrawText(line_str, align_x, (i - 1) * line_height)
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
