local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local objects = import("goluwa/objects/objects.lua")
local BaseTheme = import("./base.lua")
local JRPGTheme = objects.CreateTemplate("ui_theme_jrpg")
JRPGTheme.Base = BaseTheme
JRPGTheme.Name = "jrpg"
local ink = Color.FromHex("#04060d")
local night = Color.FromHex("#0d1626")
local neon = Color.FromHex("#3fd3e6")
local gold = Color.FromHex("#e8b64c")
local jade = Color.FromHex("#3fd68f")
local amber = Color.FromHex("#e8c15a")
local vermillion = Color.FromHex("#e04a33")
local warm_white = Color.FromHex("#eef4ff")
local border_steel = Color.FromHex("#2e5876")
local WHITE = Color(1, 1, 1)

local function set_color(c, a)
	render2d.SetColor(c.r, c.g, c.b, a)
end

local function draw_knob(theme, anim, accent, cx, cy)
	if anim.glow_alpha > 0.01 then
		render2d.PushBlendPreset("additive")
		set_color(accent, anim.glow_alpha * 0.5)
		theme:DrawDiamond(cx, cy, 12 * anim.knob_scale)
		render2d.PopBlendMode()
	end

	local goldc = theme:GetColor("gold")
	render2d.SetTexture(nil)
	set_color(goldc, 1)
	theme:DrawDiamond(cx, cy, 7 * anim.knob_scale)
	render2d.SetColor(1, 1, 1, 0.9)
	theme:DrawDiamond(cx, cy, 2.5 * anim.knob_scale)
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

function JRPGTheme:Initialize()
	self.BaseClass.Initialize(self)
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
		self.ModernFrameGradient = render2d.CreateGradient{
			mode = "linear",
			angle = 166,
			width = 512,
			height = 256,
			stops = {
				{pos = 0.0, color = Color.FromHex("#0a1122")},
				{pos = 1.0, color = Color.FromHex("#182a4e")},
			},
		}
		self.SliderFillFadeH = render2d.CreateGradient{
			mode = "linear",
			angle = 90,
			width = 256,
			height = 1,
			stops = {
				{pos = 0.0, color = Color(1, 1, 1, 1)},
				{pos = 1.0, color = Color(1, 1, 1, 0)},
			},
		}
		self.SliderFillFadeV = render2d.CreateGradient{
			mode = "linear",
			angle = 0,
			width = 1,
			height = 256,
			stops = {
				{pos = 0.0, color = Color(1, 1, 1, 1)},
				{pos = 1.0, color = Color(1, 1, 1, 0)},
			},
		}
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
	render2d.DrawShape{
		x = x - size / 2,
		y = y - size / 2,
		w = size,
		h = size,
		angle = math.rad(45),
	}
end

function JRPGTheme:DrawDiamond2(x, y, size)
	self:DrawDiamond(x, y, size / 3)
	render2d.DrawShape{
		x = x - size / 2,
		y = y - size / 2,
		w = size,
		h = size,
		angle = math.rad(45),
		layers = {
			{outline_width = -1},
		},
	}
end

-- Decorative emphasis levels: 0 none, 1 subtle (inline fields), 2 standard
-- (frames, tooltips), 3 prominent (windows). `off` pushes the corner gem and
-- its offset outline outside the frame corner.
local FRAME_LEVELS = {
	[0] = {glow = 0, corner = false},
	[1] = {glow = 0.15, corner = false},
	[2] = {glow = 0.3, corner = true, gem = 6, len = 12, off = 3},
	[3] = {glow = 0.5, corner = true, gem = 8, len = 16, off = 4},
}

local function frame_level(emphasis)
	return FRAME_LEVELS[emphasis] or FRAME_LEVELS[0]
end

-- 1px border line layers. `gap` leaves the corners open where the offset
-- corner outline and gem take over.
local function border_layers(size, color, gap, top, bottom, left, right)
	local layers = {}

	local function add(x, y, w, h)
		table.insert(layers, {color = color, alpha = 0.9, x = x, y = y, w = w, h = h})
	end

	if top then add(0.5 + gap, 0.5, size.x - 1 - gap * 2, 1) end

	if bottom then add(0.5 + gap, size.y - 1.5, size.x - 1 - gap * 2, 1) end

	if left then
		local y0 = 0.5 + (top and gap or 0)
		add(0.5, y0, 1, size.y - 1 - y0 - (bottom and gap or 0))
	end

	if right then
		local y0 = 0.5 + (top and gap or 0)
		add(size.x - 1.5, y0, 1, size.y - 1 - y0 - (bottom and gap or 0))
	end

	return layers
