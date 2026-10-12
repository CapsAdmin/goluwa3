-- wind on plants: a billboarded card, the trunk bending and the leaves and branches fluttering. the
-- vertex animation block in model_pipeline.lua reads these through the material, along with the wind
-- and the time, which are not material params, so it keeps its own block
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
