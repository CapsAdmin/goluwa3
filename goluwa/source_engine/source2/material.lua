local vfs = import("goluwa/vfs.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local material = {}
local cache = {}

local function texture_path(path)
	return path .. "_c"
end

function material.FromVMAT(path)
	path = path:lower():gsub("\\", "/")

	if cache[path] then return cache[path] end

	local self = Material.New()
	self:SetName(path)
	cache[path] = self

	if path:starts_with("materials/tools/") then
		self:SetNoDraw(true)
		return self
	end

	local ok, data = pcall(function()
		return resource.ReadKV3(resource.Load(vfs, path .. "_c"))
	end)

	if not ok then
		wlog("source 2 material %s: %s", path, tostring(data))
		self:SetColorMultiplier(Color(0.5, 0.5, 0.5, 1))
		return self
	end

	local ints, floats, vectors, textures = {}, {}, {}, {}

	for _, p in ipairs(data.m_intParams) do
		ints[p.m_name] = p.m_nValue
	end

	for _, p in ipairs(data.m_floatParams) do
		floats[p.m_name] = p.m_flValue
	end

	for _, p in ipairs(data.m_vectorParams) do
		vectors[p.m_name] = p.m_value
	end

	for _, p in ipairs(data.m_textureParams) do
		textures[p.m_name] = p.m_pValue
	end

	local function find(...)
		for _, name in ipairs{...} do
			local texture = textures[name]

			if texture and texture ~= "" and not texture:find("default", nil, true) then
				return texture_path(texture)
			end
		end
	end

	local albedo = find("g_tColor", "g_tColorA")
	local normal = find("g_tNormal", "g_tNormalA")

	if albedo then self:SetAlbedoTexture(Material.SRGBTexture(albedo)) end

	if normal then self:SetNormalTexture(Material.LinearTexture(normal)) end

	self:SetRoughnessMultiplier(0.7)
	local tint = vectors.g_vColorTint

	if tint then self:SetColorMultiplier(Color(tint[1], tint[2], tint[3], 1)) end

	if ints.F_ALPHA_TEST == 1 then
		self:SetAlphaTest(true)
		self:SetAlphaCutoff(floats.g_flAlphaTestReference or 0.5)
	end

	if ints.F_TRANSLUCENT == 1 or data.m_shaderName == "vr_glass.vfx" then
		self:SetTranslucent(true)
	end

	if ints.F_RENDER_BACKFACES == 1 then self:SetDoubleSided(true) end

	local illum = find("g_tSelfIllumMask")

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
