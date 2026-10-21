return {
	name = "vegetation",
	category = "Vegetation",
	block = "none",
	params = {
		{name = "Billboard", default = false, callback = "InvalidateFlags"},
		{name = "Bending", default = 0.0},
		{name = "DetailBending", default = "none", enums = {"none", "leaves", "grass"}},
		{name = "BendDetailFrequency", default = 5.0, requires = "DetailBending"},
		{name = "BendDetailLeafAmplitude", default = 0.08, requires = "DetailBending"},
		{name = "BendDetailBranchAmplitude", default = 0.2, requires = "DetailBending"},
		{name = "BendDetailPhase", default = 100.0, requires = "DetailBending"},
	},
}
