local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")

local function create_rays_only_cube(rays_only)
	local cube = Polygon3D.New()
	shapes.BuildCube(cube, 1)
	cube:BuildBoundingBox()
	cube:Upload()
	local entity = Entity.New{Name = "rays_only_cube"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -4))
	local visual = entity:AddComponent("visual")
	visual:SetRaysOnly(rays_only)
	visual:SetUseOcclusionCulling(false)
	local primitive = Entity.New{Name = "rays_only_cube_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(cube)
	visual_primitive:SetMaterial(Material.New{ColorMultiplier = Color(1, 0, 0, 1)})
	visual:BuildAABB()
	return entity
end

T.Test3D("Graphics render3d a rays only visual is in the scene bvh and is not drawn", function(draw)
	local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local entity = create_rays_only_cube(true)

	for _ = 1, 4 do
		draw()
	end

	local size = render.GetRenderImageSize()
	local r = gbuffer_layout.GetTexture("albedo"):GetPixel(math.floor(size.x / 2), math.floor(size.y / 2))
	scene_bvh.Build(true)
	local in_bvh = scene_bvh.visual_cache[entity.visual] ~= nil and scene_bvh.visual_cache[entity.visual].block_index ~= nil
	entity:Remove()
	T(r)["<"](200)
	T(in_bvh)["=="](true)
end)
