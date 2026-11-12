local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local codec = import("goluwa/codec.lua")
local file_path = import("goluwa/filesystem/path.lua")
local scene = import("goluwa/entities/scene.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local material_bake = import("goluwa/render3d/material_bake.lua")
local material_file = import("goluwa/render3d/material_file.lua")
local heightmap_file = import("goluwa/terrain/heightmap_file.lua")
local texture_compress = import("goluwa/render/texture_compress.lua")
local objects = import("goluwa/objects/objects.lua")
local Material = import("goluwa/render3d/material.lua")
local model_file = import("goluwa/render3d/model_file.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local scene_export = {}
local MODEL_REFERENCES = {
	{"model", "ModelPath"},
	{"visual", "ModelPath"},
	{"rigid_body", "ShapeModelPath"},
	{"scatter_placements", "Model"},
}

-- Saves the scene to storage/scenes/<name>/scene.scene. The files are written to <name>.saving and
-- replace <name> when everything is written, so a failed save leaves the old scene as it was. With options.materials every material the
-- scene draws with is written to <name>/materials/<id>/material.mat. With options.textures their
-- textures are copied next to the material file (baked textures from the cache, originals out of
-- mounted archives) so the file refers to them relatively, otherwise it keeps the paths it has.
-- With options.models the loaded models (meshes, skin weights, skeleton, physics) are written to <name>/models/<id>/model.mesh and
-- the scene refers to them as "./models/<id>/model.mesh", a path relative to the scene
-- directory. Models that are not loaded and procedural models stay as they are.
-- Materials the loaded world looked up by path but never draws (tool textures) are written too so
-- the lookup resolves. Every material file is loaded back and compared with what was written. Returns the stats.
function scene_export.Save(name, options)
	options = options or {}
	assert(
		options.materials or not (options.textures or options.models),
		"textures and models are saved with materials"
	)
	local final_name = name
	name = name .. ".saving"
	local final_directory = scene.GetSceneDirectory(final_name)
	local data = scene.Serialize()
	local stats = {
		entities = #data.entities,
		materials = 0,
		models = 0,
		terrains = 0,
		copied_textures = 0,
		failed = {},
		mismatched = {},
		unserialized = {},
		missing_textures = {},
		skipped_models = {},
		dropped = {},
		bytes = 0,
	}
	local terrain_files = {}

	if fs.exists(scene.GetSceneDirectory(name)) then
		assert(fs.remove_directory_recursive(scene.GetSceneDirectory(name)))
	end

	local function commit()
		scene.Write(name, data)

		if fs.exists(final_directory) then
			assert(fs.remove_directory_recursive(final_directory))
		end

		assert(os.rename(scene.GetSceneDirectory(name):sub(1, -2), final_directory:sub(1, -2)))
	end

	if options.terrain then
		for _, record in ipairs(data.entities) do
			local properties = record.components.terrain
			local component = properties and objects.created_objects_guid[record.guid].terrain

			if component and not component:IsEditable() then
				local terrain_data = component:GetData()
				stats.terrains = stats.terrains + 1
				local directory = scene.GetSceneDirectory(name) .. "terrain" .. (
						stats.terrains > 1 and
						stats.terrains or
						""
					) .. "/"
				heightmap_file.Save(directory, terrain_data, options)
				properties.Path = "./" .. directory:match("[^/]+/$") .. heightmap_file.FileName
				terrain_files[terrain_data.color] = "../../" .. directory:match("[^/]+/$") .. "color.dds"
			end
		end
	end

	if not options.materials then
		commit()
		return stats
	end

	local scene_directory = scene.GetSceneDirectory(name)
	local root = scene_directory .. "materials/"
	assert(fs.create_directory_recursive(root))
	local used = {}
	local material_paths = {}

	local function export_material(material)
		if material_paths[material] then return material_paths[material] end

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

		for texture, path in pairs(terrain_files) do
			relative_paths[texture] = path
		end

		for _, info in ipairs(material:GetTextures()) do
			local file_name = material_file.TextureFiles[info.name]
			local path = info.texture.config.path or
				material.bake_key and
				file_name and
				material_bake.GetCachePath(material.bake_key) .. file_name
			local texture_data = path and options.textures and (vfs.Read(path) or fs.read_file(path))

			if path and options.textures and not texture_data then
				stats.missing_textures[path] = material:GetName()
				relative_paths[info.texture] = path
			elseif texture_data then
				local copied_name = file_path.GetFileNameFromPath(path)

				if copied[copied_name] then
					copied_name = info.name:lower() .. "_" .. copied_name
				end

				copied[copied_name] = true
				assert(fs.write_file(directory .. copied_name, texture_data))
				relative_paths[info.texture] = copied_name
				stats.copied_textures = stats.copied_textures + 1
				stats.bytes = stats.bytes + #texture_data
			elseif path then
				relative_paths[info.texture] = path
			elseif info.name == "Height" then
				assert(
					fs.write_file(
						directory .. "height.dds",
						texture_compress.Recompress{
							sources = {{texture = info.texture}},
							format = "bc4",
							kind = "linear",
						}
					)
				)
				relative_paths[info.texture] = "height.dds"
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

			for _, value in pairs(written) do
				if type(value) == "table" and value.path and value.path:starts_with("../") then
					value.path = file_path.Normalize(directory .. value.path)
				end
			end

			if not scene.ValuesEqual(written, reloaded) then
				stats.mismatched[unique] = true
			end
		end

		material_paths[material] = "materials/" .. unique .. "/" .. material_file.FileName
		return material_paths[material]
	end

	for material in pairs(Visual.Library.GetSceneMaterialUsers()) do
		if not material.terrain_tile then export_material(material) end
	end

	for material in pairs(Material.GetCacheStats()) do
		if
			(
				material.vmt_path or
				material.cry_mtl_path
			)
			and
			not material.Error and
			not material_paths[material]
		then
			export_material(material)
		end
	end

	if options.models then
		local models_root = scene_directory .. "models/"
		local exported = {}
		local used_models = {}

		for _, record in ipairs(data.entities) do
			for _, reference in ipairs(MODEL_REFERENCES) do
				local model = record.components[reference[1]]
				local path = model and model[reference[2]]

				if path and path ~= "" and not path:ends_with(".lua") then
					if exported[path] == nil then
						exported[path] = false
						local loaded = model_loader.model_loads:Get(path)
						local reason

						if not loaded then reason = "not loaded" end

						local meshes = {}

						for i, entry in ipairs(loaded or {}) do
							local geometry, geometry_reason = model_file.GetGeometry(entry.mesh)

							if not geometry then
								reason = geometry_reason

								break
							end

							meshes[i] = {
								polygon = entry.mesh,
								material = entry.material and "../../" .. export_material(entry.material),
							}
						end

						if reason then
							stats.skipped_models[path] = reason
						else
							local id = path:gsub("%.%w+$", ""):gsub("[^%w]+", "_"):sub(1, 60)
							local unique = id
							local suffix = 1

							while used_models[unique] do
								suffix = suffix + 1
								unique = id .. "_" .. suffix
							end

							used_models[unique] = true
							local directory = models_root .. unique .. "/"
							assert(fs.create_directory_recursive(directory))
							local text = model_file.Serialize{
								meshes = meshes,
								bounds = loaded.bounds,
								source = path,
								physics = loaded.physics,
								skeleton = loaded.skeleton,
							}

							for _, feature in ipairs(model_file.GetDropped(loaded)) do
								stats.dropped[feature] = (stats.dropped[feature] or 0) + 1
							end

							assert(fs.write_file(directory .. model_file.FileName, text))
							stats.models = stats.models + 1
							stats.bytes = stats.bytes + #text
							exported[path] = "./models/" .. unique .. "/" .. model_file.FileName
						end
					end

					if exported[path] then model[reference[2]] = exported[path] end
				end
			end
		end
	end

	local aliases = {}

	for material, path in pairs(material_paths) do
		if material.vmt_path then
			aliases[material.upload_cache_key] = path
		elseif material.cry_mtl_path then
			local sub = material.cry_sub_material

			if sub == nil then
				if type(aliases[material.cry_mtl_path]) ~= "table" then
					aliases[material.cry_mtl_path] = path
				end
			else
				if type(aliases[material.cry_mtl_path]) ~= "table" then
					aliases[material.cry_mtl_path] = {}
				end

				aliases[material.cry_mtl_path][sub] = path
			end
		end
	end

	assert(
		fs.write_file(
			root .. material_file.AliasFileName:match("[^/]+$"),
			codec.Encode("luadata", aliases, true)
		)
	)
	commit()
	return stats
end

return scene_export
