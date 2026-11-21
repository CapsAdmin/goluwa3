local vfs = import("goluwa/vfs.lua")
local Material = import("goluwa/render3d/material.lua")
local surface_types = import("lua/source_loader/surface_types.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local media = import("goluwa/render3d/media.lua")
local resource = import("lua/source_loader/source2/resource.lua")
local vtex_c = import("lua/codecs/vtex_c.lua")
local legacy_material = import("lua/source_loader/source2/legacy_material.lua")
local texture_convert = import("lua/source_loader/source2/texture_convert.lua")
import("goluwa/render3d/texture_streaming.lua")
local material = {}
local infos = {}
local materials = {}
local BLEND_SHADERS = {["vr_simple_2way_blend.vfx"] = true}
local INCHES = 0.0254
local SOFT_ALPHA_EDGE_STRENGTH = 0.5
local TREE_HEIGHT = 5.2
local TREE_TRUNK_DEFLECTION = 0.04
local TREE_BRANCH_DEFLECTION = 0.012
local TREE_BRANCH_AMPLITUDE = 0.2
local TREE_LEAF_AMPLITUDE = 0.08

local function normalize(path)
	return (path:lower():gsub("\\", "/"))
end

-- reads the parameters of a vmat once: textures and flags by name, and what a mesh has to provide
function material.GetInfo(path)
	path = normalize(path)

	if infos[path] then return infos[path] end

	local info = {path = path, ints = {}, floats = {}, vectors = {}, textures = {}}
	infos[path] = info

	if path:find("^materials/tools/tools%a*blocklight") then
		info.block_light = true
		return info
	end

	if path:starts_with("materials/tools/") or path:find("^materials/dev/reflectivity_") then
		info.no_draw = true
		return info
	end

	local ok, data = pcall(function()
		local res = resource.Load(vfs, path .. "_c")
		local read_ok, kv3_data = pcall(resource.ReadKV3, res)

		if read_ok then return kv3_data end

		return legacy_material.Read(res)
	end)

	if not ok then
		wlog("source 2 material %s: %s", path, tostring(data))
		info.unreadable = true
		return info
	end

	info.shader = data.m_shaderName

	for _, p in ipairs(data.m_intParams) do
		info.ints[p.m_name] = p.m_nValue
	end

	for _, p in ipairs(data.m_floatParams) do
		info.floats[p.m_name] = p.m_flValue
	end

	for _, p in ipairs(data.m_vectorParams) do
		info.vectors[p.m_name] = p.m_value
	end

	for _, p in ipairs(data.m_textureParams) do
		if p.m_pValue ~= "" and not p.m_pValue:find("default", nil, true) then
			info.textures[p.m_name] = p.m_pValue .. "_c"
		end
	end

	for _, p in ipairs(data.m_stringAttributes) do
		if p.m_name == "PhysicsSurfaceProperties" then info.surface = p.m_value end
	end

	info.blend = BLEND_SHADERS[info.shader] == true
	info.decal = info.shader == "vr_static_overlay.vfx"
	info.glass = info.shader == "vr_glass.vfx" or info.shader == "vr_glass_markable.vfx"
	info.bottle = info.shader == "vr_simple_liquid.vfx" and info.ints.F_NO_LIQUID == 1
	info.liquid = info.shader == "vr_simple_liquid.vfx" and not info.bottle
	info.additive = info.ints.F_ADDITIVE_BLEND == 1
	info.alpha_test = info.ints.F_ALPHA_TEST == 1
	info.alpha_coverage = info.alpha_test and
		(
			info.floats.g_flAntiAliasedEdgeStrength or
			1
		) < SOFT_ALPHA_EDGE_STRENGTH
	info.soft_translucent = info.alpha_coverage and
		(
			path:find("trans", 1, true) or
			path:find("glass", 1, true)
		) ~= nil
	info.translucent = (
			info.ints.F_TRANSLUCENT or
			0
		) > 0 or
		info.additive or
		info.glass or
		info.decal or
		info.soft_translucent
	info.tint_mask = info.ints.F_TINT_MASK == 1 or info.ints.F_ENABLE_TINT_MASKS == 1
	return info
end

local function get_plan(info)
	local textures, ints = info.textures, info.ints
	local plan = {
		albedo_path = textures.g_tColor or textures.g_tColorA,
		normal_path = textures.g_tNormal or textures.g_tNormalA,
		conversions = {},
	}
	local conversions = plan.conversions
	plan.tinted = plan.albedo_path and
		info.tint_mask and
		not info.blend and
		not (
			info.alpha_test or
			info.translucent
		)
		and
		textures.g_tTintMask

	if plan.tinted then
		conversions[#conversions + 1] = {"tint_mask", {plan.albedo_path, textures.g_tTintMask}}
	end

	if plan.normal_path then
		conversions[#conversions + 1] = {"normal", {plan.normal_path}}
	end

	if ints.F_METALNESS_TEXTURE == 1 then
		if not (info.alpha_test or info.translucent) and plan.albedo_path then
			plan.metal_path, plan.metal_kind = plan.albedo_path, "alpha"
		elseif textures.g_tMetalness then
			plan.metal_path, plan.metal_kind = textures.g_tMetalness, "green"
		end

		if plan.metal_path then
			conversions[#conversions + 1] = {plan.metal_kind, {plan.metal_path}}
		end
	end

	if info.blend and textures.g_tColorB then
		if textures.g_tNormalB then
			conversions[#conversions + 1] = {"normal", {textures.g_tNormalB}}
		end

		if textures.g_tMask then
			conversions[#conversions + 1] = {"blend_mask", {textures.g_tMask}}
		end
	end

	if
		(
			ints.F_DETAIL_TEXTURE or
			0
		) >= 3 and
		not textures.g_tDetailMask and
		not info.blend and
		textures.g_tNormalDetail
	then
		conversions[#conversions + 1] = {"detail_normal", {textures.g_tNormalDetail}}
	end

	return plan
end

-- vr_xen_foliage is a translucent solid: the albedo is the surface colour and the transmission colour is what survives a
-- body of XEN_TRANSMISSION_DEPTH metres, so the medium absorbs it by wavelength over the thickness the light really crosses.
local XEN_TRANSMISSION_DEPTH = 0.15
local XEN_TRANSMISSION = 0.4
local MIN_TRANSMITTANCE = 0.02
local NO_SCATTERING = Vec3(0, 0, 0)
local GLASS_PANE_DEPTH = 0.05
local GLASS_IOR = 1.5
local GLASS_ROUGHNESS = 0.04
local LIQUID_DEPTH = 0.08

local function define_absorbing_medium(color, depth)
	return media.Define(
		Vec3(
			-math.log(math.max(color[1], MIN_TRANSMITTANCE)) / depth,
			-math.log(math.max(color[2], MIN_TRANSMITTANCE)) / depth,
			-math.log(math.max(color[3], MIN_TRANSMITTANCE)) / depth
		),
		NO_SCATTERING
	)
end

function material.ApplyXenFoliage(self, info)
	self:SetMedium(
		define_absorbing_medium(info.vectors.g_vTransmissionColor or {1, 1, 1}, XEN_TRANSMISSION_DEPTH)
	)
	self:SetDiffuseTransmission(XEN_TRANSMISSION)
end

-- vr_glass is a refractive pane whose GlassTintColor is what survives a pane; the additive variant only glows
function material.ApplyGlass(self, info)
	if info.additive then return end

	local tint = info.vectors.GlassTintColor

	if tint and (tint[1] < 0.99 or tint[2] < 0.99 or tint[3] < 0.99) then
		self:SetMedium(define_absorbing_medium(tint, GLASS_PANE_DEPTH))
	end

	self:SetRefraction(1)
	self:SetRefractionThickness(0)
	self:SetIndexOfRefraction(GLASS_IOR)
	self:SetMetallicMultiplier(0)
	self:SetRoughnessMultiplier(GLASS_ROUGHNESS)
	self:SetNormalTextureAlphaIsRoughness(false)
end

-- vr_simple_liquid is a bottle and the liquid in it as two materials: the bottle is glass whose roughness map is
-- g_tLiquidMask (grime and scratches) between g_flMaskMinimum and g_flMaskMaximum, the liquid a closed body whose
-- g_vLiquidColor is what survives LIQUID_DEPTH metres of it
function material.ApplyBottle(self, info)
	self:SetRefraction(1)
	self:SetRefractionThickness(0)
	self:SetIndexOfRefraction(GLASS_IOR)
	self:SetMetallicMultiplier(0)
	self:SetNormalTextureAlphaIsRoughness(false)

	if info.textures.g_tLiquidMask then
		self:SetRoughnessTexture(Material.LinearTexture(info.textures.g_tLiquidMask, {stream = true}))
		self:SetRoughnessMin(info.floats.g_flMaskMinimum or 0)
		self:SetRoughnessMax(info.floats.g_flMaskMaximum or 1)
		self:SetRoughnessMultiplier(info.floats.g_flRefractRoughnessMultiplier or 1)
	else
		self:SetRoughnessMultiplier(GLASS_ROUGHNESS)
	end
end

function material.ApplyLiquid(self, info)
	self:SetMedium(define_absorbing_medium(info.vectors.g_vLiquidColor or {1, 1, 1}, LIQUID_DEPTH))
	self:SetRefraction(1)
	self:SetMetallicMultiplier(0)
	self:SetRoughnessMultiplier(GLASS_ROUGHNESS)
	self:SetNormalTextureAlphaIsRoughness(false)
end

local MEAN_COLOR_PREFIX = 65536
local texture_means = {}

-- the linear mean colour of a vtex, which the emitters need because they cannot see the texture; nil if it cannot be decoded
local function get_mean_color(path)
	local cached = texture_means[path]

	if cached ~= nil then return cached or nil end

	local file_path, offset, size = vfs.GetReadLocation(path)
	local bytes

	if file_path then
		local file = assert(io.open(file_path, "rb"))
		file:seek("set", offset)
		bytes = file:read(math.min(size, MEAN_COLOR_PREFIX))
		file:close()
	else
		bytes = vfs.Read(path)
	end

	local r, g, b = vtex_c.GetMeanColor(bytes)
	cached = r and
		Color(math.srgb_to_linear(r), math.srgb_to_linear(g), math.srgb_to_linear(b), 1) or
		false
	texture_means[path] = cached
	return cached or nil
end

function material.Prefetch(path)
	local info = material.GetInfo(path)

	if materials[info.path] or info.no_draw or info.unreadable then return end

	for _, conversion in ipairs(get_plan(info).conversions) do
		texture_convert.Prefetch(conversion[2], conversion[1])
	end
end

function material.FromVMAT(path)
	local info = material.GetInfo(path)
	local key = info.path

	if materials[key] then return materials[key] end

	local self = Material.New()
	self:SetName(key)
	materials[key] = self

	if info.no_draw then
		self:SetNoDraw(true)
		return self
	end

	if info.block_light then return self end

	if info.unreadable then
		self:SetColorMultiplier(Color(0.5, 0.5, 0.5, 1))
		return self
	end

	if info.surface then
		self:SetSurfaceType(surface_types.Translate(info.surface))
	end

	local textures, ints, floats, vectors = info.textures, info.ints, info.floats, info.vectors
	local plan = get_plan(info)
	local albedo_path, normal_path = plan.albedo_path, plan.normal_path

	for _, conversion in ipairs(plan.conversions) do
		texture_convert.Prefetch(conversion[2], conversion[1])
	end

	if plan.tinted then
		self:SetAlbedoTexture(texture_convert.GetTintedAlbedo(albedo_path, textures.g_tTintMask))
		self:SetBlendTintByBaseAlpha(true)
	elseif albedo_path then
		self:SetAlbedoTexture(Material.SRGBTexture(albedo_path, {stream = true}))
	end

	if normal_path then
		self:SetNormalTexture(texture_convert.Get(normal_path, "normal"))
		self:SetNormalTextureAlphaIsRoughness(true)
	end

	local metalness = floats.g_flMetalness or 0

	if ints.F_METALNESS_TEXTURE == 1 then
		if plan.metal_path then
			self:SetMetallicTexture(texture_convert.Get(plan.metal_path, plan.metal_kind))
		end

		metalness = 1
	end

	self:SetMetallicMultiplier(metalness)

	if info.shader == "vr_complex.vfx" and ints.F_SPECULAR ~= 1 then
		self:SetSpecularMultiplier(0)
	end

	if info.blend and textures.g_tColorB then
		self:SetAlbedo2Texture(Material.SRGBTexture(textures.g_tColorB, {stream = true}))

		if textures.g_tNormalB then
			self:SetNormal2Texture(texture_convert.Get(textures.g_tNormalB, "normal"))
		end

		if textures.g_tMask then
			self:SetBlendTexture(texture_convert.Get(textures.g_tMask, "blend_mask"))
		end

		metalness = ((floats.g_flMetalnessA or 0) + (floats.g_flMetalnessB or 0)) / 2
		self:SetMetallicMultiplier(metalness)
	end

	local scale = vectors.g_vTexCoordScale or {1, 1}
	local offset = vectors.g_vTexCoordOffset or {0, 0}

	if scale[1] ~= 1 or scale[2] ~= 1 or offset[1] ~= 0 or offset[2] ~= 0 then
		self:SetBaseTextureTransformU(Vec4(scale[1], 0, offset[1], 0))
		self:SetBaseTextureTransformV(Vec4(0, scale[2], offset[2], 0))
		self:SetBumpTransformU(Vec4(scale[1], 0, offset[1], 0))
		self:SetBumpTransformV(Vec4(0, scale[2], offset[2], 0))
		self.has_uv_transform = true
	end

	local scale2 = vectors.g_vTexCoordScale2

	if info.blend and scale2 and (scale2[1] ~= 1 or scale2[2] ~= 1) then
		self:SetTexture2TransformU(Vec4(scale2[1], 0, 0, 0))
		self:SetTexture2TransformV(Vec4(0, scale2[2], 0, 0))
		self.has_uv_transform = true
	end

	local detail_mode = ints.F_DETAIL_TEXTURE or 0

	if detail_mode > 0 and not textures.g_tDetailMask and not info.blend then
		local detail_scale = vectors.g_vDetailTexCoordScale or {1, 1}
		self:SetDetailTiling(Vec2(detail_scale[1], detail_scale[2]))
		self:SetDetailBlendAmount(floats.g_flDetailBlendFactor or 1)
		self:SetDetailBumpScale(floats.g_flDetailNormalStrength or 1)

		if detail_mode ~= 3 and textures.g_tDetail then
			self:SetDetailColorTexture(Material.LinearTexture(textures.g_tDetail, {stream = true}))
			self:SetDetailColorMode(detail_mode == 1 and 1 or 2)
		end

		if detail_mode >= 3 and textures.g_tNormalDetail then
			self:SetDetailNormalTexture(texture_convert.Get(textures.g_tNormalDetail, "detail_normal"))
		end
	end

	local tint = vectors.g_vColorTint or {1, 1, 1}
	local metal_loss = (
			ints.F_UNLIT == 1 and
			ints.F_METALNESS_TEXTURE ~= 1
		)
		and
		1 - (
			floats.g_flMetalness or
			0
		)
		or
		1
	local color = {
		math.srgb_to_linear(tint[1]) * metal_loss,
		math.srgb_to_linear(tint[2]) * metal_loss,
		math.srgb_to_linear(tint[3]) * metal_loss,
	}
	self:SetColorMultiplier(Color(color[1], color[2], color[3], 1))

	if info.alpha_test and not info.soft_translucent then
		self:SetAlphaTest(true)
		self:SetAlphaCoverage(info.alpha_coverage)
		self:SetAlphaCutoff(floats.g_flAlphaTestReference or 0.5)
	end

	if info.translucent then self:SetTranslucent(true) end

	if info.additive then
		self:SetAdditive(true)
		self:SetDisplayReferred(true)
	end

	if ints.F_UNLIT == 1 and info.translucent then self:SetUnlit(true) end

	if info.decal then
		self:SetDecal(true)
		self:SetDithered(true)
		self:SetColorMultiplier(Color(color[1], color[2], color[3], floats.g_flOpacityScale or 1))
	end

	if (ints.F_FOLIAGE_ANIMATION or 0) > 0 then
		local size = (floats.g_flTrunkDeflectionEnd or 36) * INCHES / TREE_HEIGHT
		self:SetBending((floats.g_flTrunkDeflection or 0) / TREE_TRUNK_DEFLECTION)
		self:SetDetailBending("leaves")
		self:SetBendDetailBranchAmplitude(
			TREE_BRANCH_AMPLITUDE * (
					floats.g_flBranchDeflection or
					0
				) / TREE_BRANCH_DEFLECTION * size
		)
		self:SetBendDetailLeafAmplitude(TREE_LEAF_AMPLITUDE * (floats.g_flFrondFlutter or 0) * size)
	end

	if info.shader == "vr_xen_foliage.vfx" then
		material.ApplyXenFoliage(self, info)

		if textures.g_tMaskParameters then
			self:SetTransmissionTexture(Material.LinearTexture(textures.g_tMaskParameters, {stream = true}))
		end
	end

	if info.glass then
		material.ApplyGlass(self, info)
	elseif info.bottle then
		material.ApplyBottle(self, info)
	elseif info.liquid then
		material.ApplyLiquid(self, info)
	end

	if ints.F_RENDER_BACKFACES == 1 then self:SetDoubleSided(true) end

	local illum = textures.g_tSelfIllumMask

	if ints.F_SELF_ILLUM == 1 and illum then
		self:SetEmissiveTexture(Material.SRGBTexture(illum))
		self:SetEmissiveTextureIsColor(true)
		local mean = get_mean_color(illum)

		if mean then self:SetEmissiveMean(mean) end

		self:SetEmissiveAlbedoFactor(floats.g_flSelfIllumAlbedoFactor or 1)
		local illum_tint = vectors.g_vSelfIllumTint
		local scale = (floats.g_flSelfIllumScale or 1) * 2 ^ (floats.g_flSelfIllumBrightness or 0)

		if illum_tint then
			self:SetEmissiveMultiplier(Color(illum_tint[1] * scale, illum_tint[2] * scale, illum_tint[3] * scale, 1))
		end
	end

	return self
end

return material
