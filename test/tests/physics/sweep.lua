local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local raycast = import("goluwa/physics/raycast.lua")
local Entity = import("goluwa/ecs/entity.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local AABB = import("goluwa/structs/aabb.lua")

local function create_brush_box_source(mins, maxs)
	local ent = Entity.New({Name = "sweep_world_brush"})
	ent:AddComponent("transform")
	local source = raycast.CreateModelSource{
		{
			Owner = ent,
			Visible = true,
			WorldSpaceVertices = true,
			AABB = AABB(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z),
			Primitives = {
				{
					brush_planes = {
						{normal = Vec3(1, 0, 0), dist = maxs.x},
						{normal = Vec3(-1, 0, 0), dist = -mins.x},
						{normal = Vec3(0, 1, 0), dist = maxs.y},
						{normal = Vec3(0, -1, 0), dist = -mins.y},
						{normal = Vec3(0, 0, 1), dist = maxs.z},
						{normal = Vec3(0, 0, -1), dist = -mins.z},
					},
					aabb = AABB(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z),
				},
			},
		},
	}
	return ent, source
end

local function create_triangle_source()
	local ent = Entity.New({Name = "sweep_world_triangle"})
	ent:AddComponent("transform")
	ent:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-2, 0, -2), uv = Vec2(0, 0), normal = Vec3(0, 1, 0)}
	poly:AddVertex{pos = Vec3(2, 0, -2), uv = Vec2(1, 0), normal = Vec3(0, 1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, 2), uv = Vec2(0.5, 1), normal = Vec3(0, 1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ent.model:AddPrimitive(poly)
	ent.model:BuildAABB()
	local source = raycast.CreateModelSource{ent.model}
	return ent, source
end

T.Test3D("Physics sweep sphere hits brush world", function()
	local source_ent, source = create_brush_box_source(Vec3(-2, 0, -2), Vec3(2, 1, 2))
	physics.SetWorldTraceSource(source)
	local hit = physics.Sweep(Vec3(2.8, 0.5, 0), Vec3(-1.5, 0, 0), 0.5)
	T(hit)["~="](nil)
	T(hit.normal.x)[">"](0.9)
	T(hit.position.x)[">="](1.99)
	T(hit.position.x)["<="](2.01)
	physics.SetWorldTraceSource(nil)
	source_ent:Remove()
end)

T.Test3D("Physics sweep point hits triangle floor", function()
	local ent, source = create_triangle_source()
	physics.SetWorldTraceSource(source)
	local hit = physics.Sweep(Vec3(0, 2, 0), Vec3(0, -3, 0), 0)
	T(hit)["~="](nil)
	T(hit.normal.y)[">"](0.9)
	T(hit.position.y)[">="](-0.01)
	T(hit.position.y)["<="](0.01)
	T(hit.triangle_index)["=="](0)
	physics.SetWorldTraceSource(nil)
	ent:Remove()
end)

T.Test3D("Physics sweep collider box hits triangle floor", function()
	local source_ent, source = create_triangle_source()
	local ent = Entity.New({Name = "sweep_box_body"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 1.5, 0))
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			GravityScale = 0,
		}
	)
	physics.SetWorldTraceSource(source)
	local hit = physics.SweepCollider(body, Vec3(0, 1.5, 0), Vec3(0, -2.0, 0), ent)
	T(hit)["~="](nil)
	T(hit.normal.y)[">"](0.9)
	T(hit.position.y)[">="](-0.01)
	T(hit.position.y)["<="](0.01)
	physics.SetWorldTraceSource(nil)
	body:GetOwner():Remove()
	source_ent:Remove()
end)

T.Test3D("Physics sweep collider capsule hits triangle floor", function()
	local source_ent, source = create_triangle_source()
	local ent = Entity.New({Name = "sweep_capsule_body"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 2.2, 0))
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.5, 2.0),
			GravityScale = 0,
		}
	)
	physics.SetWorldTraceSource(source)
	local hit = physics.SweepCollider(body, Vec3(0, 2.2, 0), Vec3(0, -2.5, 0), ent)
	T(hit)["~="](nil)
	T(hit.normal.y)[">"](0.9)
	T(hit.position.y)[">="](-0.01)
	T(hit.position.y)["<="](0.01)
	physics.SetWorldTraceSource(nil)
	body:GetOwner():Remove()
	source_ent:Remove()
