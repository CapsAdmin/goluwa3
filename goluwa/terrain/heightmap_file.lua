local ffi = require("ffi")
local codec = import("goluwa/codec.lua")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Texture = import("goluwa/render/texture.lua")
local texture_compress = import("goluwa/render/texture_compress.lua")
local material_file = import("goluwa/render3d/material_file.lua")
local heightmap_file = {}
heightmap_file.FileName = "terrain.lua"
heightmap_file.Version = 3
local LAYER_TEXTURES = {"albedo", "normal", "height"}
local LAYER_NUMBERS = {
	"height_scale",
	"scale",
	"detail",
	"additive_detail",
	"specular",
	"scatter",
	"roughness",
	"medium",
}
local COLOR_SAMPLER = {
	min_filter = "linear",
	mag_filter = "linear",
	wrap_s = "clamp_to_edge",
	wrap_t = "clamp_to_edge",
}

-- Writes the data of a heightmap source (see heightmap_source.lua) to a directory: terrain.lua, the
-- height samples (height.r16), the layer map (indices.r8), the color map (color.dds, bc7) and the
-- layers as texture references (a generated height texture is written as bc4). With options.textures
-- the textures of the layers are copied next to
-- the file and referenced by name, otherwise they keep their paths. directory ends with a /.
function heightmap_file.Save(directory, data, options)
	options = options or {}
	assert(fs.create_directory_recursive(directory))
	local height = data.height
	local out = {
		version = heightmap_file.Version,
		size = data.size,
		origin = data.origin,
		uv = data.uv,
		outside = data.outside,
		min_height = data.min_height,
		max_height = data.max_height,
		height = {width = height.width, height = height.height, file = "height.r16"},
	}
	assert(
		fs.write_file(
			directory .. "height.r16",
			ffi.string(height.samples, height.width * height.height * 2)
		)
	)

	if data.indices then
		local indices = data.indices
		out.indices = {width = indices.width, height = indices.height, file = "indices.r8"}
		assert(
			fs.write_file(
				directory .. "indices.r8",
				ffi.string(indices.samples, indices.width * indices.height)
			)
		)
	end

	out.color = {file = "color.dds"}
	assert(
		fs.write_file(
			directory .. "color.dds",
			texture_compress.Recompress{
				sources = {{texture = data.color}},
				edit = "vec4 edit(ivec2 position, ivec2 size, vec4 texel) { return vec4(from_linear(texel.rgb), texel.a); }",
				format = "bc7",
				kind = "srgb",
			}
		)
	)
	out.layers = {}
	local reference = material_file.ReferenceTypes.render_texture.to_reference

	for id, layer in pairs(data.layers or {}) do
		local entry = {}
		local relative_paths = {}

		for _, name in ipairs(LAYER_TEXTURES) do
			local texture = layer[name]

			if texture then
				local path = texture.config.path

				if path and options.textures then
					local copied = "layer" .. id .. "_" .. name .. "_" .. file_path.GetFileNameFromPath(path)
					assert(fs.write_file(directory .. copied, assert(vfs.Read(path) or fs.read_file(path))))
					relative_paths[texture] = copied
				elseif not path then
					assert(name == "height", "only a layer height texture can be generated")
					local generated = "layer" .. id .. "_height.dds"
					assert(
						fs.write_file(
							directory .. generated,
							texture_compress.Recompress{sources = {{texture = texture}}, format = "bc4", kind = "linear"}
						)
					)
					relative_paths[texture] = generated
				end

				entry[name] = assert(reference(texture, {directory = directory, relative_paths = relative_paths}))
			end
		end

		for _, name in ipairs(LAYER_NUMBERS) do
			entry[name] = layer[name]
		end

		out.layers[id] = entry
	end

	assert(
		fs.write_file(directory .. heightmap_file.FileName, codec.Encode("luadata", out, true))
	)
end

-- Reads what Save wrote. The color map is a texture that loads from its file, wait for IsReady
-- before the terrain is baked from it.
function heightmap_file.Load(path)
	local directory = file_path.GetFolderFromPath(path) or ""
	local file = assert(codec.Decode("luadata", assert(vfs.Read(path) or fs.read_file(path))))
	assert(
		file.version == heightmap_file.Version,
		"unsupported terrain file version " .. tostring(file.version)
	)
	local width, height = file.height.width, file.height.height
	local samples = ffi.new("uint16_t[?]", width * height)
	local bytes = assert(
		vfs.Read(directory .. file.height.file) or
			fs.read_file(directory .. file.height.file)
	)
	ffi.copy(samples, bytes, width * height * 2)
	local data = {
		size = file.size,
		origin = file.origin,
		uv = file.uv,
		outside = file.outside,
		min_height = file.min_height,
		max_height = file.max_height,
		height = {width = width, height = height, samples = samples},
		color = Texture.New{
			path = directory .. file.color.file,
			srgb = true,
			sampler = COLOR_SAMPLER,
		},
		layers = {},
	}

	if file.indices then
		local count = file.indices.width * file.indices.height
		local indices = ffi.new("uint8_t[?]", count)
		local index_bytes = assert(
			vfs.Read(directory .. file.indices.file) or
				fs.read_file(directory .. file.indices.file)
		)
		ffi.copy(indices, index_bytes, count)
		data.indices = {width = file.indices.width, height = file.indices.height, samples = indices}
	end

	local listing = {}

	for _, name in ipairs(vfs.GetFiles{path = directory} or {}) do
		listing[name] = true
	end

	local from_reference = material_file.ReferenceTypes.render_texture.from_reference

	for id, entry in pairs(file.layers) do
		local layer = {}

		for _, name in ipairs(LAYER_TEXTURES) do
			if entry[name] then
				layer[name] = from_reference(entry[name], {directory = directory, listing = listing})
			end
		end

		for _, name in ipairs(LAYER_NUMBERS) do
			layer[name] = entry[name]
		end

		data.layers[id] = layer
	end

	return data
end

return heightmap_file
