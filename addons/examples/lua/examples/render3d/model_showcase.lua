local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local ALYX_APP_ID = 546560
local ROW_SPACING = 7
local GROUND_SIZE = 240
steam.MountSourceGame("gmod")
local alyx = steam.FindSourceGame(ALYX_APP_ID)

if alyx then steam.MountSourceGame(alyx) end

local rows = {
	{
		name = "garry's mod: props",
		spacing = 2.5,
		models = {
			"models/props_c17/oildrum001.mdl",
			"models/props_borealis/bluebarrel001.mdl",
			"models/props_junk/popcan01a.mdl",
			"models/props_junk/glassjug01.mdl",
			"models/props_junk/watermelon01.mdl",
			"models/props_c17/bench01a.mdl",
			"models/props_junk/wood_crate001a.mdl",
			"models/props_lab/monitor01a.mdl",
			"models/props_c17/lamp001a.mdl",
		},
	},
	{
		name = "garry's mod: characters",
		spacing = 3,
		models = {
			"models/alyx.mdl",
			"models/eli.mdl",
			"models/gman.mdl",
			"models/magnusson.mdl",
			"models/vortigaunt.mdl",
			"models/zombie/classic.mdl",
			"models/combine_soldier.mdl",
			"models/humans/group01/male_01.mdl",
			"models/humans/group03/female_01.mdl",
		},
	},
	{
		name = "garry's mod: large",
		spacing = 9,
		models = {
			"models/props_trainstation/train_engine.mdl",
			"models/props_canal/boat002b.mdl",
			"models/props_combine/combine_bridge_b.mdl",
			"models/props_foliage/tree_pine_large.mdl",
			"models/props_combine/breendesk.mdl",
			"models/props_rooftop/end_parliament_dome.mdl",
		},
	},
	{
		name = "half-life: alyx: xen",
		spacing = 3.5,
		alyx = true,
		models = {
			"models/props/xen/xen_foam_floor_wall001.vmdl_c",
			"models/props/xen/xen_foam_base_chunks001.vmdl_c",
			"models/props/xen/xen_foam_blobs001_large.vmdl_c",
			"models/props/xen/xen_foam_straight01.vmdl_c",
			"models/props/xen/xen_blob001.vmdl_c",
			"models/props/xen/xen_bulb001.vmdl_c",
			"models/props/xen/xen_bulb002.vmdl_c",
			"models/props/xen/xen_sac001.vmdl_c",
			"models/props/xen/xen_pod_structure001.vmdl_c",
			"models/props/xen/xen_coralear01.vmdl_c",
			"models/props/xen/xen_flower004.vmdl_c",
			"models/props/xen/xen_headcrab_cluster001.vmdl_c",
			"models/props/xen/xen_nodule001.vmdl_c",
			"models/props/xen/xen_vort_plant.vmdl_c",
		},
	},
	{
		name = "half-life: alyx: glass and liquids",
		spacing = 1.2,
		alyx = true,
		models = {
			"models/props_interiors/waterbottle.vmdl_c",
			"models/props/distillery/bottle_vodka.vmdl_c",
			"models/props/distillery/vodka_glass.vmdl_c",
			"models/props/water_meter_1.vmdl_c",
			"models/props/combine/combine_antlion_juice_jar_small.vmdl_c",
			"models/props/combine/combine_antlion_juice_jar_shell.vmdl_c",
		},
	},
	{
		name = "garry's mod: force fields, glow and refraction",
		spacing = 4,
		models = {
			"models/props_combine/stasisfield.mdl",
			"models/props_combine/combine_fence01a.mdl",
			"models/props_combine/combine_fence01b.mdl",
			"models/effects/combineball.mdl",
			"models/shadertest/predator.mdl",
			"models/props_combine/combine_light001a.mdl",
			"models/props_combine/combine_dispenser.mdl",
			"models/props_lab/tpplug.mdl",
		},
	},
	{
		name = "half-life: alyx: energy fields, additive and holograms",
		spacing = 4,
		alyx = true,
		models = {
			"models/props_combine/combine_vault_interior/combine_vault_interior_iso_cage_glass.vmdl_c",
			"models/props_combine/combine_structures/vault_shield_mesh.vmdl_c",
			"models/characters/combine_soldier_heavy/combine_hand_shield.vmdl_c",
			"models/props_combine/combine_consoles/combine_monitor_medium.vmdl_c",
			"models/props_combine/health_charger/combine_health_charger_vr_pad.vmdl_c",
			"models/hologram_fx/alyx_scan_skull_holo.vmdl_c",
			"models/hologram_fx/eli_scan_skull_holo.vmdl_c",
			"models/hologram_fx/alyxgun_holo.vmdl_c",
			"models/hologram_fx/console_holo.vmdl_c",
			"models/hologram_fx/combine_locker_holo.vmdl_c",
			"models/hacking/holo_hacking_sphere_prop.vmdl_c",
			"models/particle/sphere.vmdl_c",
		},
	},
	{
		name = "half-life: alyx: blended materials (2 way, triplanar, membrane, xen foliage)",
		spacing = 5,
		alyx = true,
		models = {
			"models/architecture/broken_concrete/broken_concrete_pillar_32x32a.vmdl_c",
			"models/architecture/broken_concrete/broken_concrete_corner_8x8a.vmdl_c",
			"models/architecture/broken_wall_segments/concrete_broken_chunk01a.vmdl_c",
			"models/props/debris/debris_plank_broken_long_001a.vmdl_c",
			"models/architecture/hotel/hotel_staircase_001a.vmdl_c",
			"models/props/xen/xen_horiz001_wide002.vmdl_c",
			"models/props/xen/xen_wall_blobs002a.vmdl_c",
			"models/props/xen/xen_wall_blobs003a.vmdl_c",
			"models/props/xen/xen_web_floor_wall002a.vmdl_c",
			"models/props/xen/xen_web_flat_segment001.vmdl_c",
		},
	},
	{
		name = "half-life: alyx: layered parallax (2 and 3 layer)",
		spacing = 6,
		alyx = true,
		models = {
			"models/combine_train/combine_train_interior_wall01a.vmdl_c",
			"models/combine_train/combine_train_exterior_door01a.vmdl_c",
			"models/combine_train/combine_train_interior_truss01a.vmdl_c",
			"models/architecture/distillery/distillery_window_large_01a.vmdl_c",
			"models/architecture/distillery/distillery_window_large_02a.vmdl_c",
			"models/architecture/distillery/distillery_window_small_01a.vmdl_c",
		},
	},
	{
		name = "half-life: alyx: large",
		spacing = 7,
		alyx = true,
		models = {
			"models/props_vehicles/car001a_hatchback.vmdl_c",
			"models/props/combine/combine_antlion_juice_tank.vmdl_c",
		},
	},
}
local ground_material = shapes.Material{Color = Color(0.35, 0.35, 0.35, 1), Roughness = 0.9, Metallic = 0}
shapes.Box{
	Name = "model_showcase_ground",
	Position = Vec3(0, -0.5, -ROW_SPACING * (#rows - 1) / 2),
	Size = Vec3(GROUND_SIZE, 1, GROUND_SIZE),
	Material = ground_material,
	RigidBody = {MotionType = "static"},
}
weather.SetSunRotation(QuatDeg3(-35, 200, 0))

for r, row in ipairs(rows) do
	if row.alyx and not alyx then
		logf("model_showcase: skipping %q, half-life: alyx is not installed\n", row.name)
	else
		for i, path in ipairs(row.models) do
			if not vfs.IsFile(path) then
				logf("model_showcase: %s not found\n", path)
			else
				local ent = Entity.New{Name = "model_showcase_" .. path}
				ent:AddComponent("transform")
				ent.transform:SetPosition(Vec3((i - (#row.models + 1) / 2) * row.spacing, 0, -(r - 1) * ROW_SPACING))
				ent:AddComponent("visual")
				ent.visual:SetGroundHeight(0)
				ent.visual:SetModelPath(path)
			end
		end
	end
end

local cam = render3d.GetCamera()
cam:SetPosition(Vec3(0, 1.7, 6))
cam:SetAngles(Deg3(-8, 0, 0))
