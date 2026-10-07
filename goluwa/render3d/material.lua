local commands = import("goluwa/cli/commands.lua")
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
local Material = objects.CreateTemplate("render3d_material")
Material:StartStorable()
Material:GetSet("AlbedoTexture", nil, {type = "render_texture", callback = "InvalidateAlbedo"})
Material:GetSet("NormalTexture", nil, {type = "render_texture"})
Material:GetSet("HeightTexture", nil, {type = "render_texture", callback = "InvalidateHeightMap"})
Material:GetSet("MetallicRoughnessTexture", nil, {type = "render_texture"})
Material:GetSet("AmbientOcclusionTexture", nil, {type = "render_texture"})
Material:GetSet(
	"EmissiveTexture",
	nil,
	{type = "render_texture", callback = "InvalidateEmission"}
)
Material:GetSet(
	"Albedo2Texture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet("Normal2Texture", nil, {type = "render_texture"})
Material:GetSet(
	"BlendTexture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet("DetailTexture", nil, {type = "render_texture"})
Material:GetSet(
	"TerrainMaterialTexture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet(
	"TerrainLayer1Texture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet(
	"TerrainLayer2Texture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet(
	"TerrainLayer3Texture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet(
	"TerrainLayer4Texture",
	nil,
	{type = "render_texture", callback = "InvalidateRayMaterial"}
)
Material:GetSet("TerrainLayer1NormalTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer2NormalTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer3NormalTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer4NormalTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer1HeightTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer2HeightTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer3HeightTexture", nil, {type = "render_texture"})
Material:GetSet("TerrainLayer4HeightTexture", nil, {type = "render_texture"})
Material:GetSet("MetallicTexture", nil, {type = "render_texture"})
Material:GetSet("RoughnessTexture", nil, {type = "render_texture"})
Material:GetSet("SpecularTexture", nil, {type = "render_texture"})
Material:GetSet("TransmissionTexture", nil, {type = "render_texture"})
Material:GetSet("ColorMultiplier", Color(1.0, 1.0, 1.0, 1.0), {callback = "InvalidateColor"})
Material:GetSet(
	"EmissiveMultiplier",
	Color(1.0, 1.0, 1.0, 1.0),
	{callback = "InvalidateEmission"}
)
Material:GetSet("TerrainLayerScales", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayerHeightScales", Color(0.0, 0.0, 0.0, 0.0))
Material:GetSet("TerrainLayerHeightDistance", 128)
Material:GetSet("TerrainLayerRoughness", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainLayerAmbientOcclusion", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet(
	"TerrainLayerDetailStrength",
	Color(0.0, 0.0, 0.0, 0.0),
	{callback = "InvalidateRayMaterial"}
)
Material:GetSet(
	"TerrainLayerAdditiveDetail",
	Color(0.0, 0.0, 0.0, 0.0),
	{callback = "InvalidateRayMaterial"}
)
Material:GetSet("TerrainLayerSpecular", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TerrainBounds", Vec3(0, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("TerrainLayerGrass", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("MetallicMultiplier", 1.0)
Material:GetSet("RoughnessMultiplier", 1.0)
Material:GetSet("SpecularMultiplier", 1.0)
Material:GetSet("Clearcoat", 0.0)
Material:GetSet("ClearcoatRoughness", 0.05)
Material:GetSet("NormalMapMultiplier", 1.0)
Material:GetSet("AmbientOcclusionMultiplier", 1.0)
Material:GetSet("HeightScale", 0.0, {callback = "InvalidateHeightMap"})
Material:GetSet("HeightMidlevel", 1.0)
Material:GetSet("HeightLayers", 24)
Material:GetSet("DetailTiling", Vec2(1.0, 1.0))
Material:GetSet("DetailBumpScale", 1.0)
Material:GetSet("DetailBlendAmount", 0.0)
Material:GetSet("GroundColorTexture", nil, {type = "render_texture"})
Material:GetSet("GroundColorBlend", 0.0)
Material:GetSet("GroundColorUV", Color(1.0, 0.0, 0.0, 1.0))
Material:GetSet("DiffuseTransmission", 0.0, {callback = "InvalidateFlags"})
Material:GetSet("TransmissionColor", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("TransmissionScattering", 0.5)
Material:GetSet("Bending", 0.0)
Material:GetSet("DetailBending", "none")
Material:GetSet("BendDetailFrequency", 5.0)
Material:GetSet("BendDetailLeafAmplitude", 0.08)
Material:GetSet("BendDetailBranchAmplitude", 0.2)
Material:GetSet("BendDetailPhase", 100.0)
Material:GetSet("GrassDensity", 700.0)
Material:GetSet("GrassHeight", 0.28)
Material:GetSet("GrassHeightVariance", 0)
Material:GetSet("GrassWidth", 0.02)
Material:GetSet("Refraction", 0.0, {callback = "InvalidateTransparency"})
Material:GetSet("IndexOfRefraction", 1.5)
Material:GetSet("RefractionThickness", -1.0)
Material:GetSet("AlphaCutoff", 0.5, {callback = "InvalidateColor"})
Material:GetSet("IgnoreZ", false, {callback = "InvalidateSceneKey"})
Material:GetSet("DoubleSided", false, {callback = "InvalidateFlags"})
Material:GetSet("NoDraw", false, {callback = "InvalidateSceneKey"})
Material:GetSet("Flags", 0)
Material:GetSet("NormalTextureAlphaIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("NormalTextureIsSSBump", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoTextureAlphaIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoLuminanceIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("BlendTintByBaseAlpha", false, {callback = "InvalidateFlags"})
Material:GetSet("MetallicTextureAlphaIsEmissive", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoAlphaIsEmissive", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoAlphaIsSpecular", false, {callback = "InvalidateFlags"})
Material:GetSet("GlossIsShininess", false, {callback = "InvalidateFlags"})
Material:GetSet("SpecularSolvesMetallic", false, {callback = "InvalidateFlags"})
Material:GetSet("Translucent", false, {callback = "InvalidateFlags"})
Material:GetSet("AlphaTest", false, {callback = "InvalidateFlags"})
Material:GetSet("Additive", false, {callback = "InvalidateFlags"})
Material:GetSet("Modulate", false, {callback = "InvalidateFlags"})
Material:GetSet("MultiplyAlbedo2", false, {callback = "InvalidateFlags"})
Material:GetSet("DisplayReferred", false, {callback = "InvalidateFlags"})
Material:GetSet("NormalAlphaIsCoverage", false, {callback = "InvalidateFlags"})
Material:GetSet("SpecularFromRoughnessMask", false, {callback = "InvalidateFlags"})
Material:GetSet("RoughnessMaskOnlyScalesSpecular", false, {callback = "InvalidateFlags"})
Material:GetSet("InvertRoughnessTexture", false, {callback = "InvalidateFlags"})
Material:GetSet("Grass", false, {callback = "InvalidateFlags"})
Material:GetSet("Billboard", false, {callback = "InvalidateFlags"})
Material:GetSet("OriginalMaterial", "", {multiline = true})
Material:GetSet("BaseTextureTransformU", Vec4(1, 0, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("BaseTextureTransformV", Vec4(0, 1, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("BumpTransformU", Vec4(1, 0, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("BumpTransformV", Vec4(0, 1, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("Texture2TransformU", Vec4(1, 0, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("Texture2TransformV", Vec4(0, 1, 0, 0), {callback = "InvalidateRayMaterial"})
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

	function Material:GetBlendEquation()
		return self.Translucent and translucent or opaque
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

function Material:HasHeightMap()
	return self.HeightTexture ~= nil and self.HeightScale > 0
end

function Material:HasVertexAnimation()
	return self.Bending > 0 or self.DetailBending ~= "none"
end

function Material:IsTransparent()
	return self.Translucent or self.Refraction > 0
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
	"Grass",
	"AlbedoAlphaIsSpecular",
	"GlossIsShininess",
	"SpecularSolvesMetallic",
	"Additive",
	"Modulate",
	"MultiplyAlbedo2",
	"DisplayReferred",
	"NormalAlphaIsCoverage",
	"SpecularFromRoughnessMask",
	"RoughnessMaskOnlyScalesSpecular",
	"Billboard",
}

for i, flag_name in ipairs(FLAGS) do
	if not Material["Get" .. flag_name] then
		error("Material is missing flag getter: " .. flag_name)
	end
end

Material.flags_generation = 0
Material.scene_dirty_materials = Material.scene_dirty_materials or {}

function Material:InvalidateSceneKey()
	Material.scene_dirty_materials[self] = true
end

Material.emission_dirty_materials = Material.emission_dirty_materials or {}

function Material:InvalidateEmission()
	Material.emission_dirty_materials[self] = true
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
	local flags = 0

	for i, flag_name in ipairs(FLAGS) do
		if self["Get" .. flag_name](self) then
			flags = bit.bor(flags, bit.lshift(1, i - 1))
		end
	end

	self.Flags = flags
	self:InvalidateShadow()
end

Material:GetSet("Name", "")

function Material.IsGrassTexture(texture)
	return texture.config.path and
		file_path.GetFileNameFromPath(texture.config.path):lower():find("grass", 1, true) ~= nil
end

function Material.IsGlassTexture(texture)
	return texture.config.path and
		file_path.GetFileNameFromPath(texture.config.path):lower():find("glass", 1, true) ~= nil
end

function Material:GetDebugFlagMap()
	local tbl = {}

	for i, flag_name in ipairs(FLAGS) do
		tbl[flag_name] = bit.band(self.Flags, bit.lshift(1, i - 1)) ~= 0
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

function Material:GetFillFlags()
	return self.Flags
end

do
	local TRANSLUCENT_FLAG = 2
	local REFRACTION_TRANSMITTANCE = 0.9

	function Material:GetShadowFlags()
		if self.Refraction > 0 or self.Additive then
			return bit.bor(self.Flags, TRANSLUCENT_FLAG)
		end

		return self.Flags
	end

	function Material:GetShadowOpacity()
		local color = self.ColorMultiplier

		if self.Additive or self.Modulate then return 0 end

		if self.Refraction > 0 and not Material.GlassCastsShadow() then return 0 end

		if self.Refraction == 0 then return color.a end

		local transmittance = REFRACTION_TRANSMITTANCE * (
				0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
			)
		local covering = self.Translucent and color.a or 1
		return 1 - (
				self.Refraction * transmittance + (
					1 - self.Refraction
				) * (
					1 - covering
				)
			)
	end

	function Material:GetSoupShadowOpacity()
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
	local opacity = self:GetSoupShadowOpacity()

	if self.soup_shadow_opacity ~= nil and self.soup_shadow_opacity ~= opacity then
		Material.shadow_generation = Material.shadow_generation + 1
		self:StampShadow()
	end

	self.soup_shadow_opacity = opacity
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

	local function get_unique_cached_materials()
		local list = {}

		for material in pairs(material_cache_stats) do
			list[#list + 1] = material
		end

		return list
	end

	local function color_is_default(color)
		return color and color.r == 1 and color.g == 1 and color.b == 1 and color.a == 1
	end

	function Material.SRGBTexture(path)
		return Texture.New{
			path = path,
			srgb = true,
		}
	end

	function Material.LinearTexture(path, config)
		config = config or {}
		config.path = path
		config.srgb = false
		return Texture.New(config)
	end

	function Material.RegisterOverrideLoader(extension, load)
		override_loaders[extension] = load
	end

	do
		local override_cache = {}

		function Material.GetOverrideFromPath(path)
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
				primary_key = stats.key_order[1] or "<unknown>",
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
			local sources = material_cache_stats[material].sources

			if sources.vmt then counts.vmt = counts.vmt + 1 end

			if sources.crymtl then counts.crymtl = counts.crymtl + 1 end

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
				material:GetAdditive() or
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
end

return Material:Register()
