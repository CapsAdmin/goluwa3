local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local system = import("goluwa/system.lua")
local objects = import("goluwa/objects/objects.lua")
local BaseTheme = import("./base.lua")
local JRPGTheme = objects.CreateTemplate("ui_theme_jrpgv2")
JRPGTheme.Base = BaseTheme
JRPGTheme.Name = "jrpg 2"
local ink = Color.FromHex("#04060d")
local night = Color.FromHex("#0d1626")
local neon = Color.FromHex("#3fd3e6")
local gold = Color.FromHex("#e8b64c")
local jade = Color.FromHex("#3fd68f")
local amber = Color.FromHex("#e8c15a")
local vermillion = Color.FromHex("#e04a33")
local warm_white = Color.FromHex("#eef4ff")
local border_steel = Color.FromHex("#2e5876")

local function to_linear_channel(c)
	if c <= 0.04045 then return c / 12.92 end

	return ((c + 0.055) / 1.055) ^ 2.4
end

local WHITE = Color(1, 1, 1)

local function set_color(c, a)
	render2d.SetColor(to_linear_channel(c.r), to_linear_channel(c.g), to_linear_channel(c.b), a)
end

function JRPGTheme:CreatePalette()
	return self:ConfigurePalette(self.BaseClass.CreatePalette(self))
end

function JRPGTheme:ConfigurePalette(palette)
	palette:SetShades{
		ink,
		Color.FromHex("#8fa8c8"),
		warm_white,
	}
	palette:SetColors{
		red = vermillion,
		yellow = amber,
		blue = neon,
		green = jade,
		purple = Color.FromHex("#9b5de5"),
		brown = Color.FromHex("#8b5e3c"),
	}
	palette.AdjustmentOptions = self:MergeTables(palette.AdjustmentOptions, {target_contrast = 4.5})
	palette:SetMap{
		dashed_underline = warm_white:Copy():SetAlpha(0.15),
		button_color = neon,
		underline = neon,
		url_color = neon,
		property_selection = neon:Copy():SetAlpha(0.22),
		text_selection = neon:Copy():SetAlpha(0.35),
		actual_black = ink,
		primary = neon,
		primary_focus = Color.FromHex("#2fa8bd"),
		secondary = gold,
		gold = gold,
		positive = jade,
		neutral = amber,
		negative = vermillion,
		ink = ink,
		heading = warm_white,
		default = warm_white,
		text = warm_white,
		text_foreground = warm_white,
		text_button = warm_white,
		text_on_accent = warm_white,
		text_on_dark = warm_white,
		text_on_dark_muted = warm_white:Copy():SetAlpha(0.8),
		text_disabled = warm_white:Copy():SetAlpha(0.4),
		text_on_surface = warm_white,
		text_on_surface_variant = warm_white,
		text_on_card = warm_white,
		text_on_header_surface = warm_white,
		text_foreground_on_surface = warm_white,
		text_foreground_on_header_surface = warm_white,
		heading_on_surface = warm_white,
		heading_on_header_surface = warm_white,
		foreground = warm_white,
		background = ink,
		main_background = ink,
		surface = night,
		surface_alt = Color.FromHex("#101c33"),
		surface_variant = Color.FromHex("#0a1120"),
		surface_pearl = Color.FromHex("#0f192c"),
		surface_tile_1 = Color.FromHex("#0b1220"),
		surface_tile_2 = Color.FromHex("#0d1526"),
		surface_tile_3 = Color.FromHex("#09101c"),
		card = Color.FromHex("#0b1322"),
		header_surface = Color.FromHex("#12203c"),
		scrollbar_track = Color(1, 1, 1, 0.06),
		scrollbar = neon:Copy():SetAlpha(0.45),
		border = border_steel,
		invisible = Color(0, 0, 0, 0),
		clickable_disabled = Color(1, 1, 1, 0.15),
		button_normal = gold,
	}
	return palette
end

