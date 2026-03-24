local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function simulate_physics(steps, dt)
	return test_helpers.SimulatePhysics(physics, steps, dt)
end

local function create_brush_primitive(mins, maxs)
	return {
		brush_planes = {
			{normal = Vec3(1, 0, 0), dist = maxs.x},
			{normal = Vec3(-1, 0, 0), dist = -mins.x},
			{normal = Vec3(0, 1, 0), dist = maxs.y},
			{normal = Vec3(0, -1, 0), dist = -mins.y},
			{normal = Vec3(0, 0, 1), dist = maxs.z},
			{normal = Vec3(0, 0, -1), dist = -mins.z},
		},
		aabb = AABB(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z),
	}
end

local function create_brush_room(name, half_extent, height, thickness)
	half_extent = half_extent or 2
	height = height or 2.5
	thickness = thickness or 0.25
	local ent = Entity.New({Name = name or "brush_room"})
	ent:AddComponent("transform")
	local primitives = {
		create_brush_primitive(Vec3(-half_extent, -thickness, -half_extent), Vec3(half_extent, 0, half_extent)),
		create_brush_primitive(Vec3(-half_extent, height, -half_extent), Vec3(half_extent, height + thickness, half_extent)),
		create_brush_primitive(Vec3(-half_extent - thickness, 0, -half_extent), Vec3(-half_extent, height, half_extent)),
		create_brush_primitive(Vec3(half_extent, 0, -half_extent), Vec3(half_extent + thickness, height, half_extent)),
		create_brush_primitive(Vec3(-half_extent, 0, -half_extent - thickness), Vec3(half_extent, height, -half_extent)),
		create_brush_primitive(Vec3(-half_extent, 0, half_extent), Vec3(half_extent, height, half_extent + thickness)),
	}
	local model = {
		Owner = ent,
		Visible = true,
		WorldSpaceVertices = true,
		AABB = AABB(
			-half_extent - thickness,
			-thickness,
			-half_extent - thickness,
			half_extent + thickness,
			height + thickness,
			half_extent + thickness
		),
		Primitives = primitives,
	}
	ent:AddComponent("rigid_body", {
		Shape = MeshShape.New{Model = model},
		MotionType = "static",
		GravityScale = 0,
		WorldGeometry = true,
	})
	return ent
end

local function create_capsule(name, position)
	local ent = Entity.New({Name = name or "brush_capsule"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position or Vec3())
	local body = ent:AddComponent("rigid_body", {
		Shape = CapsuleShape.New(0.35, 2.0),
		GravityScale = 0,
		LinearDamping = 0,
		AngularDamping = 0,
		AirLinearDamping = 0,
		AirAngularDamping = 0,
		CCD = true,
		AutoCCD = false,
		MaxLinearSpeed = 1000,
	})
	return ent, body
end

T.Test3D("Physics sweep collider capsule hits brush room wall", function()
	local room = create_brush_room("brush_room_sweep")
	local ent, body = create_capsule("brush_room_sweep_capsule", Vec3(0, 1.1, 0))
	local hit = physics.SweepCollider(
		body,
		Vec3(0, 1.1, 0),
		Vec3(3.0, 0, 0),
		ent,
		nil,
		{UseRenderMeshes = false}
	)
	T(hit)["~="](nil)
	T(hit.rigid_body)["=="](room.rigid_body)
	T(hit.normal.x)["<"](-0.9)
	T(hit.position.x)[">="](1.98)
	T(hit.position.x)["<="](2.26)
	ent:Remove()
	room:Remove()
end)

T.Test3D("Dynamic capsule with CCD stays inside brush room", function()
	local room = create_brush_room("brush_room_dynamic")
	local ent, body = create_capsule("brush_room_dynamic_capsule", Vec3(0, 1.1, 0))
	body:SetVelocity(Vec3(40, 0, 0))
	simulate_physics(1, 1 / 10)
	local position = body:GetPosition()
	local velocity = body:GetVelocity()
	ent:Remove()
	room:Remove()
	T(position.x)["<"](2.0)
	T(position.x)["<="](1.75)
	T(math.abs(position.z))["<"](0.25)
	T(math.abs(velocity.x))["<"](40)
end)

T.Test3D("Dynamic capsule does not escape brush room over multiple pushes", function()
	local room = create_brush_room("brush_room_multi")
	local ent, body = create_capsule("brush_room_multi_capsule", Vec3(0, 1.1, 0))
	body:SetVelocity(Vec3(20, 0, 0))
	simulate_physics(10, 1 / 60)
	local position = body:GetPosition()
	ent:Remove()
	room:Remove()
	T(position.x)["<"](2.0)
	T(position.x)["<="](1.75)
end)
