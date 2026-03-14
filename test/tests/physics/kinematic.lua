local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local sphere_shape = SphereShape.New

local function simulate_physics(steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

local function create_flat_ground(name, extent)
	extent = extent or 8
	local ground = Entity.New({Name = name})
	ground:AddComponent("transform")
	ground:AddComponent("model")
	local poly = Polygon3D.New()
	poly:AddVertex{pos = Vec3(-extent, 0, -extent), uv = Vec2(0, 0), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(0, 0, extent), uv = Vec2(0.5, 1), normal = Vec3(0, -1, 0)}
	poly:AddVertex{pos = Vec3(extent, 0, -extent), uv = Vec2(1, 0), normal = Vec3(0, -1, 0)}
	poly:BuildBoundingBox()
	poly:Upload()
	ground.model:AddPrimitive(poly)
	ground.model:BuildAABB()
	return ground
end

T.Test3D("Kinematic controller implies kinematic motion type", function()
	local ent = Entity.New({Name = "kinematic_motion_type"})
	ent:AddComponent("transform")
	local body = ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
	})
	local controller = ent:AddComponent("kinematic_controller")
	simulate_physics(1)
	T(body:GetMotionType())["=="]("kinematic")
	T(controller:IsControllingKinematicBody())["=="](true)
	ent:Remove()
end)

T.Test3D("Kinematic controller moves body along flat ground", function()
	local ground = create_flat_ground("kinematic_move_ground", 24)
	local ent = Entity.New({Name = "kinematic_move_body"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 3, 0))
	local body = ent:AddComponent("rigid_body", {
		Shape = sphere_shape(0.5),
		LinearDamping = 0,
	})
	local controller = ent:AddComponent("kinematic_controller", {
		Acceleration = 80,
		AirAcceleration = 80,
	})
	simulate_physics(180)
	local settled = ent.transform:GetPosition():Copy()
	T(body:GetGrounded())["=="](true)
	T(settled.y)[">="](0.49)
	T(settled.y)["<="](0.56)
	controller:SetDesiredVelocity(Vec3(6, 0, 0))
	simulate_physics(120)
	local moved = ent.transform:GetPosition()
	T(moved.x)[">"](2.5)
	T(math.abs(moved.z))["<"](0.5)
	T(moved.y)[">="](0.49)
	T(moved.y)["<="](0.58)
	ent:Remove()
	ground:Remove()
end)