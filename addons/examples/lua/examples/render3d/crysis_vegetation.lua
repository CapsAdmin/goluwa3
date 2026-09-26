local steam = import("goluwa/steam/steam.lua")
local Entity = import("goluwa/entities/entity.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local vfs = import("goluwa/vfs.lua")
local info = list.find(steam.GetGames(), function(game)
	return game.appid == 17300
end)
assert(info, "Crysis 1 not found")
local objects_root = info.game_dir .. "Game/Objects.pak/Objects/Natural/"
local height_offset = Vec3(0, 0, 1.5)
local vegetation = list.filter(vfs.GetFilesRecursive(objects_root, {"cgf"}), function(path)
	path = path:lower()
	return path:find("grass") or path:find("tree") or path:find("bush")
end)
local camera = render3d.GetCamera()
local camera_angles = camera:GetAngles()
local origin = camera:GetPosition()
local forward = camera_angles:GetForward()
local right = camera_angles:GetRight()
local x, y = 0, 0

for i, path in ipairs(vegetation) do
	local ent = Entity.New{Name = path, Parent = Entity.World}
	local transform = ent:AddComponent("transform")
	ent:AddComponent("visual")
	transform:SetPosition(origin + Vec3(x, 0, y) * 15)
	ent.visual:SetModelPath(path)
	x = x + 1

	if x > 10 then
		x = 0
		y = y + 1
	end
end
