local commands = import("goluwa/cli/commands.lua")
local tasks = import("goluwa/tasks.lua")
local event = import("goluwa/event.lua")
local gltf_scene_loader = import("lua/gltf_scene_loader.lua")
local gltf_scenes = import("lua/gltf_scenes.lua")

commands.Add("gltf_scene=string", function(name)
	local path = assert(gltf_scenes.FindIndex(name), "could not find gltf scene " .. name)

	tasks.CreateTask(
		function()
			local root_entity, gltf_data = gltf_scene_loader.Load(path, {name = name})

			if not root_entity then
				logf("failed to load gltf scene %q: %s\n", name, tostring(gltf_data))
				event.Call("GLTFSceneLoadFailed", name, gltf_data)
				return
			end

			logf(
				"loaded gltf scene %q: %d nodes, %d meshes, %d materials, %d textures\n",
				name,
				#gltf_data.nodes,
				#gltf_data.meshes,
				#gltf_data.materials,
				#gltf_data.textures
			)
			event.Call("GLTFSceneLoaded", name, root_entity, gltf_data)
		end,
		nil,
		nil,
		function(err)
			logf("gltf_scene %q failed: %s\n", name, tostring(err))
			event.Call("GLTFSceneLoadFailed", name, err)
		end
	)
end)
