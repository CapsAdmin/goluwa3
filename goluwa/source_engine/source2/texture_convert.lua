local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local crypto = import("goluwa/crypto.lua")
local codec = import("goluwa/codec.lua")
local tasks = import("goluwa/tasks.lua")
local Texture = import("goluwa/render/texture.lua")
local texture_compress = import("goluwa/render/texture_compress.lua")
local vtex_c = import("goluwa/codecs/vtex_c.lua")
local texture_convert = {}
texture_convert.CacheDirectory = "storage/cache/source2_textures/"
local EDITS = {
	normal = [[
		vec4 edit(ivec2 position, ivec2 size, vec4 texel) {
			vec2 t = vec2(texel.r + texel.g - 1.003922, texel.r - texel.g);
			vec3 n = normalize(vec3(t, 1.0 - abs(t.x) - abs(t.y)));
			n.y = -n.y;
			return vec4(n.xy * 0.5 + 0.5, 0.0, texel.b);
		}
	]],
	detail_normal = [[
		vec4 edit(ivec2 position, ivec2 size, vec4 texel) {
			vec2 t = vec2(texel.r + texel.g - 1.003922, texel.r - texel.g);
			vec3 n = normalize(vec3(t, 1.0 - abs(t.x) - abs(t.y)));
			n.y = -n.y;
			return vec4(n.xy * 0.5 + 0.5, 0.0, 1.0);
		}
	]],
	tint_mask = [[
		vec4 edit(ivec2 position, ivec2 size, vec4 texel) {
			ivec2 mask_size = source_size(1);
			return vec4(texel.rgb, fetch(1, position * mask_size / size).r);
		}
	]],
	channel = "vec4 edit(ivec2 position, ivec2 size, vec4 texel) { return texel; }",
	blend_mask = "vec4 edit(ivec2 position, ivec2 size, vec4 texel) { return vec4(0.1, texel.r, 0.0, 0.0); }",
}
local CONFIGS = {
	normal = {format = "bc7", kind = "linear"},
	detail_normal = {format = "bc7", kind = "linear"},
	tint_mask = {format = "bc7", kind = "srgb"},
	blend_mask = {format = "bc7", kind = "linear"},
	alpha = {format = "bc4", kind = "linear", channel = 3, edit = "channel"},
	green = {format = "bc4", kind = "linear", channel = 1, edit = "channel"},
}

local function convert(vtex_paths, kind, srgb)
	local config = CONFIGS[kind]
	local edit = EDITS[config.edit or kind]
	local name = vtex_paths[1]:gsub("[^%w]+", "_"):sub(-60)
	local key = table.concat(vtex_paths, "|") .. kind .. edit
	local file = texture_convert.CacheDirectory .. name .. "_" .. kind .. "_" .. crypto.CRC32(key) .. ".dds"

	if not fs.exists(file) then
		local sources, textures = {}, {}

		for i, vtex_path in ipairs(vtex_paths) do
			local data = assert(vfs.Read(vtex_path))
			local info = assert(codec.DecodeWithModule(vtex_path, data, vtex_c))
			info.vulkan_format = info.vulkan_format:gsub("_srgb", "_unorm")
			textures[i] = Texture.New{decoded = info}
			sources[i] = {texture = textures[i]}
		end

		for _, texture in ipairs(textures) do
			while not texture:IsReady() do
				tasks.Wait()
			end
		end

		local dds = texture_compress.Recompress{
			sources = sources,
			edit = edit,
			format = config.format,
			kind = config.kind,
			channel = config.channel,
		}

		for _, texture in ipairs(textures) do
			texture:Remove()
		end

		assert(fs.create_directory_recursive(texture_convert.CacheDirectory))
		assert(fs.write_file(file, dds))
	end

	return Texture.New{path = file, srgb = srgb or false}
end

-- kind: "normal" (hemi octahedron rg and roughness in b to xy and roughness in a), "alpha" or
-- "green" (that channel as a single channel metalness texture), "blend_mask", "detail_normal"
function texture_convert.Get(vtex_path, kind)
	return convert({vtex_path}, kind)
end

-- the albedo with the tint mask in its alpha, which is what the engine's BlendTintByBaseAlpha reads
function texture_convert.GetTintedAlbedo(albedo_path, mask_path)
	return convert({albedo_path, mask_path}, "tint_mask", true)
end

return texture_convert
