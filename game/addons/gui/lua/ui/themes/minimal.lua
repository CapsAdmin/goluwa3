local Color = import("goluwa/structs/color.lua")
local prototype = import("goluwa/prototype.lua")
local BaseTheme = import("./base.lua")
local MinimalTheme = prototype.CreateTemplate("ui_theme_minimal")
MinimalTheme.Name = "minimal"
MinimalTheme.Base = BaseTheme

function MinimalTheme:Initialize()
	self.BaseClass.Initialize(self)
	local palette = self:GetPalette():Copy()
	palette:SetMap(
		self:MergeTables(
			palette:GetMap(),
			{
				primary = Color.FromHex("#2563eb"),
				property_selection = Color.FromHex("#dbeafe"),
				secondary = Color.FromHex("#dbeafe"),
				button_color = Color.FromHex("#2563eb"),
				button_normal = Color.FromHex("#2563eb"),
				text_selection = Color.FromHex("#93c5fd"):SetAlpha(0.5),
				underline = Color.FromHex("#2563eb"),
				url_color = Color.FromHex("#2563eb"),
				border = Color.FromHex("#cbd5e1"),
				surface_alt = Color.FromHex("#e2e8f0"),
			}
		)
	)
	self:SetPalette(palette)
	self:SetFontCache({})
end

MinimalTheme:Register()
return MinimalTheme
