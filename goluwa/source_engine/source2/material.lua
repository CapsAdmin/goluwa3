local vfs = import("goluwa/vfs.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local legacy_material = import("goluwa/source_engine/source2/legacy_material.lua")
local texture_convert = import("goluwa/source_engine/source2/texture_convert.lua")
local material = {}
local infos = {}
local materials = {}
local BLEND_SHADERS = {["vr_simple_2way_blend.vfx"] = true}

local function normalize(path)
	return (path:lower():gsub("\\", "/"))
end

-- reads the parameters of a vmat once: textures and flags by name, and what a mesh has to provide
function material.GetInfo(path)
	path = normalize(path)

	if infos[path] then return infos[path] end

	local info = {path = path, ints = {}, floats = {}, vectors = {}, textures = {}}
	infos[path] = info

	if path:starts_with("materials/tools/") then
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

	info.blend = BLEND_SHADERS[info.shader] == true
	info.translucent = info.ints.F_TRANSLUCENT == 1 or info.shader == "vr_glass.vfx"
	info.alpha_test = info.ints.F_ALPHA_TEST == 1
	info.tint_mask = info.ints.F_TINT_MASK == 1 or info.ints.F_ENABLE_TINT_MASKS == 1
	return info
end

local function quantize(value)
	return math.floor(value * 16 + 0.5) / 16
end

-- tint: the average vertex color of a mesh, applied to the albedo as the shaders do. A material with
-- a tint mask is not tinted, the mask decides per texel and cannot be applied per mesh
function material.FromVMAT(path, tint)
	local info = material.GetInfo(path)

	if tint and (info.tint_mask or info.blend) then tint = nil end

	if tint and tint[1] >= 0.97 and tint[2] >= 0.97 and tint[3] >= 0.97 then
		tint = nil
	end

	local key = info.path

	if tint then
		tint = {quantize(tint[1]), quantize(tint[2]), quantize(tint[3])}
		key = key .. "|" .. tint[1] .. "," .. tint[2] .. "," .. tint[3]
	end

	if materials[key] then return materials[key] end

	local self = Material.New()
	self:SetName(key)
	materials[key] = self

	if info.no_draw then
		self:SetNoDraw(true)
		return self
	end

	if info.unreadable then
		self:SetColorMultiplier(Color(0.5, 0.5, 0.5, 1))
		return self
	end

	local textures, ints, floats, vectors = info.textures, info.ints, info.floats, info.vectors
	local albedo_path = textures.g_tColor or textures.g_tColorA
	local normal_path = textures.g_tNormal or textures.g_tNormalA

	if albedo_path then self:SetAlbedoTexture(Material.SRGBTexture(albedo_path)) end

	if normal_path then
		self:SetNormalTexture(texture_convert.Get(normal_path, "normal"))
		self:SetNormalTextureAlphaIsRoughness(true)
	end

	local metalness = floats.g_flMetalness or 0

	if ints.F_METALNESS_TEXTURE == 1 then
		if not (info.alpha_test or info.translucent) and albedo_path then
			self:SetMetallicTexture(texture_convert.Get(albedo_path, "alpha"))
		elseif textures.g_tMetalness then
			self:SetMetallicTexture(texture_convert.Get(textures.g_tMetalness, "green"))
		end

		metalness = 1
	end

	self:SetMetallicMultiplier(metalness)

	if info.blend and textures.g_tColorB then
		self:SetAlbedo2Texture(Material.SRGBTexture(textures.g_tColorB))

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
			self:SetDetailColorTexture(Material.LinearTexture(textures.g_tDetail))
			self:SetDetailColorMode(detail_mode == 1 and 1 or 2)
		end

		if detail_mode >= 3 and textures.g_tNormalDetail then
			self:SetDetailNormalTexture(texture_convert.Get(textures.g_tNormalDetail, "detail_normal"))
		end
	end

	local color = vectors.g_vColorTint or {1, 1, 1}
	tint = tint or {1, 1, 1}
	self:SetColorMultiplier(Color(color[1] * tint[1], color[2] * tint[2], color[3] * tint[3], 1))

	if info.alpha_test then
		self:SetAlphaTest(true)
		self:SetAlphaCutoff(floats.g_flAlphaTestReference or 0.5)
	end

	if info.translucent then self:SetTranslucent(true) end

	if ints.F_RENDER_BACKFACES == 1 then self:SetDoubleSided(true) end

	local illum = textures.g_tSelfIllumMask

	if ints.F_SELF_ILLUM == 1 and illum then
		self:SetEmissiveTexture(Material.LinearTexture(illum))
		local illum_tint = vectors.g_vSelfIllumTint
		local scale = floats.g_flSelfIllumScale or 1

		if illum_tint then
			self:SetEmissiveMultiplier(Color(illum_tint[1] * scale, illum_tint[2] * scale, illum_tint[3] * scale, 1))
		end
	end

	return self
end

return material
