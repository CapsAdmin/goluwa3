local steam = import("goluwa/steam/steam.lua")
local Entity = import("goluwa/ecs/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local info = list.find(steam.GetGames(), function(game)
	return game.appid == 17300
end)
assert(info, "Crysis 1 not found")
local objects_root = info.game_dir .. "Game/Objects.pak/Objects/Natural/"
local height_offset = Vec3(0, 0, 1.5)
local foliage = {
	{
		name = "crysis_palm_tree",
		model_path = objects_root .. "Trees/Palm_Tree/Palm_Tree_large_a.cgf",
		forward = 8.5,
		right = -5.5,
	},
	{
		name = "crysis_banana_tree",
		model_path = objects_root .. "Trees/Banana_Tree/Bananatree_big_a.cgf",
		forward = 5.0,
		right = -0.5,
	},
	{
		name = "crysis_jungle_bush",
		model_path = objects_root .. "Bushes/JungleBush/junglebush_big_b.cgf",
		forward = 7.0,
		right = 5.5,
	},
	{
		name = "crysis_tall_fern_bush",
		model_path = objects_root .. "Bushes/TallFernBush/Tall_Fern_Bush_big_a.cgf",
		forward = 5.5,
		right = 3.2,
	},
	{
		name = "crysis_fern_cover",
		model_path = objects_root .. "Ground_Plants/ground_cover_fern/fern_a.cgf",
		forward = 2.8,
		right = 1.8,
	},
	{
		name = "crysis_short_palm",
		model_path = objects_root .. "Trees/Palm_Tree/Palm_Tree_Short_b.cgf",
		forward = 9.5,
		right = 2.5,
	},
	{
		name = "crysis_palm_tree_back",
		model_path = objects_root .. "Trees/Palm_Tree/Palm_Tree_large_a.cgf",
		forward = 12.5,
		right = -8.0,
	},
	{
		name = "crysis_banana_tree_left",
		model_path = objects_root .. "Trees/Banana_Tree/Bananatree_big_a.cgf",
		forward = 6.8,
		right = -3.0,
	},
	{
		name = "crysis_banana_tree_right",
		model_path = objects_root .. "Trees/Banana_Tree/Bananatree_big_a.cgf",
		forward = 4.6,
		right = 2.2,
	},
	{
		name = "crysis_jungle_bush_left",
		model_path = objects_root .. "Bushes/JungleBush/junglebush_big_b.cgf",
		forward = 6.0,
		right = -1.8,
	},
	{
		name = "crysis_jungle_bush_far",
		model_path = objects_root .. "Bushes/JungleBush/junglebush_big_b.cgf",
		forward = 9.0,
		right = 6.8,
	},
	{
		name = "crysis_tall_fern_bush_left",
		model_path = objects_root .. "Bushes/TallFernBush/Tall_Fern_Bush_big_a.cgf",
		forward = 4.8,
		right = -2.0,
	},
	{
		name = "crysis_tall_fern_bush_far",
		model_path = objects_root .. "Bushes/TallFernBush/Tall_Fern_Bush_big_a.cgf",
		forward = 8.2,
		right = 1.0,
	},
	{
		name = "crysis_fern_cover_left",
		model_path = objects_root .. "Ground_Plants/ground_cover_fern/fern_a.cgf",
		forward = 3.2,
		right = -1.5,
	},
	{
		name = "crysis_fern_cover_right",
		model_path = objects_root .. "Ground_Plants/ground_cover_fern/fern_a.cgf",
		forward = 3.8,
		right = 4.0,
	},
	{
		name = "crysis_short_palm_far",
		model_path = objects_root .. "Trees/Palm_Tree/Palm_Tree_Short_b.cgf",
		forward = 11.5,
		right = 4.8,
	},
}
local camera = render3d.GetCamera()
local camera_angles = camera:GetAngles()
local origin = camera:GetPosition()
local forward = camera_angles:GetForward()
local right = camera_angles:GetRight()

for _, entry in ipairs(foliage) do
	local ent = Entity.New{Name = entry.name, Parent = Entity.World}
	local transform = ent:AddComponent("transform")
	ent:AddComponent("visual")
	transform:SetPosition(origin + height_offset + forward * entry.forward + right * entry.right)
	ent.visual:SetModelPath(entry.model_path)
	print("spawned", entry.model_path)
end
