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
