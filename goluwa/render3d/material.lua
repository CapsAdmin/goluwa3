local ffi = require("ffi")
local commands = import("goluwa/commands.lua")
local tasks = import("goluwa/tasks.lua")
local Texture = import("goluwa/render/texture.lua")
local Color = import("goluwa/structs/color.lua")
local prototype = import("goluwa/prototype.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Material = prototype.CreateTemplate("render3d_material")
-- textures
Material:StartStorable()
Material:GetSet("AlbedoTexture", nil, {type = "render_texture"})
Material:GetSet("NormalTexture", nil, {type = "render_texture"})
Material:GetSet("HeightTexture", nil, {type = "render_texture"})
Material:GetSet("MetallicRoughnessTexture", nil, {type = "render_texture"})
Material:GetSet("AmbientOcclusionTexture", nil, {type = "render_texture"})
Material:GetSet("EmissiveTexture", nil, {type = "render_texture"})
Material:GetSet("Albedo2Texture", nil, {type = "render_texture"})
Material:GetSet("Normal2Texture", nil, {type = "render_texture"})
Material:GetSet("BlendTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainMaterialTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer1Texture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer2Texture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer3Texture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer4Texture", nil, {type = "render_texture"})
Material:GetSet("MetallicTexture", nil, {type = "render_texture"})
Material:GetSet("RoughnessTexture", nil, {type = "render_texture"})
Material:GetSet("OpacityTexture", nil, {type = "render_texture"})
-- multipliers
Material:GetSet("ColorMultiplier", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("EmissiveMultiplier", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainCheckerScales", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayer1ColorA", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayer1ColorB", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayer2ColorA", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayer2ColorB", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayer3ColorA", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayer3ColorB", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayer4ColorA", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayer4ColorB", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayerDetailStrength", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayerRoughness", Color(0.9, 0.8, 0.7, 0.5))
Material:GetSet("TerrainLayerAmbientOcclusion", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("MetallicMultiplier", 1.0)
Material:GetSet("RoughnessMultiplier", 1.0)
Material:GetSet("NormalMapMultiplier", 1.0)
Material:GetSet("AmbientOcclusionMultiplier", 1.0)
Material:GetSet("HeightScale", 0.0)
Material:GetSet("HeightCenter", 0.0)
Material:GetSet("HeightLayers", 24)
Material:GetSet("TessellationFactor", 1.0)
Material:GetSet("TransmissionColor", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TransmissionViewDependency", 0.5)
Material:GetSet("TransmissionBlocking", 1.0)
Material:GetSet("WindAmplitude", 0.0)
Material:GetSet("WindFrequency", 1.0)
Material:GetSet("WindDetailAmplitude", 0.0)
Material:GetSet("WindDetailFrequency", 3.0)
Material:GetSet("WindPhaseScale", 0.15)
Material:GetSet("WindNormalInfluence", 0.35)
Material:GetSet("WindDirection", Vec3(1.0, 0.0, 0.35))
-- other
Material:GetSet("AlphaCutoff", 0.5)
Material:GetSet("IgnoreZ", false)
Material:GetSet("DoubleSided", false, {callback = "InvalidateFlags"})
-- flags
Material:GetSet("Flags", 0)
Material:GetSet("ReverseXZNormalMap", false, {callback = "InvalidateFlags"})
Material:GetSet("NormalTextureAlphaIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoTextureAlphaIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoLuminanceIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("BlendTintByBaseAlpha", false, {callback = "InvalidateFlags"})
Material:GetSet("MetallicTextureAlphaIsEmissive", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoAlphaIsEmissive", false, {callback = "InvalidateFlags"})
Material:GetSet("Translucent", false, {callback = "InvalidateFlags"})
Material:GetSet("AlphaTest", false, {callback = "InvalidateFlags"})
Material:GetSet("InvertRoughnessTexture", false, {callback = "InvalidateFlags"})
Material:GetSet("Subsurface", false, {callback = "InvalidateFlags"})
Material:EndStorable()

function Material.New(config)
	local self = Material:CreateObject()

	if config then
		for k, v in pairs(config) do
			if self["Set" .. k] then
				self["Set" .. k](self, v)
			else
				self[k] = v
			end
		end
	end

	return self
end

function Material:HasExplicitMetallicTexture()
	return self.MetallicTexture ~= nil and self.MetallicRoughnessTexture ~= nil
end

function Material:HasExplicitRoughnessTexture()
	if self.AlbedoTexture ~= nil and AlbedoTextureAlphaIsRoughness then
		return true
	end

	if self.NormalTexture ~= nil and NormalTextureAlphaIsRoughness then
		return true
	end

	if self.AlbedoLuminanceIsRoughness then return true end

	if self.RoughnessTexture ~= nil then return true end

	if self.MetallicRoughnessTexture ~= nil then return true end

	return false
end

-- just a shortcut for gltf
function Material:SetAlphaMode(mode)
	if mode == "MASK" then
		self:SetAlphaTest(true)
		self:SetTranslucent(false)
	elseif mode == "BLEND" then
		self:SetTranslucent(true)
		self:SetAlphaTest(false)
	else
		self:SetAlphaTest(false)
		self:SetTranslucent(false)
	end
end

local FLAGS = {
	"ReverseXZNormalMap",
	"Translucent",
	"AlphaTest",
	"BlendTintByBaseAlpha",
	"InvertRoughnessTexture",
	"NormalTextureAlphaIsRoughness",
	"AlbedoTextureAlphaIsRoughness",
	"AlbedoLuminanceIsRoughness",
	"MetallicTextureAlphaIsEmissive",
	"AlbedoAlphaIsEmissive",
	"DoubleSided",
	"Subsurface",
}

for i, flag_name in ipairs(FLAGS) do
	if not Material["Get" .. flag_name] then
		error("Material is missing flag getter: " .. flag_name)
	end
end

function Material:InvalidateFlags()
	local flags = 0

	for i, flag_name in ipairs(FLAGS) do
		if self["Get" .. flag_name](self) then
			flags = bit.bor(flags, bit.lshift(1, i - 1))
		end
	end

	self.Flags = flags
end

function Material:GetDebugFlagMap()
	local tbl = {}

	for i, flag_name in ipairs(FLAGS) do
		tbl[flag_name] = bit.band(self.Flags, bit.lshift(1, i - 1)) ~= 0
	end

	return tbl
end

function Material:GetFillFlags()
	return self.Flags
end

function Material:GetLightFlags()
	return self.Flags
end

function Material.BuildGlslFlags(var_name)
	local str = ""

	for i, flag_name in ipairs(FLAGS) do
		str = str .. "#define " .. flag_name .. " ((" .. var_name .. " & " .. tostring(bit.lshift(1, i - 1)) .. ") != 0)\n"
	end

	return str
end

do
	local steam = import("goluwa/steam/steam.lua")
	local vfs = import("goluwa/vfs.lua")
	local file_path = import("goluwa/file_path.lua")
	local xml = import("goluwa/codecs/xml.lua")
	local cry_mtl_document_cache = {}
	local cry_mtl_material_cache = {}
	local vmt_material_cache = {}
	local cry_texture_path_cache = {}
	local cry_texture_recursive_lookup_cache = {}
	local material_cache_stats = setmetatable({}, {__mode = "k"})

	local function get_cry_mtl_cache_key(path, sub_material)
		return path .. "\0" .. type(sub_material) .. ":" .. tostring(sub_material)
	end

	local function get_cry_texture_cache_key(material_path, texture_path)
		return tostring(material_path) .. "\0" .. tostring(texture_path)
	end

	local function get_vmt_cache_key(path)
		local normalized = file_path.FixPathSlashes(assert(path, "missing VMT path")):lower()

		if not normalized:starts_with("materials/") then
			normalized = "materials/" .. normalized
		end

		if not normalized:ends_with(".vmt") then normalized = normalized .. ".vmt" end

		return normalized
	end

	local function record_material_cache_request(source, cache_key, material)
		if not material then return end

		local stats = material_cache_stats[material]

		if not stats then
			stats = {
				requests = 0,
				sources = {},
				keys = {},
				key_order = {},
			}
			material_cache_stats[material] = stats
		end

		stats.requests = stats.requests + 1
		stats.sources[source] = true

		if not stats.keys[cache_key] then
			stats.keys[cache_key] = true
			stats.key_order[#stats.key_order + 1] = cache_key
		end
	end

	local function get_unique_cached_materials()
		local seen = setmetatable({}, {__mode = "k"})
		local list = {}

		for _, material in pairs(vmt_material_cache) do
			if material and not seen[material] then
				seen[material] = true
				list[#list + 1] = material
			end
		end

		for _, material in pairs(cry_mtl_material_cache) do
			if material and not seen[material] then
				seen[material] = true
				list[#list + 1] = material
			end
		end

		return list
	end

	local function color_is_default(color)
		return color and color.r == 1 and color.g == 1 and color.b == 1 and color.a == 1
	end

	local function unpack_numbers(str)
		str = str:gsub("%s+", " ")
		local t = str:split(" ")

		for k, v in ipairs(t) do
			t[k] = tonumber(v) or 0
		end

		return unpack(t)
	end

	local function unpack_csv_numbers(str)
		local out = {}

		for value in tostring(str or ""):gmatch("[^,%s]+") do
			out[#out + 1] = tonumber(value) or 0
		end

		return out[1], out[2], out[3], out[4]
	end

	local SRGBTexture = function(path)
		return Texture.New{
			path = path,
			srgb = true,
		}
	end
	local LinearTexture = function(path, config)
		config = config or {}
		config.path = path
		config.srgb = false
		return Texture.New(config)
	end
	local cry_specular_push_constant_t = ffi.typeof("int[1]")

	local function shade_cry_specular_roughness_texture(roughness_texture, source_texture)
		if not roughness_texture or not source_texture then return end

		if type(roughness_texture.Shade) ~= "function" then return end

		roughness_texture:Shade(
			[[
				vec4 spec_sample = texture(TEXTURE(cry_specular.source_tex), uv);
				float specular_level = clamp(dot(spec_sample.rgb, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
				float roughness_linear = 1.0 - specular_level * 0.5;
				float roughness_encoded = sqrt(clamp(roughness_linear, 0.0, 1.0));
				return vec4(roughness_encoded, roughness_encoded, roughness_encoded, spec_sample.a);
			]],
			{
				textures = {source_texture},
				custom_declarations = [[
					layout(push_constant, scalar) uniform CrySpecularRoughnessPush {
						int source_tex;
					} cry_specular;
				]],
				fragment_push_constants = {
					size = ffi.sizeof(cry_specular_push_constant_t),
					get_data = function(_, _, pipeline)
						return cry_specular_push_constant_t(pipeline:GetTextureIndex(source_texture))
					end,
				},
			}
		)
	end

	local function CrySpecularRoughnessTexture(path)
		local roughness_texture
		local source_texture = LinearTexture(
			path,
			{
				on_ready = function(texture)
					if roughness_texture then
						shade_cry_specular_roughness_texture(roughness_texture, texture)
					end
				end,
			}
		)

		if type(source_texture.Shade) ~= "function" then return source_texture end

		local sampler = source_texture.GetSamplerConfig and
			table.copy(source_texture:GetSamplerConfig()) or
			nil
		roughness_texture = Texture.New{
			width = math.max(source_texture:GetWidth(), 1),
			height = math.max(source_texture:GetHeight(), 1),
			format = "r8g8b8a8_unorm",
			mip_map_levels = source_texture:GetMipMapLevels() > 1 and "auto" or 1,
			image = {
				usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = sampler,
		}
		shade_cry_specular_roughness_texture(roughness_texture, source_texture)
		return roughness_texture
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
		local cache_key = get_cry_texture_cache_key(material_path, texture_path)
		local cached = cry_texture_path_cache[cache_key]

		if cached then
			return cached.resolved ~= false and cached.resolved or nil, cached.candidates
		end

		if type(texture_path) ~= "string" or texture_path == "" then return nil, {} end

		local normalized = file_path.FixPathSlashes(texture_path)
		local normalized_lower = normalized:lower()
		local base = file_path.RemoveExtensionFromPath(normalized)
		local original_basename = file_path.GetFileNameFromPath(normalized):lower()
		local basename = file_path.GetFileNameFromPath(base .. ".dds"):lower()
		local candidates = {}
		local game_root = resolve_cry_game_root(material_path)
		local is_game_relative = normalized_lower:starts_with("objects/") or
			normalized_lower:starts_with("textures/")

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
			add(game_root .. "objects.pak/" .. relative_path)
			add(game_root .. "objects.pak/" .. relative_base .. ".dds")
			add(game_root .. "Textures.pak/" .. relative_path)
			add(game_root .. "Textures.pak/" .. relative_base .. ".dds")
			add(game_root .. "textures.pak/" .. relative_path)
			add(game_root .. "textures.pak/" .. relative_base .. ".dds")
		end

		if file_path.IsPathAbsolutePath(normalized) then
			add(normalized)
			add(base .. ".dds")
		else
			local folder = file_path.GetFolderFromPath(material_path)

			if is_game_relative then
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

			if vfs.IsFile(candidate) then
				cry_texture_path_cache[cache_key] = {resolved = candidate, candidates = candidates}
				return candidate, candidates
			end
		end

		if game_root and (basename ~= "" or original_basename ~= "") then
			for _, root in ipairs{game_root .. "Objects.pak/", game_root .. "Textures.pak/"} do
				for _, recursive_name in ipairs{original_basename, basename} do
					if recursive_name ~= "" then
						local recursive_cache_key = root .. "\0" .. recursive_name
						local resolved = cry_texture_recursive_lookup_cache[recursive_cache_key]

						if resolved == nil then
							resolved = vfs.FindFileByNameRecursive(root, recursive_name) or false
							cry_texture_recursive_lookup_cache[recursive_cache_key] = resolved
						end

						if resolved ~= false then
							cry_texture_path_cache[cache_key] = {resolved = resolved, candidates = candidates}
							return resolved, candidates
						end
					end
				end
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

	local function apply_cry_material_node(self, material_node, material_path)
		if not material_node then return self end

		self.cry_texture_maps = self.cry_texture_maps or {}
		self.cry_public_params = self.cry_public_params or {}
		local is_vegetation = material_node.attrs and material_node.attrs.Shader == "Vegetation"
		self:SetMetallicMultiplier(0)

		if is_vegetation then self:SetSubsurface(true) end

		if material_node.attrs and material_node.attrs.Diffuse then
			local r, g, b = unpack_csv_numbers(material_node.attrs.Diffuse)
			self:SetColorMultiplier(Color(r, g, b, tonumber(material_node.attrs.Opacity) or 1))
		end

		if material_node.attrs then
			local alpha_test = tonumber(material_node.attrs.AlphaTest)

			if alpha_test and alpha_test > 0 then
				self:SetAlphaTest(true)
				self:SetAlphaCutoff(alpha_test)
			end
		end

		do
			local public_params = find_child_by_tag(material_node, "PublicParams")

			if public_params and public_params.attrs then
				for key, value in pairs(public_params.attrs) do
					self.cry_public_params[key] = value
				end
			end
		end

		if is_vegetation then
			local public_params = find_child_by_tag(material_node, "PublicParams")
			self:SetWindAmplitude(0.08)
			self:SetWindFrequency(0.9)
			self:SetWindDetailAmplitude(0.03)
			self:SetWindDetailFrequency(3.5)
			self:SetWindPhaseScale(0.12)
			self:SetWindNormalInfluence(0.35)
			self:SetWindDirection(Vec3(1.0, 0.0, 0.35))

			if public_params and public_params.attrs then
				local r, g, b = unpack_csv_numbers(public_params.attrs.BackDiffuse)
				local multiplier = tonumber(public_params.attrs.BackDiffuseMultiplier) or 1
				local back_view_dep = tonumber(public_params.attrs.BackViewDep)
				self:SetTransmissionColor(Color(r or 1, g or 1, b or 1, multiplier))

				if back_view_dep then self:SetTransmissionViewDependency(back_view_dep) end
			end
		end

		local textures = find_child_by_tag(material_node, "Textures")

		for texture_node in iter_children_by_tag(textures, "Texture") do
			local attrs = texture_node.attrs or {}
			local resolved, candidates = resolve_cry_texture_path(material_path, attrs.File)
			local tex_mod = find_child_by_tag(texture_node, "TexMod")
			local tex_mod_attrs = tex_mod and tex_mod.attrs or nil
			local map_name = attrs.Map
			local map_info = {
				file = attrs.File,
				resolved = resolved,
				tile_u = tex_mod_attrs and tonumber(tex_mod_attrs.TileU) or 1,
				tile_v = tex_mod_attrs and tonumber(tex_mod_attrs.TileV) or 1,
			}

			if map_name and map_name ~= "" then
				self.cry_texture_maps[map_name] = map_info
			end

			if attrs.Map == "Diffuse" then
				self:SetAlbedoTexture(
					resolved and
						SRGBTexture(resolved) or
						get_missing_cry_texture(material_path, attrs, candidates)
				)
			elseif attrs.Map == "Normalmap" then
				self:SetNormalTexture(
					resolved and
						LinearTexture(resolved) or
						get_missing_cry_texture(material_path, attrs, candidates)
				)

				if resolved then self:SetReverseXZNormalMap(true) end
			elseif attrs.Map == "Specular" then
				self:SetRoughnessTexture(
					resolved and
						CrySpecularRoughnessTexture(resolved) or
						get_missing_cry_texture(material_path, attrs, candidates)
				)
				self:SetInvertRoughnessTexture(false)
			elseif attrs.Map == "Detail" then
				self:SetNormal2Texture(
					resolved and
						LinearTexture(resolved) or
						get_missing_cry_texture(material_path, attrs, candidates)
				)
			elseif attrs.Map == "Opacity" then
				self:SetOpacityTexture(
					resolved and
						LinearTexture(resolved) or
						get_missing_cry_texture(material_path, attrs, candidates)
				)
				self:SetAlphaTest(true)

				if is_vegetation then self:SetDoubleSided(true) end
			end
		end

		return self
	end

	local function on_load_vmt(self, vmt)
		self.vmt = vmt -- store for debugging
		--self:SetReverseXZNormalMap(true) -- Source engine normals need XY flip
		self:SetInvertRoughnessTexture(true) -- Source engine normals need XY flip
		self:SetMetallicMultiplier(0)

		do -- main diffuse texture
			if vmt.basetexture then
				self:SetAlbedoTexture(SRGBTexture(vmt.basetexture))
			end

			if vmt.basetexture2 then
				self:SetAlbedo2Texture(SRGBTexture(vmt.basetexture2))
			end
		end

		do -- just a regular normal map
			if vmt.bumpmap then self:SetNormalTexture(LinearTexture(vmt.bumpmap)) end

			if vmt.bumpmap2 then self:SetNormal2Texture(LinearTexture(vmt.bumpmap2)) end

			local ssbump = vmt.ssbump == 1

			if ssbump then print("Warning: SSBump is not supported!") end
		end

		if vmt.blendmodulatetexture then
			self:SetBlendTexture(LinearTexture(vmt.blendmodulatetexture))
		end

		if vmt.blendtintbybasealpha == 1 then
			-- this should be a mask for color multiplier
			-- it allows changing the color of specific parts of the texture while keeping others unaffected
			self:SetBlendTintByBaseAlpha(true)
		end

		if vmt.texture2 then self:SetAlbedo2Texture(SRGBTexture(vmt.texture2)) end

		if vmt.envmap then -- envmap
			if vmt.envmapmask then
				self:SetRoughnessTexture(LinearTexture(vmt.envmapmask))
			end

			if vmt.normalmapalphaenvmapmask == 1 then
				self:SetNormalTextureAlphaIsRoughness(vmt.normalmapalphaenvmapmask == 1)
			end

			if vmt.basealphaenvmapmask == 1 then
				self:SetAlbedoTextureAlphaIsRoughness(vmt.basealphaenvmapmask == 1)
			end

			if false and vmt.envmaptint then
				-- maybe also set color tint?
				local val = vmt.envmaptint

				if type(val) == "string" then
					self:SetMetallicMultiplier(Vec3(unpack_numbers(val)):GetLength())
				elseif type(val) == "number" then
					self:SetMetallicMultiplier(val)
				elseif typex(val) == "vec3" then
					self:SetMetallicMultiplier(val:GetLength())
				elseif typex(val) == "color" then
					self:SetMetallicMultiplier(Vec3(val.r, val.g, val.b):GetLength())
				end
			end

			self:SetRoughnessMultiplier(0)
		end

		if vmt.phong == 1 then
			if vmt.phongexponenttexture then
				self:SetRoughnessTexture(LinearTexture(vmt.phongexponenttexture))
			end

			if vmt.basemapalphaphongmask == 1 then
				self:SetAlbedoTextureAlphaIsRoughness(true)
			elseif vmt.basemapluminancephongmask == 1 then
				self:SetAlbedoLuminanceIsRoughness(true)
			end

			-- if halflambert the model is generally brighter and more reflective?
			local halflambert = vmt.halflambert == 1
			local exponent = vmt.phongexponent or 5
			local boost = vmt.phongboost or 1
			local fresnelranges = vmt.phongfresnelranges or Vec3(0, 0.5, 1)
			-- Beckmann roughness approximation from Blinn-Phong exponent
			-- roughness ≈ sqrt(2 / (exponent + 2))
			local roughness = math.sqrt(2 / (exponent + 2))

			-- Boost affects intensity, slightly reduces apparent roughness
			if boost > 1 then roughness = roughness / math.sqrt(boost) end

			self:SetRoughnessMultiplier(math.max(0.04, math.min(1.0, roughness)))

			if vmt.invertphongmask == 1 then self:SetInvertRoughnessTexture(false) end
		end

		if vmt.selfillum == 1 then
			local tint = vmt.selfillumtint -- TODO
			self:SetAlbedoAlphaIsEmissive(true)

			if vmt.selfillummask then
				self:SetEmissiveTexture(LinearTexture(vmt.selfillummask))
				self:SetAlbedoAlphaIsEmissive(false)
			end
		end

		if vmt.selfillum_envmapmask_alpha == 1 then
			self:SetMetallicTextureAlphaIsEmissive(true)
		end

		if vmt.translucent == 1 then self:SetTranslucent(true) end

		if vmt.alphatest == 1 then self:SetAlphaTest(true) end

		if vmt.alphatestreference then
			self:SetAlphaCutoff(vmt.alphatestreference)
		end

		if vmt.nocull then self:SetDoubleSided(true) end

		-- Surface property based PBR estimation
		if vmt.surfaceprop then
			local function get_prop(prop, key)
				-- Recursively search prop and base tables for a value
				if type(prop) ~= "table" then return nil end

				if prop[key] ~= nil then return prop[key] end

				if prop.base then return get_prop(prop.base, key) end

				return nil
			end

			local name = get_prop(vmt.surfaceprop, "surfaceprop_name")

			if name then name = name:lower() end

			if not name then name = get_prop(vmt.surfaceprop, "gamematerial") end

			self.vmt_surfaceprop = name
			-- Format: { roughness, metallic }
			local surfaceprop_pbr = {
				-- Metals
				metal = {0.35, 1.0},
				metal_box = {0.4, 1.0},
				metal_barrel = {0.45, 1.0},
				metalpanel = {0.3, 1.0},
				metalvent = {0.4, 1.0},
				metalgrate = {0.5, 1.0},
				metalvehicle = {0.25, 1.0},
				metal_bouncy = {0.3, 1.0},
				solidmetal = {0.2, 1.0},
				metal_seafloorcar = {0.6, 0.8},
				chainlink = {0.5, 1.0},
				chain = {0.45, 1.0},
				weapon = {0.25, 1.0},
				grenade = {0.3, 1.0},
				crowbar = {0.3, 1.0},
				metalladder = {0.5, 1.0},
				combine_metal = {0.2, 1.0},
				combine_glass = {0.05, 0.0},
				gunship = {0.25, 1.0},
				strider = {0.3, 1.0},
				helicopter = {0.25, 1.0},
				apc_tire = {0.7, 0.0},
				jalopy = {0.4, 0.9},
				roller = {0.3, 1.0},
				popcan = {0.25, 1.0},
				-- Rusty/worn metals
				metal_sand = {0.7, 0.6},
				rustybarrel = {0.7, 0.5},
				-- Stone/masonry
				concrete = {0.9, 0.0},
				concrete_block = {0.85, 0.0},
				rock = {0.85, 0.0},
				boulder = {0.85, 0.0},
				gravel = {0.95, 0.0},
				brick = {0.8, 0.0},
				tile = {0.4, 0.0},
				ceiling_tile = {0.7, 0.0},
				asphalt = {0.9, 0.0},
				plaster = {0.85, 0.0},
				stucco = {0.9, 0.0},
				-- Natural/organic
				dirt = {0.95, 0.0},
				grass = {0.95, 0.0},
				mud = {0.85, 0.0},
				sand = {0.95, 0.0},
				quicksand = {0.8, 0.0},
				slime = {0.4, 0.0},
				antlionsand = {0.9, 0.0},
				slipperyslime = {0.3, 0.0},
				-- Wood
				wood = {0.7, 0.0},
				wood_lowdensity = {0.75, 0.0},
				wood_box = {0.7, 0.0},
				wood_crate = {0.7, 0.0},
				wood_plank = {0.7, 0.0},
				wood_furniture = {0.5, 0.0},
				wood_solid = {0.65, 0.0},
				wood_panel = {0.55, 0.0},
				wood_ladder = {0.7, 0.0},
				-- Glass/transparent
				glass = {0.05, 0.0},
				glassbottle = {0.05, 0.0},
				glass_breakable = {0.05, 0.0},
				canister = {0.15, 0.0},
				-- Fabric/soft
				cloth = {0.9, 0.0},
				carpet = {0.95, 0.0},
				paper = {0.9, 0.0},
				papercup = {0.85, 0.0},
				cardboard = {0.9, 0.0},
				upholstery = {0.9, 0.0},
				mattress = {0.95, 0.0},
				-- Rubber/plastic
				rubber = {0.8, 0.0},
				rubbertire = {0.85, 0.0},
				plastic = {0.5, 0.0},
				plastic_barrel = {0.5, 0.0},
				plastic_barrel_buoyant = {0.5, 0.0},
				plastic_box = {0.5, 0.0},
				jeeptire = {0.8, 0.0},
				brakingrubbertire = {0.75, 0.0},
				-- Organic/body
				flesh = {0.7, 0.0},
				bloodyflesh = {0.6, 0.0},
				armorflesh = {0.55, 0.15},
				alienflesh = {0.5, 0.0},
				antlion = {0.6, 0.0},
				zombieflesh = {0.65, 0.0},
				player = {0.6, 0.0},
				player_control_clip = {0.6, 0.0},
				item = {0.5, 0.0},
				-- Foliage
				foliage = {0.95, 0.0},
				tree = {0.8, 0.0},
				-- Water/liquid
				water = {0.05, 0.0},
				wade = {0.1, 0.0},
				slosh = {0.15, 0.0},
				-- Snow/ice
				ice = {0.15, 0.0},
				snow = {0.95, 0.0},
				-- Special surfaces
				default = {0.7, 0.0},
				default_silent = {0.7, 0.0},
				floating_metal_barrel = {0.45, 1.0},
				no_decal = {0.7, 0.0},
				player_gamemovement = {0.6, 0.0},
				portalgun = {0.15, 1.0},
				turret = {0.2, 1.0},
				playerclip = {0.7, 0.0},
				npcclip = {0.7, 0.0},
				-- HL2/EP specific
				metaldoor = {0.3, 1.0},
				wood_door = {0.6, 0.0},
				metal_duct = {0.35, 1.0},
				computer = {0.3, 0.4},
				pottery = {0.6, 0.0},
				-- Paintable surfaces (Portal 2)
				asphalt_portal = {0.9, 0.0},
				concrete_portal = {0.85, 0.0},
				metal_portal = {0.3, 1.0},
				-- GMOD specific
				gmod_bouncy = {0.5, 0.0},
				gmod_ice = {0.1, 0.0},
				gmod_silent = {0.7, 0.0},
				-- gamematerial
				C = {0.9, 0.0}, -- Concrete
				D = {0.95, 0.0}, -- Dirt
				G = {0.05, 0.0}, -- Glass (should use transmission)
				I = {0.5, 0.0}, -- Plastic/rubber (I = "Item")
				M = {0.35, 1.0}, -- Metal
				O = {0.7, 0.0}, -- Organic/flesh
				P = {0.6, 0.0}, -- Plaster
				S = {0.95, 0.0}, -- Sand
				T = {0.4, 0.0}, -- Tile
				V = {0.85, 0.0}, -- Vent (metallic but often painted)
				W = {0.7, 0.0}, -- Wood
				X = {0.5, 0.0}, -- Glass (breakable)
				Y = {0.05, 0.0}, -- Glass
				Z = {0.5, 0.0}, -- Flesh
				N = {0.95, 0.0}, -- Snow
				U = {0.95, 0.0}, -- Grass (U = "Underbrush")
				L = {0.85, 0.0}, -- Gravel
				A = {0.65, 0.0}, -- Antlion
				F = {0.95, 0.0}, -- Foliage
				E = {0.1, 0.0}, -- Slime/alien
				H = {0.9, 0.0}, -- Cloth
				K = {0.9, 0.0}, -- Cardboard
				R = {0.5, 0.0}, -- Computer/electronic
			}
			local pbr = surfaceprop_pbr[name]

			-- Fallback: use physical properties to estimate PBR values
			if not pbr then
				local density = get_prop(vmt.surfaceprop, "density") or 1000
				local elasticity = get_prop(vmt.surfaceprop, "elasticity") or 0.25
				local audioreflectivity = get_prop(vmt.surfaceprop, "audioreflectivity") or 0.5
				local friction = get_prop(vmt.surfaceprop, "friction") or 0.5
				self.vmt_surfaceprop = {
					name_not_found = name,
					density = density,
					elasticity = elasticity,
					audioreflectivity = audioreflectivity,
					friction = friction,
				}
				-- High density + high audio reflectivity = likely metal
				local metallic = 0.0

				if density > 6000 and audioreflectivity > 0.8 then
					metallic = 1.0
				elseif density > 4000 and audioreflectivity > 0.6 then
					metallic = 0.7
				end

				-- High friction + low audio reflectivity = rough surface
				-- Low friction + high elasticity = smooth surface
				local roughness = 0.5
				roughness = roughness + (friction - 0.5) * 0.4
				roughness = roughness - (audioreflectivity - 0.5) * 0.3
				roughness = roughness - elasticity * 0.2
				roughness = math.max(0.04, math.min(1.0, roughness))
				pbr = {roughness, metallic}
			end

			local roughness = pbr and pbr[1] or 1
			local refl = self:GetAlbedoTexture() and self:GetAlbedoTexture().reflectivity

			if refl then
				local avg = (refl[1] + refl[2] + refl[3]) / 3

				-- Use reflectivity to estimate base roughness
				-- Very dark surfaces (avg < 0.05) are either black or very rough
				-- Bright surfaces (avg > 0.3) that bounce lots of light are likely smoother
				if avg > 0.05 then
					-- Map reflectivity to roughness: higher reflectivity = lower roughness
					-- sqrt gives a more perceptually linear mapping
					local est = 1.0 - math.sqrt(avg)
					est = math.max(0.2, math.min(0.95, est))
					roughness = roughness * 0.6 + est * 0.4
				end
			end

			if not self:HasExplicitRoughnessTexture() then
				self:SetRoughnessMultiplier(roughness)
				self:SetInvertRoughnessTexture(false)
			end

			if not self:HasExplicitMetallicTexture() and pbr[2] then
				self:SetMetallicMultiplier(pbr[2] > 0.5 and 1.0 or 0.0)
			end
		end
	end

	local special_textures = {
		_rt_fullframefb = "error",
		[1] = "error", -- huh
	}

	function Material:SetError(err) end

	local blacklist = {
		"^surfaceprop",
		"^detail$",
		"transform$",
		"^fullpath$",
		"^treesway",
		"^%%compile",
		"^%%keywords",
	}

	local function is_blacklisted(key)
		for _, pattern in ipairs(blacklist) do
			if key:match(pattern) then return true end
		end

		return false
	end

	local function track_vmt(tbl, prefix)
		prefix = prefix or ""

		for k, v in pairs(tbl) do
			local full_key = prefix .. k

			if not is_blacklisted(full_key) then
				steam.vmt_stats.seen[full_key] = (steam.vmt_stats.seen[full_key] or 0) + 1

				if type(v) ~= "table" then
					steam.vmt_stats.values[full_key] = steam.vmt_stats.values[full_key] or {}
					steam.vmt_stats.values[full_key][tostring(v)] = true
				end
			end
		end

		return setmetatable(
			{},
			{
				__index = function(_, k)
					local full_key = prefix .. k

					if not is_blacklisted(full_key) then
						steam.vmt_stats.used[full_key] = (steam.vmt_stats.used[full_key] or 0) + 1
					end

					local val = tbl[k]

					if type(val) == "table" then return track_vmt(val, full_key .. ".") end

					return val
				end,
				__newindex = function(_, k, v)
					tbl[k] = v
				end,
				__pairs = function()
					return pairs(tbl)
				end,
			}
		)
	end

	steam.vmt_stats = steam.vmt_stats or {
		seen = {},
		used = {},
		values = {},
	}

	function Material.FromCryMTL(path, sub_material)
		local cache_key = get_cry_mtl_cache_key(path, sub_material)
		local cached_material = cry_mtl_material_cache[cache_key]

		if cached_material then
			record_material_cache_request("crymtl", cache_key, cached_material)
			return cached_material
		end

		local self = Material.New()
		self.cry_mtl_path = path
		self.upload_cache_key = cache_key
		local document = cry_mtl_document_cache[path]

		if document == nil then
			local data, err = vfs.Read(path)

			if not data then
				self:SetError(err or ("unable to read cry mtl " .. tostring(path)))
				cry_mtl_material_cache[cache_key] = self
				return self
			end

			local ok
			ok, document = pcall(xml.Decode, data)

			if not ok or not document or not document.children or not document.children[1] then
				cry_mtl_document_cache[path] = false
				self:SetError("unable to parse cry mtl " .. tostring(path))
				cry_mtl_material_cache[cache_key] = self
				return self
			end

			cry_mtl_document_cache[path] = document
		elseif document == false then
			self:SetError("unable to parse cry mtl " .. tostring(path))
			cry_mtl_material_cache[cache_key] = self
			return self
		end

		local root = document.children[1]
		local material_node = root

		if sub_material ~= nil then
			local sub_materials = find_child_by_tag(root, "SubMaterials")

			if type(sub_material) == "number" then
				local target_index = sub_material + 1
				local current_index = 0

				for child in iter_children_by_tag(sub_materials, "Material") do
					current_index = current_index + 1

					if current_index == target_index then
						material_node = child

						break
					end
				end
			else
				for child in iter_children_by_tag(sub_materials, "Material") do
					if child.attrs and child.attrs.Name == sub_material then
						material_node = child

						break
					end
				end
			end
		end

		if not material_node then
			self:SetError("sub material not found in cry mtl " .. tostring(path))
			cry_mtl_material_cache[cache_key] = self
			return self
		end

		if material_node.attrs and material_node.attrs.Name then
			self.cry_sub_material_name = material_node.attrs.Name
		end

		apply_cry_material_node(self, material_node, path)
		cry_mtl_material_cache[cache_key] = self
		record_material_cache_request("crymtl", cache_key, self)
		return self
	end

	function Material.FromVMT(path)
		local cache_key = get_vmt_cache_key(path)
		local cached_material = vmt_material_cache[cache_key]

		if cached_material then
			record_material_cache_request("vmt", cache_key, cached_material)
			return cached_material
		end

		local self = Material.New()
		--self:SetName(path)
		self.vmt_path = cache_key -- Store path for debugging
		self.upload_cache_key = cache_key
		vmt_material_cache[cache_key] = self
		local cb = steam.LoadVMT(cache_key, function(vmt)
			on_load_vmt(self, track_vmt(vmt))
		end, function(err)
			print("Material error for " .. cache_key .. ": " .. err)
			self:SetError(err)
		end)

		--if tasks.GetActiveTask() then pcall(cb.Get, cb) end
		if tasks.GetActiveTask() then cb:Get() end

		record_material_cache_request("vmt", cache_key, self)
		return self
	end

	commands.Add("dump_cached_materials", function()
		local rows = {}

		for material, stats in pairs(material_cache_stats) do
			local sources = {}

			for source in pairs(stats.sources) do
				sources[#sources + 1] = source
			end

			table.sort(sources)
			rows[#rows + 1] = {
				material = material,
				requests = stats.requests,
				source = table.concat(sources, "+"),
				primary_key = stats.key_order[1] or material.vmt_path or material.cry_mtl_path or "<unknown>",
				key_count = #stats.key_order,
			}
		end

		table.sort(rows, function(a, b)
			if a.requests ~= b.requests then return a.requests > b.requests end

			return a.primary_key < b.primary_key
		end)

		print(string.format("[cached_materials] unique=%d", #rows))

		for _, row in ipairs(rows) do
			print(
				string.format(
					"[cached_materials] requests=%d source=%s keys=%d material=%s",
					row.requests,
					row.source,
					row.key_count,
					row.primary_key
				)
			)
		end
	end)

	commands.Add("dump_cached_material_feature_summary", function()
		local materials = get_unique_cached_materials()
		local counts = {
			total = #materials,
			vmt = 0,
			crymtl = 0,
			albedo = 0,
			normal = 0,
			detail_blend = 0,
			detail_normal = 0,
			metallic_roughness = 0,
			metallic = 0,
			roughness = 0,
			opacity = 0,
			ambient_occlusion_texture = 0,
			emissive_texture = 0,
			nondefault_factor = 0,
			nondefault_color = 0,
			nondefault_ao = 0,
			emissive_enabled = 0,
			displacement = 0,
			terrain = 0,
			transmission = 0,
		}

		for _, material in ipairs(materials) do
			if material.vmt_path then counts.vmt = counts.vmt + 1 end

			if material.cry_mtl_path then counts.crymtl = counts.crymtl + 1 end

			if material:GetAlbedoTexture() ~= nil then counts.albedo = counts.albedo + 1 end

			if material:GetNormalTexture() ~= nil then counts.normal = counts.normal + 1 end

			if material:GetAlbedo2Texture() ~= nil or material:GetBlendTexture() ~= nil then
				counts.detail_blend = counts.detail_blend + 1
			end

			if material:GetNormal2Texture() ~= nil then
				counts.detail_normal = counts.detail_normal + 1
			end

			if material:GetMetallicRoughnessTexture() ~= nil then
				counts.metallic_roughness = counts.metallic_roughness + 1
			end

			if material:GetMetallicTexture() ~= nil then
				counts.metallic = counts.metallic + 1
			end

			if material:GetRoughnessTexture() ~= nil then
				counts.roughness = counts.roughness + 1
			end

			if material:GetOpacityTexture() ~= nil then
				counts.opacity = counts.opacity + 1
			end

			if material:GetAmbientOcclusionTexture() ~= nil then
				counts.ambient_occlusion_texture = counts.ambient_occlusion_texture + 1
			end

			if material:GetEmissiveTexture() ~= nil then
				counts.emissive_texture = counts.emissive_texture + 1
			end

			if not color_is_default(material:GetColorMultiplier()) then
				counts.nondefault_color = counts.nondefault_color + 1
			end

			if
				material:GetMetallicMultiplier() ~= 1.0 or
				material:GetRoughnessMultiplier() ~= 1.0 or
				material:GetAlphaCutoff() ~= 0.5
			then
				counts.nondefault_factor = counts.nondefault_factor + 1
			end

			if material:GetAmbientOcclusionMultiplier() ~= 1.0 then
				counts.nondefault_ao = counts.nondefault_ao + 1
			end

			if
				material:GetEmissiveTexture() ~= nil or
				material:GetAlbedoAlphaIsEmissive() or
				material:GetMetallicTextureAlphaIsEmissive()
			then
				counts.emissive_enabled = counts.emissive_enabled + 1
			end

			if material:GetHeightTexture() ~= nil and material:GetHeightScale() > 0 then
				counts.displacement = counts.displacement + 1
			end

			if material:GetTerrainMaterialTexture() ~= nil then
				counts.terrain = counts.terrain + 1
			end

			if material:GetSubsurface() then
				counts.transmission = counts.transmission + 1
			end
		end

		print(
			string.format(
				"[cached_material_features] total=%d vmt=%d crymtl=%d",
				counts.total,
				counts.vmt,
				counts.crymtl
			)
		)
		print(
			string.format(
				"[cached_material_features] base albedo=%d normal=%d",
				counts.albedo,
				counts.normal
			)
		)
		print(
			string.format(
				"[cached_material_features] detail_blend=%d detail_normal=%d",
				counts.detail_blend,
				counts.detail_normal
			)
		)
		print(
			string.format(
				"[cached_material_features] metallic_roughness=%d metallic=%d roughness=%d opacity=%d",
				counts.metallic_roughness,
				counts.metallic,
				counts.roughness,
				counts.opacity
			)
		)
		print(
			string.format(
				"[cached_material_features] ao_texture=%d ao_nondefault=%d emissive_texture=%d emissive_enabled=%d",
				counts.ambient_occlusion_texture,
				counts.nondefault_ao,
				counts.emissive_texture,
				counts.emissive_enabled
			)
		)
		print(
			string.format(
				"[cached_material_features] factor_nondefault=%d color_nondefault=%d",
				counts.nondefault_factor,
				counts.nondefault_color
			)
		)
		print(
			string.format(
				"[cached_material_features] displacement=%d terrain=%d transmission=%d",
				counts.displacement,
				counts.terrain,
				counts.transmission
			)
		)
	end)

	commands.Add("dump_unused_vmt_properties", function()
		local unused = {}

		for k, count in pairs(steam.vmt_stats.seen) do
			if not steam.vmt_stats.used[k] then
				local values = {}

				if steam.vmt_stats.values[k] then
					for val, _ in pairs(steam.vmt_stats.values[k]) do
						table.insert(values, val)
					end

					table.sort(values)
				end

				table.insert(unused, {key = k, count = count, values = values})
			end
		end

		table.sort(unused, function(a, b)
			if a.count ~= b.count then return a.count > b.count end

			return a.key < b.key
		end)

		print("Unused VMT properties (found in files but never accessed by code):")

		for _, item in ipairs(unused) do
			local val_str = #item.values > 0 and
				(
					" (values: " .. table.concat(item.values, ", ") .. ")"
				)
				or
				""
			print(string.format("  %-30s %d%s", item.key, item.count, val_str))
		end

		if #unused == 0 then
			print("  None! All properties found in VMTs have been accessed at least once.")
		end
	end)
end

return Material:Register()
