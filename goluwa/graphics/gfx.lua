local render2d = require("graphics.render2d")
local Texture = require("graphics.texture")
local Polygon2D = require("graphics.polygon_2d")
local gfx = {}

function gfx.Initialize()
	gfx.ninepatch_poly = Polygon2D.New(9 * 6)
	local tex = Texture.New(
		{
			width = 1024,
			height = 1024,
			format = "R8G8B8A8_UNORM",
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "mirrored_repeat",
			wrap_t = "mirrored_repeat",
			mip_map_levels = 32,
		}
	)
	tex:Shade([[
		// http://www.geeks3d.com/20130705/shader-library-circle-disc-fake-sphere-in-glsl-opengl-glslhacker/3/
		float disc_radius = 1;
		float border_size = 0.0001;
		vec2 uv2 = vec2(uv.x, -uv.y + 1);
		float dist = sqrt(dot(uv2, uv2));
		float t = smoothstep(disc_radius + border_size, disc_radius - border_size, dist);
		return vec4(1,1,1,t);
	]])
	tex:GenerateMipMap()
	gfx.quadrant_circle_texture = tex
end

function gfx.DrawNinePatch(x, y, w, h, patch_size_w, patch_size_h, corner_size, u_offset, v_offset, uv_scale)
	local size = render2d.GetTexture():GetSize()
	gfx.ninepatch_poly:SetNinePatch(
		1,
		x,
		y,
		w,
		h,
		patch_size_w,
		patch_size_h,
		corner_size,
		u_offset,
		v_offset,
		uv_scale,
		size.x,
		size.y
	)
	gfx.ninepatch_poly:Draw()
end

function gfx.DrawFilledCircle(x, y, sx, sy)
	sy = sy or sx
	render2d.PushTexture(gfx.quadrant_circle_texture)
	render2d.DrawRect(x, y, sx, sy)
	render2d.DrawRect(x, y, sx, sy, math.pi)
	render2d.DrawRect(x, y, sy, sx, math.pi / 2)
	render2d.DrawRect(x, y, sy, sx, -math.pi / 2)
	render2d.PopTexture()
end

function gfx.DrawRoundedRect(x, y, w, h, amt)
	amt = amt or 16

	if amt > w / 2 then amt = w / 2 end

	if amt > h / 2 then amt = h / 2 end

	amt = math.ceil(amt)
	render2d.PushTexture(render.GetWhiteTexture())
	render2d.DrawRect(x + amt, y + amt, w - amt * 2, h - amt * 2)
	render2d.DrawRect(x + amt, y, w - amt * 2, amt)
	render2d.DrawRect(x + amt, y + h - amt, w - amt * 2, amt)
	render2d.DrawRect(w - amt, amt, amt, h - amt * 2)
	render2d.DrawRect(x, amt, amt, h - amt * 2)
	render2d.PopTexture()
	render2d.PushTexture(gfx.quadrant_circle_texture)
	render2d.DrawRect(x + w - amt, y + h - amt, amt, amt)
	render2d.DrawRect(x + amt, y + h - amt, amt, amt, math.pi / 2)
	render2d.DrawRect(x + amt, y + amt, amt, amt, math.pi)
	render2d.DrawRect(x + w - amt, y + amt, amt, amt, -math.pi / 2)
	render2d.PopTexture()
end

function gfx.DrawRect(x, y, w, h, tex, r, g, b, a)
	if not y and not w and not h then
		tex = x
		x, y = 0, 0
		w, h = tex:GetSize():Unpack()
	end

	if r then render2d.PushColor(r, g, b, a) end

	tex = tex or render.GetWhiteTexture()
	render2d.PushTexture(tex)
	render2d.DrawRect(x, y, w, h)
	render2d.PopTexture()

	if r then render2d.PopColor() end
end

function gfx.DrawOutlinedRect(x, y, w, h, r, r_, g, b, a)
	r = r or 1

	if r_ then render2d.PushColor(r_, g, b, a) end

	render2d.PushTexture(render.GetWhiteTexture())

	if type(r) == "number" then r = Rect() + r end

	gfx.DrawLine(x, y, x, y + h, r.x, true, r.x)
	gfx.DrawLine(x - r.x + r.y, y, x + w + r.y + r.w, y, r.y, true, 0, r.y)
	gfx.DrawLine(x + w, y, x + w, y + h, r.w, true, 0)
	gfx.DrawLine(x - r.x, y + h, x + w + r.w, y + h, r.h, true, r.h, 0)
	render2d.PopTexture()

	if r_ then render2d.PopColor() end
end

function gfx.DrawLine(x1, y1, x2, y2, w, skip_tex, ox, oy)
	w = w or 1

	if not skip_tex then render2d.SetTexture() end

	local dx, dy = x2 - x1, y2 - y1
	local ang = math.atan2(dx, dy)
	local dst = math.sqrt((dx * dx) + (dy * dy))
	ox = ox or (w * 0.5)
	oy = oy or 0
	render2d.DrawRect(x1, y1, w, dst, -ang, ox, oy)
end

function gfx.DrawCircle(x, y, radius, width, resolution)
	resolution = resolution or 16
	local spacing = (resolution / radius) - 0.1

	for i = 0, resolution do
		local i1 = ((i + 0) / resolution) * math.pi * 2
		local i2 = ((i + 1 + spacing) / resolution) * math.pi * 2
		gfx.DrawLine(
			x + math.sin(i1) * radius,
			y + math.cos(i1) * radius,
			x + math.sin(i2) * radius,
			y + math.cos(i2) * radius,
			width
		)
	end
end

