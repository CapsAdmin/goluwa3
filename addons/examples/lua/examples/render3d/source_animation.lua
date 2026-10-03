local Vec3 = import("goluwa/structs/vec3.lua")
local Entity = import("goluwa/entities/entity.lua")
local steam = import("goluwa/steam/steam.lua")
steam.MountSourceGame("gmod")
local characters = {
	{"models/player/alyx.mdl", "walk_all", {move_x = 1}},
	{"models/player/combine_soldier.mdl", "run_all_01", {move_x = 1}},
	{"models/player/eli.mdl", "idle_all_01"},
	{"models/player/gman_high.mdl", "menu_gman"},
	{"models/player/vortigaunt.mdl", "idle_all_01"},
	{"models/player/combine_super_soldier.mdl", "cwalk_all", {move_x = 1}},
}

for i, info in ipairs(characters) do
	local entity = Entity.New({Name = "animated_" .. i})
	local transform = entity:AddComponent("transform")
	transform:SetPosition(Vec3((i - 1) * 1.5 - #characters * 0.75, 0, 0))
	entity:AddComponent("visual")
	entity.visual:SetModelPath(info[1])
	local animator = entity:AddComponent("animator")
	animator:SetSequence(info[2])

	for name, value in pairs(info[3] or {}) do
		animator:SetPoseParameterByName(name, value)
	end
end
