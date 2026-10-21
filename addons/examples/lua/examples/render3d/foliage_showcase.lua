local assets = import("goluwa/assets.lua")
local Entity = import("goluwa/entities/entity.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local gallery = import("lua/foliage/gallery.lua")

if _G.foliage_showcase then _G.foliage_showcase:Remove() end

local root = Entity.New{Name = "foliage_showcase", Parent = Entity.World}
root:AddComponent("transform")
_G.foliage_showcase = root
local ground = Entity.New{Name = "foliage_showcase_ground", Parent = root}
ground:AddComponent("transform")
ground:AddComponent("visual")
local polygon = Polygon3D.New()
shapes.BuildPlane(polygon, Vec3(0, 0, 0), Vec3(0, 1, 0), 120, 120, 30, 24, 24, Vec3(0, 0, -1))
polygon:BuildBoundingBox()
polygon:Upload()
local primitive = Entity.New{Name = "foliage_showcase_ground_primitive", Parent = ground}
primitive:AddComponent("transform")
primitive:AddComponent("visual_primitive"):SetPolygon3D(polygon)
primitive.visual_primitive:SetMaterial(assets.Load("materials/examples/soil.lua"))
ground.visual:BuildAABB()
gallery.Spawn(root, Vec3(0, 0, 20))
