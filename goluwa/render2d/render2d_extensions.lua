local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local Color = import("goluwa/structs/color.lua")
local render = import("goluwa/render/render.lua")

function render2d.CreateGradient(config)
	local width = config.width or 256
	local height = config.height or 1
	local mode = config.mode or "linear"
	local stops = config.stops or {}

	for i, stop in ipairs(stops) do
		stop.pos = stop.pos or i - 1
	end

	local tex = Texture.New{
		width = width,
		height = height,
		name = string.format("render2d %s gradient %dx%d", mode, width, height),
		format = "r8g8b8a8_unorm",
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	local glsl

	if mode == "linear" then
		local angle = config.angle or 0 -- degrees
		local rad = math.rad(angle)
		local s, c = math.sin(rad), math.cos(rad)
		glsl = [[
				vec2 dir = vec2(]] .. s .. [[, ]] .. -c .. [[);
				float t = dot(uv - 0.5, dir) + 0.5;
			]]
	elseif mode == "radial" then
		glsl = [[
				float t = distance(uv, vec2(0.5)) * 2.0;
			]]
	end

	-- Build the color ramp from stops
	-- stops = { {pos=0, color=Color(1,0,0,1)}, {pos=1, color=Color(0,0,1,1)} }
	table.sort(stops, function(a, b)
		return a.pos < b.pos
	end)

	local ramp = ""

	if #stops == 0 then
		ramp = "return vec4(1.0);"
	elseif #stops == 1 then
		local c = stops[1].color
		ramp = "return vec4(" .. c.r .. "," .. c.g .. "," .. c.b .. "," .. c.a .. ");"
	else
		ramp = "vec4 res = vec4(0.0);\n"

		for i = 1, #stops - 1 do
			local s1 = stops[i]
			local s2 = stops[i + 1]
			local cond = (i == 1) and "t <= " .. s2.pos or "t > " .. s1.pos .. " && t <= " .. s2.pos

			if i == #stops - 1 then cond = "t > " .. s1.pos end

			ramp = ramp .. "if (" .. cond .. ") {\n"
			ramp = ramp .. "  float fac = clamp((t - " .. s1.pos .. ") / (" .. s2.pos .. " - " .. s1.pos .. "), 0.0, 1.0);\n"
			ramp = ramp .. "  res = mix(vec4(" .. s1.color.r .. "," .. s1.color.g .. "," .. s1.color.b .. "," .. s1.color.a .. "), vec4(" .. s2.color.r .. "," .. s2.color.g .. "," .. s2.color.b .. "," .. s2.color.a .. "), fac);\n"
			ramp = ramp .. "}\n"
		end

		ramp = ramp .. "return res;"
	end

	tex:Shade(glsl .. "\n" .. ramp)
	return tex
end

function render2d.DrawTriangle(x, y, w, h, a)
	render2d.triangle_mesh = render2d.triangle_mesh or
		render2d.CreateMesh{
			{
				pos = Vec3(-0.5, -0.5, 0),
				uv = Vec2(0, 0),
				sample_uv = Vec2(0, 0),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(0.5, 0.5, 0),
				uv = Vec2(1, 1),
				sample_uv = Vec2(1, 1),
				color = Color(1, 1, 1, 1),
			},
			{
				pos = Vec3(-0.5, 0.5, 0),
				uv = Vec2(0, 1),
				sample_uv = Vec2(0, 1),
				color = Color(1, 1, 1, 1),
			},
		}
	render2d.BindMesh(render2d.triangle_mesh)
	render2d.PushMatrix()

	if x and y then render2d.Translate(x, y) end

	if a then render2d.Rotate(a) end

	if w and h then render2d.Scale(w, h) end

	local cmd = render.GetCommandBuffer()
	render2d.UploadConstants(w, h)
	render2d.triangle_mesh:Draw(cmd, 3)
	render2d.PopMatrix()
end

function render2d.DrawFilledCircle(x, y, radius)
	render2d.PushBorderRadius(radius)
	render2d.DrawRect(x - radius, y - radius, radius * 2, radius * 2)
	render2d.PopBorderRadius()
end

function render2d.DrawRoundedRect(x, y, w, h, amt)
	if amt > 0 then render2d.PushBorderRadius(amt or 16) end

	render2d.DrawRect(x, y, w, h)

	if amt > 0 then render2d.PopBorderRadius() end
end

function render2d.DrawOutlinedRect(x, y, w, h, thickness, radius, r, g, b, a)
	if r then render2d.PushColor(r, g, b, a) end

	render2d.PushOutlineWidth(-(thickness or 1))
	render2d.PushBorderRadius(radius or 0)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopOutlineWidth()

	if r then render2d.PopColor() end
end

function render2d.DrawLine(x1, y1, x2, y2, w, skip_tex, ox, oy)
	w = w or 1

	if not skip_tex then render2d.SetTexture() end

	local dx, dy = x2 - x1, y2 - y1
	local ang = math.atan2(dx, dy)
	local dst = math.sqrt((dx * dx) + (dy * dy))
	ox = ox or (w * 0.5)
	oy = oy or 0
	render2d.DrawRect(x1, y1, w, dst, -ang, ox, oy)
end

function render2d.DrawCircle(x, y, radius, width, resolution)
	resolution = resolution or 16
	local spacing = (resolution / radius) - 0.2

	for i = 0, resolution do
		local i1 = ((i + 0) / resolution) * math.pi * 2
		local i2 = ((i + 1 + spacing) / resolution) * math.pi * 2
		render2d.DrawLine(
			x + math.sin(i1) * radius,
			y + math.cos(i1) * radius,
			x + math.sin(i2) * radius,
			y + math.cos(i2) * radius,
			width
		)
	end
end

do
	local fonts = import("goluwa/render2d/fonts.lua")
	local Color = import("goluwa/structs/color.lua")
	local text = library()
	local font_cache = {}
	local default_foreground_color = Color(1, 1, 1, 1)
	local default_background_color = Color(0, 0, 0, 1)
	local hsv_cache = {}

	local function get_font(font_name, size, weight)
		if not font_cache[font_name] then font_cache[font_name] = {} end

		if not font_cache[font_name][size] then font_cache[font_name][size] = {} end

		if not font_cache[font_name][size][weight] then
			font_cache[font_name][size][weight] = fonts.New{
				Name = font_name,
				Size = size,
				Weight = weight,
			}
		end

		return font_cache[font_name][size][weight]
	end

	local function compute_auto_background(fg)
		local r, g, b = fg.r, fg.g, fg.b

		if not hsv_cache[r] then hsv_cache[r] = {} end

		if not hsv_cache[r][g] then hsv_cache[r][g] = {} end

		if hsv_cache[r][g][b] then return hsv_cache[r][g][b] end

		local h, s, v = fg:GetHSV()
		local v2 = v
		s = s * 0.5
		v = v * 0.5
		v = 1.0 - v

		if math.abs(v - v2) < 0.1 then v = v - 0.25 end

		local bg = Color.FromHSV(h, s, math.max(v, 0))
		hsv_cache[r][g][b] = bg
		return bg
	end

	function render2d.GetTextSize(text, font_name, size, weight, _blur_size)
		font_name = font_name or "Roboto"
		size = size or 14
		weight = weight or 0
		local font = get_font(font_name, size, weight)
		local w, h = font:GetTextSize(text)
		return w, h
	end

	function render2d.DrawText(tbl)
		local text = tbl.text or ""
		local x = tbl.x or 0
		local y = tbl.y or 0
		local font_name = tbl.font or "Roboto"
		local size = tbl.size or 14
		local weight = tbl.weight or 0
		local blur_size = tbl.blur_size or 1
		local foreground_color = tbl.foreground_color or default_foreground_color
		local background_color = tbl.background_color or default_background_color
		local alpha = (tbl.alpha or 1) * foreground_color.a

		if background_color == true then
			background_color = compute_auto_background(foreground_color)
		end

		background_color = background_color or default_background_color
		local font = get_font(font_name, size, weight)
		local w, h = font:GetTextSize(text)
		local align_x = tbl.align_x
		local align_y = tbl.align_y
		local spacing = tbl.spacing
		local outline_width = tbl.outline_width
		local outline_color = tbl.outline_color or Color(0, 0, 0, 1)
		local has_transform = tbl.scale_x or
			tbl.scale_y or
			tbl.scale or
			tbl.angle or
			tbl.skew_x or
			tbl.skew_y or
			tbl.render_x or
			tbl.render_y

		if has_transform then
			render2d.PushMatrix()
			render2d.Translate(x + w / 2, y + h / 2)

			if tbl.scale or tbl.scale_x or tbl.scale_y then
				local sx = tbl.scale_x or tbl.scale or 1
				local sy = tbl.scale_y or sx
				render2d.Scale(sx, sy)
			end

			if tbl.angle then render2d.Rotate(tbl.angle) end

			if tbl.skew_x or tbl.skew_y then
				local skew_x = math.tan(math.rad(tbl.skew_x or 0))
				local skew_y = math.tan(math.rad(tbl.skew_y or 0))
				render2d.Shear(skew_x, skew_y)
			end

			if tbl.render_x or tbl.render_y then
				render2d.Translate(tbl.render_x or 0, tbl.render_y or 0)
			end

			render2d.Translate(-(x + w / 2), -(y + h / 2))
		end

		if tbl.shadow_x or tbl.shadow_y then
			local shadow_color = tbl.shadow_color or Color(0, 0, 0, 1)
			local sx = tbl.shadow_x or tbl.shadow_y or 2
			local sy = tbl.shadow_y or tbl.shadow_x or 2
			render2d.PushColor(shadow_color.r, shadow_color.g, shadow_color.b, shadow_color.a)
			render2d.PushBlur(2, 2)
			font:DrawText(text, x + sx, y + sy, spacing, align_x, align_y)
			render2d.PopBlur()
			render2d.PopColor()
		end

		if blur_size >= 1 then
			local bg_alpha = background_color.a * (foreground_color.a ^ 2) * 0.67
			render2d.PushColor(background_color.r, background_color.g, background_color.b, bg_alpha * (tbl.blur_intensity or 1))
			render2d.PushBlur(blur_size, blur_size)
			font:DrawText(text, x, y, spacing, align_x, align_y)
			render2d.PopBlur()
			render2d.PopColor()
		end

		if outline_width then
			render2d.PushColor(outline_color.r, outline_color.g, outline_color.b, outline_color.a)
			render2d.PushOutlineWidth(-outline_width)
			font:DrawText(text, x, y, spacing, align_x, align_y)
			render2d.PopOutlineWidth()
			render2d.PopColor()
		end

		render2d.PushColor(foreground_color.r, foreground_color.g, foreground_color.b, alpha)
		font:DrawText(text, x, y, spacing, align_x, align_y)
		render2d.PopColor()

		if has_transform then render2d.PopMatrix() end

		return w, h
	end

	return text
end
