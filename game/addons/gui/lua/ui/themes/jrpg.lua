local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local system = import("goluwa/system.lua")
local prototype = import("goluwa/prototype.lua")
local BaseTheme = import("./base.lua")
local JRPGTheme = prototype.CreateTemplate("ui_theme_jrpg")
JRPGTheme.Base = BaseTheme
JRPGTheme.Name = "jrpg"
local primary = Color.FromHex("#062a67"):SetAlpha(0.9)

function JRPGTheme:Initialize()
	self.BaseClass.Initialize(self)
	local palette = self:GetPalette():Copy()
	palette:SetShades{
		Color.FromHex("#cccccc"),
		primary,
		primary:Darken(2),
	}
	palette:SetColors{
		red = Color.FromHex("#dd4546"),
		yellow = Color.FromHex("#e0c33d"),
		blue = primary,
		green = Color.FromHex("#69ce4a"),
		purple = Color.FromHex("#a454d8"),
		brown = Color.FromHex("#a17247"),
	}
	palette.AdjustmentOptions = self:MergeTables(palette.AdjustmentOptions, {target_contrast = 4.5})
	local base_map = palette:GetBaseMap()
	palette:SetMap{
		dashed_underline = Color(0.37, 0.37, 0.37, 0.25),
		button_color = base_map.blue,
		underline = base_map.blue,
		url_color = base_map.blue,
		property_selection = Color.FromHex("#5d8cff"):SetAlpha(0.9),
		actual_black = Color(0, 0, 0, 1),
		primary = base_map.blue,
		secondary = base_map.green,
		positive = base_map.green_lighter,
		neutral = base_map.yellow_lighter,
		negative = base_map.red_darker,
		heading = base_map.white,
		default = base_map.white,
		text = base_map.white,
		text_foreground = base_map.white,
		text_button = base_map.white,
		text_disabled = base_map.white:Copy():SetAlpha(0.5),
		foreground = base_map.black,
		background = base_map.black,
		text_background = base_map.black,
		main_background = base_map.black,
		surface = base_map.darkest,
		surface_variant = base_map.dark,
		card = base_map.darkest,
		header_surface = base_map.dark,
		scrollbar_track = Color(1, 1, 1, 0.08),
		scrollbar = Color(1, 1, 1, 0.45),
		frame_border = Color(0.106, 0.463, 0.678),
		invisible = Color(0, 0, 0, 0),
		clickable_disabled = Color(0.3, 0.3, 0.3, 1),
		button_normal = Color(0.8, 0.8, 0.2, 1),
	}
	self:SetPalette(palette)
	self:SetSizes(
		self:MergeTables(
			self:GetSizes(),
			{
				XXS = 7,
				S = 14,
				M = 16,
				L = 20,
				XL = 30,
				XXL = 40,
				default = 16,
			}
		)
	)
	self:SetFontSizes(
		self:MergeTables(
			self:GetFontSizes(),
			{
				XS = 10,
				S = 12,
				M = 14,
				L = 20,
				XL = 27,
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
	local gradient_classic = Texture.New{
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
	local start = Color.FromHex("#060086")
	local stop = Color.FromHex("#04013e")
	gradient_classic:Shade(
		[[
		float dist = distance(uv, vec2(0.5));
			return vec4(mix(vec3(]] .. start.r .. ", " .. start.g .. ", " .. start.b .. "), vec3(" .. stop.r .. ", " .. stop.g .. ", " .. stop.b .. [[), -uv.y + 1.0), 1.0);
		]]
	)
	self.GradientClassicTexture = gradient_classic
	self.MetalFrameTexture = assets.GetTexture(
		"textures/render/metal_frame.lua",
		{
			config = {base_color = Color.FromHex("#8f8b92")},
		}
	)
	self.MetalFrameWhiteTexture = assets.GetTexture(
		"textures/render/metal_frame.lua",
		{
			config = {
				base_color = Color.FromHex("#8f8b92"),
				frame_inner = 0.02,
				frame_outer = 0.002,
				corner_radius = 0.02,
			},
		}
	)
	local glow_color = palette:Get("light") or palette:Get("white") or Color(1, 1, 1, 1)
	local gradient = Texture.New{
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
	local grad_start = palette:Get("primary")
	local grad_stop = palette:Get("darkest") or palette:Get("surface")
	gradient:Shade(
		[[
			float dist = distance(uv, vec2(0.5));
				return mix(vec4(]] .. grad_start.r .. ", " .. grad_start.g .. ", " .. grad_start.b .. ", " .. grad_start.a .. [[), vec4(]] .. grad_stop.r .. ", " .. grad_stop.g .. ", " .. grad_stop.b .. ", " .. grad_stop.a .. [[), -uv.y + 1.0 + uv.x*0.3);
		]]
	)
	self.ModernFrameGradient = gradient
	self.ModernGlowColor = glow_color
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
	render2d.PushOutlineWidth(1)
	self:DrawDiamond(x, y, size)
	render2d.PopOutlineWidth()
end

function JRPGTheme:DrawPill(x, y, w, h)
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
	self:DrawDiamond2(x, y + h / 2, 5)
	self:DrawDiamond2(x + w, y + h / 2, 5)
end

function JRPGTheme:DrawBadge(x, y, w, h)
	x = x - 15
	w = w + 30
	render2d.PushTexture(self.Textures.Gradient)
	render2d.PushUV()
	render2d.SetUV2(-0.1, 0, 0.75, 1)
	render2d.PushBorderRadius(h)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PopUV()
	render2d.PopTexture()
	render2d.PushColor(1, 1, 1, 1)
	self:DrawDiamond2(x + 8, y + h / 2, 8)
	render2d.PopColor()
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

function JRPGTheme:DrawDisclosureIcon(size, opts)
	opts = opts or {}
	local icon_size = opts.size or 10
	local color = opts.color or self:GetColor("text_foreground")
	local center = size / 2
	render2d.PushMatrix()
	render2d.Translatef(center.x, center.y)
	render2d.Rotate(math.rad((opts.open_fraction or 0) * 90))
	render2d.SetColor(color:Unpack())
	render2d.SetTexture(nil)
	self:DrawArrow(0, 0, icon_size)
	render2d.PopMatrix()
end

function JRPGTheme:DrawDropdownIndicatorIcon(size, opts)
	opts = opts or {}
	return self:DrawDisclosureIcon(size, {
		size = opts.size or 9,
		color = opts.color,
		open_fraction = 1,
	})
end

function JRPGTheme:DrawCloseIcon(size, opts)
	opts = opts or {}
	local icon_size = opts.size or 8
	local color = opts.color or self:GetColor("text_foreground")
	local center = size / 2
	local thickness = opts.thickness or 1.5
	local length = icon_size * math.sqrt(2)
	render2d.SetColor(color:Unpack())
	render2d.SetTexture(nil)
	render2d.DrawRect(center.x, center.y, thickness, length, -math.pi / 4, thickness / 2, length / 2)
	render2d.DrawRect(center.x, center.y, thickness, length, math.pi / 4, thickness / 2, length / 2)
end

function JRPGTheme:DrawLine(x1, y1, x2, y2, thickness)
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	local s = thickness * 2
	self:DrawDiamond(x1, y1, s)
	self:DrawDiamond(x2, y2, s)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

function JRPGTheme:DrawLine2(x1, y1, x2, y2, thickness)
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	local s = thickness * 4
	render2d.PushMatrix()
	render2d.Translatef(x1, y1 + 1)
	render2d.Rotate(math.pi)
	self:DrawArrow(0, 0, s)
	render2d.PopMatrix()
	self:DrawArrow(x2, y2, s)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRect(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

function JRPGTheme:DrawGlowLine(x1, y1, x2, y2, thickness)
	thickness = thickness or 1
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.Translatef(0, -self.GlowLineTexture:GetHeight() / 2)
	render2d.SetTexture(self.GlowLineTexture)
	render2d.PushBlendMode("additive")
	render2d.DrawRectf(0, -thickness / 10, length, self.GlowLineTexture:GetHeight())
	render2d.PopBlendMode()
	render2d.PopMatrix()
end

function JRPGTheme:DrawClassicFrame(x, y, w, h)
	render2d.PushBorderRadius(h * 0.2)
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(self.GradientClassicTexture)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBorderRadius()
	render2d.PushOutlineWidth(5)
	render2d.PushBlur(10)
	render2d.SetColor(0, 0, 0, 0.5)
	render2d.SetTexture(nil)
	render2d.DrawRect(x, y, w, h)
	render2d.PopBlur()
	render2d.PopOutlineWidth()
	x = x - 3
	y = y - 3
	w = w + 6
	h = h + 6
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetNinePatchTable(self.MetalFrameTexture.nine_patch)
	render2d.SetTexture(self.MetalFrameTexture)
	render2d.DrawRect(x, y, w, h)
	render2d.ClearNinePatch()
	render2d.SetTexture(nil)
end

function JRPGTheme:DrawWhiteFrame(x, y, w, h)
	render2d.PushBorderRadius(h * 0.2)
	render2d.SetColor(1, 1, 1, 0.5)
	render2d.SetTexture(nil)
	render2d.DrawRect(x, y, w, h)
	x = x + 1
	y = y + 1
	w = w - 2
	h = h - 2
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetNinePatchTable(self.MetalFrameWhiteTexture.nine_patch)
	render2d.SetTexture(self.MetalFrameWhiteTexture)
	render2d.DrawRect(x, y, w, h)
	render2d.ClearNinePatch()
	render2d.SetTexture(nil)
	render2d.PushOutlineWidth(1)
	render2d.DrawRect(x + 1, y + 1, w - 2, h - 2)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
end

function JRPGTheme:DrawCircle(x, y, size, width)
	render2d.PushBorderRadius(size)
	render2d.PushOutlineWidth(width or 1)
	render2d.DrawRect(x - size, y - size, size * 2, size * 2)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
end

function JRPGTheme:DrawSimpleLine(x1, y1, x2, y2, thickness)
	local angle = math.atan2(y2 - y1, x2 - x1)
	local length = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
	render2d.PushMatrix()
	render2d.Translatef(x1, y1)
	render2d.Rotate(angle)
	render2d.DrawRectf(0, -thickness / 2, length, thickness)
	render2d.PopMatrix()
end

function JRPGTheme:DrawMagicCircle(x, y, size)
	render2d.PushBlur(size * 0.05)
	self:DrawCircle(x, y, size, 4)
	self:DrawCircle(x, y, size * 1.5)
	self:DrawCircle(x, y, size * 1.7)
	self:DrawCircle(x, y, size * 3)
	render2d.PopBlur()

	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2
		local length = size * 1.35
		local dx = x + math.cos(angle) * length
		local dy = y + math.sin(angle) * length
		self:DrawDiamond(dx, dy, 3)
	end

	for i = 1, 16 do
		local angle = (i / 16) * math.pi * 2
		local length = size * 1.35
		local x1 = x + math.cos(angle) * length
		local y1 = y + math.sin(angle) * length
		local x2 = x + math.cos(angle) * length * 1.5
		local y2 = y + math.sin(angle) * length * 1.5
		render2d.SetTexture(self.Textures.GlowLinear)
		self:DrawGlowLine(x1, y1, x2, y2, 1)
	end
end

function JRPGTheme:DrawGlow(x, y, size)
	render2d.PushTexture(self.Textures.GlowPoint)
	render2d.PushAlphaMultiplier(0.5)
	render2d.DrawRectf(x - size, y - size, size * 2, size * 2)
	render2d.PopAlphaMultiplier()
	render2d.PopTexture()
end

function JRPGTheme:DrawProgressBarPrimitive(x, y, w, h, progress, color)
	render2d.SetColor(0.2, 0.2, 0.3, 0.4)
	render2d.DrawRect(x, y, w, h)
	render2d.PushBlendMode("additive")
	render2d.SetColor(0.3, 0.4, 0.6, 0.5)
	self:DrawGlowLine(x, y, x + w, y, 2)
	self:DrawGlowLine(x, y + h, x + w, y + h, 2)
	render2d.SetColor(1, 1, 1, 0.1)

	for i = 1, 9 do
		render2d.DrawRect(x + (w / 10) * i, y, 1, h)
	end

	render2d.PopBlendMode()

	if progress > 0 then
		local fill_w = w * progress
		local center_y = y + h / 2
		local tip_x = x + fill_w
		render2d.PushTexture(self.Textures.Gradient)

		if color then
			render2d.SetColor(color.r, color.g, color.b, (color.a or 1) * 0.8)
		else
			render2d.SetColor(0.4, 0.7, 1, 0.8)
		end

		render2d.DrawRect(x, y, fill_w, h)
		render2d.PopTexture()
		render2d.PushBlendMode("additive")
		render2d.SetColor(1, 1, 1, 0.6)
		render2d.DrawRect(x, y, fill_w, 2)

		if color then
			render2d.SetColor(color.r, color.g, color.b, 1)
		else
			render2d.SetColor(0.6, 0.9, 1, 1)
		end

		self:DrawDiamond(tip_x, center_y, h * 0.8)

		if color then
			render2d.SetColor(color.r, color.g, color.b, 0.3)
		else
			render2d.SetColor(0.6, 0.9, 1, 0.3)
		end

		self:DrawDiamond(tip_x, center_y, h * 1.8)
		render2d.SetTexture(self.Textures.GlowLinear)
		render2d.SetColor(1, 1, 1, 1)
		render2d.PushMatrix()
		render2d.Translate(tip_x, center_y)
		render2d.Rotate(math.rad(90))
		render2d.DrawRect(-h, -1.5, h * 2, 3)
		render2d.PopMatrix()
		render2d.PopBlendMode()
		render2d.SetTexture(nil)
	end
end

function JRPGTheme:DrawModernFrame(x, y, w, h)
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(self.ModernFrameGradient)
	render2d.DrawRect(x, y, w, h)
end

function JRPGTheme:DrawModernFramePost(x, y, w, h, intensity)
	render2d.SetTexture(nil)
	x = x - 1
	y = y - 1
	w = w + 2
	h = h + 2
	local glow_color = self.ModernGlowColor
	render2d.SetColor(glow_color.r, glow_color.g, glow_color.b, 0.75 + intensity * 0.4)
	render2d.SetBlendMode("additive")
	local glow_size = 40 * intensity
	local diamond_size = 6 + 2 * intensity
	self:DrawDiamond2(x, y, diamond_size)
	self:DrawGlow(x, y, glow_size)
	self:DrawDiamond2(x + w, y, diamond_size)
	self:DrawGlow(x + w, y, glow_size)
	self:DrawDiamond2(x, y + h, diamond_size)
	self:DrawGlow(x, y + h, glow_size)
	self:DrawDiamond2(x + w, y + h, diamond_size)
	self:DrawGlow(x + w, y + h, glow_size)
	render2d.SetTexture(self.Textures.GlowLinear)
	local extent_h = -50 * intensity
	local extent_w = -50 * intensity
	render2d.SetBlendMode("alpha")
	self:DrawGlowLine(x + extent_w, y, x + w - extent_w, y, 1)
	self:DrawGlowLine(x + extent_w, y + h, x + w - extent_w, y + h, 1)
	self:DrawGlowLine(x, y + extent_h, x, y + h - extent_h, 1)
	self:DrawGlowLine(x + w, y + extent_h, x + w, y + h - extent_h, 1)
	render2d.SetTexture(nil)
end

function JRPGTheme:DrawRect(x, y, w, h, thickness, extent)
	extent = extent or 0
	self:DrawLine(x - extent, y, x + w + extent, y, thickness)
	self:DrawLine(x + w, y - extent, x + w, y + h + extent, thickness)
	self:DrawLine(x + w + extent, y + h, x - extent, y + h, thickness)
	self:DrawLine(x, y + h + extent, x, y - extent, thickness)
end

function JRPGTheme:UpdateButtonAnimations(state)
	local anim = state.anim
	local is_active = not state.disabled and
		(
			((
				state.hovered and
				state.pressed
			))
			or
			(
				state.active or
				false
			)
		)
	local is_tilting = is_active

	if is_active ~= anim.last_active then
		state.pnl.animation:Animate{
			id = "press_scale",
			get = function()
				return anim.press_scale
			end,
			set = function(value)
				anim.press_scale = value
			end,
			to = is_active and 1 or 0,
			interpolation = (state.pressed and not state.hovered) and "linear" or "inOutSine",
			time = (state.pressed and not state.hovered) and 0.2 or 0.1,
		}
		state.pnl.animation:Animate{
			id = "DrawScaleOffset",
			get = function()
				return state.pnl.transform:GetDrawScaleOffset()
			end,
			set = function(value)
				state.pnl.transform:SetDrawScaleOffset(value)
			end,
			to = is_active and (Vec2() + 0.97) or (Vec2(1, 1)),
			interpolation = (
					state.pressed and
					not state.hovered
				)
				and
				"linear" or
				{type = "spring", bounce = 0.6, duration = 100},
			time = (state.pressed and not state.hovered) and 0.2 or nil,
		}
		anim.last_active = is_active
	end

	if state.hovered ~= anim.last_hovered then
		state.pnl.animation:Animate{
			id = "glow_alpha",
			get = function()
				return anim.glow_alpha
			end,
			set = function(value)
				anim.glow_alpha = value
			end,
			to = (state.hovered and not state.disabled) and 1 or 0,
			interpolation = "inOutSine",
			time = 0.1,
		}
		anim.last_hovered = state.hovered
	end

	if is_tilting ~= anim.last_tilting or is_tilting then
		state.pnl.animation:Animate{
			id = "Pivot",
			get = function()
				return state.pnl.transform:GetPivot()
			end,
			set = function(value)
				state.pnl.transform:SetPivot(value)
			end,
			to = not is_tilting and
				Vec2(0.5, 0.5) or
				{
					__lsx_value = function(panel)
						local mpos = system.GetWindow():GetMousePosition()
						local local_pos = panel.transform:GlobalToLocal(mpos)
						local size = panel.transform:GetSize()
						local pivot = local_pos / size
						return -pivot + Vec2(1, 1)
					end,
				},
			interpolation = (
					state.pressed and
					not state.hovered
				)
				and
				"linear" or
				{type = "spring", bounce = 0.6, duration = 10},
			time = is_tilting and 0.3 or 10,
		}
		state.pnl.animation:Animate{
			id = "DrawAngleOffset",
			get = function()
				return state.pnl.transform:GetDrawAngleOffset()
			end,
			set = function(value)
				state.pnl.transform:SetDrawAngleOffset(value)
			end,
			to = not is_tilting and
				Ang3(0, 0, 0) or
				{
					__lsx_value = function(panel)
						local mpos = system.GetWindow():GetMousePosition()
						local local_pos = panel.transform:GlobalToLocal(mpos)
						local size = panel.transform:GetSize()
						local nx = (local_pos.x / size.x) * 2 - 1
						local ny = (local_pos.y / size.y) * 2 - 1
						return Ang3(-ny, nx, 0) * 0.01
					end,
				},
			interpolation = (
					state.pressed and
					not state.hovered
				)
				and
				"linear" or
				{type = "spring", bounce = 0.6, duration = 10},
			time = is_tilting and 0.3 or 10,
		}
		anim.last_tilting = is_tilting
	end
end

function JRPGTheme:DrawButton(size, state)
	local anim = state.anim
	local pnl = state.pnl

	if state.hovered then self:UpdateButtonAnimations(state) end

	if state.mode == "filled" then
		render2d.PushUV()
		render2d.SetUV2(0, 0, 0.4, 1)
		render2d.PushBorderRadius(size.y / 6)
		render2d.SetTexture(self.Textures.Gradient)
		local col = pnl.gui_element.Color or self:GetColor("primary")
		render2d.SetColor(col.r * anim.glow_alpha, col.g * anim.glow_alpha, col.b * anim.glow_alpha, 1)
		render2d.DrawRect(0, 0, size.x, size.y)
		render2d.PopBorderRadius()
		render2d.PopUV()
	end

	local mpos = system.GetWindow():GetMousePosition()

	if not state.disabled and pnl.mouse_input:IsHoveredExclusively(mpos) then
		local lpos = pnl.transform:GlobalToLocal(mpos)
		render2d.SetBlendMode("additive")
		render2d.SetTexture(self.Textures.GlowLinear)

		if anim.glow_alpha > 0 then
			local c = pnl.gui_element.Color or self:GetColor("lightest")
			render2d.SetColor(c.r, c.g, c.b, c.a * anim.glow_alpha)
			render2d.DrawRect(lpos.x - 192, lpos.y - 192, 384, 384)
		end

		render2d.SetTexture(self.Textures.GlowPoint)
		local c = pnl.gui_element.Color or self:GetColor("lighter")
		render2d.SetColor(c.r, c.g, c.b, c.a * anim.press_scale)
		local ps = anim.press_scale * 150
		render2d.DrawRect(lpos.x - ps / 2, lpos.y - ps / 2, ps, ps)
		render2d.SetBlendMode("alpha")
	end
end

function JRPGTheme:DrawSurface(draw, color)
	local size = draw.size
	local c

	if color == nil then
		c = self:GetColor("surface")
	else
		c = self:ResolveSurfaceColor(color)
	end

	local radius = draw.radius
	render2d.SetTexture(nil)
	render2d.SetColor(c.r, c.g, c.b, c.a * draw.alpha)

	if radius > 0 then
		gfx.DrawRoundedRect(0, 0, size.x, size.y, radius)
	else
		render2d.DrawRect(0, 0, size.x, size.y)
	end
end

function JRPGTheme:DrawButtonPost(size, state)
	local anim = state.anim
	render2d.SetBlendMode("additive")
	render2d.SetColor(anim.glow_alpha, anim.glow_alpha, anim.glow_alpha, 1)
	render2d.SetTexture(self.Textures.GlowLinear)

	if state.mode == "filled" then
		self:DrawGlowLine(-3, -3, -3, size.y + 6, 40)
	elseif state.mode == "outline" then
		local c = self:GetColor("frame_border")
		render2d.SetColor(c.r, c.g, c.b, anim.glow_alpha)
		self:DrawGlowLine(0, 0, 0, size.y, 1)
		self:DrawGlowLine(size.x, 0, size.x, size.y, 1)
	end

	local c = self:GetColor("frame_border")
	render2d.SetColor(c.r, c.g, c.b, anim.glow_alpha)
	self:DrawGlowLine(0, 0, size.x, 0, 1)
	self:DrawGlowLine(0, size.y, size.x, size.y, 1)
	render2d.SetBlendMode("alpha")
end

function JRPGTheme:DrawSlider(size, state)
	local anim = state.anim

	if state.hovered then self:UpdateSliderAnimations(state) end

	local knob_width = self:GetSize("S")
	local knob_height = self:GetSize("S")
	local value = state.value
	local min_value = state.min
	local max_value = state.max
	local knob_x, knob_y

	if state.mode == "2d" then
		local normalized_x = (value.x - min_value.x) / (max_value.x - min_value.x)
		local normalized_y = (value.y - min_value.y) / (max_value.y - min_value.y)
		render2d.SetTexture(nil)
		local c = self:GetColor("darker")
		render2d.SetColor(c.r, c.g, c.b, c.a)
		render2d.DrawRect(0, 0, size.x, size.y)
		knob_x = normalized_x * (size.x - knob_width)
		knob_y = normalized_y * (size.y - knob_height)
	elseif state.mode == "vertical" then
		local normalized = (value - min_value) / (max_value - min_value)
		local track_width = self:GetSize("XXS")
		local track_x = (size.x - track_width) / 2
		render2d.SetTexture(nil)
		local c = self:GetColor("darker")
		render2d.SetColor(c.r, c.g, c.b, c.a)
		render2d.DrawRect(track_x, knob_height / 2, track_width, size.y - knob_height)
		local fill_height = normalized * (size.y - knob_height)
		render2d.PushUV()
		render2d.SetUV2(0, 0, 0.5, 1)
		render2d.SetTexture(self.Textures.Gradient)
		c = self:GetColor("primary")
		render2d.SetColor(c.r, c.g, c.b, 0.9)
		render2d.DrawRect(track_x, knob_height / 2, track_width, fill_height)
		render2d.PopUV()

		if anim.glow_alpha > 0 then
			render2d.SetBlendMode("additive")
			render2d.SetTexture(self.Textures.GlowLinear)
			c = self:GetColor("light")
			render2d.SetColor(c.r, c.g * anim.glow_alpha, c.b * anim.glow_alpha, c.a)
			render2d.DrawRect(track_x - 2, knob_height / 2, track_width + 4, fill_height)
			render2d.SetBlendMode("alpha")
		end

		knob_x = (size.x - knob_width) / 2
		knob_y = normalized * (size.y - knob_height)
	else
		local normalized = (value - min_value) / (max_value - min_value)
		local track_height = self:GetSize("XXS")
		local track_y = (size.y - track_height) / 2
		render2d.SetTexture(nil)
		local c = self:GetColor("darker")
		render2d.SetColor(c.r, c.g, c.b, c.a)
		render2d.DrawRect(knob_width / 2, track_y, size.x - knob_width, track_height)
		local fill_width = normalized * (size.x - knob_width)
		render2d.PushUV()
		render2d.SetUV2(0, 0, 0.5, 1)
		render2d.SetTexture(self.Textures.Gradient)
		c = self:GetColor("primary")
		render2d.SetColor(c.r, c.g, c.b, 0.9)
		render2d.DrawRect(knob_width / 2, track_y, fill_width, track_height)
		render2d.PopUV()

		if anim.glow_alpha > 0 then
			render2d.SetBlendMode("additive")
			render2d.SetTexture(self.Textures.GlowLinear)
			c = self:GetColor("light")
			render2d.SetColor(c.r, c.g * anim.glow_alpha, c.b * anim.glow_alpha, c.a)
			render2d.DrawRect(knob_width / 2, track_y - 2, fill_width, track_height + 4)
			render2d.SetBlendMode("alpha")
		end

		knob_x = normalized * (size.x - knob_width)
		knob_y = (size.y - knob_height) / 2
	end

	render2d.SetTexture(self.Textures.GlowPoint)
	render2d.SetBlendMode("additive")
	local c = self:GetColor("lighter")
	render2d.SetColor(c.r, c.g, c.b, c.a + anim.glow_alpha * 0.3)
	local glow_size = 20 * anim.knob_scale
	render2d.DrawRect(
		knob_x + knob_width / 2 - glow_size / 2,
		knob_y + knob_height / 2 - glow_size / 2,
		glow_size,
		glow_size
	)
	render2d.SetBlendMode("alpha")
	render2d.SetTexture(nil)
	c = self:GetColor("button_normal")
	render2d.SetColor(c.r, c.g, c.b, c.a)
	local scaled_width = knob_width * anim.knob_scale
	local scaled_height = knob_height * anim.knob_scale
	local scale_offset_x = (scaled_width - knob_width) / 2
	local scale_offset_y = (scaled_height - knob_height) / 2
	render2d.DrawRect(knob_x - scale_offset_x, knob_y - scale_offset_y, scaled_width, scaled_height)
	render2d.PushUV()
	render2d.SetUV2(0, 0, 1, 0.5)
	render2d.SetTexture(self.Textures.Gradient)
	c = self:GetColor("lighter")
	render2d.SetColor(c.r, c.g, c.b, c.a)
	render2d.DrawRect(
		knob_x - scale_offset_x,
		knob_y - scale_offset_y,
		scaled_width,
		scaled_height * 0.5
	)
	render2d.PopUV()

	if anim.glow_alpha > 0 then
		render2d.SetBlendMode("additive")
		render2d.SetTexture(self.Textures.GlowLinear)
		c = self:GetColor("frame_border")
		render2d.SetColor(c.r * anim.glow_alpha, c.g * anim.glow_alpha, c.b * anim.glow_alpha, 1)
		self:DrawLine(
			knob_x - scale_offset_x,
			knob_y - scale_offset_y,
			knob_x + scaled_width - scale_offset_x,
			knob_y - scale_offset_y,
			1
		)
		self:DrawLine(
			knob_x - scale_offset_x,
			knob_y + scaled_height - scale_offset_y,
			knob_x + scaled_width - scale_offset_x,
			knob_y + scaled_height - scale_offset_y,
			1
		)
		render2d.SetBlendMode("alpha")
	end
end

function JRPGTheme:DrawCheckbox(size, state)
	local anim = state.anim

	if state.hovered then self:UpdateCheckboxAnimations(state) end

	local check_size = self:GetSize("M")
	local box_x = 0
	local box_y = (size.y - check_size) / 2
	render2d.SetTexture(nil)
	local c = self:GetColor("darker")
	render2d.SetColor(c.r, c.g, c.b, c.a)
	render2d.DrawRect(box_x, box_y, check_size, check_size)

	if anim.glow_alpha > 0 then
		render2d.SetBlendMode("additive")
		render2d.SetTexture(self.Textures.GlowLinear)
		c = self:GetColor("frame_border")
		render2d.SetColor(c.r * anim.glow_alpha, c.g * anim.glow_alpha, c.b * anim.glow_alpha, 0.5)
		self:DrawRect(box_x - 1, box_y - 1, check_size + 2, check_size + 2, 1)
		render2d.SetBlendMode("alpha")
	end

	if anim.check_anim > 0.01 then
		local s = anim.check_anim
		render2d.PushUV()
		render2d.SetUV2(0, 0, 0.5, 1)
		render2d.SetTexture()
		c = self:GetColor("primary")
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

function JRPGTheme:DrawButtonRadio(size, state)
	local anim = state.anim

	if state.hovered then self:UpdateCheckboxAnimations(state) end

	local rb_size = self:GetSize("M")
	local rb_x = 0
	local rb_y = (size.y - rb_size) / 2
	render2d.SetTexture(nil)
	local c = self:GetColor("darker")
	render2d.SetColor(c.r, c.g, c.b, c.a)
	self:DrawDiamond(rb_x + rb_size / 2, rb_y + rb_size / 2, rb_size * 0.8)

	if anim.glow_alpha > 0 then
		render2d.SetBlendMode("additive")
		render2d.PushOutlineWidth(1)
		render2d.SetTexture()
		c = self:GetColor("frame_border")
		render2d.SetColor(c.r * anim.glow_alpha, c.g * anim.glow_alpha, c.b * anim.glow_alpha, 2)
		self:DrawDiamond(rb_x + rb_size / 2, rb_y + rb_size / 2, rb_size * 0.8)
		render2d.SetBlendMode("alpha")
		render2d.PopOutlineWidth()
	end

	if anim.check_anim > 0.01 then
		local s = anim.check_anim
		render2d.SetTexture(self:GetColor("primary"))
		render2d.SetBlendMode("additive")
		c = self:GetColor("primary")
		render2d.SetColor(c.r, c.g, c.b, s)
		local dot_size = rb_size * s
		self:DrawDiamond(rb_x + dot_size / 2, rb_y + dot_size / 2, dot_size * 0.25)
		render2d.SetBlendMode("alpha")
	end
end

function JRPGTheme:DrawFrame(draw, emphasis)
	local s = draw.size
	local c

	if color == nil then
		c = self:GetColor("surface")
	else
		c = self:ResolveSurfaceColor(color)
	end

	render2d.SetColor(c.r, c.g, c.b, c.a * draw.alpha)
	render2d.PushAlphaMultiplier(draw.alpha)
	self:DrawModernFrame(0, 0, s.x, s.y, (emphasis or 1) * draw.alpha)
	render2d.PopAlphaMultiplier()
end

function JRPGTheme:DrawFramePost(draw, emphasis, color)
	local s = draw.size
	local c

	if color == nil then
		c = self:GetColor("surface")
	else
		c = self:ResolveSurfaceColor(color)
	end

	render2d.SetColor(c.r, c.g, c.b, c.a)
	render2d.PushAlphaMultiplier(draw.alpha)
	self:DrawModernFramePost(0, 0, s.x, s.y, (emphasis or 1) * draw.alpha)
	render2d.PopAlphaMultiplier()
end

function JRPGTheme:DrawMenuSpacer(size, vertical)
	local r, g, b, a = self:GetColor("lightest"):Unpack()
	render2d.PushColor(r, g, b, a)

	if vertical then
		self:DrawLine(size.x / 2, 0, size.x / 2, size.y, 2)
	else
		self:DrawLine(0, size.y / 2, size.x, size.y / 2, 2)
	end

	render2d.PopColor()
end

function JRPGTheme:DrawHeader(draw, color)
	local size = draw.size
	local c

	if color == nil then
		c = self:GetColor("header_surface")
	else
		c = self:ResolveSurfaceColor(color)
	end

	render2d.SetColor(c.r, c.g, c.b, c.a * draw.alpha)
	self:DrawPill(0, 0, size.x, size.y)
end

function JRPGTheme:DrawProgressBar(size, state, color)
	local value = state.value or 0
	local c

	if color == nil then
		c = self:GetColor("primary")
	else
		c = self:ResolveSurfaceColor(color)
	end

	self:DrawProgressBarPrimitive(0, 0, size.x, size.y, value, c)
end

function JRPGTheme:DrawDivider(draw)
	local size = draw.size
	render2d.SetColor(primary.r, primary.g, primary.b, primary.a * draw.alpha * 10)
	render2d.PushBlendMode("additive")

	if size.x > size.y then
		self:DrawGlowLine(0, size.y / 2, size.x, size.y / 2, 0)
	else
		self:DrawGlowLine(size.x / 2, 0, size.x / 2, size.y, 0)
	end

	render2d.PopBlendMode()
end

function JRPGTheme:DrawMuseum()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(nil)
	local x, y = 500, 200
	local w, h = 600, 30
	local font = self:GetFont("heading", "XXL")
	font:DrawText("Custom Font Rendering", x, y - 40)
	self:DrawClassicFrame(x, y, 60, 40)
	x = x + 80
	self:DrawModernFrame(x, y, 100, 60, 1)
	x = x + 120
	self:DrawModernFrame(x, y, 100, 60, 0)
	x = x + 120
	self:DrawWhiteFrame(x, y, 60, 40)
	x = x - 320
	y = y + 80
	render2d.SetColor(0, 0, 0, 1)
	self:DrawPill(x, y, w, h)
	y = y + 50
	self:DrawBadge(x, y, w, h)
	y = y + 50
	self:DrawDiamond(x, y, 20)
	x = x + 50
	render2d.PushOutlineWidth(1)
	self:DrawDiamond(x, y, 20)
	render2d.PopOutlineWidth()
	render2d.SetColor(1, 1, 1, 1)
	x = x + 50
	self:DrawArrow(x, y, 40)
	x = x - 100
	y = y + 50
	render2d.SetTexture(nil)
	self:DrawLine(x + 20, y, x + w - 40, y, 3)
	y = y + 20
	self:DrawLine2(x + 20, y, x + w - 40, y, 3)
	y = y + 20
	self:DrawDiamond2(x, y, 10)
	y = y + 40
	self:DrawMagicCircle(x - 100, y, 30)
	y = y + 20
	self:DrawGlowLine(x, y, x + w - 40, y, 1)
end

JRPGTheme:Register()
return JRPGTheme
