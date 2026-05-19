local steam = import("goluwa/steam/steam.lua")
local Entity = import("goluwa/ecs/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local info = list.find(steam.GetGames(), function(game)
	return game.appid == 17300
end)
assert(info, "Crysis 1 not found")
local model_path = info.game_dir .. "Game/Objects.pak/Objects/Natural/Trees/Banana_Tree/Bananatree_big_a.cgf"
local ent = Entity.New{Name = "crysis_beach_rock", Parent = Entity.World}
local camera = render3d.GetCamera()
local transform = ent:AddComponent("transform")
ent:AddComponent("visual")
transform:SetPosition(camera:GetPosition() + camera:GetAngles():GetForward() * 3)
ent.visual:SetModelPath(model_path)
print("spawned", model_path)
