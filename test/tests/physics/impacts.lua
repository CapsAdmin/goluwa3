local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local DROP = 1.5

local function drop_box(ground)
	local box = Entity.New({Name = "impact_box"})
	box:AddComponent("transform")
	box.transform:SetPosition(Vec3(0, DROP + 0.25, 0))
	box:AddComponent("rigid_body", {Shape = BoxShape.New(Vec3(0.5, 0.5, 0.5))})
	local impacts = {}

	event.AddListener("PhysicsImpact", "impacts_test", function(impact)
		impacts[#impacts + 1] = impact
	end)

	test_helpers.Simulate(240)
	local landed = #impacts
	test_helpers.Simulate(240)
	event.RemoveListener("PhysicsImpact", "impacts_test")
	local first = impacts[1]
	local gravity = physics.instance.Gravity:GetLength()
	T(first ~= nil)["=="](true)
	T(math.abs(first.speed - math.sqrt(2 * gravity * DROP)) / math.sqrt(2 * gravity * DROP))["<"](0.15)
	T(first.entity_a == ground or first.entity_b == ground)["=="](true)
	T(first.entity_a == box or first.entity_b == box)["=="](true)
	T(math.abs(first.normal.y))[">"](0.9)
	T(math.abs(first.position.y))["<"](0.6)

	for i = 2, #impacts do
		T(impacts[i].speed)["<"](first.speed * 0.5)
	end

	T(#impacts)["=="](landed)
	box:Remove()
	ground:Remove()
end

T.TestPhysics("A box dropped on a static box fires one physics impact at its approach speed", function()
	local ground = Entity.New({Name = "impact_ground"})
	ground:AddComponent("transform")
	ground.transform:SetPosition(Vec3(0, -0.5, 0))
	ground:AddComponent("rigid_body", {Shape = BoxShape.New(Vec3(8, 1, 8)), MotionType = "static"})
	drop_box(ground)
end)

T.TestPhysics("A box dropped on world geometry fires one physics impact at its approach speed", function()
	drop_box(test_helpers.CreateFlatGround("impact_world_ground"))
end)
