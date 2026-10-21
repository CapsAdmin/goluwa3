local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local objects = import("goluwa/objects/objects.lua")
local codec = import("goluwa/codec.lua")
local resource = import("goluwa/resource.lua")
local vfs = import("goluwa/vfs.lua")
local event = import("goluwa/event.lua")
local Texture = import("goluwa/render/texture.lua")
local BaseTheme = import("./base.lua")
local DermaTheme = objects.CreateTemplate("ui_theme_derma")
DermaTheme.Base = BaseTheme
DermaTheme.Name = "derma"
DermaTheme.SkinPath = "textures/gui/skins/gmod.png"
local WHITE = Color(1, 1, 1, 1)
local BLACK = Color(0, 0, 0, 1)

local function border(x, y, w, h, l, t, r, b)
	return {x, y, w, h, l, t or l, r or l, b or l}
end

local function plain(x, y, w, h)
	return {x, y, w, h, 0, 0, 0, 0}
end

local REGIONS = {
	selection = border(384, 32, 31, 31, 4),
	panel = border(256, 0, 63, 63, 16),
	button = border(480, 0, 31, 31, 8),
	button_hovered = border(480, 32, 31, 31, 8),
	button_dead = border(480, 64, 31, 31, 8),
	button_down = border(480, 96, 31, 31, 8),
	checkbox_checked = plain(448, 32, 15, 15),
	checkbox = plain(464, 32, 15, 15),
	checkbox_dead_checked = plain(448, 48, 15, 15),
	checkbox_dead = plain(464, 48, 15, 15),
	radio_checked = plain(448, 64, 15, 15),
	radio = plain(464, 64, 15, 15),
	radio_dead_checked = plain(448, 80, 15, 15),
	radio_dead = plain(464, 80, 15, 15),
	tree_plus = plain(448, 96, 15, 15),
	tree_minus = plain(464, 96, 15, 15),
	text_box = border(0, 150, 127, 21, 4),
	text_box_focus = border(0, 172, 127, 21, 4),
	text_box_dead = border(0, 194, 127, 21, 4),
	combo_box = border(384, 336, 127, 31, 8, 8, 32, 8),
	combo_box_hovered = border(384, 368, 127, 31, 8, 8, 32, 8),
	combo_box_down = border(384, 400, 127, 31, 8, 8, 32, 8),
	combo_box_dead = border(384, 432, 127, 31, 8, 8, 32, 8),
	menu = border(128, 192, 127, 63, 8),
	menu_hover = border(128, 256, 127, 31, 8),
	menu_strip = border(0, 128, 127, 21, 8),
	tab_control = border(0, 256, 127, 127, 8),
	tab_active = border(0, 384, 63, 31, 8),
	tab_inactive = border(128, 384, 63, 31, 8),
	tab_bar = border(128, 352, 127, 31, 4),
	window_header = border(0, 0, 127, 24, 8, 8, 8, 0),
	window_content = border(0, 24, 127, 103, 8, 0, 8, 8),
	scroll_track_v = border(384, 208, 15, 127, 4),
	scroll_track_h = border(384, 128, 127, 15, 4),
	scroll_handle_v = border(400, 208, 15, 127, 4),
	scroll_handle_v_hover = border(416, 208, 15, 127, 4),
	scroll_handle_v_down = border(432, 208, 15, 127, 4),
	scroll_handle_h = border(384, 144, 127, 15, 4),
	scroll_handle_h_hover = border(384, 160, 127, 15, 4),
	scroll_handle_h_down = border(384, 176, 127, 15, 4),
	slider_h = plain(416, 32, 15, 15),
	slider_h_hover = plain(416, 48, 15, 15),
	slider_h_down = plain(416, 64, 15, 15),
	slider_v = plain(432, 32, 15, 15),
	slider_v_hover = plain(432, 48, 15, 15),
	slider_v_down = plain(432, 64, 15, 15),
	progress_back = border(384, 0, 31, 31, 8),
	progress_front = border(416, 0, 31, 31, 8),
	tooltip = border(384, 64, 31, 31, 8),
	category_header = border(320, 352, 63, 31, 8),
	category_header_open = border(320, 384, 63, 20, 8),
	white_panel = border(256, 256, 63, 127, 8),
}

