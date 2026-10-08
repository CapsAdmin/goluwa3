local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local timer = import("goluwa/timer.lua")
local steam = import("goluwa/steam/steam.lua")
local vmt_material = import("goluwa/source_engine/vmt_material.lua")
steam.MountSourceGame("gmod")
-- one row per translation path of vmt_material.lua
local rows = {
	{
		name = "envmap, no mask: weak tint = smooth dielectric, strong tint = metal",
		models = {
			"models/props_c17/oildrum001.mdl",
			"models/props_borealis/bluebarrel001.mdl",
			"models/props_junk/popcan01a.mdl",
			"models/props_lab/monitor01a.mdl",
		},
	},
	{
		name = "envmap masked by base alpha / normal alpha",
		models = {
			"models/props_c17/consolebox05a.mdl",
			"models/food/hotdog.mdl",
			"models/food/burger.mdl",
			"models/weapons/w_357.mdl",
		},
	},
	{
		name = "envmapmask texture",
		models = {
			"models/props_combine/combine_interface001.mdl",
			"models/props_c17/furniturefridge001a.mdl",
			"models/props_wasteland/laundry_washer003.mdl",
			"models/weapons/w_smg1.mdl",
		},
	},
	{
		name = "phong: bump alpha mask, exponent texture, tint, albedo tint, boost",
		models = {
			"models/humans/group01/male_01.mdl",
			"models/alyx.mdl",
			"models/eli.mdl",
			"models/gman.mdl",
			"models/magnusson.mdl",
		},
	},
	{
		name = "phong: inverted mask (watch), luminance mask (shield), bump-alpha mask (scarf), flat strong fresnel (silo), normal-alpha lobe (jet)",
		models = {
			"models/weapons/c_models/c_spy_watch.mdl",
			"models/weapons/csgo/w_eq_shield.mdl",
			"models/player/items/all_class/all_winter_scarf_demo.mdl",
			"models/props_silo/silo_elevator.mdl",
			"models/xqm/jetbody2.mdl",
		},
	},
	{
		name = "surfaceprop fallback: metal vs not, glass, selfillum",
		models = {
			"models/props_wasteland/coolingtank01.mdl",
			"models/props_wasteland/boat_fishing02a.mdl",
			"models/props_junk/glassjug01.mdl",
			"models/xqm/jetbody3.mdl",
			"models/props_c17/lamp001a.mdl",
			"models/props_junk/watermelon01.mdl",
		},
	},
	{
		name = "properties without a translation yet: envmapcontrast (hoverball, glasses), rimlight (skeleton, citizen), phongalbedotint (vortigaunt, zombie, combine), envmapsaturation (coaster)",
		models = {
			"models/dav0r/hoverball.mdl",
			"models/player/skeleton.mdl",
			"models/vortigaunt.mdl",
			"models/zombie/classic.mdl",
			"models/combine_soldier.mdl",
			"models/humans/group03/female_01.mdl",
			"models/kleiner.mdl",
			"models/xqm/coastertrack/straight_1.mdl",
		},
	},
}
local map_materials = {
	"tile/tilefloor001b",
	"wood/woodfloor008a",
	"wood/woodwall016a",
	"metal4",
	"glass/glasswindow018a",
	"de_aztec/ground01_blend",
	"dev/dev_corrugatedmetal",
	"metal/citadel_tilewall005a",
	"nature/blendrockdirt_tunnel03a",
	"metal/metalwall102a",
}
local untranslated_map_materials = {
	"metal/metalwall070g",
	"concrete/concretefloor013c",
	"concrete/concretefloor037a",
	"wood/woodfloor007a",
	"metal/metal_grate_c2a2_rusty1",
	"gm_construct/wall_bottom",
}
local SPACING = 2.6
local ROW_SPACING = 4
local ground = shapes.Box{
	Name = "source_vmt_ground",
	Position = Vec3(0, -0.65, -ROW_SPACING * (#rows + 2) / 2 + ROW_SPACING / 2),
	Size = Vec3(40, 1, ROW_SPACING * (#rows + 2) + 8),
	Material = shapes.Material{Color = Color(0.45, 0.45, 0.45, 1), Roughness = 0.9, Metallic = 0},
	RigidBody = false,
}
weather.SetSunRotation(QuatDeg3(-38, 35, 0))
local visuals = {}

for r, row in ipairs(rows) do
	print("row " .. r .. " (z = " .. -(r - 1) * ROW_SPACING .. "): " .. row.name)

	for i, path in ipairs(row.models) do
		local ent = Entity.New{Name = "source_vmt_" .. path}
		ent:AddComponent("transform")
		ent.transform:SetPosition(Vec3((i - (#row.models + 1) / 2) * SPACING, 0, -(r - 1) * ROW_SPACING))
		ent:AddComponent("visual")
		ent.visual:SetModelPath(path)
		visuals[#visuals + 1] = {path = path, ent = ent}
	end
end

for cube_row, names in ipairs{map_materials, untranslated_map_materials} do
	print(
		"row " .. #rows + cube_row .. " (z = " .. -(
				#rows + cube_row - 1
			) * ROW_SPACING .. "): map materials on cubes" .. (
				cube_row == 2 and
				" (fresnelreflection, alphaenvmapmask, reflectivity)" or
				""
			)
	)

	for i, name in ipairs(names) do
		shapes.Box{
			Name = "source_vmt_cube_" .. name,
			Position = Vec3((i - (#names + 1) / 2) * SPACING, 0.75, -(#rows + cube_row - 1) * ROW_SPACING),
			Size = Vec3(1.5, 1.5, 1.5),
			Material = vmt_material.FromVMT("materials/" .. name .. ".vmt"),
			RigidBody = false,
		}
	end
end

do
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 3, 6))
	cam:SetAngles(Deg3(-12, 0, 0))
end

timer.Delay(8, function()
	for _, info in ipairs(visuals) do
		print(info.path)
		local seen = {}

		for _, child in ipairs(info.ent:GetChildrenList()) do
			local primitive = child.visual_primitive
			local material = primitive and primitive:GetMaterial()

			if material and not seen[material] then
				seen[material] = true
				print(
					string.format(
						"  %s metallic=%.2f rough=%.2f range=%.2f..%.2f maskmetal=%s alpha[a=%s n=%s l=%s] tex=%s",
						tostring(material.Name),
						material.MetallicMultiplier,
						material.RoughnessMultiplier,
						material.RoughnessMin,
						material.RoughnessMax,
						tostring(material.MetallicFromRoughnessMask),
						tostring(material.AlbedoTextureAlphaIsRoughness),
						tostring(material.NormalTextureAlphaIsRoughness),
						tostring(material.AlbedoLuminanceIsRoughness),
						tostring(material.RoughnessTexture ~= nil)
					)
				)
			end
		end
	end
end)
