local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local fonts = require("render2d.fonts")
local render2d = require("render2d.render2d")
local Ang3 = require("structs.ang3")
local window = require("window")
local theme = library()
local PRIMARY = Color.FromHex("#062a67"):SetAlpha(0.9)

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
			button_disabled = Color(0.3, 0.3, 0.3, 1),
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

	function theme.GetPadding(size_name)
		size_name = size_name or "default"
		return sizes[size_name] or sizes.default
	end

	function theme.GetSize(size_name)
		size_name = size_name or "default"
		return sizes[size_name] or sizes.default
	end
end

theme.line_height = 5
local stroke_width = theme.GetSize("line")
local stroke_width_thick = theme.GetSize("line") * 2
local small_border_radius = 1
local big_border_radius = 1
local border_sizes = {
	none = 0,
	default = theme.GetSize("L"),
	small = theme.GetSize("M"),
	circle = "50%",
}
local shadow = {
	{
		x = 0,
		y = 0,
		blur = 4,
		intensity = 2,
		color = theme.GetColor("black"):Copy():SetAlpha(0.1),
	},
	{
		x = 3,
		y = 3,
		blur = 8,
		radius = 5,
		color = theme.GetColor("darker"):Copy():SetAlpha(0.1),
	},
}
local shadow_footer = {
	{
		x = 0,
		y = 0,
		blur = 4,
		intensity = 2,
		color = theme.GetColor("black"):Copy():SetAlpha(0.1),
	},
	{
		x = 3,
		y = -3,
		blur = 8,
		radius = 5,
		color = theme.GetColor("darker"):Copy():SetAlpha(0.1),
	},
}
---
local DecorGlow = PRIMARY:Copy():SetAlpha(0.25)
local DecorWhite = Color(1, 1, 1, 1)
local ButtonShadow = Color(0, 0, 0, 0.2)
local GradientBlue = PRIMARY:Copy()
local GradientCyan = PRIMARY:Copy()
local SliderTrackBackground = Color(0.2, 0.2, 0.2, 0.8)
local SliderGlow = PRIMARY:Copy():SetAlpha(0.5)
local SliderKnobGlow = PRIMARY:Copy():SetAlpha(0.7)
local ButtonPressGlow = Color(1, 1, 1, 0.5)
local ButtonHoverGlow = Color(1, 1, 1, 0.15)
local MenuSpacer = Color(1, 1, 1, 0.1)
local KnobHighlight = Color(1, 1, 1, 0.3)
local Textures = {
	GlowLinear = require("render.textures.glow_linear"),
	GlowPoint = require("render.textures.glow_point"),
	Gradient = require("render.textures.gradient_linear"),
}

do
	local path = fonts.GetSystemDefaultFont()
	local font_sizes = {
		XS = 10,
		S = 12,
		M = 14,
		L = 20,
		XL = 27,
		XXL = 32,
		XXXL = 42,
	}
	local font_paths = {
		heading = "/home/caps/Downloads/Exo_2/static/Exo2-Regular.ttf",
		body_weak = "/home/caps/Downloads/Exo_2/static/Exo2-Light.ttf",
		body = "/home/caps/Downloads/Exo_2/static/Exo2-Regular.ttf",
		body_strong = "/home/caps/Downloads/Exo_2/static/Exo2-Regular.ttf",
	}

	function theme.GetFont(name, size_name)
		local path = font_paths[name or "body"] or font_paths.body
		local size = font_sizes[size_name or "M"] or font_sizes.M
		theme.Fonts = theme.Fonts or {}
		theme.Fonts[path] = theme.Fonts[path] or {}
		theme.Fonts[path][size] = theme.Fonts[path][size] or
			fonts.CreateFont(
				{
					path = path,
					size = size,
					shadow = {
						dir = -2,
						color = Color.FromHex("#022d58"):SetAlpha(0.75),
						blur_radius = 0.25,
						blur_passes = 1,
					},
				}
			)
		return theme.Fonts[path][size]
	end
end

