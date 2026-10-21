local Vec2 = import("goluwa/structs/vec2.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
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
return {
	Name = "svg",
	Section = "Graphics",
	Order = 1,
	View = react.Component(
		||-> do
			local size, set_size = react.UseState(64)
			local draft, set_draft = react.UseState(default_custom)
			local source, set_source = react.UseState(default_custom)
			local status, set_status = react.UseState("")
			local icon_size = Vec2(size, size)
			return kit.Page{
				Title = "SVG",
				Description = "Vector icons loaded from a path, a URL or an inline string. They are tinted with Color and scale to fit the panel minus its padding.",
			}{
				kit.Section{
					Title = "Icon set",
					Description = "Source accepts a URL, a file path or inline SVG markup.",
				}{
					kit.Group{
						ui.Text{Text = "Icon size: " .. size, IgnoreMouseInput = true},
						ui.Slider{
							Min = 24,
							Max = 128,
							Value = 64,
							OnChange = |value|->set_size(math.floor(value + 0.5)),
							layout = {GrowWidth = 1},
						},
					},
					kit.Wrap(
						list.map(
							sources,
							|entry|->ui.Frame{
								Key = entry[1],
								Padding = "S",
								layout = {FitWidth = true, FitHeight = true, GrowWidth = 0},
							}{
								ui.Column{
									layout = {ChildGap = "XS", AlignmentX = "center", GrowWidth = 0, FitWidth = true},
								}{
									ui.SVG{Source = entry[2], Color = "text", Size = icon_size, Padding = "XS"},
									ui.Text{Text = entry[1], Font = "body S", IgnoreMouseInput = true},
								},
							}
						),
						{AlignmentY = "start"}
					),
				},
				kit.Section{Title = "Inline markup"}{
					kit.Group{
						ui.SVG{Source = inline_source, Color = "neutral", Size = Vec2(64, 64)},
						ui.SVG{Source = inline_source, Color = "negative", Size = Vec2(48, 48)},
						ui.SVG{Source = inline_source, Color = "positive", Size = Vec2(32, 32)},
						ui.SVG{Source = inline_source, Color = "text_disabled", Size = Vec2(24, 24)},
					},
				},
				kit.Section{
					Title = "Custom source",
					Description = "OnLoad(svg, decoded) and OnError(svg, reason) report loading results.",
				}{
					kit.Group(
						{
							ui.SVG{
								Source = source,
								Color = "primary",
								Size = Vec2(96, 96),
								OnLoad = |svg|->set_status("Loaded " .. tostring(svg.Source)),
								OnError = |svg,reason|->set_status("Failed to load: " .. tostring(reason)),
							},
							ui.Column{layout = {ChildGap = "XS", GrowWidth = 1, AlignmentX = "stretch"}}{
								ui.TextEdit{Text = default_custom, OnTextChanged = |_,text|->set_draft(text)},
								kit.Group{ui.Button{Text = "Load", Mode = "outline", OnClick = ||->set_source(draft)}},
							},
						},
						{AlignmentY = "start"}
					),
					ui.Text{
						Text = status,
						Color = "text_disabled",
						Wrap = true,
						IgnoreMouseInput = true,
						layout = {GrowWidth = 1},
					},
				},
			}
		end
	),
}
