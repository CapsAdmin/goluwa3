local codec = import("goluwa/codec.lua")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local objects = import("goluwa/objects/objects.lua")
local Texture = import("goluwa/render/texture.lua")
local Material = import("goluwa/render3d/material.lua")
local event = import("goluwa/event.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local material_file = {}
material_file.Extension = ".mat"
material_file.FileName = "material.mat"
material_file.TextureFiles = {
	Albedo = "albedo.dds",
	Normal = "normal.dds",
	MetallicRoughness = "metallicroughness.dds",
	Emissive = "emissive.dds",
	Albedo2 = "albedo2.dds",
	Normal2 = "normal2.dds",
	MetallicRoughness2 = "metallicroughness2.dds",
}
material_file.SRGBSlots = {Albedo = true, Albedo2 = true, Emissive = true}
local SKIPPED_PROPERTIES = {Name = true, OriginalMaterial = true}
-- an object valued property is written as a reference table and rebuilt on load. to_reference
-- returns nil for an object that has none (it is listed in Meta.unserialized), from_reference gets
-- the context of the file being loaded
local reference_types = {}
material_file.ReferenceTypes = reference_types

function material_file.RegisterReferenceType(type, to_reference, from_reference)
	reference_types[type] = {to_reference = to_reference, from_reference = from_reference}
end

-- a name in the material's own directory wins over the same name looked up globally. One cached
-- directory listing answers every texture of the material, no per file probing.
material_file.RegisterReferenceType("render_texture", function(texture, context)
	if texture == Texture.GetFallback() then return {fallback = true} end

	local path = context.relative_paths and context.relative_paths[texture] or texture.config.path

	if not path then return nil end

	return {
		path = path:starts_with(context.directory) and path:sub(#context.directory + 1) or path,
		srgb = texture.config.srgb or false,
	}
end, function(reference, context)
	if reference.fallback then return Texture.GetFallback() end

	local path = reference.path

	if path:starts_with("../") or path:starts_with("./") then
		path = file_path.Normalize(context.directory .. path)
	elseif context.listing[path] then
		path = context.directory .. path
	end

	return Texture.New{path = path, srgb = reference.srgb}
end)

material_file.RegisterReferenceType("render3d_scatter_set", function(set)
	if set.Name == "" or ScatterSet.Get(set.Name) ~= set then return nil end

	return {name = set.Name}
end, function(reference)
	return assert(ScatterSet.Get(reference.name), "unknown scatter set " .. reference.name)
end)

-- The material as it is: every property that differs from its default under its own name, so the
-- file reads like a Material config. A texture is written as a reference {path, srgb} with the
-- path relative to the file's directory when it lives there; a texture without a path and
-- anything luadata cannot carry (a scatter set) is listed in Meta.unserialized, never dropped
-- silently. relative_paths maps a texture object to the file it was loaded from when its config
-- has no path (textures made from decoded data). Meta holds what is known for investigation.
function material_file.Serialize(material, directory, meta, relative_paths)
	local out, unserialized = {}, {}
	local context = {directory = directory, relative_paths = relative_paths}

	for _, info in ipairs(objects.GetStorableVariables(material)) do
		if not SKIPPED_PROPERTIES[info.var_name] then
			local value = material[info.get_name](material)
			local reference_type = reference_types[info.type]

			if reference_type then
				if value then
					local reference = reference_type.to_reference(value, context)

					if reference then
						out[info.var_name] = reference
					else
						unserialized[#unserialized + 1] = info.var_name
					end
				end
			elseif tostring(value) ~= tostring(info.default) then
				if type(value) == "table" then
					unserialized[#unserialized + 1] = info.var_name
				else
					out[info.var_name] = value
				end
			end
		end
	end

	meta = meta or {}
	meta.unserialized = unserialized
	out.Meta = meta
	return codec.Encode("luadata", out, true)
end

function material_file.Load(path)
	local data, err = vfs.Read(path) or fs.read_file(path)

	if not data then return nil, err end

	local file, decode_err = codec.Decode("luadata", data)

	if not file then return nil, decode_err end

	local directory = file_path.GetFolderFromPath(path) or ""
	local listing = {}

	for _, name in ipairs(vfs.GetFiles{path = directory} or {}) do
		listing[name] = true
	end

	local material = Material.New()
	material:SetName(path)
	material.mat_path = path
	material.source_meta = file.Meta and file.Meta.source
	local has_textures = false
	local context = {directory = directory, listing = listing}

	for _, info in ipairs(objects.GetStorableVariables(material)) do
		local value = file[info.var_name]
		local reference_type = reference_types[info.type]

		if reference_type and value then
			has_textures = has_textures or info.type == "render_texture"
			material[info.set_name](material, reference_type.from_reference(value, context))
		elseif value ~= nil then
			material[info.set_name](material, value)
		end
	end

	if not has_textures then
		for slot, name in pairs(material_file.TextureFiles) do
			if listing[name] then
				material["Set" .. slot .. "Texture"](
					material,
					Texture.New{path = directory .. name, srgb = material_file.SRGBSlots[slot] or false}
				)
			end
		end
	end

	return material, file
end

material_file.AliasFileName = "materials/index.lua"

event.AddListener("SceneReading", "material_file", function(directory)
	local data = fs.exists(directory .. material_file.AliasFileName) and
		fs.read_file(directory .. material_file.AliasFileName)
	local aliases = {}

	for key, target in pairs(data and assert(codec.Decode("luadata", data)) or {}) do
		if type(target) == "table" then
			aliases[key] = {}

			for slot, path in pairs(target) do
				aliases[key][slot] = directory .. path
			end
		else
			aliases[key] = directory .. target
		end
	end

	Material.path_aliases = aliases
end)

Material.RegisterOverrideLoader(".mat", function(path)
	return nil, assert(material_file.Load(path))
end)

return material_file
