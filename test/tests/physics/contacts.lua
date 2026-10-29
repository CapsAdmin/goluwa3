local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function create_box_ground()
	local ground = Entity.New({Name = "contact_ground"})
	ground:AddComponent("transform")
	ground.transform:SetPosition(Vec3(0, -0.5, 0))
	ground:AddComponent("rigid_body", {Shape = BoxShape.New(Vec3(40, 1, 40)), MotionType = "static", Friction = 0.8})
	return ground
end

local function launch(name, config, height, velocity)
	local entity = Entity.New({Name = name})
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, height, 0))
	local body = entity:AddComponent("rigid_body", config)
	body:SetVelocity(velocity)
	local contacts = {}

	event.AddListener("PhysicsContact", "contacts_test", function(contact)
		if contact.entity_a == entity or contact.entity_b == entity then
			contacts[#contacts + 1] = contact
		end
	end)

	test_helpers.Simulate(180)
	event.RemoveListener("PhysicsContact", "contacts_test")
	return entity, body, contacts
end

local function check_ball(ground)
	local ball, body, contacts = launch(
		"contact_ball",
		{Shape = SphereShape.New(0.25), Radius = 0.25, Friction = 0.8},
		0.6,
		Vec3(4, -2, 0)
	)
	T(#contacts > 40)["=="](true)
	local rolled = 0

	for i = #contacts - 20, #contacts do
		local contact = contacts[i]

		if contact.roll > 1 then
			rolled = rolled + 1
			T(contact.slip < contact.roll * 0.25)["=="](true)
			T(contact.roller)["=="](body)
		end
	end

	T(rolled > 10)["=="](true)
	ball:Remove()
	ground:Remove()
end

T.TestPhysics("A ball launched along a static box rolls without slipping", function()
	check_ball(create_box_ground())
end)

T.TestPhysics("A ball launched along world geometry rolls without slipping", function()
	local ground = test_helpers.CreateFlatGround("contact_world_ground", 40)
	ground.rigid_body:SetFriction(0.8)
	check_ball(ground)
end)

T.TestPhysics("A box pushed along the floor slides without rolling", function()
	local ground = create_box_ground()
	local box, _, contacts = launch("contact_box", {Shape = BoxShape.New(Vec3(0.5, 0.5, 0.5)), Friction = 0.05}, 0.25, Vec3(4, 0, 0))
	local sliding = 0

	for _, contact in ipairs(contacts) do
		if contact.slip > 1 then
			sliding = sliding + 1
			T(contact.roll < contact.slip * 0.1)["=="](true)
		end
	end

	T(sliding > 5)["=="](true)
	box:Remove()
	ground:Remove()
end)
