local commands = import("goluwa/cli/commands.lua")
local bake_scene = import("goluwa/render3d/cluster_stream/bake_scene.lua")
local cluster_stream = import("goluwa/render3d/scene/cluster_stream.lua")
local gltf_scenes = import("addons/gltf_loader/lua/gltf_loader/scenes.lua")

commands.Add({
	aliases = "gltf_bake",
	argtypes = "string",
	flags = {
		["min-level"] = {
			type = "number",
			description = "finest hierarchy level stored, 0 keeps the source triangles (default), 1 halves the cache",
		},
		threads = {type = "number", description = "worker threads (16), each needs up to 2 GB"},
	},
}, function(name, flags)
	local path = assert(gltf_scenes.FindIndex(name), "could not find gltf scene " .. name)
	bake_scene.Bake(
		path,
		{
			cache_dir = cluster_stream.GetCacheDirectory(name),
			min_level = flags["min-level"] or 0,
			threads = flags.threads or 16,
			log = function(line)
				logn(line)
			end,
		}
	)
	system.ShutDown(0)
end)