end

-- Corner gem offset outside the frame corner, with a glowing outline offset
-- outside the frame that runs from the gem along each edge, cut at the gem.
function JRPGTheme:DrawFrameCorner(cx, cy, dx, dy, emphasis)
	local lv = FRAME_LEVELS[emphasis]

	if not lv or not lv.corner then return end

	local gx = cx - dx * lv.off
	local gy = cy - dy * lv.off
	local glow = self:GetColor("primary")
	render2d.SetTexture(nil)
	render2d.PushBlendPreset("additive")
	set_color(glow, 0.7)
	self:DrawGlowLine(gx + dx * lv.gem / 2, gy, cx + dx * lv.len, gy, 1)
	self:DrawGlowLine(gx, gy + dy * lv.gem / 2, gx, cy + dy * lv.len, 1)
	set_color(glow, 1)
	self:DrawDiamond2(gx, gy, lv.gem)
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
	local goldc = self:GetColor("gold")
	local accent = self:GetColor("primary")
	render2d.DrawShape{
		x = x,
		y = y,
		w = w,
		h = h,
		border_radius = h,
		int = true,
		layers = {
			{color = Color(1, 1, 1, 1), texture = self.ModernFrameGradient},
			{color = goldc, alpha = 0.7, texture = false, outline_width = -1},
		},
	}
	render2d.PushBlendPreset("additive")
	self:DrawGem(x + 4, y + h / 2, 6, accent)
	self:DrawGem(x + w - 4, y + h / 2, 6, accent)
	render2d.PopBlendMode()
end

function JRPGTheme:DrawBadge(x, y, w, h)
	local goldc = self:GetColor("gold")
	render2d.DrawShape{
		x = x,
		y = y,
		w = w,
		h = h,
		color = goldc,
		alpha = 0.85,
		texture = self.Textures.Gradient,
		color_uv = {x = -0.1, y = 0, w = 0.75, h = 1},
		border_radius = h,
		int = true,
	}
	render2d.PushBlendPreset("additive")
	self:DrawGem(x + 8, y + h / 2, 7, goldc)
	render2d.PopBlendMode()
end

function JRPGTheme:DrawArrow(x, y, size)
	local f = size / 2
	render2d.PushMatrix()
	render2d.Translatef(x - size / 3, y - size / 3)
	render2d.Scalef(1.6, 0.75)
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size,
		h = size,
		border_radius = f,
	}
	render2d.PopMatrix()
	self:DrawDiamond(x, y + 0.5, size / 2)
end

function JRPGTheme:DrawGlowLine(x1, y1, x2, y2, thickness)
	local dx = x2 - x1
	local dy = y2 - y1
	local length = math.sqrt(dx * dx + dy * dy)
	local angle = math.atan2(dy, dx)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawShape{
		x = 0,
		y = -thickness / 2,
		w = length,
		h = thickness,
		texture = self.GlowLineTexture,
	}
	render2d.PopMatrix()
end

function JRPGTheme:DrawGlow(x, y, size)
	render2d.DrawShape{
		x = x - size / 2,
		y = y - size / 2,
		w = size,
		h = size,
		texture = self.Textures.GlowPoint,
	}
end

function JRPGTheme:DrawCircle(x, y, size, width, softness)
	render2d.DrawShape{
		x = x - size,
		y = y - size,
		w = size * 2,
		h = size * 2,
		border_radius = size,
		sdf_softness = softness,
		int = true,
		layers = {
			{outline_width = -(width or 1)},
		},
	}
end

function JRPGTheme:DrawMagicCircle(x, y, size, opts)
	opts = opts or {}
	local cyan = self:GetColor("primary")
	local goldc = self:GetColor("gold")
	render2d.SetTexture(nil)
	render2d.PushBlendPreset("additive")
	set_color(cyan, 0.9)
	local softness = size * 0.04
	self:DrawCircle(x, y, size, 3, softness)
	self:DrawCircle(x, y, size * 1.5, 1, softness)
	self:DrawCircle(x, y, size * 1.7, 1, softness)
	self:DrawCircle(x, y, size * 3, 1, softness)
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
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		color = Color(1, 1, 1, 1),
		texture = self.ModernFrameGradient,
		int = true,
	}
