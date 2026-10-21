return {
	name = "refraction",
	category = "Refraction",
	block = "none",
	params = {
		{name = "Refraction", default = 0.0, callback = "InvalidateTransparency"},
		{name = "IndexOfRefraction", default = 1.5, requires = "Refraction"},
		{name = "AbbeNumber", default = 0, requires = "Refraction"},
		{name = "RefractionThickness", default = -1.0, requires = "Refraction"},
		{name = "AttenuationDistance", default = 0.0, requires = "Refraction"},
	},
}