end)

T.Test3D("Physics sweep sphere hits rigid body box", function()
	physics.SetWorldTraceSource(nil)
	local ent = Entity.New({Name = "sweep_body_box"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 0.5, 0))
	ent:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			GravityScale = 0,
		}
	)
	local hit = physics.Sweep(
		Vec3(2.5, 0.5, 0),
		Vec3(-3, 0, 0),
		0.5,
		nil,
		nil,
		{
			IncludeRigidBodies = true,
			IgnoreWorld = true,
			UseRenderMeshes = false,
		}
	)
	T(hit)["~="](nil)
	T(hit.rigid_body)["~="](nil)
	T(hit.normal.x)[">"](0.9)
	ent:Remove()
end)

T.Test3D("Physics sweep sphere hits rigid body sphere", function()
	physics.SetWorldTraceSource(nil)
	local ent = Entity.New({Name = "sweep_body_sphere"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 0, 0))
	ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(0.6),
			Radius = 0.6,
			GravityScale = 0,
		}
	)
	local hit = physics.Sweep(
		Vec3(2.5, 0, 0),
		Vec3(-3, 0, 0),
		0.5,
		nil,
		nil,
		{
			IncludeRigidBodies = true,
			IgnoreWorld = true,
			UseRenderMeshes = false,
		}
	)
	T(hit)["~="](nil)
	T(hit.rigid_body)["~="](nil)
	T(hit.normal.x)[">"](0.9)
	ent:Remove()
end)

T.Test3D("Physics sweep sphere uses moving rigid body previous pose", function()
	physics.SetWorldTraceSource(nil)
	local ent = Entity.New({Name = "sweep_body_sphere_moving"})
	ent:AddComponent("transform")
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(0.6),
			Radius = 0.6,
			GravityScale = 0,
		}
	)
	body.PreviousPosition = Vec3(0, 0, 0)
	body:SetPosition(Vec3(5, 0, 0))
	local hit = physics.Sweep(
		Vec3(2.5, 0, 0),
		Vec3(-5, 0, 0),
		0.5,
		nil,
		nil,
		{
			IncludeRigidBodies = true,
			IgnoreWorld = true,
			UseRenderMeshes = false,
		}
	)
	T(hit)["~="](nil)
	T(hit.rigid_body)["=="](body)
	T(hit.fraction)["<"](0.6)
	ent:Remove()
end)

T.Test3D("Physics sweep collider box hits rigid body box", function()
	physics.SetWorldTraceSource(nil)
	local target = Entity.New({Name = "sweep_target_box"})
	target:AddComponent("transform")
	target.transform:SetPosition(Vec3(0, 0.5, 0))
	target:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			GravityScale = 0,
		}
	)
	local query = Entity.New({Name = "sweep_query_box"})
	query:AddComponent("transform")
	query.transform:SetPosition(Vec3(2.4, 0.5, 0))
	local body = query:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			GravityScale = 0,
		}
	)
	local hit = physics.SweepCollider(
		body,
		Vec3(2.4, 0.5, 0),
		Vec3(-3, 0, 0),
		query,
		nil,
		{
			IncludeRigidBodies = true,
			IgnoreWorld = true,
			UseRenderMeshes = false,
		}
	)
	T(hit)["~="](nil)
	T(hit.rigid_body)["~="](nil)
	T(hit.normal.x)[">"](0.9)
	query:Remove()
	target:Remove()
end)

T.Test3D("Physics sweep collider capsule hits rigid body sphere", function()
	physics.SetWorldTraceSource(nil)
	local target = Entity.New({Name = "sweep_target_sphere"})
	target:AddComponent("transform")
	target.transform:SetPosition(Vec3(0, 0.8, 0))
	target:AddComponent(
		"rigid_body",
		{
			Shape = SphereShape.New(0.6),
			Radius = 0.6,
			GravityScale = 0,
		}
	)
	local query = Entity.New({Name = "sweep_query_capsule"})
	query:AddComponent("transform")
	query.transform:SetPosition(Vec3(2.3, 0.8, 0))
	local body = query:AddComponent(
		"rigid_body",
		{
			Shape = CapsuleShape.New(0.45, 1.8),
			GravityScale = 0,
		}
	)
	local hit = physics.SweepCollider(
		body,
		Vec3(2.3, 0.8, 0),
		Vec3(-3, 0, 0),
		query,
		nil,
		{
			IncludeRigidBodies = true,
			IgnoreWorld = true,
			UseRenderMeshes = false,
		}
	)
	T(hit)["~="](nil)
	T(hit.rigid_body)["~="](nil)
	T(hit.normal.x)[">"](0.9)
	query:Remove()
	target:Remove()
end)

