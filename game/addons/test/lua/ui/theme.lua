local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local Ang3 = require("structs.ang3")
local window = require("window")
local event = require("event")
local Texture = require("render.texture")
local gfx = require("render2d.gfx")
local system = require("system")
local theme = library()
local PRIMARY = Color.FromHex("#062a67"):SetAlpha(0.9)
local Textures = {
	GlowLinear = require("render.textures.glow_linear"),
	GlowPoint = require("render.textures.glow_point"),
	Gradient = require("render.textures.gradient_linear"),
}

do
	local gradient = {
		PRIMARY:Darken(2),
		PRIMARY:Darken(1),
		PRIMARY,
		PRIMARY:Brighten(1),
		PRIMARY:Brighten(2),
	}
	local pallete = Color.BuildPallete(
		{
			Color.FromHex("#cccccc"),
			gradient[3],
			gradient[1],
		},
		{
			red = Color.FromHex("#dd4546"),
			yellow = Color.FromHex("#e0c33d"),
			blue = PRIMARY,
			green = Color.FromHex("#69ce4a"),
			purple = Color.FromHex("#a454d8"),
			brown = Color.FromHex("#a17247"),
		}
	)
	local colors = table.merge_many(
		{
			dashed_underline = Color(0.37, 0.37, 0.37, 0.25),
			button_color = pallete.blue,
			underline = pallete.blue,
			url_color = pallete.blue,
			actual_black = Color(0, 0, 0, 1),
			bar_color_horizontal = pallete.green,
			primary = pallete.blue,
			secondary = pallete.green,
			positive = pallete.green_lighter,
			neutral = pallete.yellow_lighter,
			negative = pallete.red_darker,
			heading = pallete.white,
			default = pallete.white,
			text_foreground = pallete.white,
			text_button = pallete.white,
			foreground = pallete.black,
			background = pallete.black,
			text_background = pallete.black,
			main_background = pallete.black,
			card = pallete.darkest,
			frame_border = Color(0.106, 0.463, 0.678),
			invisible = Color(0, 0, 0, 0),
			clickable_disabled = Color(0.3, 0.3, 0.3, 1),
			button_normal = Color(0.8, 0.8, 0.2, 1),
		},
		pallete
	)
	colors.text_disabled = colors.text_foreground:Copy():SetAlpha(0.5)

	function theme.GetColor(name)
		return colors[name or "primary"] or colors.primary
	end
end

do
	local sizes = {
		none = 0,
		line = 1,
		XXXS = 4,
		XXS = 7,
		XS = 8,
		S = 14,
		M = 16,
		L = 20,
		XL = 30,
		XXL = 40,
	}
	sizes.default = sizes.M
	sizes.line_height = sizes.XXXS

	function theme.GetSize(size_name)
		size_name = size_name or "default"
		return sizes[size_name] or sizes.default
	end

	function theme.GetPadding(size_name)
		size_name = size_name or "default"
		return sizes[size_name] or sizes.default
	end
end

do
	local path = fonts.GetDefaultSystemFontPath()
	local font_sizes = {
		XS = 10,
		S = 12,
		M = 14,
		L = 20,
		XL = 27,
		XXL = 32,
		XXXL = 42,
	}
	-- google fonts
	local font_styles = {
		heading = {"Orbitron", "Regular"},
		body_weak = {"Rajdhani", "Light"},
		body = {"Rajdhani", "Bold"},
		body_strong = {"Rajdhani", "Bold"},
	}

	function theme.GetFontSize(size_name)
		return font_sizes[size_name or "M"] or font_sizes.M
	end

	local font_cache = {}

	function theme.GetFont(name)
		local key = font_styles[name or "body"] or font_styles.body

		if not font_cache[key] then
			font_cache[key] = fonts.LoadGoogleFont(key[1], key[2])
		end

		return font_cache[key]
	end
end

