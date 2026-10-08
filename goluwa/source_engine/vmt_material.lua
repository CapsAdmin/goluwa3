local tasks = import("goluwa/tasks.lua")
local commands = import("goluwa/cli/commands.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Texture = import("goluwa/render/texture.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local Material = import("goluwa/render3d/material.lua")
local material_proxies = import("goluwa/source_engine/material_proxies.lua")
local vmt_loader = import("goluwa/source_engine/vmt.lua")
local vmt_material = {}
local vmt_material_cache = {}
local SRGBTexture, LinearTexture = Material.SRGBTexture, Material.LinearTexture
local vmt_stats

function vmt_material.SetTextureTransform(material, name, str)
	local m = material_proxies.ParseTransform(str)
	material["Set" .. name .. "TransformU"](material, Vec4(m[1], m[2], m[3], 0))
	material["Set" .. name .. "TransformV"](material, Vec4(m[4], m[5], m[6], 0))
	material.has_uv_transform = true
end

local function get_vmt_cache_key(path)
	local normalized = file_path.FixPathSlashes(assert(path, "missing VMT path")):lower()

	if not normalized:starts_with("materials/") then
		normalized = "materials/" .. normalized
	end

	if not normalized:ends_with(".vmt") then normalized = normalized .. ".vmt" end

	return normalized
end

local function unpack_numbers(str)
	str = str:gsub("%s+", " ")
	local t = str:split(" ")

	for k, v in ipairs(t) do
		t[k] = tonumber(v) or 0
	end

	return unpack(t)
end

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
-- static switches. a feature that is off leaves its part of the material at the Material defaults
local FEATURES = {
	-- envmap and phong become a roughness lerp (the mask) plus a metallic estimate
	reflection = true,
	-- $fresnelreflection is a dielectric signature, it lowers the envmap metal estimate
	fresnel_damping = true,
	-- source has no specular without an envmap or phong
	no_reflection_matte = true,
	-- no reflection info: roughness and metallic from $surfaceprop
	surfaceprop_fallback = true,
	-- no $surfaceprop: guess the material family from the vmt path
	path_keywords = true,
	-- lightmapped surfaces were authored dark for source's 2x overbright
	albedo_gain = true,
	refract = true,
	glass_override = true,
	grass_detection = true,
}
local FAMILIES = {
	"concrete",
	"brick",
	"plaster",
	"tile",
	"wood",
	"dirt",
	"grass",
	"sand",
	"snow",
	"rock",
	"stone",
	"asphalt",
	"carpet",
	"gravel",
	"paper",
	"cardboard",
	"plastic",
	"rubber",
	"metal",
	"glass",
	"water",
}
-- physical albedo of a family, the median of the world textures of that family is about half of it
local ALBEDO_TARGETS = {
	concrete = 0.4,
	brick = 0.3,
	plaster = 0.6,
	tile = 0.5,
	wood = 0.25,
	dirt = 0.15,
	grass = 0.15,
	sand = 0.4,
	snow = 0.85,
	rock = 0.25,
	stone = 0.3,
	asphalt = 0.08,
	carpet = 0.15,
	gravel = 0.25,
	paper = 0.6,
	cardboard = 0.4,
	plastic = 0.4,
	rubber = 0.1,
}
-- the shaders whose lighting is multiplied by source's 2x overbright
local OVERBRIGHT_SHADERS = {lightmappedgeneric = true, worldvertextransition = true}
local MAX_ALBEDO = 0.9
local on_load_vmt

do
	local function get_prop(prop, key)
		if type(prop) ~= "table" then return nil end

		if prop[key] ~= nil then return prop[key] end

		if prop.base then return get_prop(prop.base, key) end

		return nil
	end

	local function get_rgb(value)
		local t = typex(value)

		if t == "vec3" then return value.x, value.y, value.z end

		if t == "color" then return value.r, value.g, value.b end

		if type(value) == "number" then return value, value, value end

		if type(value) == "string" then
			local r, g, b = unpack_numbers(value:gsub("[%[%]{}]", ""))
			return r, g or r, b or r
		end

		return 1, 1, 1
	end

	local function find_family(name)
		for _, family in ipairs(FAMILIES) do
			if name:find(family, 1, true) then return family end
		end
	end

	-- perceptual roughness of a blinn-phong lobe: ggx alpha is sqrt(2 / (n + 2)),
	-- roughness is its square root. boost narrows the lobe so that its peak matches
	-- the brighter highlight, since the dielectric reflectance is fixed
	local function lobe_roughness(exponent, boost)
		local alpha = math.sqrt(2 / (exponent + 2)) / math.sqrt(math.max(boost, 1))
		return math.max(0.12, math.sqrt(alpha))
	end

	local function load_textures(self, vmt, ctx)
		local srgb, linear = ctx.srgb, ctx.linear

		if vmt.basetexture then self:SetAlbedoTexture(srgb(vmt.basetexture)) end

		if vmt.basetexture2 then self:SetAlbedo2Texture(srgb(vmt.basetexture2)) end

		if vmt.bumpmap then self:SetNormalTexture(linear(vmt.bumpmap)) end

		if vmt.bumpmap2 then self:SetNormal2Texture(linear(vmt.bumpmap2)) end

		if vmt.ssbump == 1 then self:SetNormalTextureIsSSBump(true) end

		if vmt.blendmodulatetexture then
			self:SetBlendTexture(linear(vmt.blendmodulatetexture))
		end

		if vmt.blendtintbybasealpha == 1 then self:SetBlendTintByBaseAlpha(true) end

		if type(vmt.basetexturetransform) == "string" then
			vmt_material.SetTextureTransform(self, "BaseTexture", vmt.basetexturetransform)
		end

		if type(vmt.bumptransform) == "string" then
			vmt_material.SetTextureTransform(self, "Bump", vmt.bumptransform)
		end

		if type(vmt.texture2transform) == "string" then
			vmt_material.SetTextureTransform(self, "Texture2", vmt.texture2transform)
		end

		if vmt.texture2 then
			self:SetAlbedo2Texture(srgb(vmt.texture2))

			if ctx.shader == "de_unlitthreetexture" or ctx.shader == "unlittwotexture" then
				self:SetMultiplyAlbedo2(true)
			end
		end
	end

	-- source has no roughness. an envmap or phong is a reflection that a mask
	-- scales, so the mask becomes a roughness lerp from fully rough (no mask)
	-- to the lobe's roughness (full mask), and metallic follows the same mask.
	-- a dielectric never reflects more than ~0.1 head on, so a strong envmap
	-- tint, a colored highlight or a flat, strong fresnel is a metal
	local function apply_reflection(self, vmt, ctx)
		local envmap, phong = ctx.envmap, ctx.phong
		local lobe = 0.1
		local metallic = 0
		local mask_texture = nil
		local mask_in_albedo, mask_in_normal, mask_in_luminance = false, false, false
		local invert_mask = false

		if envmap then
			local r, g, b = get_rgb(vmt.envmaptint)
			metallic = math.smoothstep(0.15, 0.4, r * 0.2126 + g * 0.7152 + b * 0.0722)

			if FEATURES.fresnel_damping and vmt.fresnelreflection then
				metallic = metallic * (1 - math.clamp(vmt.fresnelreflection, 0, 1))
			end

			if vmt.envmapmask then
				mask_texture = vmt.envmapmask
			elseif vmt.normalmapalphaenvmapmask == 1 and vmt.bumpmap then
				mask_in_normal = true
			elseif vmt.basealphaenvmapmask == 1 then
				-- unlike the other masks, source uses the inverse of the base alpha
				mask_in_albedo = true
				invert_mask = true
			end
		end

		local exponent_texture = nil

		if phong then
			local boost = vmt.phongboost or 1
			lobe = lobe_roughness(vmt.phongexponent or 5, boost)
			mask_texture = nil
			mask_in_albedo, mask_in_normal, mask_in_luminance = false, false, false
			invert_mask = vmt.invertphongmask == 1

			if vmt.phongexponenttexture then
				exponent_texture = vmt.phongexponenttexture
			elseif vmt.basemapalphaphongmask == 1 then
				mask_in_albedo = true
			elseif vmt.basemapluminancephongmask == 1 then
				mask_in_luminance = true
			elseif vmt.bumpmap then
				mask_in_normal = true
			end

			local ranges = vmt.phongfresnelranges or Vec3(0, 0.5, 1)
			metallic = math.max(
				metallic,
				math.smoothstep(0.25, 0.5, ranges.x * boost) * math.smoothstep(0.3, 0.8, ranges.x / math.max(ranges.z, 0.001))
			)

			if vmt.phongtint then
				local r, g, b = get_rgb(vmt.phongtint)
				local high = math.max(r, g, b)

				if high > 0 and (high - math.min(r, g, b)) / high > 0.25 then
					metallic = 1
				end
			end
		end

		if exponent_texture then
			-- the red channel is the exponent, 1 to 150
			local boost = vmt.phongboost or 1
			self:SetRoughnessTexture(ctx.linear(exponent_texture))
			self:SetRoughnessMin(lobe_roughness(1, boost))
			self:SetRoughnessMax(lobe_roughness(150, boost))
			self:SetMetallicMultiplier(metallic)
			return
		end

		if mask_texture then
			self:SetRoughnessTexture(ctx.linear(mask_texture))
		elseif mask_in_albedo then
			self:SetAlbedoTextureAlphaIsRoughness(true)
		elseif mask_in_normal then
			self:SetNormalTextureAlphaIsRoughness(true)
		elseif mask_in_luminance then
			self:SetAlbedoLuminanceIsRoughness(true)
		end

		if self:HasExplicitRoughnessTexture() then
			if invert_mask then
				self:SetRoughnessMin(lobe)
				self:SetRoughnessMax(1)
			else
				self:SetRoughnessMin(1)
				self:SetRoughnessMax(lobe)
			end

			self:SetMetallicFromRoughnessMask(metallic > 0)
		else
			self:SetRoughnessMultiplier(lobe)
		end

		self:SetMetallicMultiplier(metallic)
	end

	-- only a prior: an explicit envmap or phong already decided the surface
	local function apply_surfaceprop_fallback(self, vmt, ctx)
		local name = ctx.class
		local pbr = surfaceprop_pbr[name] or (ctx.family and surfaceprop_pbr[ctx.family])

		if not pbr and vmt.surfaceprop then
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
			pbr = {math.clamp(roughness, 0.04, 1.0), metallic}
		end

		if not pbr then return end

		local roughness = pbr[1]
		local albedo = self:GetAlbedoTexture()
		local refl = albedo and albedo.reflectivity

		if refl then
			local avg = (refl[1] + refl[2] + refl[3]) / 3

			if avg > 0.05 then
				roughness = roughness * 0.6 + math.clamp(1.0 - math.sqrt(avg), 0.2, 0.95) * 0.4
			end
		end

		self:SetRoughnessMultiplier(roughness)
		self:SetMetallicMultiplier(pbr[2] > 0.5 and 1.0 or 0.0)
	end

	-- the texture's average (the vtf reflectivity) is only known once it is loaded
	local function apply_albedo_gain(self, ctx)
		local albedo = self:GetAlbedoTexture()

		if not albedo then return end

		local family = ctx.family

		if family == "metal" or family == "glass" or family == "water" then return end

		local target = family and ALBEDO_TARGETS[family]

		albedo:AddOnReady(function(texture)
			local refl = texture.reflectivity

			if not refl or not self:IsValid() then return end

			local lum = refl[1] * 0.2126 + refl[2] * 0.7152 + refl[3] * 0.0722
			local high = math.max(refl[1], refl[2], refl[3])

			if lum < 0.001 then return end

			local gain = math.clamp(target and target / lum or 2, 1, 2)
			gain = math.min(gain, math.max(1, MAX_ALBEDO / high))
			local color = self.ColorMultiplier:Copy()
			color.r, color.g, color.b = color.r * gain, color.g * gain, color.b * gain
			self:SetColorMultiplier(color)
		end)
	end

	function on_load_vmt(self, vmt)
		local private_prefix = self.private_prefix
		local srgb, linear = SRGBTexture, LinearTexture

		if private_prefix then
			srgb = function(path)
				return Texture.New{path = path, srgb = true, cache_key = private_prefix .. "srgb|" .. path}
			end
			linear = function(path)
				return Texture.New{path = path, srgb = false, cache_key = private_prefix .. "linear|" .. path}
			end
		end

		local class = nil

		if vmt.surfaceprop then
			class = get_prop(vmt.surfaceprop, "surfaceprop_name")

			if class then class = class:lower() end

			class = class or get_prop(vmt.surfaceprop, "gamematerial")
			self.vmt_surfaceprop = class
		end

		if not class and FEATURES.path_keywords then
			class = find_family(self.vmt_path or "")
		end

		local ctx = {
			shader = vmt.shader:lower(),
			srgb = srgb,
			linear = linear,
			envmap = vmt.envmap ~= nil,
			phong = vmt.phong == 1,
			class = class,
			family = class and find_family(class),
		}
		local shader = ctx.shader
		self.vmt = vmt
		self:SetMetallicMultiplier(0)
		load_textures(self, vmt, ctx)

		if ctx.envmap or ctx.phong then
			if FEATURES.reflection then apply_reflection(self, vmt, ctx) end
		else
			if FEATURES.no_reflection_matte then self:SetSpecularMultiplier(0) end

			if FEATURES.surfaceprop_fallback then
				apply_surfaceprop_fallback(self, vmt, ctx)
			end
		end

		if vmt.selfillum == 1 then
			if vmt.selfillumtint then
				if typex(vmt.selfillumtint) == "vec3" then
					self:SetEmissiveMultiplier(Color(vmt.selfillumtint.x, vmt.selfillumtint.y, vmt.selfillumtint.z, 1))
				elseif typex(vmt.selfillumtint) == "color" then
					self:SetEmissiveMultiplier(Color(vmt.selfillumtint.r, vmt.selfillumtint.g, vmt.selfillumtint.b, 1))
				end
			end

			if vmt.selfillummask then
				self:SetEmissiveTexture(linear(vmt.selfillummask))
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

		if shader == "decalmodulate" or shader == "modulate" then
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
			local tint, color = vmt.srgbtint, self.ColorMultiplier:Copy()
			color.r, color.g, color.b = color.r * tint.x ^ 2.2, color.g * tint.y ^ 2.2, color.b * tint.z ^ 2.2
			self:SetColorMultiplier(color)
		end

		if FEATURES.refract and shader == "refract" then
			self:SetRefraction(1)
			self:SetIndexOfRefraction(1 + (vmt.refractamount or 0.5))
			self:SetRefractionThickness(0)
			self:SetSpecularMultiplier(1)

			if vmt.normalmap then self:SetNormalTexture(linear(vmt.normalmap)) end

			if vmt.normalmapalphaenvmapmask == 1 then
				self:SetNormalAlphaIsCoverage(true)
			end

			if vmt.refracttinttexture then
				self:SetAlbedoTexture(srgb(vmt.refracttinttexture))
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

		if vmt.alphatestreference then self:SetAlphaCutoff(vmt.alphatestreference) end

		if vmt.nocull then self:SetDoubleSided(true) end

		local file_name = file_path.GetFileNameFromPath(self.Name):lower()

		if
			FEATURES.grass_detection and
			(
				file_name:find("grass", 1, true) or
				(
					self.AlbedoTexture and
					Material.IsGrassTexture(self.AlbedoTexture)
				)
			)
		then
			self:SetGrass(true)
		end

		local is_glass = FEATURES.glass_override and
			self.Translucent and
			(
				file_name:find("glass", 1, true) or
				(
					self.AlbedoTexture and
					Material.IsGlassTexture(self.AlbedoTexture)
				)
			)

		if is_glass then
			self:SetAdditive(false)
			self:SetRefraction(1)
			self:SetRefractionThickness(0)
			self:SetAlbedoAlphaIsEmissive(false)
			self:SetRoughnessTexture(nil)
			self:SetAlbedoTextureAlphaIsRoughness(false)
			self:SetNormalTextureAlphaIsRoughness(false)
			self:SetAlbedoLuminanceIsRoughness(false)
			self:SetMetallicFromRoughnessMask(false)
			self:SetRoughnessMin(0)
			self:SetRoughnessMax(1)
			self:SetMetallicMultiplier(0)
			self:SetRoughnessMultiplier(0.04)
			self:SetSpecularMultiplier(1)
		elseif FEATURES.albedo_gain and OVERBRIGHT_SHADERS[shader] then
			apply_albedo_gain(self, ctx)
		end

		material_proxies.Attach(self, vmt.source_text)
		local color = self.ColorMultiplier
		local flags = {}

		for _, name in ipairs{"Additive", "Modulate", "Translucent", "AlphaTest", "DoubleSided", "NoDraw"} do
			if self[name] then flags[#flags + 1] = name end
		end

		self:SetOriginalMaterial(
			string.format(
				"path: %s\nfile: %s\nshader: %s\nbasetexture: %s\nflags: %s\ncolor multiplier: %.3f %.3f %.3f %.3f\nfamily: %s\n\n%s",
				tostring(vmt.fullpath),
				tostring(vmt.resolved_path),
				tostring(vmt.shader),
				tostring(vmt.basetexture),
				table.concat(flags, " "),
				color.r,
				color.g,
				color.b,
				color.a,
				tostring(class),
				tostring(vmt.source_text)
			)
		)
	end
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
			vmt_stats.seen[full_key] = (vmt_stats.seen[full_key] or 0) + 1

			if type(v) ~= "table" then
				vmt_stats.values[full_key] = vmt_stats.values[full_key] or {}
				vmt_stats.values[full_key][tostring(v)] = true
			end
		end
	end

	return setmetatable(
		{},
		{
			__index = function(_, k)
				local full_key = prefix .. k

				if not is_blacklisted(full_key) then
					vmt_stats.used[full_key] = (vmt_stats.used[full_key] or 0) + 1
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

vmt_stats = vmt_stats or {
	seen = {},
	used = {},
	values = {},
}

function vmt_material.FromVMT(path, private_prefix)
	local cache_key = get_vmt_cache_key(path)

	if not private_prefix then
		local cached_material = vmt_material_cache[cache_key]

		if cached_material then
			Material.RecordCacheRequest("vmt", cache_key, cached_material)
			return cached_material
		end
	end

	local self = Material.New()
	self:SetName(path)
	self.vmt_path = cache_key
	self.private_prefix = private_prefix

	if not private_prefix then
		self.upload_cache_key = cache_key
		vmt_material_cache[cache_key] = self
	end

	local cb = vmt_loader.Load(cache_key, function(vmt)
		on_load_vmt(self, track_vmt(vmt))
	end, function(err)
		print("Material error for " .. cache_key .. ": " .. err)
		self:SetError(err)
	end)

	if tasks.GetActiveTask() then cb:TryGet() end

	if not private_prefix then
		Material.RecordCacheRequest("vmt", cache_key, self)
	end

	return self
end

function vmt_material.Release(material)
	local prefix = material.private_prefix
	local fallback_image = Texture.GetFallback().image

	for _, info in ipairs(material:GetTextures()) do
		local texture = info.texture

		if
			texture:IsValid() and
			texture.cache_key and
			texture.cache_key:starts_with(prefix) and
			texture.image ~= fallback_image
		then
			texture:Remove()
		end
	end

	material:Remove()
end

Material.RegisterOverrideLoader(".vmt", function(path)
	return nil, vmt_material.FromVMT(path)
end)

commands.Add("dump_unused_vmt_properties", function()
	local unused = {}

	for k, count in pairs(vmt_stats.seen) do
		if not vmt_stats.used[k] then
			local values = {}

			if vmt_stats.values[k] then
				for val, _ in pairs(vmt_stats.values[k]) do
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

return vmt_material
