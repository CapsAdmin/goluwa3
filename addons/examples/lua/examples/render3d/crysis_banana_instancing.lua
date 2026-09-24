local steam = import("goluwa/steam/steam.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local info = list.find(steam.GetGames(), function(game)
	return game.appid == 17300
end)
assert(info, "Crysis 1 not found")
local model_path = info.game_dir .. "Game/Objects.pak/Objects/Natural/Trees/Banana_Tree/Bananatree_big_a.cgf"
local columns = 20
local rows = 15
local spacing_forward = 9
local spacing_right = 8
local start_forward = 14
local height_offset = Vec3(0, 0, 1.5)
local camera = render3d.GetCamera()
local camera_angles = camera:GetAngles()
local origin = camera:GetPosition()
local forward = camera_angles:GetForward()
local right = camera_angles:GetRight()
local half_columns = (columns - 1) * 0.5
local count = 0

for row = 0, rows - 1 do
	for column = 0, columns - 1 do
		count = count + 1
		local ent = Entity.New{
			Name = ("crysis_banana_tree_%03d"):format(count),
			Parent = Entity.World,
		}
		local transform = ent:AddComponent("transform")
		ent:AddComponent("visual")
		transform:SetPosition(
			origin + height_offset + forward * (
					start_forward + row * spacing_forward
				) + right * (
					(
						column - half_columns
					) * spacing_right
				)
		)
		ent.visual:SetModelPath(model_path)
	end
end

print("spawned", count, model_path)
