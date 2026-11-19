return {
	loaders = {
		cry = "lua/crysis_loader/crysis_loader.lua",
	},
	model_decoders = {
		[".cgf"] = "lua/crysis_loader/model_decoders/register.lua",
	},
	material_loaders = {
		[".mtl"] = "lua/crysis_loader/mtl_material.lua",
	},
	components = {
		cry_level = "lua/crysis_loader/components/cry_level.lua",
	},
}
