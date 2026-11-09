local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local crypto = import("goluwa/crypto.lua")
local codec = import("goluwa/codec.lua")
local tasks = import("goluwa/tasks.lua")
local Texture = import("goluwa/render/texture.lua")
local texture_compress = import("goluwa/render/texture_compress.lua")
local thread_pool = import("goluwa/thread_pool.lua")
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
local MAX_PENDING = 24
local pending = {}
local pending_count = 0

local function get_cache_file(vtex_paths, kind)
	local edit = EDITS[CONFIGS[kind].edit or kind]
	local name = vtex_paths[1]:gsub("[^%w]+", "_"):sub(-60)
	return texture_convert.CacheDirectory .. name .. "_" .. kind .. "_" .. crypto.CRC32(table.concat(vtex_paths, "|") .. kind .. edit) .. ".dds"
end

local function start_decode(vtex_path)
	local data = assert(vfs.Read(vtex_path))
	local entry = {job = thread_pool.Run(vtex_c.thread_job, data, #data)}
	pending[vtex_path] = entry
	pending_count = pending_count + 1
	return entry
end

local function take_decode(vtex_path)
	local entry = pending[vtex_path] or start_decode(vtex_path)
	pending[vtex_path] = nil
	pending_count = pending_count - 1
	-- a task wait here lets whole frames render between the conversion's gpu submits
	entry.job:Block()
	assert(not entry.job.err, entry.job.err)
	return assert(codec.AttachBlob(entry.job.meta, entry.job.blob))
end

-- starts decoding the sources of a conversion on the worker threads so that convert finds them done
function texture_convert.Prefetch(vtex_paths, kind)
	if fs.exists(get_cache_file(vtex_paths, kind)) then return end

	for _, vtex_path in ipairs(vtex_paths) do
		if pending_count >= MAX_PENDING then return end

		if not pending[vtex_path] then start_decode(vtex_path) end
	end
end

local function convert(vtex_paths, kind, srgb)
	local config = CONFIGS[kind]
	local file = get_cache_file(vtex_paths, kind)

	if not fs.exists(file) then
		local sources, textures = {}, {}

		for i, vtex_path in ipairs(vtex_paths) do
			local info = take_decode(vtex_path)
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
			edit = EDITS[config.edit or kind],
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
