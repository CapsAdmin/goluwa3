-- a height map the surface is parallax mapped with, only for a material that has one
return {
	name = "displacement",
	category = "Height",
	block = "own",
	active = function(material)
		return material:HasHeightMap()
	end,
	params = {
		{
			name = "HeightTexture",
			kind = "texture",
			type = "render_texture",
			callback = "InvalidateHeightMap",
		},
		{
			name = "HeightScale",
			default = 0.0,
			callback = "InvalidateHeightMap",
			requires = "HeightTexture",
		},
		{name = "HeightMidlevel", default = 1.0, requires = {"HeightTexture", "HeightScale"}},
		{name = "HeightLayers", kind = "int", default = 24, requires = {"HeightTexture", "HeightScale"}},
	},
}
