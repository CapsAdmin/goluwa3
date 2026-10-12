-- blades grown on a surface, built by grass.lua from these
return {
	name = "grass",
	category = "Grass",
	block = "none",
	params = {
		{name = "Grass", default = false, callback = "InvalidateFlags"},
		{name = "GrassDensity", default = 700.0, requires = "Grass"},
		{name = "GrassHeight", default = 0.28, requires = "Grass"},
		{name = "GrassHeightVariance", default = 0, requires = "Grass"},
		{name = "GrassWidth", default = 0.02, requires = "Grass"},
	},
}
