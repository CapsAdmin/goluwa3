local steam = import("goluwa/steam/steam.lua")
local assets = import("goluwa/assets.lua")
local Entity = import("goluwa/entities/entity.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local vfs = import("goluwa/vfs.lua")
local info = list.find(steam.GetGames(), function(game)
	return game.appid == 17300
end)
assert(info, "Crysis 1 not found")
local objects_root = info.game_dir .. "Game/Objects.pak/Objects/Natural/"
local vegetation = list.filter(vfs.GetFilesRecursive(objects_root, {"cgf"}), function(path)
	path = path:lower()
	return path:find("grass") or path:find("tree") or path:find("bush")
end)
local COLUMNS = 11
local SPACING = 15
local MARGIN = 20
local rows = math.ceil(#vegetation / COLUMNS)
local half_width = (COLUMNS - 1) * SPACING / 2 + MARGIN
local half_depth = (rows - 1) * SPACING / 2 + MARGIN
local ground = Entity.New{Name = "crysis_vegetation_ground", Parent = Entity.World}
ground:AddComponent("transform")
ground:AddComponent("visual")
local ground_poly = Polygon3D.New()
ground_poly:CreatePlane(
	Vec3(0, 0, 0),
	Vec3(0, 1, 0),
	Vec3(1, 0, 0),
	Vec3(0, 0, -1),
	half_width,
	half_depth,
	1,
	math.ceil(half_width / 5),
	math.ceil(half_depth / 5)
)
ground_poly:BuildBoundingBox()
ground_poly:Upload()
local ground_primitive = Entity.New{Name = "crysis_vegetation_ground_primitive", Parent = ground}
ground_primitive:AddComponent("transform")
local visual_primitive = ground_primitive:AddComponent("visual_primitive")
visual_primitive:SetPolygon3D(ground_poly)
visual_primitive:SetMaterial(assets.Load("materials/examples/grass.lua"))
ground.visual:BuildAABB()

for i, path in ipairs(vegetation) do
	local ent = Entity.New{Name = path, Parent = Entity.World}
	local transform = ent:AddComponent("transform")
	ent:AddComponent("visual")
	local x = (i - 1) % COLUMNS
	local y = math.floor((i - 1) / COLUMNS)
	transform:SetPosition(
		Vec3(
			x * SPACING - (COLUMNS - 1) * SPACING / 2,
			0,
			y * SPACING - (rows - 1) * SPACING / 2
		)
	)
	ent.visual:SetModelPath(path)
end