end

function JRPGTheme:DrawFramePost(size, emphasis)
	local lv = frame_level(emphasis)
	local border = self:GetColor("border")
	local gap = lv.corner and lv.off + lv.gem / 2 or 0
	local s = -0.05
	local uv = {x = -s, y = 0, w = 1 + s, h = 1}
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		texture = false,
		int = true,
		layers = border_layers(size, border, gap, true, true, true, true),
	}
	self:DrawFrameCorner(0, 0, 1, 1, emphasis)
	self:DrawFrameCorner(size.x, 0, -1, 1, emphasis)
	self:DrawFrameCorner(0, size.y, 1, -1, emphasis)
	self:DrawFrameCorner(size.x, size.y, -1, -1, emphasis)

	if lv.glow > 0 then
		local glow = self:GetColor("primary")
		render2d.PushBlendPreset("additive")
		render2d.DrawShape{
			x = 0,
			y = 0,
			w = size.x,
			h = size.y,
			texture = self.GlowLineTexture,
			int = true,
			layers = {
				{color = glow, alpha = lv.glow, x = 0, y = -1, w = size.x, h = 1, color_uv = uv},
				{
					color = glow,
					alpha = lv.glow,
					x = 0,
					y = size.y,
					w = size.x,
					h = 1,
					color_uv = uv,
				},
			},
		}
		render2d.PushMatrix()
		render2d.Translatef(1, size.y / 2)
		render2d.Rotate(math.rad(90))
		render2d.DrawShape{
			x = -size.y / 2,
			y = -1,
			w = size.y,
			h = 1,
			color = glow,
			alpha = lv.glow * 0.6,
			texture = self.GlowLineTexture,
			color_uv = uv,
		}
		render2d.PopMatrix()
		render2d.PushMatrix()
		render2d.Translatef(size.x - 1, size.y / 2)
		render2d.Rotate(math.rad(90))
		render2d.DrawShape{
			x = -size.y / 2,
			y = -1,
			w = size.y,
			h = 1,
			color = glow,
			alpha = lv.glow * 0.6,
			texture = self.GlowLineTexture,
			color_uv = uv,
		}
		render2d.PopMatrix()
		render2d.PopBlendMode()
	end
end

-- Window content shares one visual frame with its header: the header draws
-- the top edge and top corners, so the content only draws the rest.
function JRPGTheme:DrawWindowContentPost(size, emphasis)
	local lv = frame_level(emphasis)
	local border = self:GetColor("border")
	local gap = lv.corner and lv.off + lv.gem / 2 or 0
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		texture = false,
		int = true,
		layers = border_layers(size, border, gap, false, true, true, true),
	}
	self:DrawFrameCorner(0, size.y, 1, -1, emphasis)
	self:DrawFrameCorner(size.x, size.y, -1, -1, emphasis)

	if lv.glow > 0 then
		local glow = self:GetColor("primary")
		render2d.PushBlendPreset("additive")
		render2d.DrawShape{
			x = 0,
			y = size.y,
			w = size.x,
			h = 3,
			color = glow,
			alpha = lv.glow,
			texture = self.Textures.GlowLinear,
			int = true,
		}
		-- The original int-path DrawRect ceils the rotated local y (-9.5 -> -9).
		render2d.PushMatrix()
		render2d.Translatef(1, size.y / 2)
		render2d.Rotate(math.rad(90))
		render2d.DrawShape{
			x = -size.y / 2,
			y = -9,
			w = size.y,
			h = 19,
			color = glow,
			alpha = lv.glow * 0.6,
			texture = self.GlowLineTexture,
		}
		render2d.PopMatrix()
		render2d.PushMatrix()
		render2d.Translatef(size.x - 1, size.y / 2)
		render2d.Rotate(math.rad(90))
		render2d.DrawShape{
			x = -size.y / 2,
			y = -9,
			w = size.y,
			h = 19,
			color = glow,
			alpha = lv.glow * 0.6,
			texture = self.GlowLineTexture,
		}
		render2d.PopMatrix()
		render2d.PopBlendMode()
	end
end

