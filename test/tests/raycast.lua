local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping raycast tests.")
	return
end

local T = require("test.environment")
local raycast = require("raycast")
local render = require("render.render")
local render3d = require("render3d.render3d")
local Polygon3D = require("render3d.polygon_3d")
local ecs = require("ecs")
local Vec3 = require("structs.vec3")
local Vec2 = require("structs.vec2")
local Quat = require("structs.quat")
local Color = require("structs.color")
local Rect = require("structs.rect")
local transform = require("components.3d.transform").Component
local model = require("components.3d.model").Component

local function init_render3d()
	render.Initialize({headless = true, width = 512, height = 512})
	render3d.Initialize()
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 0, -5))
	cam:SetRotation(Quat(0, 0, 0, 1))
	cam:SetViewport(Rect(0, 0, 512, 512))
	cam:SetFOV(math.rad(45))
end

T.Test("Raycast basic triangle hit", function()
	init_render3d()
	-- Create entity with triangle mesh
	local ent = ecs.CreateEntity("test_triangle", ecs.Get3DWorld())
	ent:AddComponent(transform)
	ent:AddComponent(model)
	local poly = Polygon3D.New()
	-- Triangle facing +Z (CCW winding from +Z)
	poly:AddVertex({pos = Vec3(-1, -1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(1, -1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, 1)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, 1)})
	poly:AddSubMesh(3)
	poly:BuildBoundingBox()
	poly:Upload()
	ent.model:AddPrimitive(poly)
	ent.model:BuildAABB()
	-- Cast ray at triangle from +Z toward -Z
	local origin = Vec3(0, 0, 2)
	local direction = Vec3(0, 0, -1)
	local hits = raycast.Cast(origin, direction, 10)
	T(#hits)["=="](1)
	T(hits[1].entity)["=="](ent)
	T(hits[1].distance)[">="](1.9)
	T(hits[1].distance)["<="](2.1)
	ent:Remove()
end)

T.Test("Raycast miss", function()
	init_render3d()
	-- Create entity with triangle mesh
	local ent = ecs.CreateEntity("test_triangle", ecs.Get3DWorld())
	ent:AddComponent(transform)
	ent:AddComponent(model)
	local poly = Polygon3D.New()
	poly:AddVertex({pos = Vec3(-1, -1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, -1)})
	poly:AddVertex({pos = Vec3(1, -1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, -1)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, -1)})
	poly:AddSubMesh(3)
	poly:BuildBoundingBox()
	poly:Upload()
	ent.model:AddPrimitive(poly)
	ent.model:BuildAABB()
	-- Cast ray away from triangle
	local origin = Vec3(0, 0, -2)
	local direction = Vec3(1, 0, 0) -- Perpendicular to triangle
	local hits = raycast.Cast(origin, direction, 10)
	T(#hits)["=="](0)
	ent:Remove()
end)

T.Test("Raycast cube", function()
	init_render3d()
	-- Create entity with cube mesh
	local ent = ecs.CreateEntity("test_cube", ecs.Get3DWorld())
	ent:AddComponent(transform)
	ent:AddComponent(model)
	local poly = Polygon3D.New()
	poly:CreateCube(1, 1)
	poly:AddSubMesh(#poly.Vertices)
	poly:BuildBoundingBox()
	poly:Upload()
	ent.model:AddPrimitive(poly)
	ent.model:BuildAABB()
	-- Cast ray at center of cube from different directions
	local tests = {
		{origin = Vec3(0, 0, -3), dir = Vec3(0, 0, 1), name = "front"},
		{origin = Vec3(0, 0, 3), dir = Vec3(0, 0, -1), name = "back"},
		{origin = Vec3(3, 0, 0), dir = Vec3(-1, 0, 0), name = "right"},
		{origin = Vec3(-3, 0, 0), dir = Vec3(1, 0, 0), name = "left"},
		{origin = Vec3(0, 3, 0), dir = Vec3(0, -1, 0), name = "top"},
		{origin = Vec3(0, -3, 0), dir = Vec3(0, 1, 0), name = "bottom"},
	}

	for _, test in ipairs(tests) do
		local hits = raycast.Cast(test.origin, test.dir, 10)
		T(#hits, test.name)[">="](1)
	end

	ent:Remove()
end)

T.Test("Raycast with transform", function()
	init_render3d()
	-- Create entity with triangle mesh at offset position
	local ent = ecs.CreateEntity("test_triangle", ecs.Get3DWorld())
	ent:AddComponent(transform)
	ent:AddComponent(model)
	-- Position entity to the right
	ent.transform:SetPosition(Vec3(5, 0, 0))
	local poly = Polygon3D.New()
	poly:AddVertex({pos = Vec3(-1, -1, 0), uv = Vec2(0, 0), normal = Vec3(0, 0, -1)})
	poly:AddVertex({pos = Vec3(1, -1, 0), uv = Vec2(1, 0), normal = Vec3(0, 0, -1)})
	poly:AddVertex({pos = Vec3(0, 1, 0), uv = Vec2(0.5, 1), normal = Vec3(0, 0, -1)})
	poly:AddSubMesh(3)
	poly:BuildBoundingBox()
	poly:Upload()
	ent.model:AddPrimitive(poly)
	ent.model:BuildAABB()
	-- Cast ray at origin (should miss)
	local hits1 = raycast.Cast(Vec3(0, 0, -2), Vec3(0, 0, 1), 10)
	T(#hits1)["=="](0)
	-- Cast ray at offset position (should hit)
	local hits2 = raycast.Cast(Vec3(5, 0, -2), Vec3(0, 0, 1), 10)
	T(#hits2)["=="](1)
	T(hits2[1].entity)["=="](ent)
	ent:Remove()
end)

T.Test("Raycast multiple entities", function()
	init_render3d()
	-- Create two entities at different positions
	local ent1 = ecs.CreateEntity("cube1", ecs.Get3DWorld())
	ent1:AddComponent(transform)
	ent1:AddComponent(model)
	ent1.transform:SetPosition(Vec3(0, 0, 0))
	local poly1 = Polygon3D.New()
	poly1:CreateCube(0.5, 1)
	poly1:AddSubMesh(#poly1.Vertices)
	poly1:BuildBoundingBox()
	poly1:Upload()
	ent1.model:AddPrimitive(poly1)
	ent1.model:BuildAABB()
	local ent2 = ecs.CreateEntity("cube2", ecs.Get3DWorld())
	ent2:AddComponent(transform)
	ent2:AddComponent(model)
	ent2.transform:SetPosition(Vec3(0, 0, 3))
	local poly2 = Polygon3D.New()
	poly2:CreateCube(0.5, 1)
	poly2:AddSubMesh(#poly2.Vertices)
	poly2:BuildBoundingBox()
	poly2:Upload()
	ent2.model:AddPrimitive(poly2)
	ent2.model:BuildAABB()
	-- Cast ray through both
	local origin = Vec3(0, 0, -5)
	local direction = Vec3(0, 0, 1)
	local hits = raycast.Cast(origin, direction, 20)
	-- Should hit both entities, sorted by distance
	T(#hits)["=="](2)
	T(hits[1].entity)["=="](ent1) -- Closer one first
	T(hits[2].entity)["=="](ent2)
	T(hits[1].distance)["<"](hits[2].distance)
	ent1:Remove()
	ent2:Remove()
end)

T.Test("Raycast with filter", function()
	init_render3d()
	-- Create two entities
	local ent1 = ecs.CreateEntity("include_me", ecs.Get3DWorld())
	ent1:AddComponent(transform)
	ent1:AddComponent(model)
	ent1.transform:SetPosition(Vec3(0, 0, 0))
	local poly1 = Polygon3D.New()
	poly1:CreateCube(0.5, 1)
	poly1:AddSubMesh(#poly1.Vertices)
	poly1:BuildBoundingBox()
	poly1:Upload()
	ent1.model:AddPrimitive(poly1)
	ent1.model:BuildAABB()
	local ent2 = ecs.CreateEntity("exclude_me", ecs.Get3DWorld())
	ent2:AddComponent(transform)
	ent2:AddComponent(model)
	ent2.transform:SetPosition(Vec3(0, 0, 3))
	local poly2 = Polygon3D.New()
	poly2:CreateCube(0.5, 1)
	poly2:AddSubMesh(#poly2.Vertices)
	poly2:BuildBoundingBox()
	poly2:Upload()
	ent2.model:AddPrimitive(poly2)
	ent2.model:BuildAABB()
	-- Cast ray with filter that only includes entities with "include" in name
	local origin = Vec3(0, 0, -5)
	local direction = Vec3(0, 0, 1)
	local hits = raycast.Cast(
		origin,
		direction,
		20,
		function(entity)
			return entity:GetName():find("include") ~= nil
		end
	)
	-- Should only hit first entity
	T(#hits)["=="](1)
	T(hits[1].entity)["=="](ent1)
	ent1:Remove()
	ent2:Remove()
end)

T.Test("Raycast CastClosest", function()
	init_render3d()
	local ent = ecs.CreateEntity("test_cube", ecs.Get3DWorld())
	ent:AddComponent(transform)
	ent:AddComponent(model)
	local poly = Polygon3D.New()
	poly:CreateCube(1, 1)
	poly:AddSubMesh(#poly.Vertices)
	poly:BuildBoundingBox()
	poly:Upload()
	ent.model:AddPrimitive(poly)
	ent.model:BuildAABB()
	-- Cast and get only closest
	local hit = raycast.Cast(Vec3(0, 0, -5), Vec3(0, 0, 1), 10)[1]
	T(hit)["~="](nil)
	T(hit.entity)["=="](ent)
	ent:Remove()
end)

T.Test("Raycast CastAny", function()
	init_render3d()
	local ent = ecs.CreateEntity("test_cube", ecs.Get3DWorld())
	ent:AddComponent(transform)
	ent:AddComponent(model)
	local poly = Polygon3D.New()
	poly:CreateCube(1, 1)
	poly:AddSubMesh(#poly.Vertices)
	poly:BuildBoundingBox()
	poly:Upload()
	ent.model:AddPrimitive(poly)
	ent.model:BuildAABB()
	-- Check if ray hits anything
	local hit = raycast.Cast(Vec3(0, 0, -5), Vec3(0, 0, 1), 10)[1] ~= nil
	T(hit)["=="](true)
	-- Check miss
	local miss = raycast.Cast(Vec3(10, 0, -5), Vec3(0, 0, 1), 10)[1] ~= nil
	T(miss)["=="](false)
	ent:Remove()
end)
