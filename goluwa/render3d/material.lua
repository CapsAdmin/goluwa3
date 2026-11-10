local pvars = import("goluwa/cli/pvars.lua")
local tasks = import("goluwa/tasks.lua")
local Texture = import("goluwa/render/texture.lua")
local codec = import("goluwa/codec.lua")
local Color = import("goluwa/structs/color.lua")
local objects = import("goluwa/objects/objects.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local FlagSet = import("goluwa/render/flag_set.lua")
local Material = objects.CreateTemplate("render3d_material")
Material:StartStorable({versioned = true})
Material:StartCategory("Albedo")
Material:GetSet("AlbedoTexture", nil, {type = "render_texture", callback = "InvalidateAlbedo"})
Material:GetSet("ColorMultiplier", Color(1.0, 1.0, 1.0, 1.0), {callback = "InvalidateColor"})
Material:StartCategory("Surface")
Material:GetSet("NormalTexture", nil, {type = "render_texture"})
Material:GetSet("NormalMapMultiplier", 1.0, {requires = "NormalTexture"})
Material:GetSet(
	"MetallicRoughnessTexture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet("MetallicRoughness2Texture", nil, {type = "render_texture"})
Material:GetSet("PackedSpecularScale", 0.0, {requires = "MetallicRoughnessTexture"})
Material:GetSet(
	"MetallicTexture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet("MetallicMultiplier", 1.0, {callback = "InvalidateRayMaterial"})
Material:GetSet(
	"RoughnessTexture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet("RoughnessMultiplier", 1.0, {callback = "InvalidateRayMaterial"})
Material:GetSet("RoughnessMin", 0.0, {callback = "InvalidateRayMaterial"})
Material:GetSet("RoughnessMax", 1.0, {callback = "InvalidateRayMaterial"})
Material:GetSet("MetallicMaskMin", 0.0)
Material:GetSet("MetallicMaskMax", 1.0)
Material:GetSet("EmissiveAlphaFloor", 0.0)
Material:GetSet("SpecularMultiplier", 1.0)

for _, feature in ipairs(surface_features.list) do
	if feature.params then
		Material:StartCategory(feature.category or feature.name)

		for _, param in ipairs(feature.params) do
			if param.category then Material:StartCategory(param.category) end

			Material:GetSet(
				param.name,
				param.default,
				{
					requires = param.requires,
					callback = param.callback,
					type = param.type,
					enums = param.enums,
				}
			)
		end
	end
end

Material:StartCategory("Emission")
Material:GetSet(
	"EmissiveTexture",
	nil,
	{type = "render_texture", callback = "InvalidateEmission"}
)
Material:GetSet(
	"EmissiveMultiplier",
	Color(1.0, 1.0, 1.0, 1.0),
	{callback = "InvalidateEmission"}
)
Material:GetSet("EmitsLight", true, {callback = "InvalidateEmission"})
Material:GetSet("IgnoredByLightOcclusion", false, {callback = "InvalidateSceneKey"})
Material:GetSet(
	"EmissiveTextureIsColor",
	false,
	{callback = "InvalidateFlags", requires = "EmissiveTexture"}
)
Material:GetSet("RimColor", Color(0.0, 0.0, 0.0, 0.0), {callback = "InvalidateEmission"})
Material:GetSet("RimPower", 3.0, {callback = "InvalidateEmission"})
Material:GetSet("OcclusionRadius", 0.0, {callback = "InvalidateEmission"})
Material:GetSet("OcclusionSoftness", 0.25, {callback = "InvalidateEmission"})
Material:GetSet("ExposureCompensation", 0.0, {callback = "InvalidateEmission"})
Material:StartCategory("Blending")
Material:GetSet("Translucent", false, {callback = "InvalidateFlags"})
Material:GetSet("AlphaTest", false, {callback = "InvalidateFlags"})
Material:GetSet("Decal", false, {callback = "InvalidateFlags"})
Material:GetSet("SharpAlpha", false, {callback = "InvalidateFlags"})
Material:GetSet("DecalFade", false, {callback = "InvalidateFlags"})
Material:GetSet("Dithered", false, {callback = "InvalidateFlags"})
Material:GetSet("AlphaCutoff", 0.5, {callback = "InvalidateColor", requires = "AlphaTest"})
Material:GetSet("Additive", false, {callback = "InvalidateFlags"})
Material:GetSet("VertexTint", false, {callback = "InvalidateFlags"})
Material:GetSet("SimpleLighting", false, {callback = "InvalidateFlags"})
Material:GetSet("Modulate", false, {callback = "InvalidateFlags"})
Material:GetSet("DisplayReferred", false, {callback = "InvalidateFlags"})
Material:GetSet("Unlit", false, {callback = "InvalidateFlags"})
Material:StartCategory("Rendering")
Material:GetSet("DoubleSided", false, {callback = "InvalidateFlags"})
Material:GetSet("BentNormals", false, {callback = "InvalidateFlags", requires = "DoubleSided"})
Material:GetSet("IgnoreZ", false, {callback = "InvalidateSceneKey"})
Material:GetSet("NoDraw", false, {callback = "InvalidateSceneKey"})
Material:StartCategory("Channel Packing")
Material:GetSet(
	"NormalTextureAlphaIsRoughness",
	false,
	{callback = "InvalidateFlags", requires = "NormalTexture"}
)
Material:GetSet(
	"NormalTextureIsSSBump",
	false,
	{callback = "InvalidateFlags", requires = "NormalTexture"}
)
Material:GetSet(
	"NormalAlphaIsCoverage",
	false,
	{callback = "InvalidateFlags", requires = "NormalTexture"}
)
Material:GetSet(
	"AlbedoTextureAlphaIsRoughness",
	false,
	{callback = "InvalidateFlags", requires = "AlbedoTexture"}
)
Material:GetSet("AlbedoLuminanceIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoAlphaIsEmissive", false, {callback = "InvalidateFlags"})
Material:GetSet(
	"MetallicTextureAlphaIsEmissive",
	false,
	{callback = "InvalidateFlags", requires = "MetallicTexture"}
)
Material:GetSet("SpecularFromRoughnessMask", false, {callback = "InvalidateFlags"})
Material:GetSet("RoughnessMaskOnlyScalesSpecular", false, {callback = "InvalidateFlags"})
Material:GetSet("InvertRoughnessTexture", false, {callback = "InvalidateFlags"})
Material:GetSet("MetallicFromRoughnessMask", false, {callback = "InvalidateFlags"})
Material:GetSet(
	"MetallicRoughnessIsMR",
	false,
	{callback = "InvalidateFlags", requires = "MetallicRoughnessTexture"}
)
Material:GetSet(
	"HeightTextureIsAlpha",
	false,
	{callback = "InvalidateFlags", requires = "HeightTexture"}
)
Material:StartCategory("Source")
Material:GetSet("OriginalMaterial", "", {multiline = true})
Material:EndCategory()
Material:EndStorable()
Material.property_version = 0

function Material:Touch()
	local version = objects.version_counter + 1
	objects.version_counter = version
	self.property_version = version
	objects.version_log[version % objects.VERSION_LOG_SIZE] = self
end

function Material:GetRasterBothFaces()
	return self.DoubleSided or self.HeightShell > 0 or self.TerrainShell > 0
end

function Material:GetCullMode()
	return self:GetRasterBothFaces() and "none" or orientation.CULL_MODE
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
	local additive = {
		src_color_blend_factor = "src_alpha",
		dst_color_blend_factor = "one",
		color_blend_op = "add",
		src_alpha_blend_factor = "one",
		dst_alpha_blend_factor = "zero",
		alpha_blend_op = "add",
	}

	function Material:GetBlendEquation()
		if self.Additive then return additive end

		return self.Translucent and translucent or opaque
	end

	function Material:GetBlendEnabled()
		return self.Translucent or self.Additive
	end
end

local function is_color(value)
	local value_type = type(value)

	if value_type ~= "table" and value_type ~= "cdata" and value_type ~= "userdata" then
		return false
	end

	return value.r ~= nil and value.g ~= nil and value.b ~= nil
end

do
	local constant_textures = {}

	local function constant_texture(glsl)
		if constant_textures[glsl] then return constant_textures[glsl] end

		local tex = Texture.New{
			width = 4,
			height = 4,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			image = {
				usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "repeat",
				wrap_t = "repeat",
			},
		}
		tex:Shade(glsl)
		constant_textures[glsl] = tex
		return tex
	end

	function Material.ResolveTexture(source, shared)
		if not RENDER_3D then return end

		if source == nil then return nil end

		if is_color(source) then
			return constant_texture(
				string.format(
					"return vec4(%f, %f, %f, %f);",
					source.r or 0,
					source.g or 0,
					source.b or 0,
					source.a or 1
				)
			)
		end

		if type(source) == "number" then
			return constant_texture(string.format("return vec4(%f);", source))
		end

		if type(source) ~= "string" then return source end

		local tex = Texture.New{
			width = 1024,
			height = 1024,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			image = {
				usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "repeat",
				wrap_t = "clamp_to_edge",
			},
		}
		tex:Shade(source, {custom_declarations = shared})
		return tex
	end
end

function Material.New(config)
	local self = Material:CreateObject()

	if config then
		local shared = config.Shared

		if config.Color and config.Albedo then
			error("Color and Albedo both set the albedo", 2)
		end

		if config.ColorMultiplier and (config.Color or is_color(config.Albedo)) then
			error("Color and ColorMultiplier both set the color", 2)
		end

		for key, value in pairs(config) do
			if key == "Color" then key = "Albedo" end

			if key ~= "Shared" then
				local multiplier = key == "Albedo" and "ColorMultiplier" or key .. "Multiplier"
				local current = self[multiplier]

				if
					self["Set" .. key .. "Texture"] and
					current ~= nil and
					(
						type(value) == "number" and
						type(current) == "number" or
						is_color(value) and
						is_color(current)
					)
				then
					self["Set" .. multiplier](self, value)
				elseif self["Set" .. key .. "Texture"] then
					self["Set" .. key .. "Texture"](self, Material.ResolveTexture(value, shared))
				elseif self["Set" .. key] then
					self["Set" .. key](self, value)
				else
					error("unknown material key: " .. tostring(key), 2)
				end
			end
		end
	end

	return self
end

function Material:CopyFrom(source)
	for _, info in ipairs(objects.GetStorableVariables(source)) do
		local value = source[info.get_name](source)

		if type(value) == "cdata" and value.Copy then value = value:Copy() end

		self[info.set_name](self, value)
	end

	self.vmt_surfaceprop = source.vmt_surfaceprop
	self.has_uv_transform = source.has_uv_transform
end

function Material:Copy()
	local copy = Material.New()
	copy:CopyFrom(self)
	return copy
end

function Material:ResetToDefaults()
	for _, info in ipairs(objects.GetStorableVariables(self)) do
		if info.var_name ~= "Name" then
			self[info.set_name](self, info.copy and info.copy() or info.default)
		end
	end
end

function Material:IsMetallic()
	return self.MetallicMultiplier > 0
end

function Material:HasExplicitMetallicTexture()
	return self.MetallicTexture ~= nil or self.MetallicRoughnessTexture ~= nil
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

function Material:HasHeightMap()
	return self.HeightTexture ~= nil and self.HeightScale > 0
end

function Material:MarchesRelief()
	return self:HasHeightMap() or self.TerrainShell > 0
end

function Material:WritesFragmentDepth()
	return self:MarchesRelief() or self.Decal
end

function Material:HasVertexAnimation()
	return self.Bending > 0 or self.DetailBending ~= "none"
end

function Material:IsTransparent()
	if self.Dithered then return false end

	return self.Translucent or self.Refraction > 0 or self.Additive or self.Modulate
end

function Material:IsSeeThrough()
	return self.Refraction > 0 or self.Additive or self.Modulate
end

function Material:IsGlass()
	return self.Refraction > 0 and not self.Additive
end

Material.GlassCastsShadow = function()
	return true
end

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
	"Translucent",
	"AlphaTest",
	"BlendTintByBaseAlpha",
	"InvertRoughnessTexture",
	"NormalTextureAlphaIsRoughness",
	"NormalTextureIsSSBump",
	"AlbedoTextureAlphaIsRoughness",
	"AlbedoLuminanceIsRoughness",
	"MetallicTextureAlphaIsEmissive",
	"AlbedoAlphaIsEmissive",
	"DoubleSided",
	"Transmissive",
	"Additive",
	"Modulate",
	"MultiplyAlbedo2",
	"DisplayReferred",
	"NormalAlphaIsCoverage",
	"SpecularFromRoughnessMask",
	"RoughnessMaskOnlyScalesSpecular",
	"Billboard",
	"EmissiveTextureIsColor",
	"MetallicFromRoughnessMask",
	"Decal",
	"SharpAlpha",
	"DecalFade",
	"BentNormals",
	"MetallicRoughnessIsMR",
	"HeightTextureIsAlpha",
	"VertexTint",
	"Unlit",
	"SimpleLighting",
}
Material.FlagSet = FlagSet.New(FLAGS)
Material.flag_words = Material.FlagSet:NewWords()

for _, flag_name in ipairs(FLAGS) do
	if not Material["Get" .. flag_name] then
		error("Material is missing flag getter: " .. flag_name)
	end
end

Material.flags_generation = 0
Material.scene_dirty_materials = Material.scene_dirty_materials or {}

function Material:InvalidateSceneKey()
	Material.scene_dirty_materials[self] = true
end

Material.emission_generation = Material.emission_generation or 0

function Material:InvalidateEmission()
	Material.emission_generation = Material.emission_generation + 1
	self:InvalidateSceneKey()
	self:InvalidateRayMaterial()
end

Material.ray_material_generation = 0
Material.ray_material_stamp = 0

function Material:InvalidateRayMaterial()
	Material.ray_material_generation = Material.ray_material_generation + 1
	self.ray_material_stamp = Material.ray_material_generation
end

function Material:InvalidateHeightMap()
	Material.flags_generation = Material.flags_generation + 1
	self:InvalidateSceneKey()
end

function Material:InvalidateColor()
	self:InvalidateRayMaterial()
	self:InvalidateShadow()
end

Material.albedo_generation = 0
Material.shadow_stamp = 0

function Material:StampShadow()
	Material.shadow_stamp = Material.shadow_stamp + 1
	self.shadow_stamp = Material.shadow_stamp
end

function Material:InvalidateAlbedo()
	Material.albedo_generation = Material.albedo_generation + 1
	self:StampShadow()
	self:InvalidateRayMaterial()
	self:InvalidateShadow()
end

function Material:InvalidateTransparency()
	self:InvalidateSceneKey()
	self:InvalidateShadow()
end

function Material:InvalidateFlags()
	Material.flags_generation = Material.flags_generation + 1
	self:InvalidateSceneKey()
	self:InvalidateEmission()
	self:InvalidateRayMaterial()
	local words = rawget(self, "flag_words")

	if not words then
		words = Material.FlagSet:NewWords()
		self.flag_words = words
	end

	for word = 0, Material.FlagSet:GetWordCount() - 1 do
		words[word] = 0
	end

	for _, flag_name in ipairs(FLAGS) do
		if self["Get" .. flag_name](self) then
			Material.FlagSet:Set(words, flag_name, true)
		end
	end

	self:InvalidateShadow()
end

Material:GetSet("Name", "")

function Material.IsGrassTexture(texture)
	local grass = texture.is_grass_texture

	if grass == nil then
		grass = texture.config.path and
			file_path.GetFileNameFromPath(texture.config.path):lower():find("grass", 1, true) ~= nil or
			false
		texture.is_grass_texture = grass
	end

	return grass
end

function Material.IsGlassTexture(texture)
	local glass = texture.is_glass_texture

	if glass == nil then
		glass = texture.config.path and
			file_path.GetFileNameFromPath(texture.config.path):lower():find("glass", 1, true) ~= nil or
			false
		texture.is_glass_texture = glass
	end

	return glass
end

function Material:GetDebugFlagMap()
	local tbl = {}

	for _, flag_name in ipairs(FLAGS) do
		tbl[flag_name] = Material.FlagSet:Has(self.flag_words, flag_name)
	end

	return tbl
end

function Material:GetTextures()
	local out = {}

	for _, info in ipairs(objects.GetStorableVariables(self)) do
		if info.type == "render_texture" then
			local texture = self[info.var_name]

			if texture then
				out[#out + 1] = {name = info.var_name:gsub("Texture$", ""), texture = texture}
			end
		end
	end

	return out
end

do
	local LUMINANCE_WORD = Material.FlagSet:GetWord("AlbedoLuminanceIsRoughness")
	local LUMINANCE_MASK = Material.FlagSet:GetMask("AlbedoLuminanceIsRoughness")
	pvars.StartGroup("Rendering", "Materials", {store = false})
	local luminance_roughness = pvars.Setup2{
		key = "r_albedo_luminance_roughness",
		default = false,
		help = "a hack: materials without a roughness texture take their roughness from the luminance of their albedo, dark is shiny. refractive materials keep theirs",
		callback = function(value, is_init)
			if is_init then return end

			Material.flags_generation = Material.flags_generation + 1
		end,
	}
	pvars.EndGroup()

	function Material:GetFillFlags(word)
		if
			word == LUMINANCE_WORD and
			luminance_roughness:Get() and
			self.Refraction == 0 and
			not self:HasExplicitRoughnessTexture()
		then
			return bit.bor(self.flag_words[word], LUMINANCE_MASK)
		end

		return self.flag_words[word]
	end
end

do
	local TRANSLUCENT_WORD = Material.FlagSet:GetWord("Translucent")
	local TRANSLUCENT_MASK = Material.FlagSet:GetMask("Translucent")
	local REFRACTION_TRANSMITTANCE = 0.9

	function Material:GetShadowFlags(word)
		if word == TRANSLUCENT_WORD and (self.Refraction > 0 or self.Additive) then
			return bit.bor(self.flag_words[word], TRANSLUCENT_MASK)
		end

		return self.flag_words[word]
	end

	function Material:GetShadowOpacity()
		local color = self.ColorMultiplier

		if self.Additive or self.Modulate or self.Decal then return 0 end

		if self.Refraction > 0 and not Material.GlassCastsShadow() then return 0 end

		if self.Refraction == 0 then return color.a end

		local transmittance = REFRACTION_TRANSMITTANCE * color:GetLuminance()
		local covering = self.Translucent and color.a or 1
		return 1 - (self.Refraction * transmittance + (1 - self.Refraction) * (1 - covering))
	end

	function Material:GetRayShadowOpacity()
		if self.Additive or self.Modulate then return 0 end

		if self.Refraction > 0 or self.Translucent then
			return self:GetShadowOpacity()
		end

		if self.AlphaTest and self.AlbedoTexture == nil then
			return self.ColorMultiplier.a >= self.AlphaCutoff and 1 or 0
		end

		return 1
	end
end

function Material:HasShadowTexture()
	return self.AlbedoTexture ~= nil and
		not self.AlbedoTextureAlphaIsRoughness and
		not self.AlbedoAlphaIsEmissive and
		not self.BlendTintByBaseAlpha and
		not self.Additive and
		not self.Modulate and
		(
			self.AlphaTest or
			self.Translucent or
			self.Refraction > 0
		)
end

Material.shadow_generation = 0
Material.shadow_full_generation = 0

function Material:InvalidateShadow()
	local opacity = self:GetRayShadowOpacity()

	if self.ray_shadow_opacity ~= nil and self.ray_shadow_opacity ~= opacity then
		Material.shadow_generation = Material.shadow_generation + 1
		self:StampShadow()
	end

	self.ray_shadow_opacity = opacity
end

do
	local material_cache_stats = setmetatable({}, {__mode = "k"})
	local override_loaders = {}

	function Material.RecordCacheRequest(source, cache_key, material)
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

	function Material.GetCacheStats()
		return material_cache_stats
	end

	function Material.SRGBTexture(path, config)
		config = config or {}
		config.path = path
		config.srgb = true
		return Texture.New(config)
	end

	function Material.LinearTexture(path, config)
		config = config or {}
		config.path = path
		config.srgb = false
		return Texture.New(config)
	end

	-- material source path (a vmt cache key) to the path of a material file that replaces it, set
	-- by the scene being read
	Material.path_aliases = {}

	function Material.RegisterOverrideLoader(extension, load)
		override_loaders[extension] = load
	end

	do
		local texture_overrides = {}

		function Material.RegisterTextureOverride(name, find)
			texture_overrides[name] = find
		end

		function Material.GetTextureOverride(vmt_path, vmt, material)
			for _, find in pairs(texture_overrides) do
				local override = find(vmt_path, vmt, material)

				if override then return override end
			end
		end
	end

	do
		local override_cache = {}

		function Material.GetOverrideFromPath(path)
			local alias = Material.path_aliases[path]

			if type(alias) == "string" then
				return nil, select(2, Material.GetOverrideFromPath(alias))
			elseif alias then
				return setmetatable(
					{},
					{
						__index = function(slots, slot)
							local target = alias[slot]

							if not target then return nil end

							slots[slot] = select(2, Material.GetOverrideFromPath(target))
							return slots[slot]
						end,
					}
				)
			end

			local cached = override_cache[path]

			if not cached then
				local load = assert(
					override_loaders[path:lower():match("%.[^%.]+$") or ""],
					"unsupported material override format: " .. path
				)
				local slots, material = load(path)
				cached = {slots = slots, material = material}
				override_cache[path] = cached
			end

			return cached.slots, cached.material
		end
	end

	function Material:SetError(err)
		self.Error = err
		logf("material error for %q: %s\n", tostring(self:GetName()), tostring(err))
		self:SetAlbedoTexture(Texture.GetFallback())
	end
end

return Material:Register()
