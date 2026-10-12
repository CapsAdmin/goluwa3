-- what a glass like material bends the scene behind it by. the forward pass reads these through the
-- material, there is no block for them
return {
	name = "refraction",
	category = "Refraction",
	block = "none",
	params = {
		{name = "Refraction", default = 0.0, callback = "InvalidateTransparency"},
		{name = "IndexOfRefraction", default = 1.5, requires = "Refraction"},
		{name = "AbbeNumber", default = 0, requires = "Refraction"},
		{name = "RefractionThickness", default = -1.0, requires = "Refraction"},
	},
}