function JRPGTheme:Initialize(theme_context)
	self.BaseClass.Initialize(self, theme_context)
	self:SetSizes(
		self:MergeTables(
			self:GetSizes(),
			{
				XXS = 4,
				S = 8,
				M = 10,
				L = 15,
				XL = 20,
				XXL = 25,
				default = 10,
			}
		)
	)
	self:SetFontSizes(
		self:MergeTables(
			self:GetFontSizes(),
			{
				XS = 10,
				S = 11,
				M = 12,
				L = 18,
				XL = 25,
				XXL = 32,
				XXXL = 42,
			}
		)
	)
	self:SetFontStyles(
		self:MergeTables(
			self:GetFontStyles(),
			{
				heading = {"Orbitron", "Bold"},
				body_weak = {"Exo", "Bold"},
				body = {"Exo", "Regular"},
				body_strong = {"Exo", "Bold"},
			}
		)
	)
	self:SetFontCache({})
	local assets = import("goluwa/assets.lua")
	self.Textures = {
		GlowLinear = assets.GetTexture("textures/render/glow_linear.lua"),
		GlowPoint = assets.GetTexture("textures/render/glow_point.lua"),
		Gradient = assets.GetTexture("textures/render/gradient_linear.lua"),
	}
	self.GlowLineTexture = assets.GetTexture(
		"textures/render/glow_line.lua",
		{
			config = {
				core_thickness = 1,
				glow_radius = 9,
				glow_intensity = 0.2,
			},
		}
	)

	do
		local function make_gradient(top_hex, bottom_hex, diagonal)
			local top = Color.FromHex(top_hex)
			local bottom = Color.FromHex(bottom_hex)
			local lin = function(c)
				return to_linear_channel(c)
			end
			top.r, top.g, top.b = lin(top.r), lin(top.g), lin(top.b)
			bottom.r, bottom.g, bottom.b = lin(bottom.r), lin(bottom.g), lin(bottom.b)
			local tex = Texture.New{
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
			local diagonal_term = diagonal and " + uv.x * 0.25" or ""
			tex:Shade(
				[[
				return vec4(mix(vec3(]] .. bottom.r .. ", " .. bottom.g .. ", " .. bottom.b .. "), vec3(" .. top.r .. ", " .. top.g .. ", " .. top.b .. "), uv.y" .. diagonal_term .. [[), 1.0);
			]]
			)
			return tex
		end

		self.ModernFrameGradient = make_gradient("#182a4e", "#0a1122", true)
		self.GradientClassicTexture = make_gradient("#1a1440", "#05030f", false)

		local function make_fade(vertical)
			local tex = Texture.New{
				width = vertical and 1 or 16,
				height = vertical and 16 or 1,
				format = "r8g8b8a8_unorm",
				sampler = {
					min_filter = "linear",
					mag_filter = "linear",
					wrap_s = "clamp_to_edge",
					wrap_t = "clamp_to_edge",
				},
			}
			tex:Shade(
				vertical and
					"return vec4(1.0, 1.0, 1.0, uv.y);" or
					"return vec4(1.0, 1.0, 1.0, 1.0 - uv.x);"
			)
			return tex
		end

		self.SliderFillFadeH = make_fade(false)
		self.SliderFillFadeV = make_fade(true)
	end

	self.MetalFrameTexture = assets.GetTexture(
		"textures/render/metal_frame.lua",
		{
			config = {base_color = Color.FromHex("#5a6a80")},
		}
	)
	self.MetalFrameWhiteTexture = assets.GetTexture(
		"textures/render/metal_frame.lua",
		{
			config = {
				base_color = Color.FromHex("#8a94a6"),
				frame_inner = 0.02,
				frame_outer = 0.002,
				corner_radius = 0.02,
			},
		}
	)
	self.ModernGlowColor = neon
end

function JRPGTheme:DrawDiamond(x, y, size)
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	render2d.Rotate(math.rad(45))
	render2d.DrawRectf(-size / 2, -size / 2, size, size)
	render2d.PopMatrix()
end

function JRPGTheme:DrawDiamond2(x, y, size)
	self:DrawDiamond(x, y, size / 3)
	render2d.PushOutlineWidth(-1)
	self:DrawDiamond(x, y, size)
	render2d.PopOutlineWidth()
end

-- Decorative emphasis levels: 0 none, 1 subtle (inline fields), 2 standard
-- (frames, tooltips), 3 prominent (windows).
local FRAME_LEVELS = {
	[0] = {glow = 0, corner = false},
	[1] = {glow = 0.15, corner = false},
	[2] = {glow = 0.3, corner = true, gem = 14, len = 12, thick = 1.5},
	[3] = {glow = 0.5, corner = true, gem = 17, len = 16, thick = 2},
}

local function frame_level(emphasis)
	return FRAME_LEVELS[emphasis] or FRAME_LEVELS[0]
end

-- Bracket arms + corner gem centered on (cx, cy); arms run into the frame
-- in the (dx, dy) direction.
function JRPGTheme:DrawFrameCorner(cx, cy, dx, dy, emphasis)
	local lv = FRAME_LEVELS[emphasis]

	if not lv or not lv.corner then return end

	local len, thick = lv.len, lv.thick
	local goldc = self:GetColor("gold")
	local glow = self:GetColor("primary")
	render2d.SetTexture(nil)
	set_color(goldc, 1)
	render2d.DrawRect(math.min(cx, cx + dx * len), dy > 0 and cy or cy - thick, len, thick)
	render2d.DrawRect(dx > 0 and cx or cx - thick, math.min(cy, cy + dy * len), thick, len)
	render2d.PushBlendPreset("additive")
	set_color(glow, 1)
	self:DrawDiamond2(cx, cy, lv.gem)
	render2d.PopBlendMode()
end

function JRPGTheme:DrawGem(x, y, size, color)
	render2d.PushBlendPreset("additive")
	set_color(color, 1)
	self:DrawDiamond(x, y, size)
	set_color(WHITE, 0.9)
	self:DrawDiamond(x, y, size * 0.4)
	render2d.PopBlendMode()
end

function JRPGTheme:DrawPill(x, y, w, h)
	render2d.PushBorderRadius(h)
	render2d.SetColor(1, 1, 1, 1)
	render2d.PushTexture(self.ModernFrameGradient)
	render2d.DrawRect(x, y, w, h)
	render2d.PopTexture()
	local goldc = self:GetColor("gold")
	set_color(goldc, 0.7)
	render2d.PushOutlineWidth(-1)
	render2d.DrawRect(x, y, w, h)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
	render2d.PushBlendPreset("additive")
	local accent = self:GetColor("primary")
	self:DrawGem(x + 4, y + h / 2, 6, accent)
	self:DrawGem(x + w - 4, y + h / 2, 6, accent)
	render2d.PopBlendMode()
end

function JRPGTheme:DrawBadge(x, y, w, h)
	render2d.PushBorderRadius(h)
	render2d.PushTexture(self.Textures.Gradient)
	render2d.PushColorUV(-0.1, 0, 0.75, 1)
	local goldc = self:GetColor("gold")
	set_color(goldc, 0.85)
	render2d.DrawRect(x, y, w, h)
	render2d.PopColorUV()
	render2d.PopTexture()
	render2d.PopBorderRadius()
	render2d.PushBlendPreset("additive")
	self:DrawGem(x + 8, y + h / 2, 7, goldc)
	render2d.PopBlendMode()
end

function JRPGTheme:DrawArrow(x, y, size)
	local f = size / 2
	render2d.PushBorderRadius(f * 3, f * 2, f * 2, f * 3)
	render2d.PushMatrix()
	render2d.Translatef(x - size / 3, y - size / 3)
	render2d.Scalef(1.6, 0.75)
	render2d.DrawRectf(0, 0, size, size)
	render2d.PopMatrix()
	render2d.PopBorderRadius()
	self:DrawDiamond(x, y + 0.5, size / 2)
end

function JRPGTheme:DrawGlowLine(x1, y1, x2, y2, thickness)
	render2d.PushTexture(self.GlowLineTexture)
	local dx = x2 - x1
	local dy = y2 - y1
	local length = math.sqrt(dx * dx + dy * dy)
	local angle = math.atan2(dy, dx)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRectf(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
	render2d.PopTexture()
end

function JRPGTheme:DrawGlow(x, y, size)
	local tex = self.Textures.GlowPoint
	render2d.PushTexture(tex)
	render2d.DrawRectf(x - size / 2, y - size / 2, size, size)
	render2d.PopTexture()
end

function JRPGTheme:DrawCircle(x, y, size, width)
	render2d.PushOutlineWidth(-(width or 1))
	render2d.DrawFilledCircle(x, y, size)
	render2d.PopOutlineWidth()
end

function JRPGTheme:DrawMagicCircle(x, y, size, opts)
	opts = opts or {}
	local cyan = self:GetColor("primary")
	local goldc = self:GetColor("gold")
	render2d.SetTexture(nil)
	render2d.PushBlendPreset("additive")
	set_color(cyan, 0.9)
	render2d.PushSDFSoftness(size * 0.04)
	self:DrawCircle(x, y, size, 3)
	self:DrawCircle(x, y, size * 1.5)
	self:DrawCircle(x, y, size * 1.7)
	self:DrawCircle(x, y, size * 3)
	render2d.PopSDFSoftness()
	local d = math.max(4, size * 0.15)

	for i = 1, 8 do
		local a = (i / 8) * math.pi * 2 + math.pi / 8
		set_color(goldc, 0.9)
		self:DrawDiamond(x + math.cos(a) * size * 1.5, y + math.sin(a) * size * 1.5, d)
	end

	for i = 1, 16 do
		local a = (i / 16) * math.pi * 2
		local r1 = size * 1.8
		local r2 = size * 2.2
		set_color(cyan, 0.5)
		self:DrawGlowLine(
			x + math.cos(a) * r1,
			y + math.sin(a) * r1,
			x + math.cos(a) * r2,
			y + math.sin(a) * r2,
			1.5
		)
	end

	render2d.PopBlendMode()
end

function JRPGTheme:DrawFrame(size, emphasis)
	render2d.SetColor(1, 1, 1, 1)
	render2d.PushTexture(self.ModernFrameGradient)
	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.PopTexture()
end

function JRPGTheme:DrawFramePost(size, emphasis)
	local lv = frame_level(emphasis)
	local border = self:GetColor("border")
	render2d.SetTexture(nil)
	set_color(border, 0.9)
	render2d.DrawRect(0.5, 0.5, size.x - 1, 1)
	render2d.DrawRect(0.5, size.y - 1.5, size.x - 1, 1)
	render2d.DrawRect(0.5, 0.5, 1, size.y - 1)
	render2d.DrawRect(size.x - 1.5, 0.5, 1, size.y - 1)
	self:DrawFrameCorner(0, 0, 1, 1, emphasis)
	self:DrawFrameCorner(size.x, 0, -1, 1, emphasis)
	self:DrawFrameCorner(0, size.y, 1, -1, emphasis)
	self:DrawFrameCorner(size.x, size.y, -1, -1, emphasis)

	if lv.glow > 0 then
		render2d.PushBlendPreset("additive")
		local glow = self:GetColor("primary")
		set_color(glow, lv.glow)
		render2d.SetTexture(self.GlowLineTexture)
		local s = -0.05
		render2d.PushColorUV(-s, 0, 1 - -s, 1)
		render2d.DrawRect(0, -1, size.x, 1)
		render2d.DrawRect(0, size.y, size.x, 1)
		render2d.PopColorUV()
		render2d.SetTexture(self.GlowLineTexture)
		set_color(glow, lv.glow * 0.6)
		render2d.PushMatrixf()
		render2d.Translatef(1, size.y / 2)
		render2d.Rotate(math.rad(90))
		local s = -0.05
		render2d.PushColorUV(-s, 0, 1 - -s, 1)
		render2d.DrawRect(-size.y / 2, -1, size.y, 1)
		render2d.PopMatrix()
		render2d.PushMatrixf()
		render2d.Translatef(size.x - 1, size.y / 2)
		render2d.Rotate(math.rad(90))
		render2d.DrawRect(-size.y / 2, -1, size.y, 1)
		render2d.PopColorUV()
		render2d.PopMatrix()
		render2d.PopBlendMode()
		render2d.SetTexture(nil)
	end
end

-- Window content shares one visual frame with its header: the header draws
-- the top edge and top corners, so the content only draws the rest.
function JRPGTheme:DrawWindowContentPost(size, emphasis)
	local lv = frame_level(emphasis)
	local border = self:GetColor("border")
	render2d.SetTexture(nil)
	set_color(border, 0.9)
	render2d.DrawRect(0.5, size.y - 1.5, size.x - 1, 1)
	render2d.DrawRect(0.5, 0.5, 1, size.y - 1)
	render2d.DrawRect(size.x - 1.5, 0.5, 1, size.y - 1)
	self:DrawFrameCorner(0, size.y, 1, -1, emphasis)
	self:DrawFrameCorner(size.x, size.y, -1, -1, emphasis)

	if lv.glow > 0 then
		render2d.PushBlendPreset("additive")
		local glow = self:GetColor("primary")
		set_color(glow, lv.glow)
		render2d.SetTexture(self.Textures.GlowLinear)
		render2d.DrawRect(0, size.y, size.x, 3)
		render2d.SetTexture(self.GlowLineTexture)
		set_color(glow, lv.glow * 0.6)
		render2d.PushMatrixf()
		render2d.Translatef(1, size.y / 2)
		render2d.Rotate(math.rad(90))
		render2d.DrawRect(-size.y / 2, -9.5, size.y, 19)
		render2d.PopMatrix()
		render2d.PushMatrixf()
		render2d.Translatef(size.x - 1, size.y / 2)
		render2d.Rotate(math.rad(90))
		render2d.DrawRect(-size.y / 2, -9.5, size.y, 19)
		render2d.PopMatrix()
		render2d.PopBlendMode()
		render2d.SetTexture(nil)
	end
end

function JRPGTheme:DrawPost(pnl)
	if pnl.Name == "WindowContent" then
		return self:DrawWindowContentPost(pnl.transform:GetTotalSize(), self:GetEmphasis(pnl))
	end

	return self.BaseClass.DrawPost(self, pnl)
end

function JRPGTheme:DrawHeader(size, emphasis)
	render2d.SetColor(1, 1, 1, 1)
	render2d.PushTexture(self.ModernFrameGradient)
	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.PopTexture()
	local border = self:GetColor("border")
	local goldc = self:GetColor("gold")
	render2d.SetTexture(nil)
	set_color(border, 0.9)
	render2d.DrawRect(0.5, 0.5, size.x - 1, 1)
	render2d.DrawRect(0.5, 0.5, 1, size.y - 1)
	render2d.DrawRect(size.x - 1.5, 0.5, 1, size.y - 1)
	set_color(goldc, 0.8)
	render2d.DrawRect(0, size.y - 1, size.x, 1)
	self:DrawFrameCorner(0, 0, 1, 1, emphasis or 3)
	self:DrawFrameCorner(size.x, 0, -1, 1, emphasis or 3)
end

function JRPGTheme:DrawButton(size, state)
	if state.mode == "menu" then
		return self.BaseClass.DrawButton(self, size, state)
	end

	local anim = state.anim or {glow_alpha = 0, press_scale = 0}
	local accent = self:GetColor(state.button_color or "primary")
	local radius = math.max(2, math.floor(size.y / 5))
	local alpha_scale = state.disabled and 0.4 or 1

	-- Text buttons are bare text; they only gain a solid accent fill on
	-- hover/press/active.
	if state.mode == "text" then
		if not state.disabled and (state.hovered or state.pressed or state.active) then
			local fill_alpha = (state.pressed or state.active) and 0.95 or 0.8
			render2d.SetTexture(nil)
			render2d.PushBorderRadius(radius)
			set_color(accent, fill_alpha)
			render2d.DrawRect(0, 0, size.x, size.y)
			render2d.PopBorderRadius()
		end

		return
	end

	render2d.SetTexture(nil)
	local base_c = self:GetColor("surface_variant")
	set_color(base_c, alpha_scale)
	render2d.PushBorderRadius(radius)
	render2d.DrawRect(0, 0, size.x, size.y)

	if state.mode ~= "outline" then
		render2d.PushTexture(self.Textures.Gradient)
		set_color(accent, (state.disabled and 0.08) or (0.25 + anim.glow_alpha * 0.2))
		render2d.PushColorUV(0, 0, 0.5, 1)
		render2d.DrawRect(0, 0, size.x, size.y)
		render2d.PopColorUV()
		render2d.PopTexture()
	end

	local bo = (state.disabled and 0.3) or (0.6 + anim.glow_alpha * 0.4)
	render2d.SetTexture(nil)
	set_color(accent, bo)
	render2d.PushOutlineWidth(0.5)
	render2d.SetBorderRadius(0)
	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()

	if not state.disabled then
		render2d.PushBlendPreset("additive")
		local side_alpha = state.mode == "outline" and 0.9 or 0.55
		set_color(accent, side_alpha * (0.6 + anim.glow_alpha * 0.4))
		self:DrawDiamond(1, size.y / 2, 3.5)
		self:DrawDiamond(size.x - 1, size.y / 2, 3.5)
		render2d.PopBlendMode()
	end
end

function JRPGTheme:DrawButtonPost(size, state)
	if state.mode == "menu" then
		return self.BaseClass.DrawButtonPost(self, size, state)
	end

	local anim = state.anim or {glow_alpha = 0}

	if anim.glow_alpha <= 0.01 then return end

	local accent = self:GetColor(state.button_color or "primary")
	render2d.PushBlendPreset("additive")
	set_color(accent, anim.glow_alpha * 0.7)
	self:DrawGlowLine(0, 0, size.x, 0, 1)
	self:DrawGlowLine(0, size.y, size.x, size.y, 1)
	render2d.SetColor(1, 1, 1, anim.glow_alpha * 0.5)
	self:DrawGlow(3, 3, 12 * anim.glow_alpha)
	self:DrawGlow(size.x - 3, 3, 12 * anim.glow_alpha)
	self:DrawGlow(3, size.y - 3, 12 * anim.glow_alpha)
	self:DrawGlow(size.x - 3, size.y - 3, 12 * anim.glow_alpha)
	render2d.PopBlendMode()
end

function JRPGTheme:DrawSlider(size, state)
	local anim = state.anim or {glow_alpha = 0, knob_scale = 1}
	local knob = self:GetSize("S")
	local accent = self:GetColor("primary")
	local track_bg = self:GetColor("surface_variant")
	local mode = state.mode or "horizontal"

	local function draw_knob(cx, cy)
		if anim.glow_alpha > 0.01 then
			render2d.PushBlendPreset("additive")
			set_color(accent, anim.glow_alpha * 0.5)
			self:DrawDiamond(cx, cy, 12 * anim.knob_scale)
			render2d.PopBlendMode()
		end

		local goldc = self:GetColor("gold")
		render2d.SetTexture(nil)
		set_color(goldc, 1)
		self:DrawDiamond(cx, cy, 7 * anim.knob_scale)
		render2d.SetColor(1, 1, 1, 0.9)
		self:DrawDiamond(cx, cy, 2.5 * anim.knob_scale)
	end

	if mode == "horizontal" then
		local track_h = self:GetSize("XXS")
		local track_y = (size.y - track_h) / 2
		local min = state.min or 0
		local max = state.max or 1
		local normalized = (state.value or 0)

		if max > min then normalized = (normalized - min) / (max - min) end

		normalized = math.clamp(normalized, 0, 1)
		local fill_w = normalized * (size.x - knob)
		render2d.SetTexture(nil)
		set_color(track_bg, 1)
		render2d.DrawRect(knob / 2, track_y, size.x - knob, track_h)

		if fill_w > 0.5 then
			render2d.PushTexture(self.SliderFillFadeH)
			set_color(accent, 0.85)
			render2d.DrawRect(knob / 2, track_y, fill_w, track_h)
			render2d.PushBlendPreset("additive")
			set_color(accent, 0.15 + anim.glow_alpha * 0.2)
			render2d.DrawRect(knob / 2, track_y - 2, fill_w, track_h + 4)
			render2d.PopBlendMode()
			render2d.PopTexture()
		end

		draw_knob(knob / 2 + fill_w, size.y / 2)
	elseif mode == "vertical" then
		local track_w = self:GetSize("XXS")
		local track_x = (size.x - track_w) / 2
		local min = state.min or 0
		local max = state.max or 1
		local normalized = (state.value or 0)

		if max > min then normalized = (normalized - min) / (max - min) end

		normalized = math.clamp(normalized, 0, 1)
		local fill_h = normalized * (size.y - knob)
		render2d.SetTexture(nil)
		set_color(track_bg, 1)
		render2d.DrawRect(track_x, knob / 2, track_w, size.y - knob)

		if fill_h > 0.5 then
			render2d.PushTexture(self.SliderFillFadeV)
			set_color(accent, 0.85)
			render2d.DrawRect(track_x, knob / 2, track_w, fill_h)
			render2d.PushBlendPreset("additive")
			set_color(accent, 0.15 + anim.glow_alpha * 0.2)
			render2d.DrawRect(track_x - 2, knob / 2, track_w + 4, fill_h)
			render2d.PopBlendMode()
			render2d.PopTexture()
		end

		draw_knob(size.x / 2, knob / 2 + fill_h)
	elseif mode == "2d" then
		local track_bg_c = self:GetColor("surface_variant")
		render2d.SetTexture(nil)
		set_color(track_bg_c, 1)
		render2d.DrawRect(0, 0, size.x, size.y)
		local px = (state.value.x or 0) * size.x
		local py = (state.value.y or 0) * size.y
		render2d.PushBlendPreset("additive")
		set_color(accent, 0.4)
		self:DrawGlowLine(knob / 2, py, px, py, 1)
		self:DrawGlowLine(px, size.y - knob / 2, px, py, 1)
		render2d.PopBlendMode()
		draw_knob(px, py)
	end
end

function JRPGTheme:DrawCheckbox(size, state)
	local anim = state.anim or {glow_alpha = 0, check_anim = state.value and 1 or 0}
	local cs = math.max(6, math.min(size.x, size.y) - 2)
	local cx = size.x / 2
	local cy = size.y / 2
	local border = self:GetColor("border")
	render2d.SetTexture(nil)
	set_color(border, 1)
	render2d.PushOutlineWidth(-1.5)
	self:DrawDiamond(cx, cy, cs)
	render2d.PopOutlineWidth()

	if anim.glow_alpha > 0.01 then
		render2d.PushBlendPreset("additive")
		local accent = self:GetColor("primary")
		set_color(accent, anim.glow_alpha * 0.8)
		render2d.PushOutlineWidth(-1)
		self:DrawDiamond(cx, cy, cs + 3)
		render2d.PopOutlineWidth()
		render2d.PopBlendMode()
	end

	local s = anim.check_anim or 0

	if s > 0.01 then
		local goldc = self:GetColor("gold")
		render2d.PushBlendPreset("additive")
		set_color(goldc, 0.95 * s)
		self:DrawDiamond(cx, cy, cs * 0.6 * s)
		render2d.SetColor(1, 1, 1, 0.85 * s)
		self:DrawDiamond(cx, cy, cs * 0.28 * s)
		render2d.PopBlendMode()
	end
end

function JRPGTheme:DrawButtonRadio(size, state)
	local anim = state.anim or {glow_alpha = 0, check_anim = state.value and 1 or 0}
	local rs = math.max(6, math.min(size.x, size.y) - 2)
	local cx = size.x / 2
	local cy = size.y / 2
	local border = self:GetColor("border")
	render2d.SetTexture(nil)
	set_color(border, 1)
	render2d.PushOutlineWidth(-1.5)
	self:DrawDiamond(cx, cy, rs)
	render2d.PopOutlineWidth()

	if anim.glow_alpha > 0.01 then
		render2d.PushBlendPreset("additive")
		local accent = self:GetColor("primary")
		set_color(accent, anim.glow_alpha * 0.8)
		render2d.PushOutlineWidth(-1)
		self:DrawDiamond(cx, cy, rs + 3)
		render2d.PopOutlineWidth()
		render2d.PopBlendMode()
	end

	local s = anim.check_anim or 0

	if s > 0.01 then
		local accent = self:GetColor("primary")
		render2d.PushBlendPreset("additive")
		set_color(accent, 0.9 * s)
		self:DrawDiamond(cx, cy, rs * 0.55 * s)
		render2d.SetColor(1, 1, 1, 0.9 * s)
		self:DrawDiamond(cx, cy, rs * 0.25 * s)
		render2d.PopBlendMode()
	end
end

function JRPGTheme:DrawProgressBar(size, state, color)
	local value = state.value or 0
	local c = color == nil and self:GetColor("primary") or self:ResolveSurfaceColor(color)
	render2d.SetTexture(nil)
	local track = self:GetColor("surface_variant")
	set_color(track, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
	local segments = 10
	local seg_w = size.x / segments

	for i = 1, segments do
		render2d.SetColor(1, 1, 1, 0.08)
		render2d.DrawRect(i * seg_w - 0.5, 1, 1, size.y - 2)
	end

	local accent = self:GetColor("primary")
	render2d.PushBlendPreset("additive")
	set_color(accent, 0.35)
	self:DrawGlowLine(0, 0, size.x, 0, 1)
	self:DrawGlowLine(0, size.y, size.x, size.y, 1)
	render2d.PopBlendMode()
	local fill_w = size.x * value
	render2d.PushTexture(self.Textures.Gradient)
	render2d.PushColorUV(0, 0, 0.5, 1)
	set_color(c, 0.95)
	render2d.DrawRect(0, 1, fill_w, size.y - 2)
	render2d.PopColorUV()
	render2d.PopTexture()
	render2d.SetColor(1, 1, 1, 0.5)
	render2d.DrawRect(0, 1, fill_w, 1)
	local cx = fill_w
	local cy = size.y / 2
	local s = math.min(size.y / 2, 6)
	render2d.PushBlendPreset("additive")
	render2d.PushTexture(self.GlowLineTexture)
	set_color(c, 0.9)
	render2d.DrawRectf(cx - 4, cy - s * 2, 8, s * 4)
	render2d.PopTexture()
	set_color(c, 1)
	self:DrawDiamond(cx, cy, s)
	render2d.SetColor(1, 1, 1, 0.8)
	self:DrawDiamond(cx, cy, s * 0.4)
	render2d.PopBlendMode()
end

function JRPGTheme:DrawDivider(size)
	render2d.SetTexture(nil)
	local cyan = self:GetColor("primary")
	local goldc = self:GetColor("gold")

	if size.x >= size.y then
		render2d.PushBlendPreset("additive")
		set_color(cyan, 0.6)
		self:DrawGlowLine(10, size.y / 2, size.x - 10, size.y / 2, 1)
		render2d.PopBlendMode()
		set_color(goldc, 1)
		self:DrawDiamond(size.x / 2, size.y / 2, 4.5)
		render2d.SetColor(1, 1, 1, 0.8)
		self:DrawDiamond(size.x / 2, size.y / 2, 2)
	else
		render2d.PushBlendPreset("additive")
		set_color(cyan, 0.6)
		self:DrawGlowLine(size.x / 2, 10, size.x / 2, size.y - 10, 1)
		render2d.PopBlendMode()
		set_color(goldc, 1)
		self:DrawDiamond(size.x / 2, size.y / 2, 4.5)
		render2d.SetColor(1, 1, 1, 0.8)
		self:DrawDiamond(size.x / 2, size.y / 2, 2)
	end
end

function JRPGTheme:DrawMenuSpacer(size)
	local w = size.x
	local h = size.y
	local border = self:GetColor("border")
	local goldc = self:GetColor("gold")

	if h < w then
		local mid_y = h / 2
		render2d.SetTexture(nil)
		set_color(border, 0.8)
		render2d.DrawRect(8, mid_y - 0.5, w - 16, 1)
		self:DrawDiamond(4, mid_y, 4)
		self:DrawDiamond(w - 4, mid_y, 4)
		render2d.PushBlendPreset("additive")
		set_color(goldc, 0.9)
		self:DrawDiamond(4, mid_y, 3)
		self:DrawDiamond(w - 4, mid_y, 3)
		render2d.PopBlendMode()
	else
		local mid_x = w / 2
		render2d.SetTexture(nil)
		set_color(border, 0.8)
		render2d.DrawRect(mid_x - 0.5, 8, 1, h - 16)
		self:DrawDiamond(mid_x, 4, 4)
		self:DrawDiamond(mid_x, h - 4, 4)
		render2d.PushBlendPreset("additive")
		set_color(goldc, 0.9)
		self:DrawDiamond(mid_x, 4, 3)
		self:DrawDiamond(mid_x, h - 4, 3)
		render2d.PopBlendMode()
	end
end

function JRPGTheme:DrawLine(x1, y1, x2, y2, thickness)
	thickness = thickness or 1
	local dx = x2 - x1
	local dy = y2 - y1
	local length = math.sqrt(dx * dx + dy * dy)
	local angle = math.atan2(dy, dx)
	render2d.SetTexture(nil)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRectf(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

function JRPGTheme:UpdateButtonAnimations(pnl)
	return self.BaseClass.UpdateButtonAnimations(self, pnl)
end

function JRPGTheme:DrawMuseum()
	local w = system.GetWindow():GetSize()
	local goldc = self:GetColor("gold")
	local cyan = self:GetColor("primary")
	local white = self:GetColor("white")
	render2d.PushBlendPreset("additive")
	self:DrawMagicCircle(w.x - 260, 250, 60)
	render2d.PopBlendMode()

	do
		local tx = 80
		local ty = 60
		render2d.SetTexture(nil)
		render2d.PushBlendPreset("additive")
		render2d.PushTexture(self.Textures.GlowLinear)
		render2d.SetColor(cyan.r, cyan.g, cyan.b, 0.5)
		render2d.DrawRect(tx - 20, ty - 14, 540, 28)
		render2d.PopTexture()
		render2d.SetColor(white.r, white.g, white.b, 1)
		self:DrawDiamond(tx + 250, ty, 10)
		render2d.PopBlendMode()
		self:DrawDivider(Rect(0, 0, 500, 10))
	end

	do
		local x, y = 80, 140
		render2d.PushMatrix()
		render2d.Translatef(x, y)
		self:DrawFrame(Vec2(340, 170), 1)
		self:DrawFramePost(Vec2(340, 170), 1)
		self:DrawPill(40, 12, 260, 22)
		self:DrawBadge(120, 120, 100, 16)
		render2d.PopMatrix()
		local x2, y2 = 460, 140
		render2d.PushMatrix()
		render2d.Translatef(x2, y2)
		self:DrawFrame(Vec2(340, 170), 3)
		self:DrawFramePost(Vec2(340, 170), 3)
		self:DrawMenuSpacer(Vec2(300, 6))
		render2d.PopMatrix()
	end

	do
		local x, y = 80, 360
		local states = {
			{mode = "filled", label = "Primary", color = "primary"},
			{mode = "filled", label = "Positive", color = "positive"},
			{mode = "filled", label = "Negative", color = "negative"},
			{mode = "outline", label = "Outline", color = "primary"},
			{mode = "filled", label = "Disabled", color = "primary", disabled = true},
		}
		local bx = 0

		for _, s in ipairs(states) do
			render2d.PushMatrix()
			render2d.Translatef(x + bx, y)
			local bw = 40 + #s.label * 7
			local st = {
				mode = s.mode,
				button_color = s.color,
				disabled = s.disabled,
				hovered = false,
				anim = {glow_alpha = 0},
			}
			self:DrawButton(Vec2(bw, 30), st)
			render2d.PopMatrix()
			bx = bx + bw + 16
		end
	end

	do
		local x, y = 80, 440
		render2d.PushMatrix()
		render2d.Translatef(x, y)
		local st = {
			mode = "horizontal",
			value = 0.65,
			min = 0,
			max = 1,
			anim = {glow_alpha = 0.4, knob_scale = 1},
		}
		self:DrawSlider(Vec2(360, 28), st)
		render2d.Translatef(420, 0)
		st = {
			mode = "vertical",
			value = 0.4,
			min = 0,
			max = 1,
			anim = {glow_alpha = 0, knob_scale = 1},
		}
		self:DrawSlider(Vec2(28, 140), st)
		render2d.Translatef(80, 60)
		local goldc2 = self:GetColor("gold")
		render2d.PushBlendPreset("additive")
		self:DrawGem(0, 0, 10, goldc2)
		self:DrawGem(24, 0, 10, cyan)
		self:DrawGem(48, 0, 10, self:GetColor("negative"))
		render2d.PopBlendMode()
		render2d.PopMatrix()
	end

	do
		local x, y = 80, 640
		local bars = {
			{value = 0.7, color = "primary"},
			{value = 0.45, color = "positive"},
			{value = 0.85, color = "negative"},
		}

		for i, b in ipairs(bars) do
			render2d.PushMatrix()
			render2d.Translatef(x, y + (i - 1) * 26)
			self:DrawProgressBar(Vec2(500, 14), {value = b.value}, b.color)
			render2d.PopMatrix()
		end
	end

	do
		local x, y = 700, 360
		render2d.PushMatrix()
		render2d.Translatef(x, y)
		render2d.PushBlendPreset("additive")
		self:DrawGlowLine(0, 0, 400, 0, 2)
		render2d.SetColor(goldc.r, goldc.g, goldc.b, 0.9)
		self:DrawDiamond(200, 0, 8)
		render2d.SetColor(white.r, white.g, white.b, 0.8)
		self:DrawDiamond(200, 0, 4)
		render2d.PopBlendMode()
		render2d.PopMatrix()
	end
end

return JRPGTheme:Register()