function JRPGTheme:DrawPost(pnl)
	if pnl.Name == "WindowContent" then
		return self:DrawWindowContentPost(pnl.transform:GetTotalSize(), self:GetEmphasis(pnl))
	elseif pnl.Name == "clickable" then
		return self:DrawButtonPost(pnl.transform:GetTotalSize(), pnl:GetState())
	end

	return self.BaseClass.DrawPost(self, pnl)
end

function JRPGTheme:DrawSelectionFill(size, color, alpha)
	local resolved = self:ResolveColor(color, color or "primary")

	if resolved.a < 0.5 then
		return self:DrawPanelFill(size, resolved, alpha, 0)
	end

	local accent = self:GetColor("primary")
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		sdf_softness = 0.1,
		int = true,
		layers = {
			{color = accent, alpha = 0.10, texture = false},
			{color = accent, alpha = 0.14, texture = self.SliderFillFadeH},
			{color = accent, alpha = 0.9, w = 2, texture = false},
		},
	}
end

function JRPGTheme:DrawTreeGuideLines(size, meta, opts)
	opts = opts or {}
	local toggle_size = opts.toggle_size or 0
	local guide_step = opts.guide_step or 0
	local center_x = meta.level * guide_step + math.floor(toggle_size / 2)
	local center_y = math.floor(size.y / 2)
	local line_start_x = opts.line_start_x or center_x
	local accent = self:GetColor("primary")
	local T = 1

	for level = 1, #(meta.continuations or {}) do
		if meta.continuations[level] then
			local x = (level - 1) * guide_step + math.floor(toggle_size / 2)
			render2d.DrawShape{
				x = x,
				y = 0,
				w = T,
				h = size.y,
				color = accent,
				alpha = 0.28,
				texture = false,
				sdf_softness = 0,
			}
		end
	end

	if meta.level > 0 then
		render2d.DrawShape{
			x = center_x,
			y = 0,
			w = T,
			h = center_y + T,
			color = accent,
			alpha = 0.28,
			texture = false,
			sdf_softness = 0,
		}
	end

	if not meta.is_last then
		render2d.DrawShape{
			x = center_x,
			y = center_y,
			w = T,
			h = size.y - center_y,
			color = accent,
			alpha = 0.28,
			texture = false,
			sdf_softness = 0,
		}
	end

	render2d.DrawShape{
		x = line_start_x,
		y = center_y,
		w = math.max(T, size.x - line_start_x),
		h = T,
		color = accent,
		alpha = 0.28,
		texture = false,
		sdf_softness = 0,
	}
	return center_x, center_y
end

function JRPGTheme:DrawTreeToggle(size, meta, opts)
	opts = opts or {}
	local box_size = opts.box_size or 0
	local toggle_size = opts.toggle_size or box_size
	local center_x, center_y = self:DrawTreeGuideLines(
		size,
		meta,
		{
			line_color = opts.line_color,
			alpha = opts.alpha,
			toggle_size = toggle_size,
			guide_step = opts.guide_step or 0,
			line_start_x = opts.line_start_x,
		}
	)
	local accent = self:GetColor("primary")
	local border = self:GetColor("border")
	local dx = center_x + 0.5
	local dy = center_y + 0.5
	local r = box_size * 0.85

	if opts.expanded then
		render2d.PushBlendPreset("additive")
		set_color(accent, 0.3)
		self:DrawDiamond(dx, dy, r + 3)
		render2d.PopBlendMode()
	end

	render2d.DrawShape{
		x = dx - r / 2,
		y = dy - r / 2,
		w = r,
		h = r,
		angle = math.rad(45),
		color = opts.expanded and accent or border,
		texture = false,
		layers = {
			{outline_width = -1},
		},
	}
end