function theme.DrawLine(x1, y1, x2, y2, thickness, tex)
	if tex == false then
		render2d.SetTexture(nil)
	else
		render2d.SetTexture(tex or Textures.GlowLinear)
	end

	render2d.PushMatrix()
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	render2d.Translate(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

function theme.DrawRect(x, y, w, h, thickness, extent, tex)
	extent = extent or 0
	theme.DrawLine(x - extent, y, x + w + extent, y, thickness, tex)
	theme.DrawLine(x + w, y - extent, x + w, y + h + extent, thickness, tex)
	theme.DrawLine(x + w + extent, y + h, x - extent, y + h, thickness, tex)
	theme.DrawLine(x, y + h + extent, x, y - extent, thickness, tex)
end

function theme.DrawEdgeDecor(x, y)
	render2d.PushMatrix()
	render2d.Translate(x, y)
	render2d.Rotate(45)
	local size = 3
	render2d.SetEdgeFeather(0.5)
	theme.DrawRect(-size, -size, size * 2, size * 2, 2, 0, false)
	render2d.SetEdgeFeather(0)
	render2d.PopMatrix()
	render2d.SetTexture(Textures.GlowPoint)
	render2d.SetBlendMode("additive")
	local r, g, b, a = DecorGlow:Unpack()
	render2d.PushColor(r, g, b, a)
	local size_glow = size * 40
	render2d.DrawRect(x - size_glow, y - size_glow, size_glow * 2, size_glow * 2)
	render2d.PopColor()

	do
		local r, g, b, a = DecorWhite:Unpack()
		render2d.PushColor(r, g, b, a)
		local size_white = theme.GetSize("XXS")
		render2d.SetTexture(Textures.GlowPoint)
		render2d.DrawRect(x - size_white, y - size_white, size_white * 2, size_white * 2)
		render2d.SetBlendMode("alpha")
		render2d.PopColor()
	end
end

function theme.DrawFrame(pnl)
	local s = pnl.transform.Size + pnl.transform.DrawSizeOffset
	local c = pnl.rect.Color + pnl.rect.DrawColor
	render2d.SetColor(c.r, c.g, c.b, c.a * pnl.rect.DrawAlpha)
	render2d.SetBlendMode("alpha")
	render2d.PushUV()
	render2d.SetUV2(0.5, 0.1, 0.7, 0.6)
	render2d.SetTexture(Textures.GlowLinear)
	render2d.DrawRect(0, 0, s.x, s.y)
	render2d.PopUV()
end

function theme.DrawFramePost(pnl)
	local s = pnl.transform.Size + pnl.transform.DrawSizeOffset
	local c = pnl.rect.Color + pnl.rect.DrawColor

	do
		local r, g, b, a = theme.GetColor("frame_border"):Unpack()
		render2d.SetColor(r, g, b, c.a * pnl.rect.DrawAlpha)
		render2d.SetBlendMode("alpha")
		local offset = 2
		theme.DrawRect(
			-offset,
			-offset,
			s.x + offset * 2,
			s.y + offset * 2,
			theme.GetSize("XXS"),
			40
		)
		theme.DrawEdgeDecor(-offset, -offset)
		theme.DrawEdgeDecor(s.x + offset, -offset)
		theme.DrawEdgeDecor(s.x + offset, s.y + offset)
		theme.DrawEdgeDecor(-offset, s.y + offset)
	end
end

function theme.UpdateButtonAnimations(ent, s)
	if not ent or not s then return end

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
		ent.animation:Animate(
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
		ent.animation:Animate(
			{
				id = "DrawScaleOffset",
				get = function()
					return ent.transform:GetDrawScaleOffset()
				end,
				set = function(v)
					ent.transform:SetDrawScaleOffset(v)
				end,
				to = is_active and (Vec2(0.9, 0.9)) or (Vec2(1, 1)),
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
		ent.animation:Animate(
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
		ent.animation:Animate(
			{
				id = "DrawAngleOffset",
				get = function()
					return ent.transform:GetDrawAngleOffset()
				end,
				set = function(v)
					ent.transform:SetDrawAngleOffset(v)
				end,
				to = not is_tilting and
					Ang3(0, 0, 0) or
					{
						__lsx_value = function(self)
							local mpos = window.GetMousePosition()
							local local_pos = self.transform:GlobalToLocal(mpos)
							local size = self.transform:GetSize()
							local nx = (local_pos.x / size.x) * 2 - 1
							local ny = (local_pos.y / size.y) * 2 - 1
							return Ang3(-ny, nx, 0) * 0.1
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

function theme.DrawButton(self, state)
	-- Continuous tracking while hovered
	if state and state.is_hovered then
		theme.UpdateButtonAnimations(self.Owner, state)
	end

	local s = state or {glow_alpha = 0, press_scale = 0}
	local size = self.Owner.transform.Size
	render2d.PushUV()
	render2d.SetUV2(0, 0, 0.4, 1)
	render2d.SetTexture(Textures.Gradient)
	local col = GradientBlue
	render2d.SetColor(col.r * s.glow_alpha, col.g * s.glow_alpha, col.b * s.glow_alpha, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.PopUV()
	local mpos = window.GetMousePosition()

	if not s.is_disabled and self.Owner.mouse_input:IsHoveredExclusively(mpos) then
		local lpos = self.Owner.transform:GlobalToLocal(mpos)
		render2d.SetBlendMode("additive")
		render2d.SetTexture(Textures.GlowLinear)

		if s.glow_alpha > 0 then
			local c = ButtonHoverGlow
			render2d.SetColor(c.r, c.g, c.b, c.a * s.glow_alpha)
			local gs = 256 * 1.5
			render2d.DrawRect(lpos.x - gs / 2, lpos.y - gs / 2, gs, gs)
		end

		render2d.SetTexture(Textures.GlowPoint)
		local c = ButtonPressGlow
		render2d.SetColor(c.r, c.g, c.b, c.a * s.press_scale)
		local ps = s.press_scale * 150
		render2d.DrawRect(lpos.x - ps / 2, lpos.y - ps / 2, ps, ps)
		render2d.SetBlendMode("alpha")
	end
end

function theme.DrawButtonPost(self, state)
	local s = state or {glow_alpha = 0}
	local size = self.Owner.transform.Size
	render2d.SetBlendMode("additive")
	render2d.SetColor(s.glow_alpha, s.glow_alpha, s.glow_alpha, 1)
	render2d.SetTexture(Textures.GlowLinear)
	render2d.PushUV()
	render2d.SetUV2(0.2, 0, 0.8, 1)
	theme.DrawLine(-2, 0, -2, size.y, 4, Textures.GlowLinear)
	render2d.PopUV()
	local c = GradientCyan
	render2d.SetColor(c.r, c.g, c.b, s.glow_alpha)
	render2d.PushUV()
	render2d.SetUV2(0.5, 0, 1, 0.5)
	theme.DrawLine(0, 0, size.x, 0, 1, Textures.GlowLinear)
	theme.DrawLine(0, size.y, size.x, size.y, 1, Textures.GlowLinear)
	render2d.PopUV()
	render2d.SetBlendMode("alpha")
end

function theme.DrawMenuSpacer(self, props)
	local size = self.Owner.transform:GetSize()
	local w = size.x
	local h = size.y
	local r, g, b, a = MenuSpacer:Unpack()
	render2d.PushColor(r, g, b, a)

	if props.Vertical then
		theme.DrawLine(w / 2, 0, w / 2, h, 2, Textures.Gradient)
		theme.DrawEdgeDecor(w / 2, 0)
		theme.DrawEdgeDecor(w / 2, h)
	else
		theme.DrawLine(0, h / 2, w, h / 2, 2, Textures.Gradient)
		theme.DrawEdgeDecor(0, h / 2)
		theme.DrawEdgeDecor(w, h / 2)
	end

	render2d.PopColor()
end

function theme.UpdateSliderAnimations(ent, s)
	if s.is_hovered ~= s.last_hovered then
		ent.animation:Animate(
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
		ent.animation:Animate(
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

function theme.DrawSlider(self, state)
	local owner = self.Owner

	if state.is_hovered then theme.UpdateSliderAnimations(owner, state) end

	local size = owner.transform.Size
	local track_height = theme.GetSize("XXS")
	local track_y = (size.y - track_height) / 2
	local knob_width = theme.GetSize("S")
	local knob_height = theme.GetSize("S")
	local value = state.value or 0
	local min_value = state.min or 0
	local max_value = state.max or 1
	-- Draw track background
	render2d.SetTexture(nil)
	local c = SliderTrackBackground
	render2d.SetColor(c.r, c.g, c.b, c.a)
	render2d.DrawRect(knob_width / 2, track_y, size.x - knob_width, track_height)
	-- Draw filled track
	local normalized = (value - min_value) / (max_value - min_value)
	local fill_width = normalized * (size.x - knob_width)
	render2d.PushUV()
	render2d.SetUV2(0, 0, 0.5, 1)
	render2d.SetTexture(Textures.Gradient)
	local c = GradientBlue
	render2d.SetColor(c.r, c.g, c.b, 0.9)
	render2d.DrawRect(knob_width / 2, track_y, fill_width, track_height)
	render2d.PopUV()

	-- Glow effect on filled track
	if state.glow_alpha > 0 then
		render2d.SetBlendMode("additive")
		render2d.SetTexture(Textures.GlowLinear)
		local c = SliderGlow
		render2d.SetColor(c.r, c.g * state.glow_alpha, c.b * state.glow_alpha, c.a)
		render2d.DrawRect(knob_width / 2, track_y - 2, fill_width, track_height + 4)
		render2d.SetBlendMode("alpha")
	end

	-- Draw knob
	local knob_x = knob_width / 2 + normalized * (size.x - knob_width) - knob_width / 2
	local knob_y = (size.y - knob_height) / 2
	-- Knob shadow/glow
	render2d.SetTexture(Textures.GlowPoint)
	render2d.SetBlendMode("additive")
	local c = SliderKnobGlow
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
	local c = KnobHighlight
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
		local c = GradientCyan
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

function theme.UpdateCheckboxAnimations(ent, s)
	if s.is_hovered ~= s.last_hovered then
		ent.animation:Animate(
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
		ent.animation:Animate(
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

function theme.DrawCheckbox(owner, state)
	if state.is_hovered then theme.UpdateCheckboxAnimations(owner, state) end

	local size = owner.transform.Size
	local check_size = theme.GetSize("M")
	local box_x = 0
	local box_y = (size.y - check_size) / 2
	-- Background
	render2d.SetTexture(nil)
	local c = SliderTrackBackground
	render2d.SetColor(c.r, c.g, c.b, c.a)
	render2d.DrawRect(box_x, box_y, check_size, check_size)

	-- Border/Glow when hovered
	if state.glow_alpha > 0 then
		render2d.SetBlendMode("additive")
		render2d.SetTexture(Textures.GlowLinear)
		local c = GradientCyan
		render2d.SetColor(c.r * state.glow_alpha, c.g * state.glow_alpha, c.b * state.glow_alpha, 0.5)
		theme.DrawRect(box_x - 1, box_y - 1, check_size + 2, check_size + 2, 1)
		render2d.SetBlendMode("alpha")
	end

	-- Check mark
	if state.check_anim > 0.01 then
		local s = state.check_anim
		render2d.PushUV()
		render2d.SetUV2(0, 0, 0.5, 1)
		render2d.SetTexture(Textures.Gradient)
		local c = GradientBlue
		render2d.SetColor(c.r, c.g, c.b, 0.9 * s)
		local padding = check_size * 0.2
		local mark_size = (check_size - padding * 2) * s
		local mark_x = box_x + check_size / 2 - mark_size / 2
		local mark_y = box_y + check_size / 2 - mark_size / 2
		render2d.DrawRect(mark_x, mark_y, mark_size, mark_size)
		render2d.PopUV()
	end
end

function theme.DrawRadioButton(owner, state)
	if state.is_hovered then theme.UpdateCheckboxAnimations(owner, state) end

	local size = owner.transform.Size
	local rb_size = theme.GetSize("M")
	local rb_x = 0
	local rb_y = (size.y - rb_size) / 2
	-- Use a simple rect for now, but style it differently or use circular drawing if available
	-- Background
	render2d.SetTexture(nil)
	local c = SliderTrackBackground
	render2d.SetColor(c.r, c.g, c.b, c.a)
	render2d.DrawRect(rb_x, rb_y, rb_size, rb_size)

	-- Glow
	if state.glow_alpha > 0 then
		render2d.SetBlendMode("additive")
		render2d.SetTexture(Textures.GlowLinear)
		local c = GradientCyan
		render2d.SetColor(c.r * state.glow_alpha, c.g * state.glow_alpha, c.b * state.glow_alpha, 0.5)
		theme.DrawRect(rb_x - 1, rb_y - 1, rb_size + 2, rb_size + 2, 1)
		render2d.SetBlendMode("alpha")
	end

	-- Dot in the middle
	if state.check_anim > 0.01 then
		local s = state.check_anim
		render2d.SetTexture(Textures.GlowPoint)
		render2d.SetBlendMode("additive")
		local c = GradientBlue
		render2d.SetColor(c.r, c.g, c.b, 1 * s)
		local dot_size = (rb_size * 0.6) * s
		render2d.DrawRect(
			rb_x + rb_size / 2 - dot_size / 2,
			rb_y + rb_size / 2 - dot_size / 2,
			dot_size,
			dot_size
		)
		render2d.SetBlendMode("alpha")
	end
end

return theme
