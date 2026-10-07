local codec = import("goluwa/codec.lua")
local vfs = import("goluwa/vfs.lua")
local xml = import("goluwa/codecs/xml.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Texture = import("goluwa/render/texture.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local bit = require("bit")
local Material = import("goluwa/render3d/material.lua")
local mtl_material = {}
local cry_mtl_document_cache = {}
local cry_mtl_material_cache = {}
local cry_texture_path_cache = {}
local SRGBTexture, LinearTexture = Material.SRGBTexture, Material.LinearTexture
local function color_is_default(color)
	return color and color.r == 1 and color.g == 1 and color.b == 1 and color.a == 1
end

local function get_cry_mtl_cache_key(path, sub_material)
	return path .. "\0" .. type(sub_material) .. ":" .. tostring(sub_material)
end

local function unpack_csv_numbers(str)
	local out = {}

	for value in tostring(str or ""):gmatch("[^,%s]+") do
		out[#out + 1] = tonumber(value) or 0
	end

	return out[1], out[2], out[3], out[4]
end

local function find_child_by_tag(node, tag)
	if not (node and node.children) then return nil end

	for i = 1, node.children.n do
		local child = node.children[i]

		if child.tag == tag then return child end
	end
end

local function iter_children_by_tag(node, tag)
	local children = node and node.children
	local index = 0
	return function()
		if not children then return nil end

		for i = index + 1, children.n do
			local child = children[i]

			if child.tag == tag then
				index = i
				return child, i
			end
		end
	end
end

local function resolve_cry_game_root(path)
	if type(path) ~= "string" then return nil end

	local normalized = file_path.FixPathSlashes(path)
	local lower = normalized:lower()
	local game_start, game_end = lower:find("/game/", 1, true)

	if game_start then return normalized:sub(1, game_end) end

	local objects_start = lower:find("/objects.pak/", 1, true)

	if objects_start then return normalized:sub(1, objects_start) end

	local textures_start = lower:find("/textures.pak/", 1, true)

	if textures_start then return normalized:sub(1, textures_start) end

	return nil
end

local function resolve_cry_texture_path(material_path, texture_path)
	if type(texture_path) ~= "string" or texture_path == "" then return nil, {} end

	local normalized = file_path.FixPathSlashes(texture_path)
	local normalized_lower = normalized:lower()

	do
		local game_start = normalized_lower:find("%f[%w]game/objects/") or
			normalized_lower:find("%f[%w]game/textures/")

		if game_start then
			normalized = normalized:sub(game_start + 5)
			normalized_lower = normalized:lower()
		end
	end

	local is_game_relative = normalized_lower:starts_with("objects/") or
		normalized_lower:starts_with("textures/") or
		normalized_lower:starts_with("languages/")
	local game_root = resolve_cry_game_root(material_path)
	local cache_key

	if file_path.IsPathAbsolutePath(normalized) then
		cache_key = "a\0" .. normalized
	elseif is_game_relative then
		cache_key = "g\0" .. (game_root or "") .. "\0" .. normalized
	else
		cache_key = "r\0" .. (
				game_root or
				""
			) .. "\0" .. (
				file_path.GetFolderFromPath(material_path) or
				""
			) .. "\0" .. normalized
	end

	local cached = cry_texture_path_cache[cache_key]

	if cached then
		return cached.resolved ~= false and cached.resolved or nil, cached.candidates
	end

	local base = file_path.RemoveExtensionFromPath(normalized)
	local candidates = {}

	local function add(path)
		if path and path ~= "" then
			candidates[#candidates + 1] = file_path.FixPathSlashes(path)
		end
	end

	local function add_pak_candidates(relative_path, relative_base)
		if not game_root then return end

		add(game_root .. relative_path)
		add(game_root .. relative_base .. ".dds")
		add(game_root .. "Objects.pak/" .. relative_path)
		add(game_root .. "Objects.pak/" .. relative_base .. ".dds")
		add(game_root .. "Textures.pak/" .. relative_path)
		add(game_root .. "Textures.pak/" .. relative_base .. ".dds")
		add(game_root .. "Localized/english.pak/" .. relative_path)
		add(game_root .. "Localized/english.pak/" .. relative_base .. ".dds")
	end

	if file_path.IsPathAbsolutePath(normalized) then
		add(normalized)
		add(base .. ".dds")
	else
		local folder = file_path.GetFolderFromPath(material_path)

		if is_game_relative then
			if not game_root then
				add(normalized)
				add(base .. ".dds")
			end

			add_pak_candidates(normalized, base)
		else
			add(folder and (folder .. normalized) or normalized)
			add(folder and (folder .. base .. ".dds") or (base .. ".dds"))

			if game_root then add_pak_candidates(normalized, base) end
		end
	end

	for _, candidate in ipairs(candidates) do
		local found = vfs.FindMixedCasePath(candidate)

		if found then
			cry_texture_path_cache[cache_key] = {resolved = found, candidates = candidates}
			return found, candidates
		end
	end

	cry_texture_path_cache[cache_key] = {resolved = false, candidates = candidates}
	return nil, candidates
end

local function get_missing_cry_texture(material_path, attrs, candidates)
	if attrs.File and attrs.File ~= "" then
		logf(
			"crytek texture not found for %q referenced by %q (map %q)\n",
			tostring(attrs.File),
			tostring(material_path),
			tostring(attrs.Map)
		)

		for _, candidate in ipairs(candidates) do
			logf("  tried %q\n", candidate)
		end
	end

	return Texture.GetFallback()
end

local GEN_MASKS = {
	Illum = {
		DETAIL_BUMP_MAPPING = 0x4000,
		GLOSS_DIFFUSEALPHA = 0x20,
		ALPHAGLOW = 0x2000,
		OFFSETBUMPMAPPING = 0x20000,
		PARALLAX_OCCLUSION_MAPPING = 0x8000000,
	},
	Metal = {DETAIL_BUMP_MAPPING = 0x8000, ALPHAGLOW = 0x20, OFFSETBUMPMAPPING = 0x4000},
	["Terrain.Layer"] = {OFFSETBUMPMAPPING = 0x1000, PARALLAX_OCCLUSION_MAPPING = 0x8000000},
	Cloth = {DETAIL_BUMP_MAPPING = 0x40000},
	Vegetation = {
		DETAIL_BUMP_MAPPING = 0x20000,
		LEAVES = 0x100,
		GRASS = 0x2000,
		TERRAINHEIGHTADAPTION = 0x4000,
		DETAIL_BENDING = 0x10000,
	},
}
local MTL_FLAG_2SIDED = 0x2
local MTL_FLAG_NODRAW = 0x400
local cry_height_texture_cache = {}

local function get_cry_height_texture(normal_map_path)
	local cached = cry_height_texture_cache[normal_map_path]

	if cached ~= nil then return cached or nil end

	local attached = codec.DecodeFile(normal_map_path, "dds").attached_image
	local texture = attached and Texture.New{decoded = attached, srgb = false} or false
	cry_height_texture_cache[normal_map_path] = texture
	return texture or nil
end

local function apply_cry_material_node(self, material_node, material_path)
	local attrs = material_node.attrs or {}
	local shader = attrs.Shader or ""
	local gen_mask = tonumber(attrs.GenMask) or 0
	local shader_masks = GEN_MASKS[shader] or {}
	local mtl_flags = tonumber(attrs.MtlFlags) or 0

	local function has_gen(name)
		return shader_masks[name] ~= nil and bit.band(gen_mask, shader_masks[name]) ~= 0
	end

	self.cry_texture_maps = {}
	self.cry_public_params = {}

	do
		local lines = {"path: " .. tostring(material_path), "shader: " .. shader}
		local keys = {}

		for key in pairs(attrs) do
			keys[#keys + 1] = key
		end

		table.sort(keys)

		for _, key in ipairs(keys) do
			lines[#lines + 1] = key .. " = " .. tostring(attrs[key])
		end

		self:SetOriginalMaterial(table.concat(lines, "\n"))
	end

	do
		local public_params = find_child_by_tag(material_node, "PublicParams")

		if public_params and public_params.attrs then
			for key, value in pairs(public_params.attrs) do
				self.cry_public_params[key] = value
			end
		end
	end

	local params = self.cry_public_params

	do
		local r, g, b = unpack_csv_numbers(attrs.Specular)
		self.cry_specular_color = Color(r or 0, g or 0, b or 0, 1)
	end

	if shader:lower() == "nodraw" or bit.band(mtl_flags, MTL_FLAG_NODRAW) ~= 0 then
		self:SetNoDraw(true)
		return self
	end

	self:SetMetallicMultiplier(0)

	do
		local specular = self.cry_specular_color
		local roughness = 2 / ((tonumber(attrs.Shininess) or 0) + 2)
		self:SetRoughnessMultiplier(roughness ^ 0.25)
		self:SetSpecularMultiplier((specular.r * 0.2126 + specular.g * 0.7152 + specular.b * 0.0722) * roughness / 0.04)
		self:SetAlbedoAlphaIsSpecular(has_gen("GLOSS_DIFFUSEALPHA"))
		self:SetGlossIsShininess(true)
		self:SetSpecularSolvesMetallic(shader == "Metal" or (attrs.SurfaceType or ""):find("metal", 1, true) ~= nil)
	end

	local alpha_test = tonumber(attrs.AlphaTest) or 0
	local opacity = tonumber(attrs.Opacity) or 1

	do
		local r, g, b = unpack_csv_numbers(attrs.Diffuse)
		self:SetColorMultiplier(Color(r or 1, g or 1, b or 1, alpha_test > 0 and 1 or opacity))
	end

	if alpha_test > 0 then
		self:SetAlphaTest(true)
		self:SetAlphaCutoff(alpha_test)
	elseif opacity < 1 or shader == "Glass" then
		self:SetTranslucent(true)
	end

	local leaves = has_gen("LEAVES") or has_gen("GRASS")
	self:SetDoubleSided(leaves or bit.band(mtl_flags, MTL_FLAG_2SIDED) ~= 0)

	if shader == "Vegetation" then
		self:SetBending(1)

		if has_gen("DETAIL_BENDING") then
			if has_gen("GRASS") then
				self:SetDetailBending("grass")
			elseif has_gen("LEAVES") then
				self:SetDetailBending("leaves")
			end
		end

		self:SetBendDetailFrequency(tonumber(params.bendDetailFrequency) or 5)
		self:SetBendDetailLeafAmplitude(tonumber(params.bendDetailLeafAmplitude) or 0.08)
		self:SetBendDetailBranchAmplitude(tonumber(params.bendDetailBranchAmplitude) or 0.2)
		self:SetBendDetailPhase(tonumber(params.bendDetailPhase) or 100)
	end

	if has_gen("GRASS") then
		self:SetGroundColorBlend(tonumber(params.blendWithTerrainAmount) or 0.5)
	end

	if leaves then
		local r, g, b = unpack_csv_numbers(params.BackDiffuse)
		local multiplier = tonumber(params.BackDiffuseMultiplier) or 1
		r, g, b = (r or 1) * multiplier, (g or 1) * multiplier, (b or 1) * multiplier
		local ratio = r * 0.2126 + g * 0.7152 + b * 0.0722

		if ratio > 0 then
			self:SetDiffuseTransmission(ratio / (1 + ratio))
			self:SetTransmissionColor(Color(r, g, b, 1))
		end

		self:SetTransmissionScattering(math.clamp(tonumber(params.BackViewDep) or 0.5, 0, 1))
	end

	local detail_bump_mapping = has_gen("DETAIL_BUMP_MAPPING")

	if detail_bump_mapping then
		self:SetDetailTiling(
			Vec2(
				tonumber(params.DetailBumpTillingU) or 1,
				tonumber(params.DetailBumpTillingV) or 1
			)
		)
		self:SetDetailBumpScale(tonumber(params.DetailBumpScale) or 1)
		self:SetDetailBlendAmount(tonumber(params.DetailBlendAmount) or 0)
	end

	local height_scale = 0

	if has_gen("PARALLAX_OCCLUSION_MAPPING") then
		height_scale = tonumber(params.PomDisplacement) or 0.025
	elseif has_gen("OFFSETBUMPMAPPING") then
		if shader == "Metal" then
			height_scale = 2 * (tonumber(params.Displacement) or 0.025)
		else
			height_scale = 2 * (tonumber(params.ObmDisplacement) or 0.004)
		end
	end

	local textures = find_child_by_tag(material_node, "Textures")

	for texture_node in iter_children_by_tag(textures, "Texture") do
		local texture_attrs = texture_node.attrs or {}
		local resolved, candidates = resolve_cry_texture_path(material_path, texture_attrs.File)
		local tex_mod = find_child_by_tag(texture_node, "TexMod")
		local tex_mod_attrs = tex_mod and tex_mod.attrs or {}
		local map_name = texture_attrs.Map

		if map_name and map_name ~= "" then
			self.cry_texture_maps[map_name] = {
				file = texture_attrs.File,
				resolved = resolved,
				tile_u = tonumber(tex_mod_attrs.TileU) or 1,
				tile_v = tonumber(tex_mod_attrs.TileV) or 1,
				offset_u = tonumber(tex_mod_attrs.OffsetU) or 0,
				offset_v = tonumber(tex_mod_attrs.OffsetV) or 0,
			}
		end

		if map_name == "Diffuse" then
			self:SetAlbedoTexture(
				resolved and
					SRGBTexture(resolved) or
					get_missing_cry_texture(material_path, texture_attrs, candidates)
			)
		elseif map_name == "Normalmap" or map_name == "Bumpmap" then
			self:SetNormalTexture(
				resolved and
					LinearTexture(resolved) or
					get_missing_cry_texture(material_path, texture_attrs, candidates)
			)
			local height_texture = height_scale > 0 and resolved and get_cry_height_texture(resolved)

			if height_texture then
				self:SetHeightTexture(height_texture)
				self:SetHeightScale(height_scale)
			end
		elseif map_name == "Specular" then
			self:SetSpecularTexture(
				resolved and
					SRGBTexture(resolved) or
					get_missing_cry_texture(material_path, texture_attrs, candidates)
			)
		elseif map_name == "Detail" and detail_bump_mapping then
			self:SetDetailTexture(
				resolved and
					LinearTexture(resolved) or
					get_missing_cry_texture(material_path, texture_attrs, candidates)
			)
		elseif map_name == "Opacity" and leaves then
			self:SetTransmissionTexture(
				resolved and
					LinearTexture(resolved) or
					get_missing_cry_texture(material_path, texture_attrs, candidates)
			)
		end
	end

	do
		local glow = tonumber(attrs.GlowAmount) or 0

		if has_gen("ALPHAGLOW") then
			glow = glow + (tonumber(params.AmbientMultiplier) or 1)
		end

		if glow > 0 then
			self:SetEmissiveMultiplier(Color(1, 1, 1, glow))

			if self.AlphaTest then
				self:SetEmissiveTexture(self.AlbedoTexture)
			else
				self:SetAlbedoAlphaIsEmissive(true)
			end
		end
	end

	return self
end


local function load_cry_mtl_document(path)
	local document = cry_mtl_document_cache[path]

	if document == nil then
		local data, err = vfs.Read(path)

		if not data then return nil, err or ("unable to read cry mtl " .. path) end

		local ok
		ok, document = pcall(xml.Decode, data)

		if not ok or not document or not document.children or not document.children[1] then
			document = false
		end

		cry_mtl_document_cache[path] = document
	end

	if document == false then return nil, "unable to parse cry mtl " .. path end

	return document
end

function mtl_material.FromCryMTL(path, sub_material)
	local cache_key = get_cry_mtl_cache_key(path, sub_material)
	local cached_material = cry_mtl_material_cache[cache_key]

	if cached_material then
		Material.RecordCacheRequest("crymtl", cache_key, cached_material)
		return cached_material
	end

	local self = Material.New()
	self:SetName(path .. (sub_material and ("/" .. sub_material) or ""))
	self.cry_mtl_path = path
	self.upload_cache_key = cache_key
	cry_mtl_material_cache[cache_key] = self
	local document, err = load_cry_mtl_document(path)

	if not document then
		self:SetError(err)
		return self
	end

	local root = document.children[1]
	local sub_materials = find_child_by_tag(root, "SubMaterials")
	local material_node = root

	if sub_material ~= nil and sub_materials then
		material_node = nil
		local index = 0

		for child in iter_children_by_tag(sub_materials, "Material") do
			if
				(
					type(sub_material) == "number" and
					index == sub_material
				)
				or
				(
					child.attrs and
					child.attrs.Name == sub_material
				)
			then
				material_node = child

				break
			end

			index = index + 1
		end
	end

	if not material_node then
		self:SetError("sub material " .. tostring(sub_material) .. " not found in cry mtl " .. path)
		return self
	end

	if material_node.attrs and material_node.attrs.Name then
		self.cry_sub_material_name = material_node.attrs.Name
	end

	apply_cry_material_node(self, material_node, path)
	Material.RecordCacheRequest("crymtl", cache_key, self)
	return self
end

function mtl_material.FromCryMTLSlots(path)
	local document, err = load_cry_mtl_document(path)

	if not document then return nil, err end

	if not find_child_by_tag(document.children[1], "SubMaterials") then
		return nil
	end

	return setmetatable(
		{},
		{
			__index = function(slots, slot)
				if slot == nil then return nil end

				slots[slot] = mtl_material.FromCryMTL(path, slot)
				return slots[slot]
			end,
		}
	)
end

function mtl_material.FromCryMTLList(path)
	local document = load_cry_mtl_document(path)
	local sub_materials = document and find_child_by_tag(document.children[1], "SubMaterials")

	if not sub_materials then return {mtl_material.FromCryMTL(path)} end

	local out = {}

	for _ in iter_children_by_tag(sub_materials, "Material") do
		out[#out + 1] = mtl_material.FromCryMTL(path, #out)
	end

	return out
end

Material.RegisterOverrideLoader(".mtl", function(path)
	local slots = mtl_material.FromCryMTLSlots(path)

	return slots, not slots and mtl_material.FromCryMTL(path) or nil
end)

function mtl_material.CryMTLHasGenFlag(path, name)
	local document = load_cry_mtl_document(path)

	if not document then return false end

	local stack = {document.children[1]}

	while stack[1] do
		local node = table.remove(stack)
		local attrs = node.attrs or {}
		local mask = (GEN_MASKS[attrs.Shader or ""] or {})[name]

		if mask and bit.band(tonumber(attrs.GenMask) or 0, mask) ~= 0 then
			return true
		end

		for child in iter_children_by_tag(find_child_by_tag(node, "SubMaterials"), "Material") do
			stack[#stack + 1] = child
		end
	end

	return false
end


return mtl_material
