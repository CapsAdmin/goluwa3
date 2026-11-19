return {
	loaders = {
		gltf = "lua/gltf_loader/gltf_loader.lua",
	},
	model_decoders = {
		[".glb"] = "lua/gltf_loader/model_decoders/gltf.lua",
		[".gltf"] = "lua/gltf_loader/model_decoders/gltf.lua",
	},
}
