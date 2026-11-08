local T = import("test/environment.lua")
local ffi = require("ffi")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local Texture = import("goluwa/render/texture.lua")
local HeightmapSource = import("goluwa/terrain/heightmap_source.lua")
local heightmap_file = import("goluwa/terrain/heightmap_file.lua")
local DIRECTORY = vfs.GetStorageDirectory("storage") .. "cache/test_heightmap_file/"
local COPY_DIRECTORY = vfs.GetStorageDirectory("storage") .. "cache/test_heightmap_file_copy/"
local LAYER_SOURCE = "storage/cache/test_heightmap_layer.dds"

local function make_data()
	local samples = ffi.new("uint16_t[?]", 16 * 16)

	for i = 0, 255 do
		samples[i] = i * 256
	end

	local indices = ffi.new("uint8_t[?]", 8 * 8)

	for i = 0, 63 do
		indices[i] = i % 3
	end

	local pixels = ffi.new("uint8_t[?]", 16 * 16 * 4)
	ffi.fill(pixels, 16 * 16 * 4, 120)
	return {
		size = 512,
		origin = {0, 0},
		uv = {0, -1, 1, 0},
		outside = "zero",
		max_height = 100,
		height = {width = 16, height = 16, samples = samples},
		color = Texture.New{buffer = pixels, width = 16, height = 16, format = "r8g8b8a8_srgb", srgb = true},
		indices = {width = 8, height = 8, samples = indices},
		layers = {
			[2] = {
				albedo = Texture.New{path = LAYER_SOURCE, srgb = false},
				height_scale = 0.25,
				scale = 3,
				detail = 1,
				additive_detail = 0.5,
				specular = 1,
				scatter = 0,
				roughness = 1,
			},
		},
	}
end

T.Test3D("heightmap source samples heights in the map orientation", function()
	local data = make_data()
	T(HeightmapSource.SampleHeight(data, 0, 0))["=="](0)
	T(HeightmapSource.SampleHeight(data, -1000, 5))["=="](0)
	T(
		math.abs(HeightmapSource.SampleHeight(data, 256, -256) - (8 * 16 + 8) * 256 / 65535 * 100) < 0.5
	)["=="](true)
end)

T.Test3D("heightmap source moves with its origin and follows the outside policy", function()
	local data = make_data()
	local inside = HeightmapSource.SampleHeight(data, 256, -256)
	data.origin = {1000, 2000}
	T(HeightmapSource.SampleHeight(data, 1256, 1744))["=="](inside)
	T(HeightmapSource.SampleHeight(data, 256, -256))["=="](0)
	data.outside = "clamp"
	T(
		HeightmapSource.SampleHeight(data, 1000 - 80, 2000) == HeightmapSource.SampleHeight(data, 1000, 2000)
	)["=="](true)
	T(HeightmapSource.SampleHeight(data, 1000 - 80, 2000) == 0)["=="](true)
	local corner = HeightmapSource.SampleHeight(data, 1000 + 512 + 80, 2000 - 512 - 80)
	T(corner == HeightmapSource.SampleHeight(data, 1000 + 512, 2000 - 512))["=="](true)
	T(corner > 90)["=="](true)
	data.outside = 7.5
	T(HeightmapSource.SampleHeight(data, 0, 0))["=="](7.5)
end)

T.Test3D("heightmap file round trips the maps and the layers", function()
	assert(fs.write_file(LAYER_SOURCE, "not really a dds"))
	local data = make_data()
	fs.remove_directory_recursive(DIRECTORY)
	heightmap_file.Save(DIRECTORY, data)

	for _, name in ipairs{"terrain.lua", "height.r16", "indices.r8", "color.dds"} do
		T(fs.exists(DIRECTORY .. name))["=="](true)
	end

	local loaded = heightmap_file.Load(DIRECTORY .. heightmap_file.FileName)
	T(loaded.size)["=="](512)
	T(loaded.max_height)["=="](100)
	T(loaded.uv[2])["=="](-1)
	T(loaded.origin[1])["=="](0)
	T(loaded.outside)["=="]("zero")
	T(loaded.height.width)["=="](16)

	for i = 0, 255 do
		T(loaded.height.samples[i])["=="](data.height.samples[i])
	end

	for i = 0, 63 do
		T(loaded.indices.samples[i])["=="](data.indices.samples[i])
	end

	T(loaded.color.config.path)["=="](DIRECTORY .. "color.dds")
	T(loaded.color.config.srgb)["=="](true)
	T(loaded.layers[2].height_scale)["=="](0.25)
	T(loaded.layers[2].scale)["=="](3)
	T(loaded.layers[2].albedo.config.path)["=="](LAYER_SOURCE)
	T(loaded.layers[1])["=="](nil)
	T(HeightmapSource.SampleHeight(loaded, 256, -256))["=="](HeightmapSource.SampleHeight(data, 256, -256))
	fs.remove_directory_recursive(DIRECTORY)
	fs.remove_file(LAYER_SOURCE)
end)

T.Test3D("heightmap file copies the layer textures next to itself when asked", function()
	assert(fs.write_file(LAYER_SOURCE, "not really a dds"))
	local data = make_data()
	fs.remove_directory_recursive(COPY_DIRECTORY)
	heightmap_file.Save(COPY_DIRECTORY, data, {textures = true})
	T(fs.exists(COPY_DIRECTORY .. "layer2_albedo_test_heightmap_layer.dds"))["=="](true)
	local loaded = heightmap_file.Load(COPY_DIRECTORY .. heightmap_file.FileName)
	T(loaded.layers[2].albedo.config.path)["=="](COPY_DIRECTORY .. "layer2_albedo_test_heightmap_layer.dds")
	fs.remove_directory_recursive(COPY_DIRECTORY)
	fs.remove_file(LAYER_SOURCE)
end)

T.Test3D("heightmap file keeps the origin and the outside policy and refuses another version", function()
	local data = make_data()
	data.origin = {10, -20}
	data.outside = 3.5
	local directory = vfs.GetStorageDirectory("storage") .. "cache/test_heightmap_file_policy/"
	fs.remove_directory_recursive(directory)
	heightmap_file.Save(directory, data)
	local loaded = heightmap_file.Load(directory .. heightmap_file.FileName)
	T(loaded.origin[1])["=="](10)
	T(loaded.origin[2])["=="](-20)
	T(loaded.outside)["=="](3.5)
	local text = assert(fs.read_file(directory .. heightmap_file.FileName))
	assert(
		fs.write_file(directory .. heightmap_file.FileName, (text:gsub("version = %d+", "version = 1")))
	)
	T(pcall(heightmap_file.Load, directory .. heightmap_file.FileName))["=="](false)
	fs.remove_directory_recursive(directory)
end)