function JRPGTheme:DrawHeader(size, emphasis)
	local lv = frame_level(emphasis or 3)
	local border = self:GetColor("border")
	local goldc = self:GetColor("gold")
	local gap = lv.corner and lv.off + lv.gem / 2 or 0
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		color = Color(1, 1, 1, 1),
		texture = self.ModernFrameGradient,
		int = true,
	}
	local layers = border_layers(size, border, gap, true, false, true, true)
	table.insert(layers, {color = goldc, alpha = 0.8, x = 0, y = size.y - 1, w = size.x, h = 1})
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		texture = false,
		int = true,
		layers = layers,
	}
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
			render2d.DrawShape{
				x = 0,
				y = 0,
				w = size.x,
				h = size.y,
				color = accent,
				alpha = fill_alpha,
				texture = false,
				border_radius = radius,
				int = true,
			}
		end

		return
	end

	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		color = self:GetColor("surface_variant"),
		alpha = alpha_scale,
		texture = false,
		border_radius = radius,
		int = true,
	}

	if state.mode ~= "outline" then
		render2d.DrawShape{
			x = 0,
			y = 0,
			w = size.x,
			h = size.y,
			color = accent,
			alpha = (state.disabled and 0.08) or (0.25 + anim.glow_alpha * 0.2),
			texture = self.Textures.Gradient,
			color_uv = {x = 0, y = 0, w = 0.5, h = 1},
			border_radius = radius,
			int = true,
		}
	end

	local bo = (state.disabled and 0.3) or (0.2 + anim.glow_alpha * 0.4)
	local r = 1
	render2d.DrawShape{
		x = r,
		y = r,
		w = math.ceil(size.x - r * 2),
		h = math.ceil(size.y - r * 2),
		color = accent,
		alpha = bo,
		texture = false,
		sdf_softness = 1,
		int = true,
		layers = {
			{outline_width = 0.4},
		},
	}

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
	if state.mode == "menu" then return end

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

	if mode == "horizontal" then
		local track_h = self:GetSize("XXS")
		local track_y = (size.y - track_h) / 2
		local min = state.min or 0
		local max = state.max or 1
		local normalized = (state.value or 0)

		if max > min then normalized = (normalized - min) / (max - min) end

		normalized = math.clamp(normalized, 0, 1)
		local fill_w = normalized * (size.x - knob)
		render2d.DrawShape{
			x = knob / 2,
			y = track_y,
			w = size.x - knob,
			h = track_h,
			color = track_bg,
			texture = false,
			int = true,
		}

		if fill_w > 0.5 then
			render2d.DrawShape{
				x = knob / 2,
				y = track_y,
				w = fill_w,
				h = track_h,
				color = accent,
				alpha = 0.85,
				int = true,
				texture = self.SliderFillFadeH,
			}
			render2d.DrawShape{
				x = knob / 2,
				y = track_y - 2,
				w = fill_w,
				h = track_h + 4,
				color = accent,
				int = true,
				alpha = 0.15 + anim.glow_alpha * 0.2,
				texture = self.SliderFillFadeH,
				blend = "additive",
			}
		end

		draw_knob(self, anim, accent, knob / 2 + fill_w, size.y / 2)
	elseif mode == "vertical" then
		local track_w = self:GetSize("XXS")
		local track_x = (size.x - track_w) / 2
		local min = state.min or 0
		local max = state.max or 1
		local normalized = (state.value or 0)

		if max > min then normalized = (normalized - min) / (max - min) end

		normalized = math.clamp(normalized, 0, 1)
		local fill_h = normalized * (size.y - knob)
		render2d.DrawShape{
			x = track_x,
			y = knob / 2,
			w = track_w,
			h = size.y - knob,
			color = track_bg,
			texture = false,
			int = true,
		}

		if fill_h > 0.5 then
			render2d.DrawShape{
				x = track_x,
				y = knob / 2,
				w = track_w,
				h = fill_h,
				color = accent,
				alpha = 0.85,
				int = true,
				texture = self.SliderFillFadeV,
			}
			render2d.DrawShape{
				x = track_x - 2,
				y = knob / 2,
				w = track_w + 4,
				h = fill_h,
				color = accent,
				int = true,
				alpha = 0.15 + anim.glow_alpha * 0.2,
				texture = self.SliderFillFadeV,
				blend = "additive",
			}
		end

		draw_knob(self, anim, accent, size.x / 2, knob / 2 + fill_h)
	elseif mode == "2d" then
		local px = (state.value.x or 0) * size.x
		local py = (state.value.y or 0) * size.y
		render2d.DrawShape{
			x = 0,
			y = 0,
			w = size.x,
			h = size.y,
			color = track_bg,
			texture = false,
			int = true,
		}
		render2d.PushBlendPreset("additive")
		set_color(accent, 0.4)
		self:DrawGlowLine(knob / 2, py, px, py, 1)
		self:DrawGlowLine(px, size.y - knob / 2, px, py, 1)
		render2d.PopBlendMode()
		draw_knob(self, anim, accent, px, py)
	end