-- the skin image is stored bottom-up in memory, so image row y is stored at height - 1 - y
local function sample(image, x, y)
	local i = ((image.height - 1 - y) * image.width + x) * 4
	local data = image.data
	return Color(data[i] / 255, data[i + 1] / 255, data[i + 2] / 255, data[i + 3] / 255)
end

function DermaTheme:CreatePalette()
	return self:ConfigurePalette(DermaTheme.BaseClass.CreatePalette(self))
end

function DermaTheme:ConfigurePalette(palette)
	local image = self.SkinImage

	local function pick(x, y, fallback)
		if image then return sample(image, x, y) end

		return fallback
	end

	local body = pick(64, 80, Color(0.396, 0.392, 0.412, 1))
	local header = pick(64, 12, Color(0.28, 0.29, 0.31, 1))
	local text = pick(4 + 8 * 8, 508, Color(0.9, 0.9, 0.9, 1))
	local bright = pick(4 + 8 * 9, 508, WHITE)
	local button_text = pick(4 + 8 * 2, 508, Color(0.32, 0.32, 0.32, 1))
	local title_text = pick(4, 508, Color(1, 1, 1, 0.8))
	local selection = pick(399, 47, Color(0.39, 0.67, 0.86, 1))
	local ink = Color(0.12, 0.12, 0.12, 1)

	local function flat_color_of(region)
		if not image then return WHITE end

		local c = sample(image, math.floor(region[1] + region[3] / 2), math.floor(region[2] + region[4] / 2))
		return c:Copy():GetLerped(1 - c.a, body)
	end

	local function readable_on(region)
		local flat = flat_color_of(region)
		return flat.r * 0.299 + flat.g * 0.587 + flat.b * 0.114 > 0.5 and Color(0.08, 0.08, 0.08, 1) or text
	end

	self.SkinPanelColor = flat_color_of(REGIONS.white_panel)

	local red = Color(0.82, 0.27, 0.27, 1)
	local yellow = Color(0.95, 0.76, 0.25, 1)
	local green = Color(0.31, 0.68, 0.31, 1)
	local lighter = body:Copy():GetLerped(0.12, WHITE)
	local darker = body:Copy():GetLerped(0.2, BLACK)
	self.PanelTint = Color(
		math.min(body.r / 0.9, 1),
		math.min(body.g / 0.9, 1),
		math.min(body.b / 0.9, 1),
		1
	)
	palette:SetShades{ink, body, bright}
	palette:SetColors{
		red = red,
		yellow = yellow,
		blue = selection,
		green = green,
		purple = Color(0.6, 0.4, 0.8, 1),
		brown = Color(0.55, 0.38, 0.22, 1),
	}
	palette.AdjustmentOptions = self:MergeTables(palette.AdjustmentOptions, {target_contrast = 3})
	palette:SetMap{
		ink = ink,
		actual_black = BLACK,
		primary = selection,
		primary_focus = selection:Copy():GetLerped(0.25, WHITE),
		secondary = yellow,
		button_color = WHITE,
		button_normal = WHITE,
		underline = selection,
		url_color = selection:Copy():GetLerped(0.3, WHITE),
		dashed_underline = text:Copy():SetAlpha(0.3),
		property_selection = selection,
		text_selection = selection:Copy():SetAlpha(0.6),
		text_highlight = Color.FromHex("#facc15"):SetAlpha(0.5),
		positive = green,
		neutral = yellow,
		negative = red,
		prefab = "purple",
		heading = bright,
		heading_on_surface = bright,
		heading_on_header_surface = title_text,
		default = text,
		text = text,
		text_input = readable_on(REGIONS.text_box),
		text_content = readable_on(REGIONS.white_panel),
		text_combo = readable_on(REGIONS.combo_box),
		text_tab_active = readable_on(REGIONS.tab_active),
		foreground = text,
		text_foreground = text,
		text_button = button_text,
		text_on_accent = button_text,
		text_on_dark = text,
		text_on_dark_muted = text:Copy():SetAlpha(0.7),
		text_disabled = text:Copy():GetLerped(0.45, body),
		text_on_surface = text,
		text_on_surface_variant = text,
		text_on_card = text,
		text_on_header_surface = title_text,
		text_foreground_on_surface = text,
		text_foreground_on_header_surface = title_text,
		background = darker,
		main_background = darker,
		surface = body,
		surface_alt = lighter,
		surface_variant = darker,
		surface_pearl = lighter,
		surface_tile_1 = darker,
		surface_tile_2 = body,
		surface_tile_3 = darker,
		card = lighter,
		header_surface = header,
		track = darker,
		border = Color(0.2, 0.2, 0.2, 1),
		border_strong = Color(0.12, 0.12, 0.12, 1),
		scrollbar_track = darker,
		scrollbar = lighter,
		clickable_disabled = darker,
		invisible = Color(0, 0, 0, 0),
	}
	return palette
