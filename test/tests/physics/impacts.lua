local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local convex_hull = import("goluwa/physics/convex_hull.lua")
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

local function create_split_ground()
	local ground = Entity.New({Name = "impact_split_ground"})
	ground:AddComponent("transform")
	local shapes = {}

	for _, x in ipairs({-10, 10}) do
		local poly = Polygon3D.New()
		test_helpers.AddTriangle(poly, Vec3(x - 10, 0, -10), Vec3(x - 10, 0, 10), Vec3(x + 10, 0, -10))
		test_helpers.AddTriangle(poly, Vec3(x + 10, 0, -10), Vec3(x - 10, 0, 10), Vec3(x + 10, 0, 10))
		poly:BuildBoundingBox()
		shapes[#shapes + 1] = {Polygon3D = poly}
	end

	ground:AddComponent("rigid_body", {Shapes = shapes, MotionType = "static", WorldGeometry = true})
	return ground
end

local function create_crate_hull()
	local corners = {}

	for i = 0, 7 do
		corners[i + 1] = Vec3(
			i % 2 == 0 and -0.38 or 0.38,
			i % 4 < 2 and -0.38 or 0.38,
			i < 4 and -0.38 or 0.38
		)
	end

	return ConvexShape.New(convex_hull.BuildFromTriangles(corners))
end

local function land_flat(create_ground, shape, gap)
	local ground = create_ground()
	local crate = Entity.New({Name = "impact_crate"})
	crate:AddComponent("transform")
	crate.transform:SetPosition(Vec3(0.13, 0.38 + gap, 0.21))
	crate:AddComponent("rigid_body", {Shape = shape}):SetVelocity(Vec3(0, -6, 0))
	local first

	event.AddListener("PhysicsImpact", "impacts_test", function(impact)
		first = first or impact
	end)

	test_helpers.Simulate(60)
	event.RemoveListener("PhysicsImpact", "impacts_test")
	local speed = math.sqrt(36 + 2 * physics.instance.Gravity:GetLength() * gap)
	T(first ~= nil)["=="](true)
	T(math.abs(first.speed - speed) / speed)["<"](0.1)
	crate:Remove()
	ground:Remove()
end

T.TestPhysics("A crate landing flat reports its approach speed when the solver contact catching it is rebuilt", function()
	for _, gap in ipairs({0.005, 0.01, 0.015}) do
		land_flat(test_helpers.CreateFlatGround, create_crate_hull(), gap)
		land_flat(test_helpers.CreateFlatGround, BoxShape.New(Vec3(0.76, 0.76, 0.76)), gap)
	end
end)

T.TestPhysics("A crate landing flat reports its approach speed when ground support stops it before any solver contact", function()
	for _, gap in ipairs({0.065, 0.075, 0.115}) do
		land_flat(create_split_ground, create_crate_hull(), gap)
		land_flat(create_split_ground, BoxShape.New(Vec3(0.76, 0.76, 0.76)), gap)
	end
end)
