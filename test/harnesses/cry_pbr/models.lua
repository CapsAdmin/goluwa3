local pvars = import("goluwa/cli/pvars.lua")
if os.getenv("LUM") then pvars.SetSession("r_albedo_luminance_roughness", true) end
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Shot = import("goluwa/render3d/shot.lua")
local root = "/run/media/caps/extra/SteamLibrary/steamapps/common/Crysis/Game/Objects.pak/Objects/"
local models = {
	"Library/Storage/Barrels/Barrel_blue.cgf",
	"Library/Storage/Barrels/Barrel_explosiv_black.cgf",
	"Library/Architecture/Aircraftcarrier/props/furniture/lockers/equipment_locker1.cgf",
	"Library/Machines/Cranes/Harbor_crane_pump/harbour_crane_pump_cabin.cgf",
	"Library/Architecture/Mobile_Camp_Structures/Mobile_Generator_US/mobile_generator.cgf",
	"Library/Props/Gasstation/pumping_station.cgf",
	"Vehicles/speedboat/speedboat.cgf",
	"Library/Vehicles/asian_transport_helicopter/asian_transport_helicopter.cgf",
	"Library/Barriers/tank_trap/tank_trap.cgf",
	"Natural/Rocks/Cliff_Rocks/cliff_rock_neutral_big_a.cgf",
	"Natural/Trees/Palm_Tree/Palm_Tree_Large_e.cgf",
	"Library/Barriers/Fence/Metall/metallfence/metalfence_b_4m.cgf",
	"Library/Architecture/Village/school_modern_frame_low_big.cgf",
	"Library/Storage/Crates/cardboard_boxes/cardboard_boxA.cgf",
	"Weapons/Alien/MOAR/MOAR.cgf",
	"Library/Props/Electronic_Devices/Radars/portable_radar1_asian.cgf",
	"Vehicles/US_Cargoplane_Damaged/US_Cargoplane_Damaged_Main.cgf",
	"Library/Alien/Alien_mountain/AMountain_Tank_Ship.cgf",
}
local only = os.getenv("ONLY")
local tag = os.getenv("TAG") or "m"
local ents = {}

for i, rel in ipairs(models) do
	if not only or tostring(i) == only then
		local ent = Entity.New{Name = rel, Parent = Entity.World}
		ent:AddComponent("transform"):SetPosition(Vec3(#ents * 400, 0, 0))
		ent:AddComponent("visual")
		ent.visual:SetModelPath(root .. rel)
		ents[#ents + 1] = {ent = ent, index = i, rel = rel}
	end
end

local start = system.GetTime()
local started = false

event.AddListener("Update", "cry_models_shots", function()
	if started then return end

	for _, info in ipairs(ents) do
		if info.ent.visual:IsLoading() and system.GetTime() - start < 60 then return end
	end

	if system.GetTime() - start < 3 then return end

	started = true
	local views = {}

	for _, info in ipairs(ents) do
		local aabb = info.ent.visual:GetWorldAABB()
		local min = Vec3(aabb.min_x, aabb.min_y, aabb.min_z)
		local max = Vec3(aabb.max_x, aabb.max_y, aabb.max_z)
		local center = (min + max) * 0.5
		local radius = math.max((max - min):GetLength() * 0.5, 0.5)
		local distance = radius / math.tan(math.rad(40) / 2) * 1.05
		local pitch = math.rad(15)
		print(("[%d/%d] %s size=%s"):format(info.index, #models, info.rel, tostring(max - min)))

		for _, child in ipairs(info.ent:GetChildrenList()) do
			local primitive = child.visual_primitive
			local m = primitive and primitive:GetMaterial()

			if m then
				print(
					("    %-28s metal=%.2f rough_mult=%.2f min=%.2f max=%.2f spec=%.0f rtex=%s albedoA=%s maskmetal=%s"):format(
						tostring(m.cry_sub_material_name or "?"),
						m.MetallicMultiplier,
						m.RoughnessMultiplier,
						m.RoughnessMin,
						m.RoughnessMax,
						m.SpecularMultiplier,
						tostring(m.RoughnessTexture ~= nil),
						tostring(m.AlbedoTextureAlphaIsRoughness),
						tostring(m.MetallicFromRoughnessMask)
					)
				)
			end
		end
		views[#views + 1] = {
			Position = center + Vec3(0, math.sin(pitch) * distance, math.cos(pitch) * distance),
			Rotation = QuatDeg3(-15, 0, 0),
			FOV = math.rad(40),
			ExposureLock = 13,
		}
	end

	local i = 0

	Shot.Sequence(
		views,
		function(tex)
			i = i + 1
			print(tex:SaveWithoutAlpha(("tmp/cry_model_%s_%02d.png"):format(tag, ents[i].index)))
		end,
		{settle = 2},
		function()
			system.ShutDown(0)
		end
	)
end)