do -- primitives
	function theme.DrawDiamond(x, y, size)
		render2d.PushMatrix()
		render2d.Translatef(x, y)
		render2d.Rotate(math.rad(45))
		render2d.DrawRectf(-size / 2, -size / 2, size, size)
		render2d.PopMatrix()
	end

	function theme.DrawDiamond2(x, y, size)
		local s = size
		theme.DrawDiamond(x, y, s / 3)
		render2d.PushOutlineWidth(1)
		theme.DrawDiamond(x, y, s)
		render2d.PopOutlineWidth()
	end

	function theme.DrawPill(x, y, w, h)
		x = x - 15
		w = w + 30
		render2d.PushBorderRadius(h)
		render2d.DrawRect(x, y, w, h)
		render2d.SetBorderRadius(h / 2)
		render2d.PushOutlineWidth(1)
		render2d.PushBlendMode("additive")
		render2d.PushAlphaMultiplier(1)
		render2d.DrawRect(x, y, w, h)
		render2d.PopAlphaMultiplier()
		render2d.PopBlendMode()
		render2d.PopOutlineWidth()
		render2d.PopBorderRadius()
		local s = 5
		local offset = 1
		theme.DrawDiamond2(x, y + h / 2, s)
		theme.DrawDiamond2(x + w, y + h / 2, s)
	end

	function theme.DrawBadge(x, y, w, h)
		x = x - 15
		w = w + 30
		render2d.PushTexture(Textures.Gradient)
		render2d.PushUV()
		render2d.SetUV2(-0.1, 0, 0.75, 1)
		render2d.PushBorderRadius(h)
		render2d.DrawRect(x, y, w, h)
		render2d.PopBorderRadius()
		render2d.PopUV()
		render2d.PopTexture()
		render2d.PushColor(1, 1, 1, 1)
		local s = 8
		local offset = -s
		theme.DrawDiamond2(x - offset, y + h / 2, s)
		render2d.PopColor()
	end

	function theme.DrawArrow(x, y, size)
		local f = size / 2
		render2d.PushBorderRadius(f * 3, f * 2, f * 2, f * 3)
		render2d.PushMatrix()
		render2d.Translatef(x - size / 3, y - size / 3)
		render2d.Scalef(1.6, 0.75)
		render2d.DrawRectf(0, 0, size * 1, size)
		render2d.PopMatrix()
		render2d.PopBorderRadius()
		theme.DrawDiamond(x, y + 0.5, size / 2)
	end

	function theme.DrawLine(x1, y1, x2, y2, thickness)
		local angle = math.atan2(y2 - y1, x2 - x1)
		local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
		local s = thickness * 2
		theme.DrawDiamond(x1, y1, s)
		theme.DrawDiamond(x2, y2, s)
		render2d.PushMatrix()
		render2d.Translatef(x1, y1)
		render2d.Rotate(angle)
		render2d.DrawRect(0, -thickness / 2, length, thickness)
		render2d.PopMatrix()
	end

	function theme.DrawLine2(x1, y1, x2, y2, thickness)
		local angle = math.atan2(y2 - y1, x2 - x1)
		local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
		local s = thickness * 4
		render2d.PushMatrix()
		render2d.Translatef(x1, y1 + 1)
		render2d.Rotate(math.pi)
		theme.DrawArrow(0, 0, s)
		render2d.PopMatrix()
		theme.DrawArrow(x2, y2, s)
		render2d.PushMatrix()
		render2d.Translatef(x1, y1)
		render2d.Rotate(angle)
		render2d.DrawRect(0, -thickness / 2, length, thickness)
		render2d.PopMatrix()
	end

	local create_glow_line = require("render.textures.glow_line")
	local glow_line = create_glow_line(1, 9, 0.2) -- 1px thick line, 10px fade on each side
	function theme.DrawGlowLine(x1, y1, x2, y2, thickness)
		thickness = thickness or 1
		local angle = math.atan2(y2 - y1, x2 - x1)
		local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
		render2d.PushMatrix()
		render2d.Translatef(x1, y1)
		render2d.Rotate(angle)
		render2d.Translatef(0, -glow_line:GetHeight() / 2)
		render2d.SetTexture(glow_line)
		render2d.PushBlendMode("additive")
		render2d.DrawRectf(0, -thickness / 10, length, glow_line:GetHeight())
		render2d.PopBlendMode()
		render2d.PopMatrix()
	end

	local gradient_classic = Texture.New(
		{
			width = 16,
			height = 16,
			format = "r8g8b8a8_unorm",
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	)
	local start = Color.FromHex("#060086")
	local stop = Color.FromHex("#04013e")
	gradient_classic:Shade(
		[[
			float dist = distance(uv, vec2(0.5));
				return vec4(mix(vec3(]] .. start.r .. ", " .. start.g .. ", " .. start.b .. "), vec3(" .. stop.r .. ", " .. stop.g .. ", " .. stop.b .. [[), -uv.y + 1.0), 1.0);
		]]
	)
	local create_metal_frame = require("render.textures.metal_frame")
	local metal_frame = create_metal_frame({
		base_color = Color.FromHex("#8f8b92"),
	})

	function theme.DrawClassicFrame(x, y, w, h)
		render2d.PushBorderRadius(h * 0.2)
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetTexture(gradient_classic)
		render2d.DrawRect(x, y, w, h)
		render2d.PopBorderRadius()

		do
			render2d.PushOutlineWidth(5)
			render2d.PushBlur(10)
			render2d.SetColor(0, 0, 0, 0.5)
			render2d.SetTexture(nil)
			render2d.DrawRect(x, y, w, h)
			render2d.PopBlur()
			render2d.PopOutlineWidth()
		end

		x = x - 3
		y = y - 3
		w = w + 6
		h = h + 6

		do
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetNinePatchTable(metal_frame.nine_patch)
			render2d.SetTexture(metal_frame)
			render2d.DrawRect(x, y, w, h)
			render2d.ClearNinePatch()
			render2d.SetTexture(nil)
		end
	end

	local create_metal_frame = require("render.textures.metal_frame")
	local metal_frame = create_metal_frame(
		{
			base_color = Color.FromHex("#8f8b92"),
			frame_inner = 0.02,
			frame_outer = 0.002,
			corner_radius = 0.02,
		}
	)

	function theme.DrawWhiteFrame(x, y, w, h)
		render2d.PushBorderRadius(h * 0.2)
		render2d.SetColor(1, 1, 1, 0.5)
		render2d.SetTexture(nil)
		render2d.DrawRect(x, y, w, h)
		x = x + 1
		y = y + 1
		w = w - 2
		h = h - 2

		do
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetNinePatchTable(metal_frame.nine_patch)
			render2d.SetTexture(metal_frame)
			render2d.DrawRect(x, y, w, h)
			render2d.ClearNinePatch()
			render2d.SetTexture(nil)
			render2d.PushOutlineWidth(1)
			render2d.DrawRect(x + 1, y + 1, w - 2, h - 2)
			render2d.PopOutlineWidth()
		end

		render2d.PopBorderRadius()
	end

	function theme.DrawCircle(x, y, size, width)
		render2d.PushBorderRadius(size)
		render2d.PushOutlineWidth(width or 1)
		render2d.DrawRect(x - size, y - size, size * 2, size * 2)
		render2d.PopOutlineWidth()
		render2d.PopBorderRadius()
	end

	function theme.DrawSimpleLine(x1, y1, x2, y2, thickness)
		local angle = math.atan2(y2 - y1, x2 - x1)
		local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
		render2d.PushMatrix()
		render2d.Translatef(x1, y1)
		render2d.Rotate(angle)
		render2d.DrawRectf(0, -thickness / 2, length, thickness)
		render2d.PopMatrix()
	end

	function theme.DrawMagicCircle(x, y, size)
		render2d.PushBlur(size * 0.05)
		theme.DrawCircle(x, y, size, 4)
		theme.DrawCircle(x, y, size * 1.5)
		theme.DrawCircle(x, y, size * 1.7)
		theme.DrawCircle(x, y, size * 3)
		render2d.PopBlur()

		for i = 1, 8 do
			local angle = (i / 8) * math.pi * 2
			local length = size * 1.35
			local x1 = x + math.cos(angle) * length
			local y1 = y + math.sin(angle) * length
			theme.DrawDiamond(x1, y1, 3)
		end

		for i = 1, 16 do
			local angle = (i / 16) * math.pi * 2
			local length = size * 1.35
			local x1 = x + math.cos(angle) * length
			local y1 = y + math.sin(angle) * length
			local x2 = x + math.cos(angle) * length * 1.5
			local y2 = y + math.sin(angle) * length * 1.5
			render2d.SetTexture(Textures.GlowLinear)
			theme.DrawGlowLine(x1, y1, x2, y2, 1)
		end
	end

	function theme.DrawGlow(x, y, size)
		render2d.PushTexture(Textures.GlowPoint)
		render2d.PushAlphaMultiplier(0.5)
		render2d.DrawRectf(x - size, y - size, size * 2, size * 2)
		render2d.PopAlphaMultiplier()
		render2d.PopTexture()
	end

	function theme.DrawProgressBarPrimitive(x, y, w, h, progress, color)
		-- Background Frame
		render2d.SetColor(0.2, 0.2, 0.3, 0.4)
		render2d.DrawRect(x, y, w, h)
		-- Top/Bottom glow lines
		render2d.PushBlendMode("additive")
		render2d.SetColor(0.3, 0.4, 0.6, 0.5)
		theme.DrawGlowLine(x, y, x + w, y, 2)
		theme.DrawGlowLine(x, y + h, x + w, y + h, 2)
		-- Vertical dividers every 10%
		render2d.SetColor(1, 1, 1, 0.1)
		local div_w = w / 10

		for i = 1, 9 do
			local dx = x + div_w * i
			render2d.DrawRect(dx, y, 1, h)
		end

		render2d.PopBlendMode()

		-- Fill
		if progress > 0 then
			local fill_w = w * progress
			local center_y = y + h / 2
			local tip_x = x + fill_w
			-- Main bar gradient
			render2d.PushTexture(Textures.Gradient)

			if color then
				render2d.SetColor(color.r, color.g, color.b, (color.a or 1) * 0.8)
			else
				render2d.SetColor(0.4, 0.7, 1, 0.8)
			end

			-- Rotate gradient for a slash effect? Maybe just linear for now
			render2d.DrawRect(x, y, fill_w, h)
			render2d.PopTexture()
			-- Additive glow layer over the bar
			render2d.PushBlendMode("additive")
			-- Highlight top edge of the filled part
			render2d.SetColor(1, 1, 1, 0.6)
			render2d.DrawRect(x, y, fill_w, 2)

			-- Tip decoration (Diamond / Sci-Fi marker)
			-- Color for the tip
			if color then
				render2d.SetColor(color.r, color.g, color.b, 1)
			else
				render2d.SetColor(0.6, 0.9, 1, 1)
			end

			-- Small sharp diamond at the tip
			theme.DrawDiamond(tip_x, center_y, h * 0.8)

			-- Larger faint halo diamond
			if color then
				render2d.SetColor(color.r, color.g, color.b, 0.3)
			else
				render2d.SetColor(0.6, 0.9, 1, 0.3)
			end

			theme.DrawDiamond(tip_x, center_y, h * 1.8)
			-- Vertical glow line at the very tip to mark position clearly
			render2d.SetTexture(Textures.GlowLinear)
			render2d.SetColor(1, 1, 1, 1)
			render2d.PushMatrix()
			render2d.Translate(tip_x, center_y)
			render2d.Rotate(math.rad(90))
			-- Draw centered vertical line
			render2d.DrawRect(-h, -1.5, h * 2, 3)
			render2d.PopMatrix()
			render2d.PopBlendMode()
			render2d.SetTexture(nil)
		end
	end

	do
		local glow_color = Color.FromHex("#5ea6e9")
		local gradient = Texture.New(
			{
				width = 16,
				height = 16,
				format = "r8g8b8a8_unorm",
				sampler = {
					min_filter = "linear",
					mag_filter = "linear",
					wrap_s = "clamp_to_edge",
					wrap_t = "clamp_to_edge",
				},
			}
		)
		local start = Color.FromHex("#004687ff")
		local stop = Color.FromHex("#04013e00")
		gradient:Shade(
			[[
			float dist = distance(uv, vec2(0.5));
				return mix(vec4(]] .. start.r .. ", " .. start.g .. ", " .. start.b .. ", " .. start.a .. [[), vec4(]] .. stop.r .. ", " .. stop.g .. ", " .. stop.b .. ", " .. stop.a .. [[), -uv.y + 1.0 + uv.x*0.3);
		]]
		)

		function theme.DrawModernFrame(x, y, w, h, intensity)
			render2d.SetColor(1, 1, 1, 1)
			render2d.SetTexture(gradient)
			render2d.DrawRect(x, y, w, h)
		end

		function theme.DrawModernFramePost(x, y, w, h, intensity)
			render2d.SetTexture(nil)
			x = x - 1
			y = y - 1
			w = w + 2
			h = h + 2
			render2d.SetColor(glow_color.r, glow_color.g, glow_color.b, 0.75 + intensity * 0.4)
			render2d.SetBlendMode("additive")
			local glow_size = 40 * intensity
			local diamond_size = 6 + 2 * intensity
			theme.DrawDiamond2(x, y, diamond_size)
			theme.DrawGlow(x, y, glow_size)
			theme.DrawDiamond2(x + w, y, diamond_size)
			theme.DrawGlow(x + w, y, glow_size)
			theme.DrawDiamond2(x, y + h, diamond_size)
			theme.DrawGlow(x, y + h, glow_size)
			theme.DrawDiamond2(x + w, y + h, diamond_size)
			theme.DrawGlow(x + w, y + h, glow_size)
			render2d.SetTexture(Textures.GlowLinear)
			local extent_h = -200 * 0.25 * intensity
			local extent_w = -200 * 0.25 * intensity
			render2d.SetBlendMode("alpha")
			theme.DrawGlowLine(x + extent_w, y, x + w - extent_w, y, 1)
			theme.DrawGlowLine(x + extent_w, y + h, x + w - extent_w, y + h, 1)
			theme.DrawGlowLine(x, y + extent_h, x, y + h - extent_h, 1)
			theme.DrawGlowLine(x + w, y + extent_h, x + w, y + h - extent_h, 1)
			render2d.SetTexture(nil)
		end
	end

	function theme.DrawRect(x, y, w, h, thickness, extent, tex)
		extent = extent or 0
		theme.DrawLine(x - extent, y, x + w + extent, y, thickness, tex)
		theme.DrawLine(x + w, y - extent, x + w, y + h + extent, thickness, tex)
		theme.DrawLine(x + w + extent, y + h, x - extent, y + h, thickness, tex)
		theme.DrawLine(x, y + h + extent, x, y - extent, thickness, tex)
	end
end

do -- animations
	function theme.UpdateButtonAnimations(pnl, s)
		if not pnl or not s then return end

		local is_active = not s.is_disabled and
			(
				(
					s.is_hovered and
					s.is_pressed
				)
				or
				(
					s.active_prop or
					false
				)
			)
		local is_tilting = is_active

		if is_active ~= s.last_active then
			pnl.animation:Animate(
				{
					id = "press_scale",
					get = function()
						return s.press_scale
					end,
					set = function(val)
						s.press_scale = val
					end,
					to = is_active and 1 or 0,
					interpolation = (s.is_pressed and not s.is_hovered) and "linear" or "inOutSine",
					time = (s.is_pressed and not s.is_hovered) and 0.2 or 0.1,
				}
			)
			pnl.animation:Animate(
				{
					id = "DrawScaleOffset",
					get = function()
						return pnl.transform:GetDrawScaleOffset()
					end,
					set = function(v)
						pnl.transform:SetDrawScaleOffset(v)
					end,
					to = is_active and (Vec2() + 0.97) or (Vec2(1, 1)),
					interpolation = (
							s.is_pressed and
							not s.is_hovered
						)
						and
						"linear" or
						{
							type = "spring",
							bounce = 0.6,
							duration = 100,
						},
					time = (s.is_pressed and not s.is_hovered) and 0.2 or nil,
				}
			)
			s.last_active = is_active
		end

		if s.is_hovered ~= s.last_hovered then
			pnl.animation:Animate(
				{
					id = "glow_alpha",
					get = function()
						return s.glow_alpha
					end,
					set = function(val)
						s.glow_alpha = val
					end,
					to = (s.is_hovered and not s.is_disabled) and 1 or 0,
					interpolation = "inOutSine",
					time = 0.1,
				}
			)
			s.last_hovered = s.is_hovered
		end

		if is_tilting ~= s.last_tilting or is_tilting then
			pnl.animation:Animate(
				{
					id = "Pivot",
					get = function()
						return pnl.transform:GetPivot()
					end,
					set = function(v)
						pnl.transform:SetPivot(v)
					end,
					to = not is_tilting and
						Vec2(0.5, 0.5) or
						{
							__lsx_value = function(pnl)
								local mpos = window.GetMousePosition()
								local local_pos = pnl.transform:GlobalToLocal(mpos)
								local size = pnl.transform:GetSize()
								local pivot = local_pos / size
								return -pivot + Vec2(1, 1)
							end,
						},
					interpolation = (
							s.is_pressed and
							not s.is_hovered
						)
						and
						"linear" or
						{
							type = "spring",
							bounce = 0.6,
							duration = 10,
						},
					time = is_tilting and 0.3 or 10,
				}
			)
			pnl.animation:Animate(
				{
					id = "DrawAngleOffset",
					get = function()
						return pnl.transform:GetDrawAngleOffset()
					end,
					set = function(v)
						pnl.transform:SetDrawAngleOffset(v)
					end,
					to = not is_tilting and
						Ang3(0, 0, 0) or
						{
							__lsx_value = function(pnl)
								local mpos = window.GetMousePosition()
								local local_pos = pnl.transform:GlobalToLocal(mpos)
								local size = pnl.transform:GetSize()
								local nx = (local_pos.x / size.x) * 2 - 1
								local ny = (local_pos.y / size.y) * 2 - 1
								return Ang3(-ny, nx, 0) * 0.01
							end,
						},
					interpolation = (
							s.is_pressed and
							not s.is_hovered
						)
						and
						"linear" or
						{
							type = "spring",
							bounce = 0.6,
							duration = 10,
						},
					time = is_tilting and 0.3 or 10,
				}
			)
			s.last_tilting = is_tilting
		end
	end

	function theme.UpdateSliderAnimations(pnl, s)
		if s.is_hovered ~= s.last_hovered then
			pnl.animation:Animate(
				{
					id = "glow_alpha",
					get = function()
						return s.glow_alpha
					end,
					set = function(val)
						s.glow_alpha = val
					end,
					to = s.is_hovered and 1 or 0,
					interpolation = "inOutSine",
					time = 0.15,
				}
			)
			pnl.animation:Animate(
				{
					id = "knob_scale",
					get = function()
						return s.knob_scale
					end,
					set = function(val)
						s.knob_scale = val
					end,
					to = s.is_hovered and 1.2 or 1,
					interpolation = {
						type = "spring",
						bounce = 0.5,
						duration = 80,
					},
				}
			)
			s.last_hovered = s.is_hovered
		end
	end

	function theme.UpdateCheckboxAnimations(pnl, s)
		if s.is_hovered ~= s.last_hovered then
			pnl.animation:Animate(
				{
					id = "glow_alpha",
					get = function()
						return s.glow_alpha
					end,
					set = function(val)
						s.glow_alpha = val
					end,
					to = s.is_hovered and 1 or 0,
					interpolation = "inOutSine",
					time = 0.15,
				}
			)
			s.last_hovered = s.is_hovered
		end

		if s.value ~= s.last_value then
			pnl.animation:Animate(
				{
					id = "check_anim",
					get = function()
						return s.check_anim
					end,
					set = function(val)
						s.check_anim = val
					end,
					to = s.value and 1 or 0,
					interpolation = {
						type = "spring",
						bounce = 0.4,
						duration = 100,
					},
				}
			)
			s.last_value = s.value
		end
	end
end

do
	theme.panels = {}

	function theme.panels.button(pnl, state)
		-- Continuous tracking while hovered
		if state and state.is_hovered then
			theme.UpdateButtonAnimations(pnl.Owner, state)
		end

		local s = state or {glow_alpha = 0, press_scale = 0}
		local size = pnl.Owner.transform.Size

		if state.mode == "filled" then
			render2d.PushUV()
			render2d.SetUV2(0, 0, 0.4, 1)
			render2d.PushBorderRadius(size.y / 6)
			render2d.SetTexture(Textures.Gradient)
			local col = pnl.Owner.rect.Color or theme.GetColor("primary")
			render2d.SetColor(col.r * s.glow_alpha, col.g * s.glow_alpha, col.b * s.glow_alpha, 1)
			render2d.DrawRect(0, 0, size.x, size.y)
			render2d.PopBorderRadius()
			render2d.PopUV()
		end

		local mpos = window.GetMousePosition()

		if not s.is_disabled and pnl.Owner.mouse_input:IsHoveredExclusively(mpos) then
			local lpos = pnl.Owner.transform:GlobalToLocal(mpos)
			render2d.SetBlendMode("additive")
			render2d.SetTexture(Textures.GlowLinear)

			if s.glow_alpha > 0 then
				local c = pnl.Owner.rect.Color or theme.GetColor("lightest")
				render2d.SetColor(c.r, c.g, c.b, c.a * s.glow_alpha)
				local gs = 256 * 1.5
				render2d.DrawRect(lpos.x - gs / 2, lpos.y - gs / 2, gs, gs)
			end

			render2d.SetTexture(Textures.GlowPoint)
			local c = pnl.Owner.rect.Color or theme.GetColor("lighter")
			render2d.SetColor(c.r, c.g, c.b, c.a * s.press_scale)
			local ps = s.press_scale * 150
			render2d.DrawRect(lpos.x - ps / 2, lpos.y - ps / 2, ps, ps)
			render2d.SetBlendMode("alpha")
		end
	end

	function theme.panels.button_post(pnl, state)
		local s = state or {glow_alpha = 0}
		local size = pnl.Owner.transform.Size
		render2d.SetBlendMode("additive")
		render2d.SetColor(s.glow_alpha, s.glow_alpha, s.glow_alpha, 1)
		render2d.SetTexture(Textures.GlowLinear)

		if state.mode == "filled" then
			theme.DrawGlowLine(-3, -3, -3, size.y + 6, 40)
		elseif state.mode == "outline" then
			local c = theme.GetColor("frame_border")
			render2d.SetColor(c.r, c.g, c.b, s.glow_alpha)
			theme.DrawGlowLine(0, 0, 0, size.y, 1)
			theme.DrawGlowLine(size.x, 0, size.x, size.y, 1)
		end

		local c = theme.GetColor("frame_border")
		render2d.SetColor(c.r, c.g, c.b, s.glow_alpha)
		theme.DrawGlowLine(0, 0, size.x, 0, 1)
		theme.DrawGlowLine(0, size.y, size.x, size.y, 1)
		render2d.SetBlendMode("alpha")
	end

	function theme.panels.slider(pnl, state)
		local pnl = pnl.Owner

		if state.is_hovered then theme.UpdateSliderAnimations(pnl, state) end

		local size = pnl.transform.Size
		local knob_width = theme.GetSize("S")
		local knob_height = theme.GetSize("S")
		local value = state.value
		local min_value = state.min
		local max_value = state.max
		local knob_x, knob_y

		if state.mode == "2d" then
			local normalized_x = (value.x - min_value.x) / (max_value.x - min_value.x)
			local normalized_y = (value.y - min_value.y) / (max_value.y - min_value.y)
			-- Draw track background
			render2d.SetTexture(nil)
			local c = theme.GetColor("darker")
			render2d.SetColor(c.r, c.g, c.b, c.a)
			render2d.DrawRect(0, 0, size.x, size.y)
			knob_x = normalized_x * (size.x - knob_width)
			knob_y = normalized_y * (size.y - knob_height)
		elseif state.mode == "vertical" then
			local normalized = (value - min_value) / (max_value - min_value)
			local track_width = theme.GetSize("XXS")
			local track_x = (size.x - track_width) / 2
			-- Draw track background
			render2d.SetTexture(nil)
			local c = theme.GetColor("darker")
			render2d.SetColor(c.r, c.g, c.b, c.a)
			render2d.DrawRect(track_x, knob_height / 2, track_width, size.y - knob_height)
			-- Draw filled track
			local fill_height = normalized * (size.y - knob_height)
			render2d.PushUV()
			render2d.SetUV2(0, 0, 0.5, 1)
			render2d.SetTexture(Textures.Gradient)
			local c = theme.GetColor("primary")
			render2d.SetColor(c.r, c.g, c.b, 0.9)
			render2d.DrawRect(track_x, knob_height / 2, track_width, fill_height)
			render2d.PopUV()

			-- Glow effect on filled track
			if state.glow_alpha > 0 then
				render2d.SetBlendMode("additive")
				render2d.SetTexture(Textures.GlowLinear)
				local c = theme.GetColor("light")
				render2d.SetColor(c.r, c.g * state.glow_alpha, c.b * state.glow_alpha, c.a)
				render2d.DrawRect(track_x - 2, knob_height / 2, track_width + 4, fill_height)
				render2d.SetBlendMode("alpha")
			end

			knob_x = (size.x - knob_width) / 2
			knob_y = normalized * (size.y - knob_height)
		else
			local normalized = (value - min_value) / (max_value - min_value)
			local track_height = theme.GetSize("XXS")
			local track_y = (size.y - track_height) / 2
			-- Draw track background
			render2d.SetTexture(nil)
			local c = theme.GetColor("darker")
			render2d.SetColor(c.r, c.g, c.b, c.a)
			render2d.DrawRect(knob_width / 2, track_y, size.x - knob_width, track_height)
			-- Draw filled track
			local fill_width = normalized * (size.x - knob_width)
			render2d.PushUV()
			render2d.SetUV2(0, 0, 0.5, 1)
			render2d.SetTexture(Textures.Gradient)
			local c = theme.GetColor("primary")
			render2d.SetColor(c.r, c.g, c.b, 0.9)
			render2d.DrawRect(knob_width / 2, track_y, fill_width, track_height)
			render2d.PopUV()

			-- Glow effect on filled track
			if state.glow_alpha > 0 then
				render2d.SetBlendMode("additive")
				render2d.SetTexture(Textures.GlowLinear)
				local c = theme.GetColor("light")
				render2d.SetColor(c.r, c.g * state.glow_alpha, c.b * state.glow_alpha, c.a)
				render2d.DrawRect(knob_width / 2, track_y - 2, fill_width, track_height + 4)
				render2d.SetBlendMode("alpha")
			end

			knob_x = normalized * (size.x - knob_width)
			knob_y = (size.y - knob_height) / 2
		end

		-- Draw knob
		-- Knob shadow/glow
		render2d.SetTexture(Textures.GlowPoint)
		render2d.SetBlendMode("additive")
		local c = theme.GetColor("lighter")
		render2d.SetColor(c.r, c.g, c.b, c.a + state.glow_alpha * 0.3)
		local glow_size = 20 * state.knob_scale
		render2d.DrawRect(
			knob_x + knob_width / 2 - glow_size / 2,
			knob_y + knob_height / 2 - glow_size / 2,
			glow_size,
			glow_size
		)
		render2d.SetBlendMode("alpha")
		-- Knob body
		render2d.SetTexture(nil)
		local c = theme.GetColor("button_normal")
		render2d.SetColor(c.r, c.g, c.b, c.a)
		local scaled_width = knob_width * state.knob_scale
		local scaled_height = knob_height * state.knob_scale
		local scale_offset_x = (scaled_width - knob_width) / 2
		local scale_offset_y = (scaled_height - knob_height) / 2
		render2d.DrawRect(
			knob_x - scale_offset_x,
			knob_y - scale_offset_y,
			scaled_width,
			scaled_height
		)
		-- Knob highlight
		render2d.PushUV()
		render2d.SetUV2(0, 0, 1, 0.5)
		render2d.SetTexture(Textures.Gradient)
		local c = theme.GetColor("lighter")
		render2d.SetColor(c.r, c.g, c.b, c.a)
		render2d.DrawRect(
			knob_x - scale_offset_x,
			knob_y - scale_offset_y,
			scaled_width,
			scaled_height * 0.5
		)
		render2d.PopUV()

		-- Edge glow
		if state.glow_alpha > 0 then
			render2d.SetBlendMode("additive")
			render2d.SetTexture(Textures.GlowLinear)
			local c = theme.GetColor("frame_border")
			render2d.SetColor(c.r * state.glow_alpha, c.g * state.glow_alpha, c.b * state.glow_alpha, 1)
			-- Top edge
			theme.DrawLine(
				knob_x - scale_offset_x,
				knob_y - scale_offset_y,
				knob_x + scaled_width - scale_offset_x,
				knob_y - scale_offset_y,
				1
			)
			-- Bottom edge
			theme.DrawLine(
				knob_x - scale_offset_x,
				knob_y + scaled_height - scale_offset_y,
				knob_x + scaled_width - scale_offset_x,
				knob_y + scaled_height - scale_offset_y,
				1
			)
			render2d.SetBlendMode("alpha")
		end
	end

	function theme.panels.checkbox(pnl, state)
		if state.is_hovered then theme.UpdateCheckboxAnimations(pnl, state) end

		local size = pnl.transform.Size
		local check_size = theme.GetSize("M")
		local box_x = 0
		local box_y = (size.y - check_size) / 2
		-- Background
		render2d.SetTexture(nil)
		local c = theme.GetColor("darker")
		render2d.SetColor(c.r, c.g, c.b, c.a)
		render2d.DrawRect(box_x, box_y, check_size, check_size)

		-- Border/Glow when hovered
		if state.glow_alpha > 0 then
			render2d.SetBlendMode("additive")
			render2d.SetTexture(Textures.GlowLinear)
			local c = theme.GetColor("frame_border")
			render2d.SetColor(c.r * state.glow_alpha, c.g * state.glow_alpha, c.b * state.glow_alpha, 0.5)
			theme.DrawRect(box_x - 1, box_y - 1, check_size + 2, check_size + 2, 1)
			render2d.SetBlendMode("alpha")
		end

		-- Check mark
		if state.check_anim > 0.01 then
			local s = state.check_anim
			render2d.PushUV()
			render2d.SetUV2(0, 0, 0.5, 1)
			render2d.SetTexture()
			local c = theme.GetColor("primary")
			render2d.SetBlendMode("additive")
			render2d.SetColor(c.r, c.g, c.b, 0.9 * s)
			local padding = check_size * 0.2
			local mark_size = (check_size - padding * 2) * s
			local mark_x = box_x + check_size / 2 - mark_size / 2
			local mark_y = box_y + check_size / 2 - mark_size / 2
			render2d.DrawRect(mark_x, mark_y, mark_size, mark_size)
			render2d.PopUV()
			render2d.SetBlendMode("alpha")
		end
	end

	function theme.panels.button_radio(pnl, state)
		if state.is_hovered then theme.UpdateCheckboxAnimations(pnl, state) end

		local size = pnl.transform.Size
		local rb_size = theme.GetSize("M")
		local rb_x = 0
		local rb_y = (size.y - rb_size) / 2
		-- Use a simple rect for now, but style it differently or use circular drawing if available
		-- Background
		render2d.SetTexture(nil)
		local c = theme.GetColor("darker")
		render2d.SetColor(c.r, c.g, c.b, c.a)
		theme.DrawDiamond(rb_x + rb_size / 2, rb_y + rb_size / 2, rb_size * 0.8)

		-- Glow
		if state.glow_alpha > 0 then
			render2d.SetBlendMode("additive")
			render2d.PushOutlineWidth(1)
			render2d.SetTexture()
			local c = theme.GetColor("frame_border")
			render2d.SetColor(c.r * state.glow_alpha, c.g * state.glow_alpha, c.b * state.glow_alpha, 2)
			theme.DrawDiamond(rb_x + rb_size / 2, rb_y + rb_size / 2, rb_size * 0.8)
			render2d.SetBlendMode("alpha")
			render2d.PopOutlineWidth()
		end

		-- Dot in the middle
		if state.check_anim > 0.01 then
			local s = state.check_anim
			render2d.SetTexture(theme.GetColor("primary"))
			render2d.SetBlendMode("additive")
			local c = theme.GetColor("primary")
			render2d.SetColor(c.r, c.g, c.b, 1 * s)
			local dot_size = (rb_size) * s
			theme.DrawDiamond(rb_x + dot_size / 2, rb_y + dot_size / 2, dot_size * 0.25)
			render2d.SetBlendMode("alpha")
		end
	end

	function theme.panels.frame(pnl, emphasis)
		local s = pnl.transform.Size + pnl.transform.DrawSizeOffset
		local c = pnl.rect.Color + pnl.rect.DrawColor
		render2d.SetColor(c.r, c.g, c.b, c.a * pnl.rect.DrawAlpha)
		render2d.PushAlphaMultiplier(pnl.rect.DrawAlpha)
		theme.DrawModernFrame(0, 0, s.x, s.y, (emphasis or 1) * pnl.rect.DrawAlpha)
		render2d.PopAlphaMultiplier()
	end

	function theme.panels.frame_post(pnl, emphasis)
		local s = pnl.transform.Size + pnl.transform.DrawSizeOffset
		local c = pnl.rect.Color + pnl.rect.DrawColor
		render2d.SetColor(c.r, c.g, c.b, c.a)
		render2d.PushAlphaMultiplier(pnl.rect.DrawAlpha)
		theme.DrawModernFramePost(0, 0, s.x, s.y, (emphasis or 1) * pnl.rect.DrawAlpha)
		render2d.PopAlphaMultiplier()
	end

	function theme.panels.menu_spacer(pnl, vertical)
		local size = pnl.Owner.transform:GetSize()
		local w = size.x
		local h = size.y
		local r, g, b, a = theme.GetColor("lightest"):Unpack()
		render2d.PushColor(r, g, b, a)

		if vertical then
			theme.DrawLine(w / 2, 0, w / 2, h, 2)
		else
			theme.DrawLine(0, h / 2, w, h / 2, 2)
		end

		render2d.PopColor()
	end

	function theme.panels.header(pnl)
		local size = pnl.transform.Size
		render2d.SetColor(PRIMARY.r, PRIMARY.g, PRIMARY.b, PRIMARY.a * pnl.rect.DrawAlpha)
		theme.DrawPill(0, 0, size.x, size.y)
	end

	function theme.panels.progress_bar(pnl, state)
		local size = pnl.Owner.transform.Size
		local value = state.value or 0
		local col = pnl.Owner.rect.Color or PRIMARY
		theme.DrawProgressBarPrimitive(0, 0, size.x, size.y, value, col)
	end

	function theme.panels.divider(pnl)
		local size = pnl.transform.Size
		render2d.SetColor(PRIMARY.r, PRIMARY.g, PRIMARY.b, PRIMARY.a * pnl.rect.DrawAlpha * 10)
		render2d.PushBlendMode("additive")

		if size.x > size.y then
			-- horizontal
			theme.DrawGlowLine(0, size.y / 2, size.x, size.y / 2, 0)
		else
			-- vertical
			theme.DrawGlowLine(size.x / 2, 0, size.x / 2, size.y, 0)
		end

		render2d.PopBlendMode()
	end
end

do
	local blur_color = Color.FromHex("#2374DD")
	HeadingFont = fonts.New(
		{
			Path = "/home/caps/Downloads/Exo_2/static/Exo2-Bold.ttf",
			Size = 30,
			Padding = 20,
			SeparateEffects = true,
			Effects = {
				{
					Type = "shadow",
					Dir = -1.5,
					Color = Color.FromHex("#0c1721"),
					BlurRadius = 0.25,
					BlurPasses = 1,
				},
				{
					Type = "shadow",
					Dir = 0,
					Color = blur_color,
					BlurRadius = 3,
					BlurPasses = 3,
					AlphaPow = 0.6,
				},
			},
		}
	)

	function theme.DrawMuseum()
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetTexture(nil)
		local x, y = 500, 200 --gfx.GetMousePosition()
		local w, h = 600, 30

		do
			local f = theme.GetFont("heading")
			f:SetSize(theme.GetFontSize("XXL"))
			f:DrawText("Custom Font Rendering", x, y - 40)
		end

		theme.DrawClassicFrame(x, y, 60, 40)
		x = x + 80
		theme.DrawModernFrame(x, y, 100, 60, 1)
		x = x + 120
		theme.DrawModernFrame(x, y, 100, 60, 0)
		x = x + 120
		theme.DrawWhiteFrame(x, y, 60, 40)
		x = x - 120 - 80 - 120
		y = y + 80
		render2d.SetColor(0, 0, 0, 1)
		theme.DrawPill(x, y, w, h)
		y = y + 50
		theme.DrawBadge(x, y, w, h)
		y = y + 50
		theme.DrawDiamond(x, y, 20)
		x = x + 50
		render2d.PushOutlineWidth(1)
		theme.DrawDiamond(x, y, 20)
		render2d.PopOutlineWidth()
		render2d.SetColor(1, 1, 1, 1)
		x = x + 50
		theme.DrawArrow(x, y, 40)
		x = x - 100
		y = y + 50
		render2d.SetTexture(nil)
		theme.DrawLine(x + 20, y, x + w - 40, y, 3)
		y = y + 20
		theme.DrawLine2(x + 20, y, x + w - 40, y, 3)
		y = y + 20
		theme.DrawDiamond2(x, y, 10)
		y = y + 20
		render2d.SetColor(1, 1, 1, 1)
		y = y + 20
		theme.DrawMagicCircle(x - 100, y, 30)
		y = y + 20
		theme.DrawGlowLine(x, y, x + w - 40, y, 1)
	end
end

if HOTRELOAD then
	event.AddListener("Draw2D", "theme_museum", function()
		theme.DrawMuseum()
	end)
end

return theme
