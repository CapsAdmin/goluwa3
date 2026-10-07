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
local ENVMAP_F0 = 0.5
local ENVMAP_ROUGHNESS = 0.125 * 0
local PHONG_MAX_F0 = 0.5

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

local function on_load_vmt(self, vmt)
	local SRGBTexture, LinearTexture = SRGBTexture, LinearTexture
	local private_prefix = self.private_prefix

	if private_prefix then
		SRGBTexture = function(path)
			return Texture.New{path = path, srgb = true, cache_key = private_prefix .. "srgb|" .. path}
		end
		LinearTexture = function(path)
			return Texture.New{path = path, srgb = false, cache_key = private_prefix .. "linear|" .. path}
		end
	end

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
		vmt_material.SetTextureTransform(self, "BaseTexture", vmt.basetexturetransform)
	end

	if type(vmt.bumptransform) == "string" then
		vmt_material.SetTextureTransform(self, "Bump", vmt.bumptransform)
	end

	if type(vmt.texture2transform) == "string" then
		vmt_material.SetTextureTransform(self, "Texture2", vmt.texture2transform)
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

	if vmt.alphatestreference then self:SetAlphaCutoff(vmt.alphatestreference) end

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

		if
			not self:HasExplicitMetallicTexture() and
			not self.SpecularSolvesMetallic and
			pbr[2]
		then
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

-- a private_prefix makes a material that is not shared through the cache and owns its textures, release it with vmt_material.Release
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
