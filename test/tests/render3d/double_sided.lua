local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local gpu_culling = import("goluwa/render3d/gpu_culling.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")

local function create_back_facing_quad()
	local cube = Polygon3D.New()
	shapes.BuildCube(cube, 0.5, 1.0)
	local poly = Polygon3D.New()

	for i = 1, #cube.Vertices, 3 do
		local a, b, c = cube.Vertices[i], cube.Vertices[i + 1], cube.Vertices[i + 2]

		if a.pos.z < 0 and b.pos.z < 0 and c.pos.z < 0 then
			poly:AddVertex(a)
			poly:AddVertex(b)
			poly:AddVertex(c)
		end
	end

	T(#poly.Vertices)["=="](6)
	poly:BuildBoundingBox()
	poly:Upload()
	return poly
end

local function spawn(polygon3d, material)
	local entity = Entity.New{Name = "double_sided_quad"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -4))
	entity:AddComponent("visual")
	local primitive = Entity.New{Name = "double_sided_quad_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	return entity
end

local function draw_center_red(draw, double_sided, count, use_gpu_culling)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local polygon3d = create_back_facing_quad()
	local material = Material.New{
		ColorMultiplier = Color(1, 0, 0, 1),
		DoubleSided = double_sided,
	}
	local entities = {}

	for i = 1, count do
		entities[i] = spawn(polygon3d, material)
	end

	local was_enabled = gpu_culling.IsEnabled()
	gpu_culling.SetEnabled(use_gpu_culling)
	local ok, err = pcall(function()
		for _ = 1, use_gpu_culling and 4 or 1 do
			draw()
		end
	end)
	gpu_culling.SetEnabled(was_enabled)

	for _, entity in ipairs(entities) do
		entity:Remove()
	end

	if not ok then error(err, 0) end

	local size = render.GetRenderImageSize()
	return (gbuffer_layout.GetTexture("albedo"):GetPixel(math.floor(size.x / 2), math.floor(size.y / 2)))
end

T.Test3D("Graphics render3d double sided materials draw back faces in single draws", function(draw)
	T(draw_center_red(draw, false, 1, false))["<"](10)
	T(draw_center_red(draw, true, 1, false))[">"](200)
	T(gbuffer_instancing.GetStats().singleton_draws)["=="](1)
end)

T.Test3D("Graphics render3d double sided materials draw back faces in instanced draws", function(draw)
	T(draw_center_red(draw, false, 2, false))["<"](10)
	T(draw_center_red(draw, true, 2, false))[">"](200)
	T(gbuffer_instancing.GetStats().instanced_draws)["=="](1)
end)

T.Test3D("Graphics render3d double sided materials draw back faces in gpu culled draws", function(draw)
	T(draw_center_red(draw, false, 1, true))["<"](10)
	T(draw_center_red(draw, true, 1, true))[">"](200)
end)