T.Test3D("Physics sweep collider box uses moving rigid body previous pose", function()
	physics.SetWorldTraceSource(nil)
	local target = Entity.New({Name = "sweep_target_box_moving"})
	target:AddComponent("transform")
	local target_body = target:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(0.4, 1, 1.6)),
			GravityScale = 0,
		}
	)
	target_body.PreviousPosition = Vec3(0, 0.5, 0)
	target_body:SetPosition(Vec3(5, 0.5, 0))

	local query = Entity.New({Name = "sweep_query_box_moving_target"})
	query:AddComponent("transform")
	query.transform:SetPosition(Vec3(2.5, 0.5, 0))
	local body = query:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			GravityScale = 0,
		}
	)
	local hit = physics.SweepCollider(
		body,
		Vec3(2.5, 0.5, 0),
		Vec3(-5, 0, 0),
		query,
		nil,
		{
			IncludeRigidBodies = true,
			IgnoreWorld = true,
			UseRenderMeshes = false,
		}
	)
	T(hit)["~="](nil)
	T(hit.rigid_body)["=="](target_body)
	T(hit.fraction)["<"](0.7)
	query:Remove()
	target:Remove()
end)

T.Test3D("Physics sweep collider box handles rotating rigid body target pose", function()
	physics.SetWorldTraceSource(nil)
	local target = Entity.New({Name = "sweep_target_box_rotating"})
	target:AddComponent("transform")
	target.transform:SetPosition(Vec3(0, 0.5, 0))
	local target_body = target:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			GravityScale = 0,
		}
	)
	local previous_rotation = Quat()
	previous_rotation:Identity()
	local current_rotation = Quat()
	current_rotation:Identity()
	current_rotation:RotateYaw(math.pi / 2)
	target_body.PreviousRotation = previous_rotation
	target_body:SetRotation(current_rotation)

	local query = Entity.New({Name = "sweep_query_box_rotating_target"})
	query:AddComponent("transform")
	query.transform:SetPosition(Vec3(2.4, 0.5, 0))
	local body = query:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			GravityScale = 0,
		}
	)
	local hit = physics.SweepCollider(
		body,
		Vec3(2.4, 0.5, 0),
		Vec3(-3, 0, 0),
		query,
		nil,
		{
			IncludeRigidBodies = true,
			IgnoreWorld = true,
			UseRenderMeshes = false,
		}
	)
	T(hit)["~="](nil)
	T(hit.rigid_body)["=="](target_body)
	T(hit.normal.x)[">"](0.7)
	query:Remove()
	target:Remove()
end)

T.Test3D("Physics sweep sphere handles rotating rigid body target pose", function()
	physics.SetWorldTraceSource(nil)
	local target = Entity.New({Name = "sweep_target_box_rotating_sphere_query"})
	target:AddComponent("transform")
	local target_body = target:AddComponent(
		"rigid_body",
		{
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			GravityScale = 0,
		}
	)
	local previous_rotation = Quat()
	previous_rotation:Identity()
	local current_rotation = Quat()
	current_rotation:Identity()
	current_rotation:RotateYaw(math.pi / 2)
	target_body.PreviousRotation = previous_rotation
	target_body:SetRotation(current_rotation)
	local hit = physics.Sweep(
		Vec3(2.5, 0.5, 0),
		Vec3(-3, 0, 0),
		0.5,
		nil,
		nil,
		{
			IncludeRigidBodies = true,
			IgnoreWorld = true,
			UseRenderMeshes = false,
		}
	)
	T(hit)["~="](nil)
	T(hit.rigid_body)["=="](target_body)
	T(hit.normal.x)[">"](0.7)
	target:Remove()
end)