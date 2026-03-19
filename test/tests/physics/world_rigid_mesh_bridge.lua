local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local world_mesh_contacts = import("goluwa/physics/world_mesh_contacts.lua")
local world_mesh_body = import("goluwa/physics/world_mesh_body.lua")

local function create_triangle_ground(name)
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-6, 0, -6), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, 6), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(6, 0, -6), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	return ground, poly
end

local function create_brush_box_ground(name)
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	local primitive = {
		brush_planes = {
			{normal = Vec3(1, 0, 0), dist = 6},
			{normal = Vec3(-1, 0, 0), dist = 6},
			{normal = Vec3(0, 1, 0), dist = 0},
			{normal = Vec3(0, -1, 0), dist = 1},
			{normal = Vec3(0, 0, 1), dist = 6},
			{normal = Vec3(0, 0, -1), dist = 6},
		},
		aabb = AABB(-6, -1, -6, 6, 0, 6),
	}
	local model = {
		Owner = ground,
		Primitives = {primitive},
		AABB = primitive.aabb,
	}

	function model:GetWorldAABB()
		return self.AABB
	end

	return ground, model, primitive
end

T.Test3D("World mesh proxy bodies expose static mesh shape semantics", function()
	local ground, poly = create_triangle_ground("world_mesh_proxy_ground")
	local primitive = ground.model.Primitives[1]
	local proxy = world_mesh_body.GetPrimitiveBody(ground.model, ground, primitive)
	local bounds = proxy:GetBroadphaseAABB()
	T(proxy:GetShapeType())["=="]("mesh")
	T(proxy:IsStatic())["=="](true)
	T(proxy:IsSolverImmovable())["=="](true)
	T(proxy:HasSolverMass())["=="](false)
	T(proxy:GetOwner())["=="](ground)
	T(proxy:GetPhysicsShape() ~= nil)["=="](true)
	T(bounds.min_x)["<="](-5.9)
	T(bounds.max_x)[">="](5.9)
	T(bounds.min_y)["=="](0)
	T(bounds.max_y)["=="](0)
	ground:Remove()
end)

T.Test3D("World rigid mesh bridge resolves sphere against triangle primitive", function()
	local ground = create_triangle_ground("world_mesh_bridge_sphere_ground")
	local primitive = ground.model.Primitives[1]
	local proxy = world_mesh_body.GetPrimitiveBody(ground.model, ground, primitive)
	local sphere_ent = Entity.New({Name = "world_mesh_bridge_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 0.42, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	local solved = world_mesh_contacts.ResolveBodyAgainstProxyBody(sphere, proxy, 1 / 60)
	local position = sphere:GetPosition()
	sphere_ent:Remove()
	ground:Remove()
	T(solved)["=="](true)
	T(sphere:GetGrounded())["=="](true)
	T(position.y)[">"](0.42)
end)

T.Test3D("World rigid mesh bridge resolves box against triangle primitive", function()
	local ground = create_triangle_ground("world_mesh_bridge_box_ground")
	local primitive = ground.model.Primitives[1]
	local proxy = world_mesh_body.GetPrimitiveBody(ground.model, ground, primitive)
	local box_ent = Entity.New({Name = "world_mesh_bridge_box"})
	box_ent:AddComponent("transform")
	box_ent.transform:SetPosition(Vec3(0, 0.48, 0))
	local box = box_ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			Size = Vec3(1, 1, 1),
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	local solved = world_mesh_contacts.ResolveBodyAgainstProxyBody(box, proxy, 1 / 60)
	box_ent:Remove()
	ground:Remove()
	T(solved)["=="](true)
	T(box:GetGrounded())["=="](true)
end)

T.Test3D("World rigid mesh bridge resolves near-support sphere without penetration", function()
	local ground = create_triangle_ground("world_mesh_bridge_support_sphere_ground")
	local primitive = ground.model.Primitives[1]
	local proxy = world_mesh_body.GetPrimitiveBody(ground.model, ground, primitive)
	local sphere_ent = Entity.New({Name = "world_mesh_bridge_support_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 0.53, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	local solved = world_mesh_contacts.ResolveBodyAgainstProxyBody(sphere, proxy, 1 / 60)
	local position = sphere:GetPosition()
	sphere_ent:Remove()
	ground:Remove()
	T(solved)["=="](true)
	T(sphere:GetGrounded())["=="](true)
	T(position.y)[">="](0.53)
	T(position.y)["<="](0.6)
end)

T.Test3D("World rigid mesh bridge resolves sphere against brush primitive", function()
	local ground, model, primitive = create_brush_box_ground("world_mesh_bridge_brush_ground")
	local proxy = world_mesh_body.GetPrimitiveBody(model, ground, primitive)
	local sphere_ent = Entity.New({Name = "world_mesh_bridge_brush_sphere"})
	sphere_ent:AddComponent("transform")
	sphere_ent.transform:SetPosition(Vec3(0, 0.42, 0))
	local sphere = sphere_ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(0.5),
			Radius = 0.5,
			LinearDamping = 0,
			AngularDamping = 0,
		}
	)
	local solved = world_mesh_contacts.ResolveBodyAgainstProxyBody(sphere, proxy, 1 / 60)
	local position = sphere:GetPosition()
	sphere_ent:Remove()
	ground:Remove()
	T(solved)["=="](true)
	T(sphere:GetGrounded())["=="](true)
	T(position.y)[">"](0.42)
end)