do
	function gfx.GetMousePosition()
		if window.GetMouseTrapped() then
			return render.GetWidth() / 2, render.GetHeight() / 2
		end

		return window.GetMousePosition():Unpack()
	end

	local last_x = 0
	local last_y = 0
	local last_diff = 0

	function gfx.GetMouseVel()
		local x, y = window.GetMousePosition():Unpack()
		local vx = x - last_x
		local vy = y - last_y
		local time = system.GetElapsedTime()

		if last_diff < time then
			last_x = x
			last_y = y
			last_diff = time + 0.1
		end

		return vx, vy
	end
end

do -- text
	local font = require("graphics.bitmap_font")

	function gfx.GetDefaultFont()
		return font
	end

	function gfx.SetFont(font)
		gfx.current_font = font or gfx.GetDefaultFont()
	end

	function gfx.GetFont()
		return gfx.current_font or gfx.GetDefaultFont()
	end

	local X, Y = 0, 0

	function gfx.DrawText(str, x, y, spacing, align_x, align_y)
		x = x or X
		y = y or Y

		if align_x or align_y then
			local w, h = gfx.GetTextSize(str)
			x = x + (w * (align_x or 0))
			y = y + (h * (align_y or 0))
		end

		gfx.GetFont():DrawString(str, x, y, spacing)
	end

	function gfx.SetTextPosition(x, y)
		X = x or X
		Y = y or Y
	end

	function gfx.GetTextPosition()
		return X, Y
	end

	do
		local cache = {} or table.weak()

		function gfx.GetTextSize(str, font)
			str = str or "|"
			font = font or gfx.GetFont()

			if cache[font] and cache[font][str] then
				return cache[font][str][1], cache[font][str][2]
			end

			local x, y = font:GetTextSize(str)
			cache[font] = cache[font] or table.weak()
			cache[font][str] = cache[font][str] or table.weak()
			cache[font][str][1] = x
			cache[font][str][2] = y
			return x, y
		end

		function gfx.InvalidateFontSizeCache(font)
			if font then cache[font] = nil else cache = {} end
		end
	end

	do -- text wrap
		local function wrap_1(str, max_width)
			local lines = {}
			local i = 1
			local last_pos = 0
			local line_width = 0
			local space_pos
			local tbl = str:utf8_to_list()

			--local pos = 1
			--for _ = 1, 10000 do
			--	local char = tbl[pos]
			--	if not char then break end
			for pos, char in ipairs(tbl) do
				local w = gfx.GetTextSize(char)

				if char:find("%s") then space_pos = pos end

				if line_width + w >= max_width then
					if space_pos then
						lines[i] = str:utf8_sub(last_pos + 1, space_pos)
						last_pos = space_pos
					else
						lines[i] = str:utf8_sub(last_pos + 1, pos)
						last_pos = pos
					end

					i = i + 1
					line_width = 0
					space_pos = nil
				end

				line_width = line_width + w
			--pos = pos + 1
			end

			if lines[1] then
				lines[i] = str:utf8_sub(last_pos + 1)
				return list.concat(lines, "\n")
			end

			return str
		end

		local function wrap_2(str, max_width, font)
			local tbl = str:utf8_to_list()
			local lines = {}
			local chars = {}
			local i = 1
			local width = 0
			local width_before_last_space = 0
			local width_of_trailing_space = 0
			local last_space_index = -1
			local prev_char

			while i < #tbl do
				local c = tbl[i]
				local char_width = gfx.GetTextSize(c, font)
				local new_width = width + char_width

				if c == "\n" then
					list.insert(lines, list.concat(chars))
					list.clear(chars)
					width = 0
					width_before_last_space = 0
					width_of_trailing_space = 0
					prev_char = nil
					last_space_index = -1
					i = i + 1
				elseif char ~= " " and width >= max_width then
					if #chars == 0 then
						i = i + 1
					elseif last_space_index ~= -1 then
						for i = #chars, 1, -1 do
							if chars[i] == " " then break end

							list.remove(chars, i)
						end

						width = width_before_last_space
						i = last_space_index
						i = i + 1
					end

					list.insert(lines, list.concat(chars))
					list.clear(chars)
					prev_char = nil
					width = char_width
					width_before_last_space = 0
					width_of_trailing_space = 0
					last_space_index = -1
				else
					if prev_char ~= " " and c == " " then
						width_before_last_space = width
					end

					width = new_width
					prev_char = c
					list.insert(chars, c)

					if c == " " then
						last_space_index = i
					elseif c ~= "\n" then
						width_of_trailing_space = 0
					end

					i = i + 1
				end
			end

			if #chars ~= 0 then list.insert(lines, list.concat(chars)) end

			return list.concat(lines, "\n")
		end

		local cache = table.weak()

		function gfx.WrapString(str, max_width, font)
			font = font or gfx.GetFont()

			if cache[str] and cache[str][max_width] and cache[str][max_width][font] then
				return cache[str][max_width][font]
			end

			if max_width < gfx.GetTextSize(nil, font) then
				return list.concat(str:split(""), "\n")
			end

			if max_width > gfx.GetTextSize(str, font) then return str end

			local res = wrap_2(str, max_width, font)
			cache[str] = cache[str] or {}
			cache[str][max_width] = cache[str][max_width] or {}
			cache[str][max_width][font] = res
			return res
		end
	end

	function gfx.DotLimitText(text, w, font)
		local strw, strh = gfx.GetTextSize(text, font)
		local dot_w = gfx.GetTextSize(".", font)

		if strw > w + 2 then
			local x = 0

			for i, char in ipairs(text:utf8_to_list()) do
				if x >= w - dot_w * 3 then return text:utf8_sub(0, i - 2) .. "..." end

				x = x + gfx.GetTextSize(char, font)
			end
		end

		return text
	end
end

gfx.Initialize()
return gfx
