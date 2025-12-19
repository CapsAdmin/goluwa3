local fs = require("fs")
local MAP = "gm_construct"

--MAP = nil
if not MAP then return end

if MAP:starts_with("gltf_") then
	local gltf = require("gltf")
	local ecs = require("ecs")
	local Light = require("components.light")
	gltf.debug_white_textures = false
	gltf.debug_print_nodes = false
	local files = {}

	fs.walk(
		"/home/caps/projects/RTXDI-Assets/",
		files,
		nil,
		function(path)
			if path:ends_with(".git") then return false end

			return true
		end
	)

	fs.walk(
		"/home/caps/projects/glTF-Sample-Assets-main/",
		files,
		nil,
		function(path)
			if path:ends_with(".git") then return false end

			return true
		end
	)

	local found = {}

	for i, v in ipairs(files) do
		if v:ends_with(".gltf") then
			local name = v:match("([^/]+)%.gltf$")
			found[name] = v
		end
	end

	local gltf_result = assert(gltf.Load(found[MAP:sub(6)]))
	local scene_root = gltf.CreateEntityHierarchy(gltf_result, ecs.GetWorld(), {
		split_primitives = false,
	})
else
	local steam = require("steam")
	steam.SetMap(MAP)
end
