local T = import("test/environment.lua")
local Material = import("goluwa/render3d/material.lua")
local vmt_material = import("goluwa/source_engine/vmt_material.lua")

T.Test3D("Material texture transforms follow source's center scale rotate translate", function()
	local material = Material.New{}
	vmt_material.SetTextureTransform(material, "Bump", "center .5 .5 scale 10 10 rotate 0 translate 0.25 0")
	local u, v = material:GetBumpTransformU(), material:GetBumpTransformV()
	T(u.x * 0.5 + u.y * 0.5 + u.z)["=="](0.75)
	T(v.x * 0.5 + v.y * 0.5 + v.z)["=="](0.5)
	T(u.x * 0.6 + u.y * 0.5 + u.z)["=="](1.75)
	vmt_material.SetTextureTransform(material, "BaseTexture", "center .5 .5 scale 1 1 rotate 180 translate 0 0")
	local bu, bv = material:GetBaseTextureTransformU(), material:GetBaseTextureTransformV()
	T(math.abs(bu.x * 0.5 + bu.y * 0.5 + bu.z - 0.5) < 1e-6)["=="](true)
	T(math.abs(bu.x * 1 + bu.y * 0.5 + bu.z - 0) < 1e-6)["=="](true)
	T(math.abs(bv.x * 0.5 + bv.y * 1 + bv.z - 0) < 1e-6)["=="](true)
end)

local Vec3 = import("goluwa/structs/vec3.lua")
local objects = import("goluwa/objects/objects.lua")

local function snapshot(material)
	local out = {}

	for _, info in ipairs(objects.GetStorableVariables(material)) do
		out[info.var_name] = tostring(material[info.get_name](material))
	end

	return out
end

T.Test3D("vmt_material.Apply is idempotent and a changed vmt leaves nothing behind", function()
	local material = Material.New{}
	material:SetName("materials/test/reapply.vmt")

	local function make()
		return {
			shader = "lightmappedgeneric",
			envmap = "env_cubemap",
			envmaptint = Vec3(0.9, 0.9, 0.9),
			color = Vec3(0.5, 0.5, 0.5),
			srgbtint = Vec3(0.5, 0.5, 0.5),
			translucent = 1,
			nocull = 1,
			source_text = "",
		}
	end

	vmt_material.Apply(material, make())
	local first = snapshot(material)
	vmt_material.Apply(material, make())
	local second = snapshot(material)

	for key, value in pairs(first) do
		T(second[key])["=="](value)
	end

	T(material.vmt_generation)["=="](2)
	vmt_material.Apply(material, {shader = "vertexlitgeneric", source_text = ""})
	local plain = snapshot(Material.New{})

	for key, value in pairs(snapshot(material)) do
		if
			key ~= "OriginalMaterial" and
			key ~= "SpecularMultiplier" and
			key ~= "RoughnessMultiplier" and
			key ~= "MetallicMultiplier"
		then
			T(plain[key])["=="](value)
		end
	end

	T(material.Translucent)["=="](false)
	T(material.DoubleSided)["=="](false)
end)

T.Test3D("vmt materials take their acoustic absorption from surfaceprop chains before names", function()
	local function absorption(path, vmt)
		local material = Material.New{}
		material.vmt_path = path
		vmt.shader = "lightmappedgeneric"
		vmt.source_text = ""
		vmt_material.Apply(material, vmt)
		return material:GetAcousticAbsorption()
	end

	local metal_box = {surfaceprop_name = "Metal_Box", base = {surfaceprop_name = "SolidMetal"}}
	local metal = absorption("materials/test/crate.vmt", {surfaceprop = metal_box})
	local concrete = absorption(
		"materials/test/concretewall001a.vmt",
		{surfaceprop = {surfaceprop_name = "default"}}
	)
	local sofa = absorption("materials/models/props/sofa.vmt", {})
	local fence = absorption("materials/test/fence.vmt", {surfaceprop = {surfaceprop_name = "chainlink"}})
	local ceiling = absorption(
		"materials/test/ceiling.vmt",
		{
			surfaceprop = {surfaceprop_name = "ceiling_tile", base = {surfaceprop_name = "cardboard"}},
		}
	)
	T(metal.y)["<"](0.05)
	T(concrete.y)["<"](0.05)
	T(sofa.y)[">"](0.5)
	T(fence.y)[">"](0.7)
	T(ceiling.y)[">"](0.5)
end)

T.Test3D("a registered texture override replaces the source texture conversion", function()
	local function make()
		return {
			shader = "lightmappedgeneric",
			basetexture = "test/override_source",
			envmap = "env_cubemap",
			phong = 1,
			alphatest = 1,
			nocull = 1,
			source_text = "",
		}
	end

	local material = Material.New{}
	material:SetName("materials/test/override.vmt")
	material.vmt_path = "materials/test/override.vmt"

	Material.RegisterTextureOverride("test", function(path)
		if path ~= "materials/test/override.vmt" then return end

		return {
			textures = {
				Albedo = "test/override_albedo",
				Normal = "test/override_normal",
				MetallicRoughness = "test/override_mr",
			},
			properties = {HeightScale = 0.25},
		}
	end)

	vmt_material.Apply(material, make())
	Material.RegisterTextureOverride("test", nil)
	T(material:GetAlbedoTexture() ~= nil)["=="](true)
	T(material:GetNormalTexture() ~= nil)["=="](true)
	T(material:GetMetallicRoughnessTexture() ~= nil)["=="](true)
	T(material:GetMetallicMultiplier())["=="](1)
	T(material:GetHeightScale())["=="](0.25)
	T(material:GetAlphaTest())["=="](true)
	T(material:GetDoubleSided())["=="](true)
	T(material:GetAlbedoLuminanceIsRoughness())["=="](false)
	local source = Material.New{}
	source.vmt_path = "materials/test/override.vmt"
	vmt_material.Apply(source, make())
	T(source:GetMetallicRoughnessTexture())["=="](nil)
end)

T.Test3D("vmt_material.GetSurfacePrior resolves the class from the model surface property or the path", function()
	local metal = vmt_material.GetSurfacePrior("materials/foo.vmt", {}, "metalpanel")
	T(metal.class)["=="]("metalpanel")
	T(metal.roughness)["=="](0.3)
	T(metal.metallic)["=="](1)
	local brick = vmt_material.GetSurfacePrior("materials/brick/wall.vmt", {})
	T(brick.class)["=="]("brick")
	T(brick.metallic)["=="](0)
	T(vmt_material.GetSurfacePrior("materials/foo.vmt", {}))["=="](nil)
end)
