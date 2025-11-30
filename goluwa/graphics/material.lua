local ffi = require("ffi")
local Texture = require("graphics.texture")
local Material = {}
Material.__index = Material
-- Default material values (PBR metallic-roughness workflow)
local DEFAULT_BASE_COLOR = {1.0, 1.0, 1.0, 1.0}
local DEFAULT_METALLIC = 0.0
local DEFAULT_ROUGHNESS = 1.0
local DEFAULT_NORMAL_SCALE = 1.0
local DEFAULT_OCCLUSION_STRENGTH = 1.0
local DEFAULT_EMISSIVE = {0.0, 0.0, 0.0}
-- Cached default textures
local default_textures = {}

local function get_default_texture(type)
	if default_textures[type] then return default_textures[type] end

	local tex

	if type == "albedo" then
		-- White texture for albedo
		tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "R8G8B8A8_UNORM",
				buffer = ffi.new("uint8_t[4]", {255, 255, 255, 255}),
			}
		)
	elseif type == "normal" then
		-- Flat normal (pointing up in tangent space: 0.5, 0.5, 1.0)
		tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "R8G8B8A8_UNORM",
				buffer = ffi.new("uint8_t[4]", {128, 128, 255, 255}),
			}
		)
	elseif type == "metallic_roughness" then
		-- G channel = roughness (1.0), B channel = metallic (0.0)
		-- Following glTF spec: metallic in B, roughness in G
		tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "R8G8B8A8_UNORM",
				buffer = ffi.new("uint8_t[4]", {0, 255, 0, 255}), -- roughness=1.0, metallic=0.0
			}
		)
	elseif type == "occlusion" then
		-- White = no occlusion
		tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "R8G8B8A8_UNORM",
				buffer = ffi.new("uint8_t[4]", {255, 255, 255, 255}),
			}
		)
	elseif type == "emissive" then
		-- Black = no emission
		tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "R8G8B8A8_UNORM",
				buffer = ffi.new("uint8_t[4]", {0, 0, 0, 255}),
			}
		)
	end

	default_textures[type] = tex
	return tex
end

function Material.New(config)
	config = config or {}
	local self = setmetatable({}, Material)
	-- Textures (nil means use default)
	self.albedo_texture = config.albedo_texture
	self.normal_texture = config.normal_texture
	self.metallic_roughness_texture = config.metallic_roughness_texture
	self.occlusion_texture = config.occlusion_texture
	self.emissive_texture = config.emissive_texture
	-- Factors/multipliers
	self.base_color_factor = config.base_color_factor or DEFAULT_BASE_COLOR
	self.metallic_factor = config.metallic_factor or DEFAULT_METALLIC
	self.roughness_factor = config.roughness_factor or DEFAULT_ROUGHNESS
	self.normal_scale = config.normal_scale or DEFAULT_NORMAL_SCALE
	self.occlusion_strength = config.occlusion_strength or DEFAULT_OCCLUSION_STRENGTH
	self.emissive_factor = config.emissive_factor or DEFAULT_EMISSIVE
	-- Rendering flags
	self.double_sided = config.double_sided or false
	self.alpha_mode = config.alpha_mode or "OPAQUE" -- OPAQUE, MASK, BLEND
	self.alpha_cutoff = config.alpha_cutoff or 0.5
	-- Name for debugging
	self.name = config.name or "unnamed"
	return self
end

-- Get texture or default fallback
function Material:GetAlbedoTexture()
	return self.albedo_texture or get_default_texture("albedo")
end

function Material:GetNormalTexture()
	return self.normal_texture or get_default_texture("normal")
end

function Material:GetMetallicRoughnessTexture()
	return self.metallic_roughness_texture or get_default_texture("metallic_roughness")
end

function Material:GetOcclusionTexture()
	return self.occlusion_texture or get_default_texture("occlusion")
end

function Material:GetEmissiveTexture()
	return self.emissive_texture or get_default_texture("emissive")
end

-- Register all textures with a pipeline's bindless array
function Material:RegisterTextures(pipeline)
	pipeline:RegisterTexture(self:GetAlbedoTexture())
	pipeline:RegisterTexture(self:GetNormalTexture())
	pipeline:RegisterTexture(self:GetMetallicRoughnessTexture())
	pipeline:RegisterTexture(self:GetOcclusionTexture())
	pipeline:RegisterTexture(self:GetEmissiveTexture())
end

-- Get all texture indices for push constants
function Material:GetTextureIndices(pipeline)
	return {
		albedo = pipeline:GetTextureIndex(self:GetAlbedoTexture()),
		normal = pipeline:GetTextureIndex(self:GetNormalTexture()),
		metallic_roughness = pipeline:GetTextureIndex(self:GetMetallicRoughnessTexture()),
		occlusion = pipeline:GetTextureIndex(self:GetOcclusionTexture()),
		emissive = pipeline:GetTextureIndex(self:GetEmissiveTexture()),
	}
end

-- Check if material needs alpha blending
function Material:NeedsBlending()
	return self.alpha_mode == "BLEND"
end

-- Check if material needs alpha testing
function Material:NeedsAlphaTest()
	return self.alpha_mode == "MASK"
end

-- Create a default material
function Material.GetDefault()
	return Material.New()
end

return Material
