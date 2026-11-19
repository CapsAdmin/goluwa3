return {
	loaders = {
		source = "lua/source_loader/source_loader.lua",
	},
	model_decoders = {
		[".mdl"] = "lua/source_loader/model_decoders/mdl.lua",
		[".bsp"] = "lua/source_loader/model_decoders/bsp.lua",
		[".vmdl_c"] = "lua/source_loader/model_decoders/vmdl_c.lua",
		[".vmesh_c"] = "lua/source_loader/model_decoders/vmdl_c.lua",
		[".vphys_c"] = "lua/source_loader/model_decoders/vphys_c.lua",
	},
	material_loaders = {
		[".vmt"] = "lua/source_loader/vmt_material.lua",
	},
	components = {
		source_light = "lua/source_loader/components/source_light.lua",
	},
}
