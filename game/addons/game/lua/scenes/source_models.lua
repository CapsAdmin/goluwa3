local Vec3 = import("goluwa/structs/vec3.lua")
local Entity = import("goluwa/ecs/entity.lua")
local vfs = import("goluwa/vfs.lua")
local steam = import("goluwa/steam.lua")
steam.MountSourceGame("gmod")
local models = {
	"models/zombie/classic.mdl",
	"models/zombie/zombie_soldier.mdl",
	"models/vehicles/prisoner_pod_inner.mdl",
	"models/vehicle/vehicle_rich.mdl",
	"models/props_trainstation/train_engine.mdl",
	"models/props_trainstation/train001.mdl",
	"models/props_rooftop/end_parliament_dome.mdl",
	"models/props_foliage/tree_pine_large.mdl",
	"models/props_foliage/ah_ash_tree_med.mdl",
	"models/props_foliage/bush2.mdl",
	"models/props_foliage/treepine03c.mdl",
	"models/props_docks/channelmarker_gib02.mdl",
	"models/props_canal/boat002b.mdl",
	"models/props_c17/oildrum001_explosive.mdl",
	"models/props_debris/barricade_tall04a.mdl",
	"models/props_combine/combine_monitorbay.mdl",
	"models/props_combine/combine_interface002.mdl",
	"models/props_combine/combine_interface002.mdl",
	"models/props_combine/combinetrain01a.mdl",
	"models/props_combine/masterinterface_dyn.mdl",
	"models/props_combine/breendesk.mdl",
	"models/props_combine/breenglobe.mdl",
	"models/props_combine/breenchair.mdl",
	"models/props_combine/combine_bridge_b.mdl",
	"models/props_combine/combine_booth_short01a.mdl",
	"models/props_combine/weaponstripper.mdl",
	"models/props_c17/oildrum001.mdl",
	"models/props_c17/trappropeller_blade.mdl",
	"models/props_borealis/bluebarrel001.mdl",
	"models/cliffs/rocks_small01_veg.mdl",
	"models/combine_helicopter/helicopter_bomb01.mdl",
	"models/combine_turrets/combine_cannon_gun.mdl",
	"models/player/alyx.mdl",
	"models/player/combine_super_soldier.mdl",
	"models/player/vortigaunt.mdl",
	"models/player/combine_soldier.mdl",
	"models/player/eli.mdl",
	"models/player/gman_high.mdl",
}

for _, path in ipairs(vfs.Find("models/shadertest/")) do
	if path:ends_with(".mdl") then
		table.insert(models, "models/shadertest/" .. path)
	end
end

local pos = Vec3(-10, -10, 0)

for _, model_path in ipairs(models) do
	if not vfs.IsFile(model_path) then
		print(model_path .. " not found!")
	else
		local e = Entity.New({Name = "model_ent"})
		local t = e:AddComponent("transform")
		t:SetPosition(pos:Copy())
		pos.x = pos.x + 5

		if pos.x > 10 then
			pos.x = -10
			pos.z = pos.z + 5
		end

		e:AddComponent("visual")
		e.visual:SetModelPath(model_path)
	end
end
