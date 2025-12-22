local ffi = require("ffi")
local commands = require("commands")
local tasks = require("tasks")
local Texture = require("render.texture")
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
				format = "r8g8b8a8_unorm",
				buffer = ffi.new("uint8_t[4]", {255, 255, 255, 255}),
			}
		)
	elseif type == "normal" then
		-- Flat normal (pointing up in tangent space: 0.5, 0.5, 1.0)
		tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "r8g8b8a8_unorm",
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
				format = "r8g8b8a8_unorm",
				buffer = ffi.new("uint8_t[4]", {0, 255, 0, 255}), -- roughness=1.0, metallic=0.0
			}
		)
	elseif type == "occlusion" then
		-- White = no occlusion
		tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "r8g8b8a8_unorm",
				buffer = ffi.new("uint8_t[4]", {255, 255, 255, 255}),
			}
		)
	elseif type == "emissive" then
		-- Black = no emission
		tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "r8g8b8a8_unorm",
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

do
	local steam = require("steam")

	local function unpack_numbers(str)
		str = str:gsub("%s+", " ")
		local t = str:split(" ")

		for k, v in ipairs(t) do
			t[k] = tonumber(v) or 0
		end

		return unpack(t)
	end

	local get_srgb = function(path)
		--return render.CreateTextureFromPath("[srgb]" .. path)
		return Texture.New({
			path = path,
			srgb = true,
		})
	end
	local get_non_srgb = function(path)
		--return render.CreateTextureFromPath("[~srgb]" .. path)
		return Texture.New({
			path = path,
			srgb = false,
		})
	end
	local property_translate = {
		basetexture = {"AlbedoTexture", get_srgb},
		basetexture2 = {"Albedo2Texture", get_srgb},
		texture2 = {"Albedo2Texture", get_srgb},
		bumpmap = {"NormalTexture", get_non_srgb},
		bumpmap2 = {"Normal2Texture", get_non_srgb},
		envmapmask = {"MetallicTexture", get_non_srgb},
		phongexponenttexture = {"RoughnessTexture", get_non_srgb},
		blendmodulatetexture = {"BlendTexture", get_non_srgb},
		selfillummask = {"SelfIlluminationTexture", get_non_srgb},
		selfillum = {
			"SelfIllumination",
			function(num)
				return num ~= 0
			end,
		},
		selfillumtint = {
			"IlluminationColor",
			function(v)
				if type(v) == "string" then
					if v:starts_with("[") then v = v:sub(2, -2) end

					local r, g, b = unpack_numbers(v)
					return Color(r, g, b, 1)
				elseif typex(v) == "vec3" then
					return Color(v.x, v.y, v.z, 1)
				end

				return v
			end,
		},
		alphatest = {
			"AlphaTest",
			function(num)
				return num == 1
			end,
		},
		ssbump = {
			"SSBump",
			function(num)
				return num == 1
			end,
		},
		nocull = {"NoCull"},
		translucent = {
			"Translucent",
			function(num)
				return num == 1
			end,
		},
		normalmapalphaenvmapmask = {
			"NormalAlphaMetallic",
			function(num)
				return num == 1
			end,
		},
		basealphaenvmapmask = {
			"AlbedoAlphaMetallic",
			function(num)
				return num == 1
			end,
		},
		basemapluminancephongmask = {
			"AlbedoLuminancePhongMask",
			function(num)
				return num == 1
			end,
		},
		basemapalphaphongmask = {
			"AlbedoPhongMask",
			function(num)
				return num == 1
			end,
		},
		blendtintbybasealpha = {
			"BlendTintByBaseAlpha",
			function(num)
				return num == 1
			end,
		},
		phongexponent = {
			"RoughnessMultiplier",
			function(num)
				return 1 / (-num + 1) ^ 3
			end,
		},
		envmaptint = {
			"MetallicMultiplier",
			function(num)
				if type(num) == "string" then
					return Vec3(unpack_numbers(num)):GetLength()
				elseif type(num) == "number" then
					return num
				elseif typex(num) == "vec3" then
					return num:GetLength()
				elseif typex(num) == "color" then
					return Vec3(num.r, num.g, num.b):GetLength()
				end
			end,
		},
	}
	local special_textures = {
		_rt_fullframefb = "error",
		[1] = "error", -- huh
	}
	steam.unused_vmt_properties = steam.unused_vmt_properties or {}

	function Material.FromVMT(path)
		local self = Material.New()
		--self:SetName(path)
		self.vmt = {}
		self.vmt_path = path -- Store path for debugging
		local cb = steam.LoadVMT(path, function(key, val, full_path)
			self.vmt.fullpath = full_path
			self.vmt[key] = val
			local unused = false

			if property_translate[key] then
				local field_name, convert = unpack(property_translate[key])

				if convert then val = convert(val) end

				-- Convert field name to lowercase with underscore (AlbedoTexture -> albedo_texture)
				local internal_field = field_name:gsub("(%u)", function(c)
					return "_" .. c:lower()
				end):sub(2)
				-- Directly set the field on the material
				self[internal_field] = val
			else
				unused = true
			end

			if unused then
				steam.unused_vmt_properties[full_path] = steam.unused_vmt_properties[full_path] or {}
				steam.unused_vmt_properties[full_path][key] = val
			end
		end, function(err)
			print("Material error for " .. path .. ": " .. err)
		--self:SetError(err)
		end)

		if tasks.GetActiveTask() then cb:Get() end

		return self
	end

	if RELOAD then
		for _, v in pairs(prototype.GetCreated()) do
			if v.Type == "material" and v.ClassName == "model" and v.vmt then

			--v:SetMetallicMultiplier(v:GetMetallicMultiplier()/3)
			end
		end
	end

	commands.Add("dump_unused_vmt_properties", function()
		for k, v in pairs(steam.unused_vmt_properties) do
			local properties = {}

			for k, v in pairs(v) do
				if
					k ~= "shader" and
					k ~= "fullpath" and
					k ~= "envmap" and
					k ~= "%keywords" and
					k ~= "surfaceprop"
				then
					properties[k] = v
				end
			end

			if next(properties) then
				logf("%s %s:\n", v.shader, k)

				for k, v in pairs(properties) do
					logf("\t%s = %s\n", k, v)
				end
			end
		end
	end)
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
local def = nil

function Material.GetDefault()
	def = def or Material.New()
	return def
end

return Material
