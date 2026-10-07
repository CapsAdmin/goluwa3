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
local material_proxies = import("goluwa/render3d/material_proxies.lua")
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
Material:GetSet("OriginalMaterial", "", {multiline = true})
Material:GetSet("BaseTextureTransformU", Vec4(1, 0, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("BaseTextureTransformV", Vec4(0, 1, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("BumpTransformU", Vec4(1, 0, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("BumpTransformV", Vec4(0, 1, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("Texture2TransformU", Vec4(1, 0, 0, 0), {callback = "InvalidateRayMaterial"})
Material:GetSet("Texture2TransformV", Vec4(0, 1, 0, 0), {callback = "InvalidateRayMaterial"})
Material:EndStorable()

function Material:SetTextureTransformFromVMT(name, str)
	local m = material_proxies.ParseTransform(str)
	self["Set" .. name .. "TransformU"](self, Vec4(m[1], m[2], m[3], 0))
	self["Set" .. name .. "TransformV"](self, Vec4(m[4], m[5], m[6], 0))
	self.has_uv_transform = true
end

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

	local ENVMAP_F0 = 0.5
	local ENVMAP_ROUGHNESS = 0.125 * 0
	local PHONG_MAX_F0 = 0.5

	local function on_load_vmt(self, vmt)
		self.vmt = vmt
		self:SetMetallicMultiplier(0)

		do
			if vmt.basetexture then
				self:SetAlbedoTexture(SRGBTexture(vmt.basetexture))
			end

			if vmt.basetexture2 then
				self:SetAlbedo2Texture(SRGBTexture(vmt.basetexture2))
			end
		end

		do
			if vmt.bumpmap then self:SetNormalTexture(LinearTexture(vmt.bumpmap)) end

			if vmt.bumpmap2 then self:SetNormal2Texture(LinearTexture(vmt.bumpmap2)) end

			if vmt.ssbump == 1 then self:SetNormalTextureIsSSBump(true) end
		end

		if vmt.blendmodulatetexture then
			self:SetBlendTexture(LinearTexture(vmt.blendmodulatetexture))
		end

		if vmt.blendtintbybasealpha == 1 then self:SetBlendTintByBaseAlpha(true) end

		if type(vmt.basetexturetransform) == "string" then
			self:SetTextureTransformFromVMT("BaseTexture", vmt.basetexturetransform)
		end

		if type(vmt.bumptransform) == "string" then
			self:SetTextureTransformFromVMT("Bump", vmt.bumptransform)
		end

		if type(vmt.texture2transform) == "string" then
			self:SetTextureTransformFromVMT("Texture2", vmt.texture2transform)
		end

		if vmt.texture2 then
			self:SetAlbedo2Texture(SRGBTexture(vmt.texture2))
			local shader = vmt.shader:lower()

			if shader == "de_unlitthreetexture" or shader == "unlittwotexture" then
				self:SetMultiplyAlbedo2(true)
			end
		end

		if vmt.envmap then
			if vmt.envmapmask then
				self:SetRoughnessTexture(LinearTexture(vmt.envmapmask))
				self:SetInvertRoughnessTexture(true)
			end

			-- the mask is the normal map's alpha when it has one, and only then the base alpha
			local normal_mask = vmt.normalmapalphaenvmapmask == 1 and vmt.bumpmap ~= nil

			if normal_mask then
				self:SetNormalTextureAlphaIsRoughness(true)
				self:SetInvertRoughnessTexture(true)
			elseif vmt.basealphaenvmapmask == 1 then
				-- source reflects where the base alpha is low, unlike the normal map's alpha
				self:SetAlbedoTextureAlphaIsRoughness(true)
			end

			if not self:HasExplicitRoughnessTexture() then self:SetRoughnessMultiplier(0) end

			-- an envmap is a cubemap lookup of fixed sharpness, its mask only scales how much of it is added
			if vmt.phong ~= 1 then
				self:SetRoughnessMaskOnlyScalesSpecular(true)
				self:SetRoughnessMultiplier(ENVMAP_ROUGHNESS)
			end
		end

		if vmt.phong == 1 then
			-- a bump mapped phong is masked by the normal map's alpha unless told otherwise
			if
				vmt.bumpmap and
				not vmt.phongexponenttexture and
				vmt.basemapalphaphongmask ~= 1 and
				vmt.basemapluminancephongmask ~= 1 and
				not self:HasExplicitRoughnessTexture()
			then
				self:SetNormalTextureAlphaIsRoughness(true)
			end

			self:SetInvertRoughnessTexture(vmt.invertphongmask ~= 1)

			if vmt.phongexponenttexture then
				self:SetRoughnessTexture(LinearTexture(vmt.phongexponenttexture))
			end

			if vmt.basemapalphaphongmask == 1 then
				self:SetAlbedoTextureAlphaIsRoughness(true)
			elseif vmt.basemapluminancephongmask == 1 then
				self:SetAlbedoLuminanceIsRoughness(true)
			end

			local halflambert = vmt.halflambert == 1
			local exponent = vmt.phongexponent or 5
			local boost = vmt.phongboost or 1
			local fresnelranges = vmt.phongfresnelranges or Vec3(0, 0.5, 1)
			local roughness = math.sqrt(2 / (exponent + 2))

			if boost > 1 then roughness = roughness / math.sqrt(boost) end

			roughness = math.max(0.04, math.min(1.0, roughness))

			-- a phong mask only decides how strong the highlight is, the exponent alone sets its size
			if
				not vmt.phongexponenttexture and
				(
					self:HasExplicitRoughnessTexture() or
					self.AlbedoLuminanceIsRoughness
				)
			then
				self:SetRoughnessMaskOnlyScalesSpecular(true)
			elseif self:HasExplicitRoughnessTexture() then
				roughness = 1 - roughness
			end

			self:SetRoughnessMultiplier(roughness)
		end

		if not vmt.envmap and vmt.phong ~= 1 then
			self:SetSpecularMultiplier(0)
		else
			-- source adds the envmap and the phong highlight on top of the diffuse. a
			-- dielectric's F0 of 0.04 can't hold that, a metallic that keeps both can
			local f0 = 0.04

			if vmt.envmap then
				local tint = vmt.envmaptint
				local lum = 1

				if type(tint) == "string" then
					local r, g, b = unpack_numbers(tint)
					lum = r * 0.2126 + (g or r) * 0.7152 + (b or r) * 0.0722
				elseif type(tint) == "number" then
					lum = tint
				elseif typex(tint) == "vec3" then
					lum = tint.x * 0.2126 + tint.y * 0.7152 + tint.z * 0.0722
				elseif typex(tint) == "color" then
					lum = tint.r * 0.2126 + tint.g * 0.7152 + tint.b * 0.0722
				end

				-- without a phong there is no direct specular in source, so no dielectric floor
				f0 = vmt.phong == 1 and math.max(f0, ENVMAP_F0 * lum) or ENVMAP_F0 * lum
			end

			if vmt.phong == 1 then
				local ranges = vmt.phongfresnelranges
				f0 = math.max(
					f0,
					math.min(0.04 * (vmt.phongboost or 1) * (ranges and ranges.x or 0), PHONG_MAX_F0)
				)
			end

			self:SetSpecularMultiplier(f0 / 0.04)
			self:SetSpecularSolvesMetallic(true)
			self:SetSpecularFromRoughnessMask(self:HasExplicitRoughnessTexture())
		end

		if vmt.selfillum == 1 then
			if vmt.selfillumtint then
				if typex(vmt.selfillumtint) == "vec3" then
					self:SetEmissiveMultiplier(Color(vmt.selfillumtint.x, vmt.selfillumtint.y, vmt.selfillumtint.z, 1))
				elseif typex(vmt.selfillumtint) == "color" then
					self:SetEmissiveMultiplier(Color(vmt.selfillumtint.r, vmt.selfillumtint.g, vmt.selfillumtint.b, 1))
				else
					print("wtf ", vmt.selfillumtint)
				end
			end

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

		if vmt.additive == 1 then
			self:SetAdditive(true)
			self:SetDisplayReferred(true)
			self:SetTranslucent(true)
		end

		if vmt.shader:lower() == "decalmodulate" or vmt.shader:lower() == "modulate" then
			self:SetModulate(true)
			self:SetTranslucent(true)
		end

		if vmt.color or vmt.alpha then
			local tint = vmt.color
			local alpha = vmt.alpha or 1

			if typex(tint) == "vec3" then
				self:SetColorMultiplier(Color(tint.x, tint.y, tint.z, alpha))
			elseif tint then
				self:SetColorMultiplier(Color(tint.r, tint.g, tint.b, alpha))
			else
				self:SetColorMultiplier(Color(1, 1, 1, alpha))
			end
		end

		if typex(vmt.srgbtint) == "vec3" then
			-- source multiplies this in gamma space, which in linear is the tint to the 2.2
			local tint, color = vmt.srgbtint, self.ColorMultiplier:Copy()
			color.r, color.g, color.b = color.r * tint.x ^ 2.2, color.g * tint.y ^ 2.2, color.b * tint.z ^ 2.2
			self:SetColorMultiplier(color)
		end

		if vmt.shader:lower() == "refract" then
			self:SetRefraction(1)
			self:SetIndexOfRefraction(1 + (vmt.refractamount or 0.5))
			self:SetRefractionThickness(0)
			self:SetSpecularMultiplier(1)

			if vmt.normalmap then self:SetNormalTexture(LinearTexture(vmt.normalmap)) end

			if vmt.normalmapalphaenvmapmask == 1 then
				self:SetNormalAlphaIsCoverage(true)
			end

			if vmt.refracttinttexture then
				self:SetAlbedoTexture(SRGBTexture(vmt.refracttinttexture))
			end

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

		if vmt.surfaceprop then
			local function get_prop(prop, key)
				if type(prop) ~= "table" then return nil end

				if prop[key] ~= nil then return prop[key] end

				if prop.base then return get_prop(prop.base, key) end

				return nil
			end

			local name = get_prop(vmt.surfaceprop, "surfaceprop_name")

			if name then name = name:lower() end

			if not name then name = get_prop(vmt.surfaceprop, "gamematerial") end

			self.vmt_surfaceprop = name
			local surfaceprop_pbr = {
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
				metal_sand = {0.7, 0.6},
				rustybarrel = {0.7, 0.5},
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
				dirt = {0.95, 0.0},
				grass = {0.95, 0.0},
				mud = {0.85, 0.0},
				sand = {0.95, 0.0},
				quicksand = {0.8, 0.0},
				slime = {0.4, 0.0},
				antlionsand = {0.9, 0.0},
				slipperyslime = {0.3, 0.0},
				wood = {0.7, 0.0},
				wood_lowdensity = {0.75, 0.0},
				wood_box = {0.7, 0.0},
				wood_crate = {0.7, 0.0},
				wood_plank = {0.7, 0.0},
				wood_furniture = {0.5, 0.0},
				wood_solid = {0.65, 0.0},
				wood_panel = {0.55, 0.0},
				wood_ladder = {0.7, 0.0},
				glass = {0.05, 0.0},
				glassbottle = {0.05, 0.0},
				glass_breakable = {0.05, 0.0},
				canister = {0.15, 0.0},
				cloth = {0.9, 0.0},
				carpet = {0.95, 0.0},
				paper = {0.9, 0.0},
				papercup = {0.85, 0.0},
				cardboard = {0.9, 0.0},
				upholstery = {0.9, 0.0},
				mattress = {0.95, 0.0},
				rubber = {0.8, 0.0},
				rubbertire = {0.85, 0.0},
				plastic = {0.5, 0.0},
				plastic_barrel = {0.5, 0.0},
				plastic_barrel_buoyant = {0.5, 0.0},
				plastic_box = {0.5, 0.0},
				jeeptire = {0.8, 0.0},
				brakingrubbertire = {0.75, 0.0},
				flesh = {0.7, 0.0},
				bloodyflesh = {0.6, 0.0},
				armorflesh = {0.55, 0.15},
				alienflesh = {0.5, 0.0},
				antlion = {0.6, 0.0},
				zombieflesh = {0.65, 0.0},
				player = {0.6, 0.0},
				player_control_clip = {0.6, 0.0},
				item = {0.5, 0.0},
				foliage = {0.95, 0.0},
				tree = {0.8, 0.0},
				water = {0.05, 0.0},
				wade = {0.1, 0.0},
				slosh = {0.15, 0.0},
				ice = {0.15, 0.0},
				snow = {0.95, 0.0},
				default = {0.7, 0.0},
				default_silent = {0.7, 0.0},
				floating_metal_barrel = {0.45, 1.0},
				no_decal = {0.7, 0.0},
				player_gamemovement = {0.6, 0.0},
				portalgun = {0.15, 1.0},
				turret = {0.2, 1.0},
				playerclip = {0.7, 0.0},
				npcclip = {0.7, 0.0},
				metaldoor = {0.3, 1.0},
				wood_door = {0.6, 0.0},
				metal_duct = {0.35, 1.0},
				computer = {0.3, 0.4},
				pottery = {0.6, 0.0},
				asphalt_portal = {0.9, 0.0},
				concrete_portal = {0.85, 0.0},
				metal_portal = {0.3, 1.0},
				gmod_bouncy = {0.5, 0.0},
				gmod_ice = {0.1, 0.0},
				gmod_silent = {0.7, 0.0},
				C = {0.9, 0.0},
				D = {0.95, 0.0},
				G = {0.05, 0.0},
				I = {0.5, 0.0},
				M = {0.35, 1.0},
				O = {0.7, 0.0},
				P = {0.6, 0.0},
				S = {0.95, 0.0},
				T = {0.4, 0.0},
				V = {0.85, 0.0},
				W = {0.7, 0.0},
				X = {0.5, 0.0},
				Y = {0.05, 0.0},
				Z = {0.5, 0.0},
				N = {0.95, 0.0},
				U = {0.95, 0.0},
				L = {0.85, 0.0},
				A = {0.65, 0.0},
				F = {0.95, 0.0},
				E = {0.1, 0.0},
				H = {0.9, 0.0},
				K = {0.9, 0.0},
				R = {0.5, 0.0},
			}
			local pbr = surfaceprop_pbr[name]

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
				local metallic = 0.0

				if density > 6000 and audioreflectivity > 0.8 then
					metallic = 1.0
				elseif density > 4000 and audioreflectivity > 0.6 then
					metallic = 0.7
				end

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

				if avg > 0.05 then
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

		if
			file_path.GetFileNameFromPath(self.Name):lower():find("grass", 1, true) or
			(
				self.AlbedoTexture and
				Material.IsGrassTexture(self.AlbedoTexture)
			)
		then
			self:SetGrass(true)
		end

		if
			self.Translucent and
			(
				file_path.GetFileNameFromPath(self.Name):lower():find("glass", 1, true) or
				(
					self.AlbedoTexture and
					Material.IsGlassTexture(self.AlbedoTexture)
				)
			)
		then
			self:SetAdditive(false)
			self:SetRefraction(1)
			self:SetRefractionThickness(0)
			self:SetAlbedoAlphaIsEmissive(false)
			self:SetRoughnessTexture(nil)
			self:SetInvertRoughnessTexture(false)
			self:SetMetallicMultiplier(0)
			self:SetRoughnessMultiplier(0.04)
			self:SetSpecularMultiplier(1)
		end

		material_proxies.Attach(self, vmt.source_text)
		local color = self.ColorMultiplier
		local flags = {}

		for _, name in ipairs{"Additive", "Modulate", "Translucent", "AlphaTest", "DoubleSided", "NoDraw"} do
			if self[name] then flags[#flags + 1] = name end
		end

		self:SetOriginalMaterial(
			string.format(
				"path: %s\nfile: %s\nshader: %s\nbasetexture: %s\nflags: %s\ncolor multiplier: %.3f %.3f %.3f %.3f\n\n%s",
				tostring(vmt.fullpath),
				tostring(vmt.resolved_path),
				tostring(vmt.shader),
				tostring(vmt.basetexture),
				table.concat(flags, " "),
				color.r,
				color.g,
				color.b,
				color.a,
				tostring(vmt.source_text)
			)
		)
	end

	local special_textures = {
		_rt_fullframefb = "error",
		[1] = "error",
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
		"^resolved_path$",
		"^source_text$",
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
		self.vmt_path = cache_key
		self.upload_cache_key = cache_key
		vmt_material_cache[cache_key] = self
		local cb = steam.LoadVMT(cache_key, function(vmt)
			on_load_vmt(self, track_vmt(vmt))
		end, function(err)
			print("Material error for " .. cache_key .. ": " .. err)
			self:SetError(err)
		end)

		if tasks.GetActiveTask() then cb:TryGet() end

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
