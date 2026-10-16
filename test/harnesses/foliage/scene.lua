-- a ground and a grid of foliage models. MODEL is a ; separated list of model paths (the trees by default), SPACING
-- the meters between them, COLUMNS how many in a row
local assets = import("goluwa/assets.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local system = import("goluwa/system.lua")
local foliage = import("lua/foliage/foliage.lua")
local models = {}

for path in (os.getenv("MODEL") or table.concat(foliage.GetModelPaths("trees"), ";")):gmatch("[^;]+") do
	models[#models + 1] = path
end

local spacing = tonumber(os.getenv("SPACING") or "") or 14
local columns = tonumber(os.getenv("COLUMNS") or "") or #models
local ground = Entity.New{Name = "foliage_ground", Parent = Entity.World}
ground:AddComponent("transform")
ground:AddComponent("visual")
local poly = Polygon3D.New()
shapes.BuildPlane(poly, Vec3(0, 0, 0), Vec3(0, 1, 0), 200, 200, 40, 20, 20, Vec3(0, 0, -1))
poly:BuildBoundingBox()
poly:Upload()
local primitive = Entity.New{Name = "foliage_ground_primitive", Parent = ground}
primitive:AddComponent("transform")
primitive:AddComponent("visual_primitive"):SetPolygon3D(poly)
primitive.visual_primitive:SetMaterial(assets.Load(os.getenv("GROUND") or "materials/examples/soil.lua"))
ground.visual:BuildAABB()
local start = system.GetTime()

for i, path in ipairs(models) do
	local x = (i - 1) % columns
	local z = math.floor((i - 1) / columns)
	local ent = Entity.New{Name = path, Parent = Entity.World}
	ent:AddComponent("transform"):SetPosition(Vec3((x - (columns - 1) / 2) * spacing, 0, -z * spacing))
	ent:AddComponent("visual"):SetModelPath(path)
end

print(("built %d foliage models in %.2f s"):format(#models, system.GetTime() - start))
