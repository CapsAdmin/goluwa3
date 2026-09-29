local commands = import("goluwa/cli/commands.lua")
local tasks = import("goluwa/tasks.lua")
local Texture = import("goluwa/render/texture.lua")
local codec = import("goluwa/codec.lua")
local Color = import("goluwa/structs/color.lua")
local objects = import("goluwa/objects/objects.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Material = objects.CreateTemplate("render3d_material")
-- textures
Material:StartStorable()
Material:GetSet("AlbedoTexture", nil, {type = "render_texture"})
Material:GetSet("NormalTexture", nil, {type = "render_texture"})
Material:GetSet("HeightTexture", nil, {type = "render_texture", callback = "InvalidateHeightMap"})
Material:GetSet("MetallicRoughnessTexture", nil, {type = "render_texture"})
Material:GetSet("AmbientOcclusionTexture", nil, {type = "render_texture"})
Material:GetSet(
	"EmissiveTexture",
	nil,
	{type = "render_texture", callback = "InvalidateEmission"}
)
Material:GetSet("Albedo2Texture", nil, {type = "render_texture"})
Material:GetSet("Normal2Texture", nil, {type = "render_texture"})
Material:GetSet("BlendTexture", nil, {type = "render_texture"})
Material:GetSet("DetailTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainMaterialTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer1Texture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer2Texture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer3Texture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer4Texture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer1NormalTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer2NormalTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer3NormalTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer4NormalTexture", nil, {type = "render_texture"})
-- a layer's height, parallax mapped by TerrainLayerHeightScales in texture units
Material:GetSet("TerrainLayer1HeightTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer2HeightTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer3HeightTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer4HeightTexture", nil, {type = "render_texture"})
Material:GetSet("MetallicTexture", nil, {type = "render_texture"})
Material:GetSet("RoughnessTexture", nil, {type = "render_texture"})
-- the luminance scales SpecularMultiplier
Material:GetSet("SpecularTexture", nil, {type = "render_texture"})
-- the luminance scales DiffuseTransmission
Material:GetSet("TransmissionTexture", nil, {type = "render_texture"})
-- multipliers
Material:GetSet("ColorMultiplier", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet(
	"EmissiveMultiplier",
	Color(1.0, 1.0, 1.0, 1.0),
	{callback = "InvalidateEmission"}
)
-- terrain layers: world space texture scale in meters, roughness and ambient occlusion multipliers per layer
Material:GetSet("TerrainLayerScales", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayerHeightScales", Color(0.0, 0.0, 0.0, 0.0))
-- the layer heights fade out towards this distance from the camera
Material:GetSet("TerrainLayerHeightDistance", 128)
Material:GetSet("TerrainLayerRoughness", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayerAmbientOcclusion", Color(1.0, 1.0, 1.0, 1.0))
-- 0 uses a layer's albedo as is with alpha as roughness, above 0 the layer only adds its color variation
-- around its average color to the albedo texture, with that strength, and its alpha is ignored
Material:GetSet("TerrainLayerDetailStrength", Color(0.0, 0.0, 0.0, 0.0))
-- above 0 a detail layer is added to the gamma encoded albedo texture around 0.5 with its strength, like cry
-- terrain layers, and the sum is multiplied by this
Material:GetSet("TerrainLayerAdditiveDetail", Color(0.0, 0.0, 0.0, 0.0))
-- SpecularMultiplier per layer
Material:GetSet("TerrainLayerSpecular", Color(1.0, 1.0, 1.0, 1.0))
-- with Grass, how much grass grows where each layer is, 0 to 1. grass thins and shortens across layer transitions
Material:GetSet("TerrainLayerGrass", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("MetallicMultiplier", 1.0)
Material:GetSet("RoughnessMultiplier", 1.0)
-- scales the dielectric reflectance (F0 0.04), 0 to 2
Material:GetSet("SpecularMultiplier", 1.0)
Material:GetSet("NormalMapMultiplier", 1.0)
Material:GetSet("AmbientOcclusionMultiplier", 1.0)
Material:GetSet("HeightScale", 0.0, {callback = "InvalidateHeightMap"})
Material:GetSet("HeightCenter", 0.0)
Material:GetSet("HeightLayers", 24)
-- crysis style detail map: rg offsets the normal, alpha multiplies albedo
Material:GetSet("DetailTiling", Vec2(1.0, 1.0))
Material:GetSet("DetailBumpScale", 1.0)
Material:GetSet("DetailBlendAmount", 0.0)
-- blends the albedo towards a world space ground color texture, ie vegetation picking up the terrain's color
Material:GetSet("GroundColorTexture", nil, {type = "render_texture"})
Material:GetSet("GroundColorBlend", 0.0)
-- the texture's uv is (dot(world.xz, rg), dot(world.xz, ba))
Material:GetSet("GroundColorUV", Color(1.0, 0.0, 0.0, 1.0))
-- how much of the diffuse light goes through a thin surface, like a leaf, and out its other side
Material:GetSet("DiffuseTransmission", 0.0, {callback = "InvalidateFlags"})
-- tints the light going through, on top of the albedo. only its hue is used
Material:GetSet("TransmissionColor", Color(1.0, 1.0, 1.0, 1.0))
-- 0 spreads the light going through evenly, 1 concentrates it around a light behind the surface
Material:GetSet("TransmissionScattering", 0.5)
-- cryengine 2 vegetation bending, see model_pipeline.BuildVertexAnimationGlsl
-- how much the wind bends the whole object around its origin, 0 is rigid
Material:GetSet("Bending", 0.0)
-- "none", "leaves" or "grass", leaf and branch flutter driven by the vertex colors
Material:GetSet("DetailBending", "none")
Material:GetSet("BendDetailFrequency", 5.0)
Material:GetSet("BendDetailLeafAmplitude", 0.08)
Material:GetSet("BendDetailBranchAmplitude", 0.2)
Material:GetSet("BendDetailPhase", 100.0)
-- grass
Material:GetSet("GrassDensity", 700.0)
Material:GetSet("GrassHeight", 0.28)
Material:GetSet("GrassHeightVariance", 2)
Material:GetSet("GrassWidth", 0.02)
-- other
-- how much light passes through the surface, bent by IndexOfRefraction (0..1,
-- gltf's transmission). the transmitted light is tinted by the albedo
Material:GetSet("Refraction", 0.0, {callback = "InvalidateSceneKey"})
Material:GetSet("IndexOfRefraction", 1.5)
-- how far light travels inside, in world units. 0 is a thin wall (a window,
-- a bubble) and below 0 takes the object's thinnest extent
Material:GetSet("RefractionThickness", -1.0)
Material:GetSet("AlphaCutoff", 0.5)
Material:GetSet("IgnoreZ", false, {callback = "InvalidateSceneKey"})
Material:GetSet("DoubleSided", false, {callback = "InvalidateFlags"})
-- the primitives drawing with it are left out, ie collision proxies
Material:GetSet("NoDraw", false, {callback = "InvalidateSceneKey"})
-- flags
Material:GetSet("Flags", 0)
Material:GetSet("ReverseXZNormalMap", false, {callback = "InvalidateFlags"})
Material:GetSet("NormalTextureAlphaIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoTextureAlphaIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoLuminanceIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("BlendTintByBaseAlpha", false, {callback = "InvalidateFlags"})
Material:GetSet("MetallicTextureAlphaIsEmissive", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoAlphaIsEmissive", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoAlphaIsSpecular", false, {callback = "InvalidateFlags"})
-- the gloss map also scales the phong power RoughnessMultiplier was derived from
Material:GetSet("GlossIsShininess", false, {callback = "InvalidateFlags"})
-- a SpecularMultiplier above 1 is solved into metallic with the albedo as the diffuse
Material:GetSet("SpecularSolvesMetallic", false, {callback = "InvalidateFlags"})
Material:GetSet("Translucent", false, {callback = "InvalidateFlags"})
Material:GetSet("AlphaTest", false, {callback = "InvalidateFlags"})
Material:GetSet("InvertRoughnessTexture", false, {callback = "InvalidateFlags"})
Material:GetSet("Grass", false, {callback = "InvalidateFlags"})
Material:EndStorable()

function Material:GetCullMode()
	return self.DoubleSided and "none" or orientation.CULL_MODE
end

do
	local opaque = {
		src_color_blend_factor = "one",
		dst_color_blend_factor = "zero",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
	}
	local translucent = {
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one_minus_src_alpha",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
	}

	-- for forward drawn surfaces, which blend over what is behind them when
	-- translucent
	function Material:GetBlendEquation()
		return self.Translucent and translucent or opaque
	end
end

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
	if self.AlbedoTexture ~= nil and self.AlbedoTextureAlphaIsRoughness then
		return true
	end

	if self.NormalTexture ~= nil and self.NormalTextureAlphaIsRoughness then
		return true
	end

	if self.AlbedoLuminanceIsRoughness then return true end

	if self.RoughnessTexture ~= nil then return true end

	if self.MetallicRoughnessTexture ~= nil then return true end

	return false
end

-- drawn forward, over the lit opaque scene, instead of into the gbuffer
-- a height mapped surface writes its own depth, which costs it early depth
-- testing, so it draws with its own gbuffer pipelines
function Material:HasHeightMap()
	return self.HeightTexture ~= nil and self.HeightScale > 0
end

function Material:HasVertexAnimation()
	return self.Bending > 0 or self.DetailBending ~= "none"
end

function Material:IsTransparent()
	return self.Translucent or self.Refraction > 0
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

function Material:GetTransmissive()
	return self.DiffuseTransmission > 0
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
	"Transmissive",
	"Grass",
	"AlbedoAlphaIsSpecular",
	"GlossIsShininess",
	"SpecularSolvesMetallic",
}

for i, flag_name in ipairs(FLAGS) do
	if not Material["Get" .. flag_name] then
		error("Material is missing flag getter: " .. flag_name)
	end
end

-- bumped whenever any material's flags or HasHeightMap change
Material.flags_generation = 0
-- materials whose transparency, depth test or displacement changed, which
-- moves the visuals drawing with them between passes
Material.scene_dirty_materials = Material.scene_dirty_materials or {}

function Material:InvalidateSceneKey()
	Material.scene_dirty_materials[self] = true
end

-- materials whose emission changed, which the ray tracing soup bakes per
-- triangle
Material.emission_dirty_materials = Material.emission_dirty_materials or {}

function Material:InvalidateEmission()
	Material.emission_dirty_materials[self] = true
end

function Material:InvalidateHeightMap()
	Material.flags_generation = Material.flags_generation + 1
	self:InvalidateSceneKey()
end

function Material:InvalidateFlags()
	Material.flags_generation = Material.flags_generation + 1
	self:InvalidateSceneKey()
	self:InvalidateEmission()
	local flags = 0

	for i, flag_name in ipairs(FLAGS) do
		if self["Get" .. flag_name](self) then
			flags = bit.bor(flags, bit.lshift(1, i - 1))
		end
	end

	self.Flags = flags
end

Material:GetSet("Name", "")

-- source materials say nothing about grass, so for now any vmt or base texture
-- with grass in its file name grows it. only the file name, since map folders
-- like gm_flatgrass would match every material in the map
function Material:DetectGrass()
	local texture = self.AlbedoTexture

	if
		file_path.GetFileNameFromPath(self.Name):lower():find("grass", 1, true) or
		(
			texture and
			texture.config.path and
			file_path.GetFileNameFromPath(texture.config.path):lower():find("grass", 1, true)
		)
	then
		self:SetGrass(true)
	end
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

-- a shadow map sees light pass through a refracting surface as through a
-- translucent one: dithered, blocking what its two faces reflect (~10%)
do
	local TRANSLUCENT_FLAG = 2

	function Material:GetShadowFlags()
		if self.Refraction > 0 then return bit.bor(self.Flags, TRANSLUCENT_FLAG) end

		return self.Flags
	end

	function Material:GetShadowOpacity()
		return self.ColorMultiplier.a * (1 - 0.9 * self.Refraction)
	end
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
	local xml = import("goluwa/codecs/xml.lua")
	local cry_mtl_document_cache = {}
	local cry_mtl_material_cache = {}
	local vmt_material_cache = {}
	local cry_texture_path_cache = {}
	local material_cache_stats = setmetatable({}, {__mode = "k"})

	local function get_cry_mtl_cache_key(path, sub_material)
		return path .. "\0" .. type(sub_material) .. ":" .. tostring(sub_material)
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
			-- some materials were saved with the artist's checkout path, ie j:/game02/game/objects/...
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
			-- like CryEngine's language pak, mounted at the game root for Languages/...
			add(game_root .. "Localized/english.pak/" .. relative_path)
			add(game_root .. "Localized/english.pak/" .. relative_base .. ".dds")
		end

		if file_path.IsPathAbsolutePath(normalized) then
			add(normalized)
			add(base .. ".dds")
		else
			local folder = file_path.GetFolderFromPath(material_path)

			if is_game_relative then
				-- a material loaded through a mounted game root, ie Objects/..., resolves its textures through the same mounts
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

	-- GenMask bits from Shaders/<shader>.ext, the mask is stored as a decimal number
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
			-- "fit to terrain", the vertex shader bends the model's height to the terrain's around the instance
			TERRAINHEIGHTADAPTION = 0x4000,
			DETAIL_BENDING = 0x10000,
		},
	}
	-- MtlFlags
	local MTL_FLAG_2SIDED = 0x2
	local MTL_FLAG_NODRAW = 0x400
	-- the height offset bump and parallax occlusion mapping read is the alpha
	-- attached to the normal map's dds. only a few dozen materials use it, so it's
	-- decoded here rather than through the texture loader
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

		-- collision proxies and other helpers that CryEngine never draws
		if shader:lower() == "nodraw" or bit.band(mtl_flags, MTL_FLAG_NODRAW) ~= 0 then
			self:SetNoDraw(true)
			return self
		end

		self:SetMetallicMultiplier(0)

		-- phong: specular = light * cos^n * gloss map * Specular color S, n being the Shininess, next to a diffuse
		-- of light * albedo. under the same light, pi of ours, that lobe is the normalized (n + 2) / 2pi phong lobe
		-- of F0 = 2 S / (n + 2), and (2 / (n + 2))^0.25 is the equivalent perceptual roughness. above the 0.04 of
		-- a dielectric the gbuffer pass solves the F0 and albedo into metallic, but only for what crysis says is
		-- metal. glossy leaves, glass, plastic and concrete stay dielectric
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
			-- alpha testing ignores the opacity
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
			-- the level's vegetation objects have their own Bending, this is for models placed on their own
			self:SetBending(1)

			-- Vegetation.cfx only detail bends leaves and grass
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

		-- leaves and grass light their back face through the opacity map, which is never alpha
		-- crysis adds BackDiffuse * BackDiffuseMultiplier * albedo of back light next to the albedo of front light,
		-- so its brightness is the ratio of light going through to light reflected, and its color the tint
		-- with the vegetation's UseTerrainColor, grass is lerped towards the terrain color by this much
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

			-- crysis weighs its view dependent term with BackViewDep, unset is -1
			self:SetTransmissionScattering(math.clamp(tonumber(params.BackViewDep) or 0.5, 0, 1))
		end

		-- without the detail bump bit, crysis only uses the detail map in a legacy color modulate pass
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

		-- both offset the uv by height * displacement in texture space. POM marches
		-- down from 1 to 0 like ours, so its displacement is our scale. offset bump
		-- shifts by (2 * height - 1) * displacement, twice that over the same range.
		-- illum's offset bump reads ObmDisplacement, older materials still carry a
		-- Displacement it ignores
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
				-- without an attached alpha crysis reads the flat 1 of the normal map, which displaces nothing
				local height_texture = height_scale > 0 and resolved and get_cry_height_texture(resolved)

				if height_texture then
					self:SetHeightTexture(height_texture)
					self:SetHeightScale(height_scale)
				end
			elseif map_name == "Specular" then
				-- the gloss map, sampled as srgb
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

		-- the glow pass adds diffuse * diffuse alpha * GlowAmount, alpha glow adds the same scaled by AmbientMultiplier
		do
			local glow = tonumber(attrs.GlowAmount) or 0

			if has_gen("ALPHAGLOW") then
				glow = glow + (tonumber(params.AmbientMultiplier) or 1)
			end

			if glow > 0 then
				self:SetEmissiveMultiplier(Color(1, 1, 1, glow))

				-- alpha testing needs the diffuse alpha, so the glow is masked by the diffuse red channel instead
				if self.AlphaTest then
					self:SetEmissiveTexture(self.AlbedoTexture)
				else
					self:SetAlbedoAlphaIsEmissive(true)
				end
			end
		end

		return self
	end

	local function on_load_vmt(self, vmt)
		self.vmt = vmt -- store for debugging
		--self:SetReverseXZNormalMap(true) -- Source engine normals need XY flip
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

		-- the envmap masks are reflectivity. source reads the normal map alpha and envmapmask as is, but the
		-- base alpha inverted, so only the envmapmask texture needs inverting to be roughness
		if vmt.envmap then -- envmap
			if vmt.envmapmask then
				self:SetRoughnessTexture(LinearTexture(vmt.envmapmask))
				self:SetInvertRoughnessTexture(true)
			end

			if vmt.normalmapalphaenvmapmask == 1 then
				self:SetNormalTextureAlphaIsRoughness(true)
			end

			if vmt.basealphaenvmapmask == 1 then
				self:SetAlbedoTextureAlphaIsRoughness(true)
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

			if not self:HasExplicitRoughnessTexture() then self:SetRoughnessMultiplier(0) end
		end

		if vmt.phong == 1 then
			self:SetInvertRoughnessTexture(vmt.invertphongmask ~= 1)

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
		end

		-- source only reflects light off materials that ask for an envmap or phong
		if not vmt.envmap and vmt.phong ~= 1 then self:SetSpecularMultiplier(0) end

		if vmt.selfillum == 1 then
			if vmt.selfillumtint then self:SetEmissiveMultiplier(vmt.selfillumtint) end

			if vmt.selfillummask then
				self:SetEmissiveTexture(LinearTexture(vmt.selfillummask))
				self:SetAlbedoAlphaIsEmissive(false)
			else
				self:SetAlbedoAlphaIsEmissive(true)
			end
		end

		if vmt.selfillum_envmapmask_alpha == 1 then
			self:SetMetallicTextureAlphaIsEmissive(true)
		end

		if vmt.translucent == 1 then self:SetTranslucent(true) end

		-- the refract shader distorts what is behind it by its normal map
		if vmt.shader:lower() == "refract" then
			self:SetRefraction(1)
			-- source offsets the screen by $refractamount times the normal, the
			-- closest thing to a bend it has
			self:SetIndexOfRefraction(1 + (vmt.refractamount or 0.5))
			self:SetRefractionThickness(0)
			self:SetSpecularMultiplier(1)

			if vmt.normalmap then self:SetNormalTexture(LinearTexture(vmt.normalmap)) end

			if vmt.refracttinttexture then
				self:SetAlbedoTexture(SRGBTexture(vmt.refracttinttexture))
			end

			-- "[r g b]" parses to a vec3, "{r g b}" stays a 0..255 string
			local tint = vmt.refracttint

			if typex(tint) == "vec3" then
				self:SetColorMultiplier(Color(tint.x, tint.y, tint.z, 1))
			elseif type(tint) == "string" then
				local r, g, b = tint:match("{%s*(%S+)%s+(%S+)%s+(%S+)%s*}")

				if r then
					self:SetColorMultiplier(Color(tonumber(r) / 255, tonumber(g) / 255, tonumber(b) / 255, 1))
				end
			end
		end

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

		self:DetectGrass()
	end

	local special_textures = {
		_rt_fullframefb = "error",
		[1] = "error", -- huh
	}

	function Material:SetError(err)
		self.Error = err
		logf("material error for %q: %s\n", tostring(self:GetName()), tostring(err))
		self:SetAlbedoTexture(Texture.GetFallback())
	end

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

	function Material.FromCryMTL(path, sub_material)
		local cache_key = get_cry_mtl_cache_key(path, sub_material)
		local cached_material = cry_mtl_material_cache[cache_key]

		if cached_material then
			record_material_cache_request("crymtl", cache_key, cached_material)
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

		-- like CryEngine, a material without sub materials is used for every subset
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
		record_material_cache_request("crymtl", cache_key, self)
		return self
	end

	-- the sub materials of a cry mtl by 0 based slot, or nil when it has none and applies as a whole
	-- like CryEngine, a slot the mtl doesn't have resolves to an error material
	function Material.FromCryMTLSlots(path)
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

					slots[slot] = Material.FromCryMTL(path, slot)
					return slots[slot]
				end,
			}
		)
	end

	-- the materials a cry mtl override applies, one per sub material or the mtl as a whole
	function Material.FromCryMTLList(path)
		local document = load_cry_mtl_document(path)
		local sub_materials = document and find_child_by_tag(document.children[1], "SubMaterials")

		if not sub_materials then return {Material.FromCryMTL(path)} end

		local out = {}

		for _ in iter_children_by_tag(sub_materials, "Material") do
			out[#out + 1] = Material.FromCryMTL(path, #out)
		end

		return out
	end

	-- whether the material or any of its sub materials sets a GenMask flag from GEN_MASKS
	function Material.CryMTLHasGenFlag(path, name)
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

	function Material.FromVMT(path)
		local cache_key = get_vmt_cache_key(path)
		local cached_material = vmt_material_cache[cache_key]

		if cached_material then
			record_material_cache_request("vmt", cache_key, cached_material)
			return cached_material
		end

		local self = Material.New()
		self:SetName(path)
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
			transmission_texture = 0,
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

			if material:GetNormal2Texture() ~= nil or material:GetDetailTexture() ~= nil then
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

			if material:GetTransmissionTexture() ~= nil then
				counts.transmission_texture = counts.transmission_texture + 1
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

			if material:HasHeightMap() then
				counts.displacement = counts.displacement + 1
			end

			if material:GetTerrainMaterialTexture() ~= nil then
				counts.terrain = counts.terrain + 1
			end

			if material:GetTransmissive() then
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
				"[cached_material_features] metallic_roughness=%d metallic=%d roughness=%d transmission_texture=%d",
				counts.metallic_roughness,
				counts.metallic,
				counts.roughness,
				counts.transmission_texture
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