end

local SKIN_SAMPLER = {
	min_filter = "nearest",
	mag_filter = "nearest",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
}

function DermaTheme:Initialize()
	local local_path = vfs.GetAbsolutePath(self.SkinPath)

	if local_path then
		self.SkinImage = assert(codec.DecodeFile(local_path))
		self.SkinTexture = Texture.New{decoded = self.SkinImage, sampler = SKIN_SAMPLER}
	else
		self.SkinTexture = Texture.New{path = self.SkinPath, sampler = SKIN_SAMPLER}
		resource.Download(self.SkinPath):Then(function(downloaded_path)
			self.SkinImage = assert(codec.DecodeFile(downloaded_path))
			self.SkinTexture = Texture.New{decoded = self.SkinImage, sampler = SKIN_SAMPLER}
			self:SetPalette(self:CreatePalette())

			if import("goluwa/render2d/ui/theme.lua").active == self then event.Call("ThemeChanged") end
		end)
	end

	DermaTheme.BaseClass.Initialize(self)
	self:SetSizes(
		self:MergeTables(
			self:GetSizes(),
			{
				XXXS = 1,
				XXS = 2,
				XS = 4,
				S = 4,
				M = 8,
				L = 12,
				XL = 16,
				XXL = 24,
				icon = 16,
				header_icon = 16,
				header_padding = 4,
				toggle_box = 15,
				default = 8,
			}
		)
	)
	self:SetRadii({none = 0, XS = 0, S = 0, M = 0, L = 0, full = 0})
	self:SetFontSizes(
		self:MergeTables(
			self:GetFontSizes(),
			{
				XS = 11,
				S = 12,
				M = 13,
				L = 16,
				XL = 20,
				XXL = 26,
				XXXL = 32,
			}
		)
	)
	self:SetFontStyles(
		self:MergeTables(
			self:GetFontStyles(),
			{
				heading = {"Roboto", "Medium"},
				body_weak = {"Roboto", "Regular"},
				body = {"Roboto", "Regular"},
				body_strong = {"Roboto", "Bold"},
			}
		)
	)
	self:SetFontCache({})
	self:SetContentForeground("text_content")
end

function DermaTheme:GetScrollbarWidth()
	return 15
end

function DermaTheme:GetScrollbarCollapsedWidth()
	return self:GetScrollbarWidth()
end

function DermaTheme:GetScrollbarMargin()
	return 0
end

function DermaTheme:UpdateButtonAnimations(pnl) end

function DermaTheme:UpdateCheckboxAnimations(pnl) end

function DermaTheme:UpdateSliderAnimations(pnl) end

