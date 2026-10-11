local META = gine.EnsureMetaTable("ProjectedTexture")

function gine.env.ProjectedTexture()
	return gine.WrapObject({
		IsValid = function(self)
			return not self.removed
		end,
	}, "ProjectedTexture")
end

function META:IsValid()
	return not self.__obj.removed
end

function META:Remove()
	self.__obj.removed = true
end

function META:Update() end

for name, default in pairs{
	Brightness = 1,
	ConstantAttenuation = 0,
	LinearAttenuation = 100,
	QuadraticAttenuation = 0,
	EnableShadows = true,
	FarZ = 750,
	NearZ = 12,
	HorizontalFOV = 90,
	VerticalFOV = 90,
	LightWorld = true,
	NoCull = false,
	Orthographic = false,
	ShadowDepthBias = 0.0001,
	ShadowFilter = 0,
	ShadowSlopeScaleDepthBias = 2,
	SkipShadowUpdates = false,
	TextureFrame = 0,
} do
	gine.GetSet(META, name, default)
end

gine.GetSet(META, "Pos", function()
	return gine.env.Vector()
end)

gine.GetSet(META, "Angles", function()
	return gine.env.Angle()
end)

gine.GetSet(META, "Color", function()
	return gine.env.Color(255, 255, 255)
end)

gine.GetSet(META, "TargetEntity", function()
	return gine.env.NULL
end)

gine.GetSet(META, "Texture", function()
	return gine.env.Material("effects/flashlight001"):GetTexture("$basetexture")
end)

function META:SetFOV(fov)
	self.__obj.gine_vars.HorizontalFOV = fov
	self.__obj.gine_vars.VerticalFOV = fov
end
