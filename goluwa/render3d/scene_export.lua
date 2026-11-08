local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local codec = import("goluwa/codec.lua")
local file_path = import("goluwa/filesystem/path.lua")
local scene = import("goluwa/entities/scene.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local material_bake = import("goluwa/render3d/material_bake.lua")
local material_file = import("goluwa/render3d/material_file.lua")
local scene_export = {}

-- Saves the scene to storage/scenes/<name>/scene.scene. With options.materials every material the
-- scene draws with is written to <name>/materials/<id>/material.mat. With options.textures their
-- textures are copied next to the material file (baked textures from the cache, originals out of
-- mounted archives) so the file refers to them relatively, otherwise it keeps the paths it has.
-- Every material file is loaded back and compared with what was written. Models are not saved.
-- Returns the stats.
function scene_export.Save(name, options)
	options = options or {}
	assert(options.materials or not options.textures, "textures are saved next to materials")
	local stats = {
		entities = scene.Save(name),
		materials = 0,
		copied_textures = 0,
		failed = {},
		mismatched = {},
		unserialized = {},
		bytes = 0,
	}

	if not options.materials then return stats end

	local root = scene.GetSceneDirectory(name) .. "materials/"

	if fs.exists(root) then assert(fs.remove_directory_recursive(root)) end

	assert(fs.create_directory_recursive(root))
	local used = {}

	for material in pairs(Visual.Library.GetSceneMaterialUsers()) do
		local id = (
			material.vmt_path or
			material:GetName()
		):gsub("^materials/", ""):gsub("%.%w+$", ""):gsub("[^%w]+", "_"):sub(1, 60)

		if id == "" then id = "material" end

		local unique = id
		local suffix = 1

		while used[unique] do
			suffix = suffix + 1
			unique = id .. "_" .. suffix
		end

		used[unique] = true
		local directory = root .. unique .. "/"
		assert(fs.create_directory_recursive(directory))
		local relative_paths = {}
		local copied = {}

		for _, info in ipairs(material:GetTextures()) do
			local file_name = material_file.TextureFiles[info.name]
			local path = info.texture.config.path or
				material.bake_key and
				file_name and
				material_bake.GetCachePath(material.bake_key) .. file_name

			if path and options.textures then
				local copied_name = file_path.GetFileNameFromPath(path)

				if copied[copied_name] then
					copied_name = info.name:lower() .. "_" .. copied_name
				end

				copied[copied_name] = true
				local data = assert(vfs.Read(path) or fs.read_file(path))
				assert(fs.write_file(directory .. copied_name, data))
				relative_paths[info.texture] = copied_name
				stats.copied_textures = stats.copied_textures + 1
				stats.bytes = stats.bytes + #data
			elseif path then
				relative_paths[info.texture] = path
			end
		end

		local meta = material_bake.GetMeta(material) or {source = material.source_meta}
		local text = material_file.Serialize(material, directory, meta, relative_paths)
		local path = directory .. material_file.FileName
		assert(fs.write_file(path, text))
		stats.materials = stats.materials + 1

		if #meta.unserialized > 0 then
			stats.unserialized[unique] = table.concat(meta.unserialized, ", ")
		end

		local ok, loaded = pcall(material_file.Load, path)

		if not ok or not loaded then
			stats.failed[unique] = tostring(loaded)
		else
			local written = codec.Decode("luadata", text)
			local reloaded = codec.Decode("luadata", material_file.Serialize(loaded, directory))
			written.Meta, reloaded.Meta = nil, nil

			if not scene.ValuesEqual(written, reloaded) then
				stats.mismatched[unique] = true
			end
		end
	end

	return stats
end

return scene_export