function DermaTheme:DrawRegion(region, x, y, w, h, tint, alpha)
	local c = tint or WHITE
	render2d.SetColor(c.r, c.g, c.b, (alpha or 1) * c.a)
	render2d.DrawNinePatch(
		self.SkinTexture,
		region[1],
		region[2],
		region[3],
		region[4],
		region[5],
		region[6],
		region[7],
		region[8],
		x,
		y,
		w,
		h
	)
end

function DermaTheme:DrawFrame(size, emphasis)
	local w, h = math.floor(size.x), math.floor(size.y)

	if emphasis == 2 then
		self:DrawRegion(REGIONS.tooltip, 0, 0, w, h, self.PanelTint)
	else
		self:DrawRegion(REGIONS.white_panel, 0, 0, w, h)
	end
end

function DermaTheme:DrawFramePost(size, emphasis) end

function DermaTheme:DrawHeader(size, emphasis)
	self:DrawRegion(REGIONS.window_header, 0, 0, math.floor(size.x), math.floor(size.y))
end

function DermaTheme:DrawSurface(size, color)
	self:DrawRegion(REGIONS.text_box, 0, 0, math.floor(size.x), math.floor(size.y))
end

function DermaTheme:DrawButton(size, state)
	if state.mode == "menu" then
		return self:DrawMenuButton(size, state)
	elseif state.mode == "tab" then
		return self:DrawTabButton(size, state)
	end

	local w, h = math.floor(size.x), math.floor(size.y)
	local pressed = (state.pressed or state.active) and not state.disabled
	local hovered = state.hovered and not state.disabled

	if state.theme_role == "dropdown" then
		local region = REGIONS.combo_box

		if state.disabled then
			region = REGIONS.combo_box_dead
		elseif pressed then
			region = REGIONS.combo_box_down
		elseif hovered then
			region = REGIONS.combo_box_hovered
		end

		return self:DrawRegion(region, 0, 0, w, h)
	end

	if state.mode == "text" then
		if pressed then
			self:DrawRegion(REGIONS.selection, 0, 0, w, h, nil, 0.85)
		elseif hovered then
			self:DrawRegion(REGIONS.selection, 0, 0, w, h, nil, 0.45)
		end

		return
	end

	local region = REGIONS.button
	local tint

	if state.disabled then
		region = REGIONS.button_dead
	elseif pressed then
		region = REGIONS.button_down
	elseif hovered then
		region = REGIONS.button_hovered
	end

	if state.mode == "outline" then
		tint = self.PanelTint
	elseif state.button_color ~= nil and not state.disabled then
		tint = self:GetColor(state.button_color):Copy():GetLerped(0.35, WHITE)
	end

	self:DrawRegion(region, 0, 0, w, h, tint)
end

function DermaTheme:ResolveButtonStyleContext(state)
	local context = DermaTheme.BaseClass.ResolveButtonStyleContext(self, state)

	if state.theme_role == "dropdown" then
		context.foreground_token = state.disabled and "text_disabled" or "text_combo"
	elseif state.mode == "menu" or (state.mode == "text" and state.button_color == nil) then
		context.foreground_token = state.disabled and "text_disabled" or nil
	elseif state.mode == "tab" then
		if state.disabled then
			context.foreground_token = "text_disabled"
		elseif state.active then
			context.foreground_token = "text_tab_active"
		elseif state.hovered then
			context.foreground_token = "heading"
		else
			context.foreground_token = "text"
		end
	end

	return context
end

function DermaTheme:DrawMenuButton(size, state)
	if state.pressed or state.selected or state.active or state.hovered then
		self:DrawRegion(REGIONS.menu_hover, 0, 0, math.floor(size.x), math.floor(size.y))
	end
end

function DermaTheme:DrawTabButton(size, state)
	local w, h = math.floor(size.x), math.floor(size.y)

	if state.active then
		self:DrawRegion(REGIONS.tab_active, 0, 0, w, h + 3)
	else
		self:DrawRegion(REGIONS.tab_inactive, 0, 3, w, h - 3)
	end
