local T = import("test/environment.lua")
local ffi = require("ffi")
local fs = import("goluwa/filesystem/fs.lua")
local codec = import("goluwa/codec.lua")
local Texture = import("goluwa/render/texture.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local material_bake = import("goluwa/render3d/material_bake.lua")
local material_file = import("goluwa/render3d/material_file.lua")
local DIRECTORY = "storage/cache/test_material_file/"

local function make_source()
	local pixels = ffi.new("uint8_t[?]", 16 * 16 * 4)
	ffi.fill(pixels, 16 * 16 * 4, 200)
	local material = Material.New{}
	material:SetAlbedoTexture(
		Texture.New{buffer = pixels, width = 16, height = 16, format = "r8g8b8a8_srgb", srgb = true}
	)
	return material
end

local function bake_into_directory()
	local baked = material_bake.Bake(make_source(), 16, 16)
	fs.remove_directory_recursive(DIRECTORY)
	assert(fs.create_directory_recursive(DIRECTORY))

	for slot, data in pairs(baked) do
		assert(fs.write_file(DIRECTORY .. material_file.TextureFiles[slot], data))
	end

	return baked
end

T.Test3D("material_file finds its textures next to the material and keeps its properties", function()
	bake_into_directory()
	local source = Material.New{}
	source:SetAlbedoTexture(Texture.New{path = DIRECTORY .. "albedo.dds", srgb = true})
	source:SetNormalTexture(Texture.New{path = DIRECTORY .. "normal.dds", srgb = false})
	source:SetEmissiveTexture(Texture.New{path = "not/in/this/directory.dds", srgb = true})
	source:SetAlphaTest(true)
	source:SetColorMultiplier(Color(0.5, 0.25, 1, 1))
	source:SetRoughnessMultiplier(0.4)
	source:SetMedium("ice")
	source:SetMediumDensity(2.5)
	local text = material_file.Serialize(source, DIRECTORY, {source = {engine = "test"}})
	T(text:find("^return {") ~= nil)["=="](true)
	T(text:find("path = \"albedo.dds\"", 1, true) ~= nil)["=="](true)
	assert(fs.write_file(DIRECTORY .. material_file.FileName, text))
	local material, file = material_file.Load(DIRECTORY .. material_file.FileName)
	T(material:GetAlphaTest())["=="](true)
	T(material:GetRoughnessMultiplier())["=="](0.4)
	T(material:GetColorMultiplier().g)["=="](0.25)
	T(file.Meta.source.engine)["=="]("test")
	T(material:GetMedium())["=="]("ice")
	T(material:GetMediumDensity())["=="](2.5)
	T(material:GetMediumSlot())["=="](source:GetMediumSlot())
	T(material:GetAlbedoTexture().config.path)["=="](DIRECTORY .. "albedo.dds")
	T(material:GetNormalTexture().config.path)["=="](DIRECTORY .. "normal.dds")
	T(material:GetAlbedoTexture().config.srgb)["=="](true)
	T(material:GetNormalTexture().config.srgb)["=="](false)
	T(material:GetEmissiveTexture().config.path)["=="]("not/in/this/directory.dds")
	fs.remove_directory_recursive(DIRECTORY)
end)

T.Test3D("material_file without textures takes the conventional files of its directory", function()
	bake_into_directory()
	assert(
		fs.write_file(
			DIRECTORY .. material_file.FileName,
			material_file.Serialize(Material.New{}, DIRECTORY)
		)
	)
	local material = material_file.Load(DIRECTORY .. material_file.FileName)
	T(material:GetAlbedoTexture().config.path)["=="](DIRECTORY .. "albedo.dds")
	T(material:GetNormalTexture().config.path)["=="](DIRECTORY .. "normal.dds")
	T(material:GetMetallicRoughnessTexture().config.path)["=="](DIRECTORY .. "metallicroughness.dds")
	T(material:GetEmissiveTexture())["=="](nil)
	T(material:GetAlbedo2Texture())["=="](nil)
	fs.remove_directory_recursive(DIRECTORY)
end)

T.Test3D("a baked material serializes with relative texture references and lists what it cannot carry", function()
	local material = make_source()
	material:SetDoubleSided(true)
	local baked = material_bake.Bake(material, 16, 16)
	local textures = material_bake.CreateTextures(baked)
	material_bake.Apply(material, textures)
	local relative_paths = {}

	for slot, texture in pairs(textures) do
		relative_paths[texture] = material_file.TextureFiles[slot]
	end

	material:SetScatterSet(import("goluwa/render3d/scatter_set.lua").GetGrass())
	local file = assert(
		codec.Decode("luadata", material_file.Serialize(material, DIRECTORY, {}, relative_paths))
	)
	T(file.DoubleSided)["=="](true)
	T(file.PackedSpecularScale)["=="](2)
	T(file.RoughnessMultiplier)["=="](nil)
	T(file.AlbedoTexture.path)["=="]("albedo.dds")
	T(file.AlbedoTexture.srgb)["=="](true)
	T(file.NormalTexture.path)["=="]("normal.dds")
	T(file.ScatterSet.name)["=="]("grass")
	T(#file.Meta.unserialized)["=="](0)
	local ScatterSet = import("goluwa/render3d/scatter_set.lua")
	material:SetScatterSet(ScatterSet.New{Prototypes = ScatterSet.GetGrass().Prototypes})
	file = assert(
		codec.Decode("luadata", material_file.Serialize(material, DIRECTORY, {}, relative_paths))
	)
	T(file.ScatterSet)["=="](nil)
	T(file.Meta.unserialized[1])["=="]("ScatterSet")
end)

T.Test3D("material_file gives a material its scatter set back by name", function()
	local ScatterSet = import("goluwa/render3d/scatter_set.lua")
	fs.remove_directory_recursive(DIRECTORY)
	assert(fs.create_directory_recursive(DIRECTORY))
	local source = Material.New{}
	source:SetScatterSet(ScatterSet.GetGrass())
	source:SetScatterDensity(0.5)
	assert(
		fs.write_file(DIRECTORY .. material_file.FileName, material_file.Serialize(source, DIRECTORY))
	)
	local material = material_file.Load(DIRECTORY .. material_file.FileName)
	T(material:GetScatterSet() == ScatterSet.GetGrass())["=="](true)
	T(material:GetScatterDensity())["=="](0.5)
	assert(
		fs.write_file(
			DIRECTORY .. material_file.FileName,
			"return {ScatterSet = {name = \"no_such_set\"}}"
		)
	)
	T(pcall(material_file.Load, DIRECTORY .. material_file.FileName))["=="](false)
	fs.remove_directory_recursive(DIRECTORY)
end)