end

function JRPGTheme:DrawCheckbox(size, state)
	local anim = state.anim or {glow_alpha = 0, check_anim = state.value and 1 or 0}
	local cs = math.max(6, math.min(size.x, size.y) - 2)
	local cx = size.x / 2
	local cy = size.y / 2
	local border = self:GetColor("border")
	render2d.SetTexture(nil)
	render2d.DrawShape{
		x = cx - cs / 2,
		y = cy - cs / 2,
		w = cs,
		h = cs,
		angle = math.rad(45),
		color = border,
		texture = false,
		layers = {
			{outline_width = -1.5},
		},
	}

	if anim.glow_alpha > 0.01 then
		local accent = self:GetColor("primary")
		render2d.PushBlendPreset("additive")
		render2d.DrawShape{
			x = cx - (cs + 3) / 2,
			y = cy - (cs + 3) / 2,
			w = cs + 3,
			h = cs + 3,
			angle = math.rad(45),
			color = accent,
			alpha = anim.glow_alpha * 0.8,
			texture = false,
			layers = {
				{outline_width = -1},
			},
		}
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
	render2d.DrawShape{
		x = cx - rs / 2,
		y = cy - rs / 2,
		w = rs,
		h = rs,
		angle = math.rad(45),
		color = border,
		texture = false,
		layers = {
			{outline_width = -1.5},
		},
	}

	if anim.glow_alpha > 0.01 then
		local accent = self:GetColor("primary")
		render2d.PushBlendPreset("additive")
		render2d.DrawShape{
			x = cx - (rs + 3) / 2,
			y = cy - (rs + 3) / 2,
			w = rs + 3,
			h = rs + 3,
			angle = math.rad(45),
			color = accent,
			alpha = anim.glow_alpha * 0.8,
			texture = false,
			layers = {
				{outline_width = -1},
			},
		}
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
	render2d.DrawShape{
		x = 0,
		y = 0,
		w = size.x,
		h = size.y,
		color = track,
		texture = false,
		int = true,
	}
	local segments = 10
	local seg_w = size.x / segments
	render2d.SetColor(1, 1, 1, 0.08)

	for i = 1, segments do
		render2d.DrawShape{
			x = i * seg_w - 0.5,
			y = 1,
			w = 1,
			h = size.y - 2,
			texture = false,
			int = true,
		}
	end

	local accent = self:GetColor("primary")
	render2d.PushBlendPreset("additive")
	set_color(accent, 0.35)
	self:DrawGlowLine(0, 0, size.x, 0, 1)
	self:DrawGlowLine(0, size.y, size.x, size.y, 1)
	render2d.PopBlendMode()
	local fill_w = size.x * value
	render2d.DrawShape{
		x = 0,
		y = 1,
		w = fill_w,
		h = size.y - 2,
		color = c,
		alpha = 0.95,
		texture = self.Textures.Gradient,
		color_uv = {x = 0, y = 0, w = 0.5, h = 1},
		int = true,
	}
	render2d.SetColor(1, 1, 1, 0.5)
	render2d.DrawShape{
		x = 0,
		y = 1,
		w = fill_w,
		h = 1,
		texture = false,
		int = true,
	}
	local cx = fill_w
	local cy = size.y / 2
	local s = math.min(size.y / 2, 6)
	render2d.PushBlendPreset("additive")
	render2d.DrawShape{
		x = cx - 4,
		y = cy - s * 2,
		w = 8,
		h = s * 4,
		color = c,
		alpha = 0.9,
		texture = self.GlowLineTexture,
	}
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
		render2d.DrawShape{
			x = 8,
			y = mid_y - 0.5,
			w = w - 16,
			h = 1,
			int = true,
		}
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
		render2d.DrawShape{
			x = mid_x - 0.5,
			y = 8,
			w = 1,
			h = h - 16,
			int = true,
		}
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
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawShape{
		x = 0,
		y = -thickness / 2,
		w = length,
		h = thickness,
		texture = false,
	}
	render2d.PopMatrix()
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
		render2d.DrawShape{
			x = tx - 20,
			y = ty - 14,
			w = 540,
			h = 28,
			color = cyan,
			alpha = 0.5,
			texture = self.Textures.GlowLinear,
			int = true,
		}
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
