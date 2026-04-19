local Color = import("goluwa/structs/color.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local build_base_theme = import("./base.lua")
local base = build_base_theme{
	primary = Color.FromHex("#334155"),
	default_font_path = fonts.GetDefaultSystemFontPath(),
}
return {
	preset = base.extend_preset(
		base.preset,
		{
			label = "Minimal",
			colors = {
				primary = Color.FromHex("#2563eb"),
				property_selection = Color.FromHex("#dbeafe"),
				secondary = Color.FromHex("#dbeafe"),
				button_color = Color.FromHex("#2563eb"),
				button_normal = Color.FromHex("#2563eb"),
				text_selection = Color.FromHex("#93c5fd"):SetAlpha(0.5),
				underline = Color.FromHex("#2563eb"),
				url_color = Color.FromHex("#2563eb"),
				frame_border = Color.FromHex("#cbd5e1"),
				surface_variant = Color.FromHex("#e2e8f0"),
			},
		}
	),
	create_runtime = base.create_runtime,
}
