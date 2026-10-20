local T = import("test/environment.lua")
local tasks = import("goluwa/tasks.lua")
local steam = import("goluwa/steam/steam.lua")
local Material = import("goluwa/render3d/material.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local vmt_material = import("goluwa/source_engine/vmt_material.lua")

local function apply(vmt)
	local material = Material.New{}
	vmt.source_text = ""
	vmt_material.Apply(material, vmt)
	return material
end

T.Test3D("source materials: chrome, matte and the pbr shader", function()
	local chrome = apply{shader = "vertexlitgeneric", envmap = "env_cubemap", envmapsphere = 1, envmapmode = 1}
	T(chrome:IsMetallic())["=="](true)
	T(chrome:GetRoughnessMultiplier())["=="](0.05)
	local matte = apply{shader = "vertexlitgeneric"}
	T(matte:IsMetallic())["=="](false)
	local pbr = apply{shader = "pbr"}
	T(pbr:IsMetallic())["=="](false)
end)

T.Test3D("source materials: a colored envmap tint is a metal and a wood surfaceprop is not", function()
	local gold = apply{shader = "vertexlitgeneric", envmap = "env_cubemap", envmaptint = "[1 .8 .4]"}
	T(gold:IsMetallic())["=="](true)
	-- a translucent material is not metal for a class guess, an opaque one is
	local panel = {shader = "vertexlitgeneric", surfaceprop = {surfaceprop_name = "metalpanel"}}
	T(apply(panel):IsMetallic())["=="](true)
	panel = {shader = "vertexlitgeneric", surfaceprop = {surfaceprop_name = "metalpanel"}, translucent = 1}
	T(apply(panel):IsMetallic())["=="](false)
	local wood = apply{
		shader = "vertexlitgeneric",
		envmap = "env_cubemap",
		envmaptint = "[.3 .3 .2]",
		surfaceprop = {surfaceprop_name = "wood"},
	}
	T(wood:IsMetallic())["=="](false)
end)

-- name, is metal. what the metal gate and the surfaceprop, detail and model hints have to get right on content that ships with gmod
local vmts = {
	{"models/props_combine/breendesk_sheet", false, "dark brown wood with a metal surfaceprop and a strong envmap tint"},
	{"models/props_combine/breenglobe_sheet", false, "wood surfaceprop with a warm envmap tint"},
	{"models/props_c17/furnituretable001a", false, "dark wood"},
	{"models/props_wasteland/wood_fence01a", false, "wood"},
	{"models/props_c17/lockers001a", true, "no surfaceprop, a metal detail texture"},
	{"models/props_junk/metalbucket01a", true, "gray metal"},
	{"models/props_c17/metalladder001", true, "gray metal"},
	{"models/props_combine/combine_barricade_short01a", true, "dark metal, a bluish envmap tint"},
	{"models/props_combine/combine_interface001", true, "metal surfaceprop with an envmap tint of 0.1"},
}
-- model, material, is metal. the vmt of the material says nothing, the surfaceprop the model was compiled with does
local models = {
	{"models/props_lab/blastdoor001a.mdl", "materials/models/props_lab/blastdoor_sheet.vmt", true},
	{"models/props_lab/workspace004.mdl", "materials/models/props_lab/workspace_wires.vmt", false},
}

T.Test3D("source materials: metallic estimate on gmod content", function()
	if not steam.MountSourceGame("gmod", true) then
		return T.Unavailable("gmod content not mounted")
	end

	local materials = {}

	for i, info in ipairs(vmts) do
		materials[i] = vmt_material.FromVMT("materials/" .. info[1] .. ".vmt")
	end

	local model_materials = {}

	for i, info in ipairs(models) do
		model_loader.LoadModel(info[1], function() end, function(entry)
			if entry.material and entry.material:GetName() == info[2] then
				model_materials[i] = entry.material
			end
		end, function(err)
			error(info[1] .. ": " .. tostring(err))
		end)
	end

	local function ready(material)
		local albedo = material and material:GetAlbedoTexture()
		return material and (material.Error or (albedo and albedo.reflectivity))
	end

	local start = os.clock()

	while os.clock() - start < 30 do
		local all = true

		for _, material in ipairs(materials) do
			if not ready(material) then all = false end
		end

		for i in ipairs(models) do
			if not ready(model_materials[i]) then all = false end
		end

		if all then break end

		tasks.Wait(0.05)
	end

	for i, info in ipairs(vmts) do
		T(materials[i].Error)["=="](nil)
		T(materials[i]:IsMetallic(), info[1] .. " (" .. info[3] .. ")")["=="](info[2])
	end

	-- the lockers have a $detail texture, which varies their roughness
	T(materials[5]:GetMicroDetailTexture() ~= nil)["=="](true)
	T(materials[5]:GetMicroDetailRoughness() > 0)["=="](true)
	-- the desk has a roughness source of its own, the bump alpha. the fence has none, so its roughness is derived
	T(materials[1]:GetDerivedRoughnessAlbedo())["=="](0)
	T(materials[4]:GetDerivedRoughnessAlbedo() > 0)["=="](true)

	for i, info in ipairs(models) do
		T(model_materials[i] ~= nil, info[1])["=="](true)
		T(model_materials[i]:IsMetallic(), info[1] .. " " .. info[2])["=="](info[3])
	end
end)
