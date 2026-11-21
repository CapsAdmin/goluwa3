return {
	name = "decal",
	category = "Decal",
	block = "own",
	active = function(material)
		return material:GetDecal()
	end,
	params = {
		{name = "DecalAlphaClean", default = 0.0},
	},
}
