local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/ecs/panel.lua")
local ColorPalette = import("goluwa/palette.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Button = import("../elements/button.lua")
local Column = import("../elements/column.lua")
local PropertyEditor = import("../elements/property_editor.lua")
local Row = import("../elements/row.lua")
local ScrollablePanel = import("../elements/scrollable_panel.lua")
local Splitter = import("../elements/splitter.lua")
local Text = import("../elements/text.lua")
local accent_names = {"red", "yellow", "blue", "green", "purple", "brown"}
local shade_names = {"light", "mid", "dark"}
local accent_defaults = {
	red = Color.FromHex("#dc2626"),
	yellow = Color.FromHex("#d97706"),
	blue = Color.FromHex("#2563eb"),
	green = Color.FromHex("#16a34a"),
	purple = Color.FromHex("#7c3aed"),
	brown = Color.FromHex("#8b5e3c"),
}
local shade_defaults = {
	light = Color.FromHex("#f8fafc"),
	mid = Color.FromHex("#cbd5e1"),
	dark = Color.FromHex("#080a0e"),
}
local body_copy = "Drag any of the nine source colors on the left. The preview rebuilds the palette in real time and uses the generated tones to paint this card directly with render2d and fonts."
local color_min = Color.CType(0, 0, 0, 0)
local color_max = Color.CType(1, 1, 1, 1)

local function copy_color(color)
	return Color.CType(color.r, color.g, color.b, color.a)
end

local function copy_named_colors(source, names)
	local out = {}

	for _, name in ipairs(names) do
		out[name] = copy_color(source[name])
	end

	return out
end

local function make_default_state()
	return {
		colors = copy_named_colors(accent_defaults, accent_names),
		shades = copy_named_colors(shade_defaults, shade_names),
		surface_token = "white",
		text_token = "blue",
	}
end

local function build_palette_from_state(state)
	local palette = ColorPalette.New()
	palette:SetShades{state.shades.light, state.shades.mid, state.shades.dark}
	palette:SetColors(state.colors)
	palette.AdjustmentOptions = {target_contrast = 4.5}
	return palette
end

local function get_token_label(token)
	return tostring(token):gsub("_", " "):gsub("^%l", string.upper)
end

local function build_token_options(palette)
	local names = {}

	for token in pairs(palette:GetBaseMap()) do
		names[#names + 1] = token
	end

	table.sort(names)
	local options = {}

	for _, token in ipairs(names) do
		options[#options + 1] = {
			Text = get_token_label(token),
			Value = token,
		}
	end

	return options
end

local function resolve_token(token, fallback, palette)
	if palette:GetBaseMap()[token] then return token end

	return fallback
end

local function set_color(color, alpha_multiplier)
	alpha_multiplier = alpha_multiplier or 1
	render2d.SetColor(color.r, color.g, color.b, color.a * alpha_multiplier)
end

local function draw_round_rect(x, y, w, h, radius, color, alpha_multiplier)
	render2d.SetTexture(nil)
	set_color(color, alpha_multiplier)

	if radius > 0 then
		gfx.DrawRoundedRect(x, y, w, h, radius)
	else
		render2d.DrawRect(x, y, w, h)
	end
end

local function draw_round_outline(x, y, w, h, radius, color, alpha_multiplier, width)
	render2d.SetTexture(nil)
	set_color(color, alpha_multiplier)
	render2d.PushBorderRadius(radius)
	render2d.PushOutlineWidth(width or 1)
	render2d.DrawRect(x, y, w, h)
	render2d.PopOutlineWidth()
	render2d.PopBorderRadius()
end

local function draw_text(font, text, x, y, color, alpha_multiplier)
	set_color(color, alpha_multiplier)
	font:DrawText(text, x, y)
end

local function draw_wrapped_text(font, text, x, y, width, color, alpha_multiplier)
	local wrapped = font:WrapString(text, width)
	local line_y = y

	for line in tostring(wrapped):gmatch("[^\n]+") do
		draw_text(font, line, x, line_y, color, alpha_multiplier)
		line_y = line_y + font:GetLineHeight() + 4
	end

	return line_y - y
end

local function draw_centered_label(font, label, x, y, width, color)
	local text_w = select(1, font:GetTextSize(label))
	draw_text(font, label, x + math.floor((width - text_w) / 2), y, color)
end

local function build_items(state, palette, on_change)
	local token_options = build_token_options(palette)
	local card_children = {
		{
			Key = "card/surface",
			Text = "Surface",
			Type = "enum",
			Value = state.surface_token,
			Options = token_options,
			Description = "Chooses which palette token is used for the card background.",
			OnChange = function(_, value)
				state.surface_token = value
				on_change()
			end,
		},
		{
			Key = "card/text",
			Text = "Text",
			Type = "enum",
			Value = state.text_token,
			Options = token_options,
			Description = "Chooses which palette token is resolved through ColorPalette:Get(text, surface).",
			OnChange = function(_, value)
				state.text_token = value
				on_change()
			end,
		},
	}
	local accent_children = {}
	local shade_children = {}

	for _, name in ipairs(accent_names) do
		accent_children[#accent_children + 1] = {
			Key = "accents/" .. name,
			Text = name:gsub("^%l", string.upper),
			Type = "color",
			Value = state.colors[name],
			Default = accent_defaults[name],
			Min = color_min,
			Max = color_max,
			Precision = 3,
			SwatchSize = 28,
			Description = "Accent tone used by the demo card for emphasis, chips, and actions.",
			OnChange = function(_, value)
				state.colors[name] = copy_color(value)
				on_change()
			end,
		}
	end

	for _, name in ipairs(shade_names) do
		shade_children[#shade_children + 1] = {
			Key = "shades/" .. name,
			Text = name == "mid" and "Mid" or name:gsub("^%l", string.upper),
			Type = "color",
			Value = state.shades[name],
			Default = shade_defaults[name],
			Min = color_min,
			Max = color_max,
			Precision = 3,
			SwatchSize = 28,
			Description = "Base shade used to derive neutral surfaces and contrast tokens.",
			OnChange = function(_, value)
				state.shades[name] = copy_color(value)
				on_change()
			end,
		}
	end

	return {
		{
			Key = "card",
			Text = "Card",
			Expanded = true,
			Description = "Preview settings for the simplified card surface and typography.",
			Children = card_children,
		},
		{
			Key = "shades",
			Text = "Shades",
			Expanded = true,
			Description = "These three anchors define the neutral ramp for the generated palette.",
			Children = shade_children,
		},
		{
			Key = "accents",
			Text = "Accents",
			Expanded = true,
			Description = "Six accent families that feed the semantic card preview.",
			Children = accent_children,
		},
	}
end

local function create_preview_panel(preview_state)
	local font_path = fonts.GetDefaultSystemFontPath()
	local eyebrow_font = fonts.New{Path = font_path, Size = 12}
	local title_font = fonts.New{Path = font_path, Size = 26}
	local body_font = fonts.New{Path = font_path, Size = 15}
	local button_font = fonts.New{Path = font_path, Size = 13}
	return Panel.New{
		transform = true,
		rect = true,
		layout = {
			GrowWidth = 1,
			GrowHeight = 1,
			MinSize = Vec2(480, 560),
		},
		OnDraw = function(self)
			local palette = preview_state.palette
			local state = preview_state.state
			local size = self.transform.Size + self.transform.DrawSizeOffset
			local background = palette:GetBase("lightest")
			local surface_token = resolve_token(state.surface_token, "white", palette)
			local text_token = resolve_token(state.text_token, "blue", palette)
			local card = palette:GetBase(surface_token)
			local outline = palette:GetBase("grey")
			local shadow = palette:GetBase("black")
			local primary = palette:GetBase("blue")
			local text_color = palette:Get(text_token, surface_token)
			local body_color = text_color:Copy():SetAlpha(0.78)
			local on_primary = palette:Get("white", "blue")
			local card_w = math.min(size.x - 64, 560)
			local card_h = math.min(size.y - 96, 260)
			local card_x = math.floor((size.x - card_w) / 2)
			local card_y = math.floor((size.y - card_h) / 2)
			local content_x = card_x + 28
			local content_w = card_w - 56
			local text_y = card_y + 28
			local button_y = card_y + card_h - 56
			local button_w = 136
			draw_round_rect(0, 0, size.x, size.y, 0, background)
			set_color(primary, 0.08)
			gfx.DrawFilledCircle(size.x * 0.18, size.y * 0.18, 96)
			gfx.DrawFilledCircle(size.x * 0.84, size.y * 0.22, 120)
			draw_round_rect(card_x, card_y + 28, card_w, card_h, 28, shadow, 0.06)
			draw_round_rect(card_x, card_y + 16, card_w, card_h, 28, shadow, 0.05)
			draw_round_rect(card_x, card_y, card_w, card_h, 28, card)
			draw_round_outline(card_x, card_y, card_w, card_h, 28, outline, 0.32, 1)
			draw_text(eyebrow_font, "CARD PREVIEW", content_x, text_y, body_color)
			draw_text(title_font, "Simple Palette Card", content_x, text_y + 22, text_color)
			draw_wrapped_text(body_font, body_copy, content_x, text_y + 60, content_w, body_color)
			draw_round_rect(content_x, button_y, button_w, 36, 18, primary)
			draw_centered_label(button_font, "Take Action", content_x, button_y + 10, button_w, on_primary)
		end,
	}
end

return {
	Name = "palette card",
	Create = function()
		local state = make_default_state()
		local preview_state = {palette = build_palette_from_state(state), state = state}
		local editor

		local function rebuild_palette()
			preview_state.palette = build_palette_from_state(state)
			state.surface_token = resolve_token(state.surface_token, "white", preview_state.palette)
			state.text_token = resolve_token(state.text_token, "blue", preview_state.palette)
		end

		local function refresh_editor()
			if editor and editor:IsValid() then
				editor:SetItems(build_items(state, preview_state.palette, rebuild_palette))
			end
		end

		local function reset_palette()
			state = make_default_state()
			preview_state.state = state
			rebuild_palette()
			refresh_editor()
		end

		return Column{
			layout = {
				Direction = "y",
				FitHeight = true,
				GrowWidth = 1,
				ChildGap = 12,
				Padding = Rect(20, 20, 20, 20),
				AlignmentX = "stretch",
			},
		}{
			Text{
				Text = "Palette Card",
				Font = "body_strong S",
				IgnoreMouseInput = true,
			},
			Text{
				Text = "Edit the three shade anchors and six accent colors on the left. The right side rebuilds goluwa/palette.lua semantics live and paints a material-like card without UI text or surface widgets.",
				Wrap = true,
				IgnoreMouseInput = true,
				layout = {
					GrowWidth = 1,
				},
			},
			Row{
				layout = {
					GrowWidth = 1,
					ChildGap = 8,
					AlignmentY = "center",
				},
			}{
				Button{
					Text = "Reset Palette",
					Mode = "outline",
					OnClick = reset_palette,
				},
			},
			Splitter{
				InitialSize = 420,
				layout = {
					GrowWidth = 1,
					MinSize = Vec2(0, 620),
					MaxSize = Vec2(0, 620),
				},
			}{
				ScrollablePanel{
					ScrollX = false,
					ScrollY = true,
					ScrollBarContentShiftMode = "auto_shift",
					layout = {
						GrowWidth = 1,
						GrowHeight = 1,
					},
				}{
					PropertyEditor{
						Ref = function(self)
							editor = self
							self:SetItems(build_items(state, preview_state.palette, rebuild_palette))
							self:SetSelectedKey("card/surface")
						end,
						ValueWidth = 244,
						KeyWidth = 110,
						layout = {
							GrowWidth = 1,
							MinSize = Vec2(0, 0),
						},
					},
				},
				create_preview_panel(preview_state),
			},
		}
	end,
}
