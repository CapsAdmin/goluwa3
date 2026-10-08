local Vec2 = import("goluwa/structs/vec2.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local Frame = import("goluwa/render2d/ui/elements/frame.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Slider = import("goluwa/render2d/ui/elements/slider.lua")
local SVG = import("goluwa/render2d/ui/elements/svg.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local kit = import("addons/ui_gallery/lua/gallery_kit.lua")
local sources = {
	{"Home", "https://api.iconify.design/mdi-light/home.svg"},
	{"Heart", "https://api.iconify.design/mdi-light/heart.svg"},
	{"Account", "https://api.iconify.design/mdi-light/account.svg"},
	{"Cog", "https://api.iconify.design/mdi-light/cog.svg"},
	{"Bell", "https://api.iconify.design/mdi-light/bell.svg"},
	{"Camera", "https://api.iconify.design/mdi-light/camera.svg"},
	{"Folder", "https://api.iconify.design/mdi-light/folder.svg"},
	{"Cloud", "https://api.iconify.design/mdi-light/cloud.svg"},
}
local inline_source = [[<svg viewBox="0 0 24 24"><path d="M12 2l3 7h7l-5.5 4.5L18.5 21 12 16.8 5.5 21l2-7.5L2 9h7z"/></svg>]]
local default_custom = "https://api.iconify.design/mdi-light/star.svg"

local function on_size_change(value, slider)
	local page = slider.Page
	local size = math.floor(value + 0.5)
	page.label.text:SetText("Icon size: " .. size)

	for _, icon in ipairs(page.icons) do
		icon.transform:SetSize(Vec2(size, size))
	end
end

local function load_custom(button)
	local page = button.Page
	page.preview:SetSource(page.input:GetText())
end

local function on_load(svg)
	svg.Page.status.text:SetText("Loaded " .. tostring(svg.Source))
end

local function on_error(svg, reason)
	svg.Page.status.text:SetText("Failed to load: " .. tostring(reason))
end

return {
	Name = "svg",
	Section = "Graphics",
	Order = 1,
	Create = function()
		local page = {icons = {}}
		page.label = Text{Text = "Icon size: 64", IgnoreMouseInput = true}
		page.status = Text{
			Text = "",
			Color = "text_disabled",
			Wrap = true,
			IgnoreMouseInput = true,
			layout = {GrowWidth = 1},
		}
		local tiles = {}

		for index, entry in ipairs(sources) do
			local icon = SVG{Source = entry[2], Color = "text", Size = Vec2(64, 64), Padding = "XS"}
			page.icons[index] = icon
			tiles[index] = Frame{Padding = "S", layout = {FitWidth = true, FitHeight = true, GrowWidth = 0}}{
				Column{
					layout = {ChildGap = "XS", AlignmentX = "center", GrowWidth = 0, FitWidth = true},
				}{
					icon,
					Text{Text = entry[1], Font = "body S", IgnoreMouseInput = true},
				},
			}
		end

		page.preview = SVG{
			Page = page,
			Source = default_custom,
			Color = "primary",
			Size = Vec2(96, 96),
			OnLoad = on_load,
			OnError = on_error,
		}
		page.input = TextEdit{Text = default_custom}
		return kit.Page{
			Title = "SVG",
			Description = "Vector icons loaded from a path, a URL or an inline string. They are tinted with Color and scale to fit the panel minus its padding.",
		}{
			kit.Section{
				Title = "Icon set",
				Description = "Source accepts a URL, a file path or inline SVG markup.",
			}{
				kit.Group{
					page.label,
					Slider{
						Page = page,
						Min = 24,
						Max = 128,
						Value = 64,
						OnChange = on_size_change,
						layout = {GrowWidth = 1},
					},
				},
				kit.Wrap(tiles, {AlignmentY = "start"}),
			},
			kit.Section{Title = "Inline markup"}{
				kit.Group{
					SVG{Source = inline_source, Color = "neutral", Size = Vec2(64, 64)},
					SVG{Source = inline_source, Color = "negative", Size = Vec2(48, 48)},
					SVG{Source = inline_source, Color = "positive", Size = Vec2(32, 32)},
					SVG{Source = inline_source, Color = "text_disabled", Size = Vec2(24, 24)},
				},
			},
			kit.Section{
				Title = "Custom source",
				Description = "OnLoad(svg, decoded) and OnError(svg, reason) report loading results.",
			}{
				kit.Group(
					{
						page.preview,
						Column{layout = {ChildGap = "XS", GrowWidth = 1, AlignmentX = "stretch"}}{
							page.input,
							kit.Group{Button{Page = page, Text = "Load", Mode = "outline", OnClick = load_custom}},
						},
					},
					{AlignmentY = "start"}
				),
				page.status,
			},
		}
	end,
}
