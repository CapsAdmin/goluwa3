local T = import("test/environment.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")

T.Test3D("Material.New sets multipliers from colors and numbers, without textures", function()
	local material = Material.New{
		Color = Color(1, 0, 0, 1),
		Roughness = 0.3,
		Metallic = 0,
		Emissive = Color(0, 1, 0, 1),
	}
	T(material:GetAlbedoTexture())["=="](nil)
	T(material:GetRoughnessTexture())["=="](nil)
	T(material:GetMetallicTexture())["=="](nil)
	T(material:GetColorMultiplier().r)["=="](1)
	T(material:GetColorMultiplier().g)["=="](0)
	T(material:GetRoughnessMultiplier())["=="](0.3)
	T(material:GetMetallicMultiplier())["=="](0)
	T(material:GetEmissiveMultiplier().g)["=="](1)
end)

T.Test3D("Material.New makes textures from glsl and keeps textures it is given", function()
	local material = Material.New{Albedo = "return vec4(1.0, 0.0, 0.0, 1.0);"}
	T(material:GetAlbedoTexture())["~="](nil)
	local texture = material:GetAlbedoTexture()
	T(Material.New{Roughness = texture}:GetRoughnessTexture())["=="](texture)
end)

T.Test3D("Material.New rejects keys that are not properties", function()
	local ok, err = pcall(Material.New, {Colour = Color(1, 0, 0, 1)})
	T(ok)["=="](false)
	T(err:find("unknown material key: Colour", 1, true) ~= nil)["=="](true)
end)

T.Test3D("Material.New rejects two ways of setting the color", function()
	T(
		pcall(Material.New, {Color = Color(1, 0, 0, 1), ColorMultiplier = Color(1, 1, 1, 1)})
	)["=="](false)
	T(pcall(Material.New, {Color = Color(1, 0, 0, 1), Albedo = Color(0, 1, 0, 1)}))["=="](false)
end)

T.Test3D("Material.New leaves multipliers at their defaults", function()
	local material = Material.New{}
	T(material:GetMetallicMultiplier())["=="](1)
	T(material:GetRoughnessMultiplier())["=="](1)
end)

T.Test3D("Material texture transforms follow source's center scale rotate translate", function()
	local material = Material.New{}
	material:SetTextureTransformFromVMT("Bump", "center .5 .5 scale 10 10 rotate 0 translate 0.25 0")
	local u, v = material:GetBumpTransformU(), material:GetBumpTransformV()
	T(u.x * 0.5 + u.y * 0.5 + u.z)["=="](0.75)
	T(v.x * 0.5 + v.y * 0.5 + v.z)["=="](0.5)
	T(u.x * 0.6 + u.y * 0.5 + u.z)["=="](1.75)
	material:SetTextureTransformFromVMT("BaseTexture", "center .5 .5 scale 1 1 rotate 180 translate 0 0")
	local bu, bv = material:GetBaseTextureTransformU(), material:GetBaseTextureTransformV()
	T(math.abs(bu.x * 0.5 + bu.y * 0.5 + bu.z - 0.5) < 1e-6)["=="](true)
	T(math.abs(bu.x * 1 + bu.y * 0.5 + bu.z - 0) < 1e-6)["=="](true)
	T(math.abs(bv.x * 0.5 + bv.y * 1 + bv.z - 0) < 1e-6)["=="](true)
end)