end

function DermaTheme:DrawTabBar(size)
	render2d.SetColor(0, 0, 0, 0.4)
	render2d.DrawRect(0, math.floor(size.y) - 1, math.floor(size.x), 1)
end

function DermaTheme:DrawCheckbox(size, state)
	local y = math.floor((size.y - 15) / 2)
	local region

	if state.value then
		region = state.disabled and REGIONS.checkbox_dead_checked or REGIONS.checkbox_checked
	else
		region = state.disabled and REGIONS.checkbox_dead or REGIONS.checkbox
	end

	self:DrawRegion(region, 0, y, 15, 15)
end

function DermaTheme:DrawButtonRadio(size, state)
	local y = math.floor((size.y - 15) / 2)
	local region

	if state.value then
		region = state.disabled and REGIONS.radio_dead_checked or REGIONS.radio_checked
	else
		region = state.disabled and REGIONS.radio_dead or REGIONS.radio
	end

	self:DrawRegion(region, 0, y, 15, 15)
end

function DermaTheme:DrawSlider(size, state)
	local value, min_value, max_value = state.value, state.min, state.max
	local w, h = math.floor(size.x), math.floor(size.y)
	local suffix = state.pressed and "_down" or (state.hovered and "_hover" or "")

	if state.mode == "2d" then
		self:DrawRegion(REGIONS.text_box, 0, 0, w, h)
		local x = (value.x - min_value.x) / (max_value.x - min_value.x) * (w - 15)
		local y = (value.y - min_value.y) / (max_value.y - min_value.y) * (h - 15)
		self:DrawRegion(REGIONS["slider_h" .. suffix], math.floor(x), math.floor(y), 15, 15)
		return
	end

	local normalized = (value - min_value) / (max_value - min_value)
	local track = self:GetColor("border_strong")
	render2d.SetColor(track.r, track.g, track.b, 0.6)

	if state.mode == "vertical" then
		render2d.DrawRect(math.floor(w / 2), 7, 1, h - 15)
		self:DrawRegion(
			REGIONS["slider_v" .. suffix],
			math.floor((w - 15) / 2),
			math.floor(normalized * (h - 15)),
			15,
			15
		)
		return
	end

	render2d.DrawRect(7, math.floor(h / 2), w - 15, 1)
	self:DrawRegion(
		REGIONS["slider_h" .. suffix],
		math.floor(normalized * (w - 15)),
		math.floor((h - 15) / 2),
		15,
		15
	)
end

function DermaTheme:DrawProgressBar(size, state, color)
	local w, h = math.floor(size.x), math.floor(size.y)
	local value = math.clamp(state.value or 0, 0, 1)
	self:DrawRegion(REGIONS.progress_back, 0, 0, w, h)

	if value > 0 then
		local tint

		if color ~= nil then tint = self:ResolveSurfaceFill(color, "primary"):Copy():GetLerped(0.3, WHITE) end

		self:DrawRegion(REGIONS.progress_front, 0, 0, math.max(1, math.floor(w * value)), h, tint)
	end
end

function DermaTheme:DrawDivider(size)
	render2d.SetColor(0, 0, 0, 0.4)

	if size.x > size.y then
		render2d.DrawRect(0, math.floor(size.y / 2), math.floor(size.x), 1)
	else
		render2d.DrawRect(math.floor(size.x / 2), 0, 1, math.floor(size.y))
	end
end

function DermaTheme:DrawMenuSpacer(size, vertical)
	render2d.SetColor(0, 0, 0, 0.4)

	if vertical then
		render2d.DrawRect(math.floor(size.x / 2), 0, 1, math.floor(size.y))
	else
		render2d.DrawRect(0, math.floor(size.y / 2), math.floor(size.x), 1)
	end
end

function DermaTheme:DrawMenuContainer(size)
	self:DrawRegion(REGIONS.menu, 0, 0, math.floor(size.x), math.floor(size.y))
