local fs = import("goluwa/filesystem/fs.lua")
local gltf_scenes = {}
gltf_scenes.DIR = "addons/gltf_loader/scenes/"
local SUBDIRECTORIES = {"", "gltf/", "glTF/", "glTF-Binary/"}
local FILE_RANKS = {
	{"^scene%.gltf$"},
	{"_extended%.gltf$"},
	{"_extended%.glb$"},
	{"%.gltf$"},
	{"%.glb$"},
}

function gltf_scenes.FindIndex(name)
	local root = gltf_scenes.DIR .. name .. "/"

	for _, subdirectory in ipairs(SUBDIRECTORIES) do
		local files = fs.get_files(root .. subdirectory) or {}
		table.sort(files)

		for _, ranks in ipairs(FILE_RANKS) do
			for _, file in ipairs(files) do
				if file:match(ranks[1]) then return root .. subdirectory .. file end
			end
		end
	end
end

function gltf_scenes.GetNames()
	local names = {}

	for _, name in ipairs(fs.get_files(gltf_scenes.DIR) or {}) do
		if fs.is_directory(gltf_scenes.DIR .. name) and gltf_scenes.FindIndex(name) then
			names[#names + 1] = name
		end
	end

	table.sort(names)
	return names
end

function gltf_scenes.FindThumbnail(name)
	local root = gltf_scenes.DIR .. name .. "/"

	for _, file in ipairs(fs.get_files(root) or {}) do
		if file:match("_thumbnail%.png$") then return root .. file end
	end

	for _, file in ipairs{"screenshot/screenshot.jpg", "screenshot/screenshot_large.jpg"} do
		if fs.is_file(root .. file) then return root .. file end
	end
end

return gltf_scenes
