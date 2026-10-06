local T = import("test/environment.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CapsuleShape = import("goluwa/physics/shapes/capsule.lua")

T.TestPhysics("Physics transform scale scales box colliders", function()
	local ground = Entity.New{
		transform = {Position = Vec3(0, 0, 0), Scale = Vec3(100, 1, 50)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local size = ground.rigid_body:GetPhysicsShape():GetSize()
	T(size.x)["=="](100)
	T(size.y)["=="](1)
	T(size.z)["=="](50)
	ground:Remove()
end)

T.TestPhysics("Physics transform scale rebuilds colliders when the scale changes", function()
	local box = Entity.New{
		transform = {Position = Vec3(0, 0, 0)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	T(box.rigid_body:GetPhysicsShape():GetSize().x)["=="](1)
	box.transform:SetScale(Vec3(4, 2, 4))
	T(box.rigid_body:GetPhysicsShape():GetSize().x)["=="](4)
	T(box.rigid_body:GetPhysicsShape():GetSize().y)["=="](2)
	box.transform:SetSize(2)
	T(box.rigid_body:GetPhysicsShape():GetSize().x)["=="](8)
	box:Remove()
end)

T.TestPhysics("Physics transform scale scales spheres and capsules", function()
	local sphere = Entity.New{
		transform = {Scale = Vec3(2, 2, 2)},
		rigid_body = {Shape = SphereShape.New(0.5)},
	}
	T(sphere.rigid_body:GetPhysicsShape():GetRadius())["=="](1)
	local capsule = Entity.New{
		transform = {Scale = Vec3(2, 3, 2)},
		rigid_body = {Shape = CapsuleShape.New(0.25, 1)},
	}
	T(capsule.rigid_body:GetPhysicsShape():GetRadius())["=="](0.5)
	T(capsule.rigid_body:GetPhysicsShape():GetHeight())["=="](3)
	sphere:Remove()
	capsule:Remove()
end)

T.TestPhysics("Physics a ball rests on a scaled ground", function()
	local ground = Entity.New{
		transform = {Position = Vec3(0, 0, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local ball = Entity.New{
		transform = {Position = Vec3(30, 5, 20)},
		rigid_body = {Shape = SphereShape.New(0.5)},
	}
	test_helpers.Simulate(240)
	T(math.abs(ball.transform:GetPosition().y - 1))["<"](0.05)
	ball:Remove()
	ground:Remove()
end)