end

function DermaTheme:DrawSelectionFill(size, color, alpha)
	local c = self:ResolveColor(color, color or "primary")

	if c.a < 1 or (alpha and alpha < 1) then
		render2d.SetColor(c.r, c.g, c.b, (alpha or 1) * c.a)
		render2d.DrawRect(0, 0, math.floor(size.x), math.floor(size.y))
	else
		self:DrawRegion(REGIONS.selection, 0, 0, math.floor(size.x), math.floor(size.y))
	end
end

function DermaTheme:DrawTreeToggle(size, meta, opts)
	opts = opts or {}
	local box = opts.box_size or 0
	local center_x, center_y = self:DrawTreeGuideLines(
		size,
		meta,
		{
			line_color = opts.line_color,
			alpha = opts.alpha,
			toggle_size = opts.toggle_size or box,
			guide_step = opts.guide_step or 0,
			line_start_x = opts.line_start_x,
		}
	)
	self:DrawRegion(
		opts.expanded and REGIONS.tree_minus or REGIONS.tree_plus,
		center_x - math.floor(box / 2),
		center_y - math.floor(box / 2),
		box,
		box
	)
	return center_x, center_y
end

function DermaTheme:DrawScrollbarTrack(size, axis)
	self:DrawRegion(
		axis == "y" and REGIONS.scroll_track_v or REGIONS.scroll_track_h,
		0,
		0,
		math.floor(size.x),
		math.floor(size.y)
	)
end

function DermaTheme:DrawScrollbarHandle(size, axis, pressed, hovered)
	local suffix = pressed and "_down" or (hovered and "_hover" or "")
	self:DrawRegion(
		REGIONS[(axis == "y" and "scroll_handle_v" or "scroll_handle_h") .. suffix],
		0,
		0,
		math.floor(size.x),
		math.floor(size.y)
	)
end

function DermaTheme:Draw(pnl)
	local name = pnl.ThemeName or pnl.Name

	if name == "menu_bar" then
		local size = pnl.transform:GetSize()
		return self:DrawRegion(REGIONS.menu_strip, 0, 0, math.floor(size.x), math.floor(size.y))
	end

	if name == "window_content" then
		local size = pnl.transform:GetTotalSize()
		local w, h = math.floor(size.x), math.floor(size.y)
		self:DrawRegion(REGIONS.window_content, 0, 0, w, h)
		return self:DrawRegion(REGIONS.white_panel, 3, 0, w - 6, h - 3)
	end

	if name == "frame" then
		local size = pnl.transform:GetSize()
		return self:DrawRegion(REGIONS.white_panel, 0, 0, math.floor(size.x), math.floor(size.y))
	end

	if name == "collapsible_body" then
		local size = pnl.transform:GetSize()
		return self:DrawRegion(REGIONS.white_panel, 0, 0, math.floor(size.x), math.floor(size.y))
	end

	if pnl:GetState("theme_role") == "collapsible_header" then
		local size = pnl.transform:GetSize()
		local state = pnl:GetState()
		local region = pnl.Collapsible.OpenFraction > 0.5 and REGIONS.category_header_open or REGIONS.category_header
		local tint

		if state.button_color ~= nil then
			tint = self:GetColor(state.button_color):Copy():GetLerped(0.35, WHITE)
		end

		return self:DrawRegion(region, 0, 0, math.floor(size.x), math.floor(size.y), tint)
	end

	if type(name) == "string" then
		if name:starts_with("scrollbar_track_") then
			return self:DrawScrollbarTrack(pnl.transform:GetTotalSize(), name:sub(-1))
		elseif name:starts_with("scrollbar_handle_") then
			return self:DrawScrollbarHandle(
				pnl.transform:GetTotalSize(),
				name:sub(-1),
				pnl:GetState("pressed"),
				pnl:GetState("hovered")
			)
		end
	end

	return DermaTheme.BaseClass.Draw(self, pnl)
end

return DermaTheme:Register()
