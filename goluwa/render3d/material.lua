local ffi = require("ffi")
local commands = require("commands")
local tasks = require("tasks")
local Texture = require("render.texture")
local Color = require("structs.color")
local prototype = require("prototype")
local Material = prototype.CreateTemplate("material")
-- textures
Material:GetSet("AlbedoTexture", nil)
Material:GetSet("NormalTexture", nil)
Material:GetSet("MetallicRoughnessTexture", nil)
Material:GetSet("AmbientOcclusionTexture", nil)
Material:GetSet("EmissiveTexture", nil)
Material:GetSet("Albedo2Texture", nil)
Material:GetSet("Normal2Texture", nil)
Material:GetSet("AlbedoBlendTexture", nil)
Material:GetSet("MetallicTexture", nil)
Material:GetSet("SelfIlluminationTexture", nil)
Material:GetSet("RoughnessTexture", nil)
-- multipliers
Material:GetSet("ColorMultiplier", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("EmissiveMultiplier", Color(0.0, 0.0, 0.0, 0.0))
Material:GetSet("MetallicMultiplier", 1.0)
Material:GetSet("RoughnessMultiplier", 1.0)
Material:GetSet("NormalMapMultiplier", 1.0)
Material:GetSet("AmbientOcclusionMultiplier", 1.0)
-- other
Material:GetSet("AlphaCutoff", 0.5)
Material:GetSet("DoubleSided", false) -- todo, disable culling
-- flags
Material:GetSet("Flags", 0)
Material:GetSet("ReverseXZNormalMap", false, {callback = "InvalidateFlags"})
Material:GetSet("NormalTextureAlphaIsMetallic", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoTextureAlphaIsMetallic", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoTextureAlphaIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("AlbedoLuminanceIsRoughness", false, {callback = "InvalidateFlags"})
Material:GetSet("BlendTintByBaseAlpha", false, {callback = "InvalidateFlags"})
Material:GetSet("MetallicTextureAlphaIsEmissive", false, {callback = "InvalidateFlags"})
Material:GetSet("Translucent", false, {callback = "InvalidateFlags"})
Material:GetSet("AlphaTest", false, {callback = "InvalidateFlags"})
Material:GetSet("InvertRoughnessTexture", false, {callback = "InvalidateFlags"})

function Material.New(config)
	local self = prototype.CreateObject("material")

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
	"NormalTextureAlphaIsMetallic",
	"AlbedoTextureAlphaIsMetallic",
	"AlbedoTextureAlphaIsRoughness",
	"AlbedoLuminanceIsRoughness",
	"MetallicTextureAlphaIsEmissive",
}

function Material:InvalidateFlags()
	local flags = 0

	for i, flag_name in ipairs(FLAGS) do
		if self["Get" .. flag_name](self) then
			flags = bit.bor(flags, bit.lshift(1, i - 1))
		end
	end

	self.Flags = flags
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
	local steam = require("steam")

	local function unpack_numbers(str)
		str = str:gsub("%s+", " ")
		local t = str:split(" ")

		for k, v in ipairs(t) do
			t[k] = tonumber(v) or 0
		end

		return unpack(t)
	end

	local SRGBTexture = function(path)
		--return render.CreateTextureFromPath("[srgb]" .. path)
		return Texture.New({
			path = path,
			srgb = true,
		})
	end
	local LinearTexture = function(path)
		--return render.CreateTextureFromPath("[~srgb]" .. path)
		return Texture.New({
			path = path,
			srgb = false,
		})
	end

	local function on_load_vmt(self, vmt)
		self:SetReverseXZNormalMap(true) -- Source engine normals need XY flip
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
			self:SetAlbedoBlendTexture(SRGBTexture(vmt.blendmodulatetexture))
		end

		if vmt.envmap then -- envmap
			if vmt.envmapmask then
				self:SetMetallicTexture(LinearTexture(vmt.envmapmask))
			end

			if vmt.normalmapalphaenvmapmask == 1 then
				self:SetNormalTextureAlphaIsMetallic(vmt.normalmapalphaenvmapmask == 1)
			end

			if vmt.basealphaenvmapmask == 1 then
				self:SetAlbedoTextureAlphaIsMetallic(vmt.basealphaenvmapmask == 1)
			end

			if vmt.envmaptint then
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
				-- Phong exponent texture stores exponent values (high = shiny)
				-- PBR roughness is inverted (high = rough), so we need to invert
				self:SetInvertRoughnessTexture(true)
			end

			if vmt.basemapalphaphongmask == 1 then
				self:SetAlbedoTextureAlphaIsRoughness(true)
			elseif vmt.basemapluminancephongmask == 1 then
				self:SetAlbedoLuminanceIsRoughness(true)
			end

			-- invertphongmask flips the inversion (so if we already set it, toggle it off)
			if vmt.invertphongmask == 1 then
				self:SetInvertRoughnessTexture(not self:GetInvertRoughnessTexture())
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

		if vmt.blendtintbybasealpha == 1 then
			-- this should be a mask for color multiplier
			-- it allows changing the color of specific parts of the texture while keeping others unaffected
			self:SetBlendTintByBaseAlpha(true)
		end

		if vmt.selfillum == 1 then
			local tint = vmt.selfillumtint -- TODO
			if vmt.selfillummask then
				self:SetSelfIlluminationTexture(LinearTexture(vmt.selfillummask))
			elseif vmt.selfillum_envmapmask_alpha == 1 then
				self:SetMetallicTextureAlphaIsEmissive(true)
			end
		end

		if vmt.translucent == 1 then self:SetTranslucent(true) end

		if vmt.alphatest == 1 then self:SetAlphaTest(true) end

		if vmt.alphatestreference then
			self:SetAlphaCutoff(vmt.alphatestreference)
		end

		if vmt.nocull then self:SetDoubleSided(true) end

		-- Surface property based PBR estimation
		if vmt.surfaceprop then
			local function get_surfaceprop_name(prop)
				-- Handle nested base tables, get the most specific name
				if type(prop) == "table" then
					return prop.surfaceprop_name or (prop.base and get_surfaceprop_name(prop.base))
				end

				return prop
			end

			local function get_prop(prop, key)
				-- Recursively search prop and base tables for a value
				if type(prop) ~= "table" then return nil end

				if prop[key] ~= nil then return prop[key] end

				if prop.base then return get_prop(prop.base, key) end

				return nil
			end

			local name = get_surfaceprop_name(vmt.surfaceprop)

			if name then name = name:lower() end

			-- Comprehensive surface property to PBR mapping
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
			}
			local pbr = surfaceprop_pbr[name]

			-- Fallback: try to match by gamematerial if no direct match
			if not pbr then
				local gamematerial = get_prop(vmt.surfaceprop, "gamematerial")

				if gamematerial then
					local gamematerial_pbr = {
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
					pbr = gamematerial_pbr[gamematerial:upper()]
				end
			end

			-- Fallback: use physical properties to estimate PBR values
			if not pbr then
				local density = get_prop(vmt.surfaceprop, "density") or 1000
				local elasticity = get_prop(vmt.surfaceprop, "elasticity") or 0.25
				local audioreflectivity = get_prop(vmt.surfaceprop, "audioreflectivity") or 0.5
				local friction = get_prop(vmt.surfaceprop, "friction") or 0.5
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

			if pbr then
				-- Only apply surfaceprop values as defaults (don't override explicit material settings)
				-- Check if roughness wasn't already set by phong or other explicit VMT parameters
				if not vmt.phong and not vmt.phongexponent and not vmt.phongexponenttexture then
					self:SetRoughnessMultiplier(pbr[1])
				end

				-- Check if metallic wasn't already set by envmap parameters
				if not vmt.envmap and not vmt.envmapmask then
					self:SetMetallicMultiplier(pbr[2])
				end
			end
		end
	end

	local special_textures = {
		_rt_fullframefb = "error",
		[1] = "error", -- huh
	}
	steam.unused_vmt_properties = steam.unused_vmt_properties or {}

	function Material:SetError(err) end

	function Material.FromVMT(path)
		local self = Material.New()
		--self:SetName(path)
		self.vmt_path = path -- Store path for debugging
		local cb = steam.LoadVMT(path, function(vmt)
			on_load_vmt(self, vmt)
		end, function(err)
			print("Material error for " .. path .. ": " .. err)
		--self:SetError(err)
		end)

		if tasks.GetActiveTask() then cb:Get() end

		return self
	end
end

return Material:Register()
