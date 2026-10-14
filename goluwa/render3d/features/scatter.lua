-- the model set grown on a surface, built by scatter.lua from these, see scatter_set.lua
return {
	name = "scatter",
	category = "Scatter",
	block = "none",
	params = {
		{name = "ScatterSet", default = nil, type = "render3d_scatter_set", callback = "InvalidateFlags"},
		{name = "ScatterDensity", default = 1.0, requires = "ScatterSet"},
	},
}
